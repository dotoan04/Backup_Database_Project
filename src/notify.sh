#!/usr/bin/env bash
#
# MBC Database Backup - notification sender
# Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.5 and appendix A
#
# Builds the JSON payload from the current run directory and POSTs it to the
# Power Automate flow "Backup Result Handler".
#
# Usage:
#   notify.sh send                 aggregate result of the finished run
#   notify.sh fatal <line>         script died mid-run (called from the ERR trap)
#   notify.sh service-failure      systemd OnFailure= handler, e.g. OOM kill or
#                                  TimeoutStartSec, where backup.sh never got
#                                  the chance to report anything itself
#
# Exits 0 when the flow accepted the payload, 1 otherwise. The caller must
# treat a failure here as exit code 60 and MUST NOT discard the backup: a
# notification problem is not a backup problem.
#
set -Eeuo pipefail

BASE_DIR="${MBC_BASE_DIR:-/opt/mbc-backup}"
LOG_FILE="${MBC_LOG_FILE:-/var/log/mbc-backup.log}"
STATE_DIR="${MBC_STATE_DIR:-/var/lib/mbc-backup}"
LOG_TAIL_LINES=20

MODE="${1:-send}"
ARG="${2:-}"

set -a
# shellcheck source=/dev/null
[ -f "${BASE_DIR}/.env" ] && source "${BASE_DIR}/.env"
set +a

nlog() { printf '[%s] notify: %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE" >&2; }

# backup.sh exports RUN_DIR. The systemd OnFailure unit does not, so fall back
# to the most recent run directory on disk.
if [ -z "${RUN_DIR:-}" ]; then
  RUN_DIR="$(find "${STATE_DIR}/runs" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
             | sort | tail -1)"
fi

RUN_ID="unknown"
STARTED_AT="$(date -Is)"
HOSTNAME_VAL="$(hostname)"
SCRIPT_VERSION="unknown"
FINISHED_AT="$(date -Is)"
DURATION_SEC=0
STATUS="fatal"
SITES_DIR=""

if [ -n "$RUN_DIR" ] && [ -f "${RUN_DIR}/meta.env" ]; then
  # shellcheck source=/dev/null
  source "${RUN_DIR}/meta.env"
  HOSTNAME_VAL="${RUN_HOSTNAME:-$HOSTNAME_VAL}"
  SITES_DIR="${RUN_DIR}/sites"
  if [ -f "${RUN_DIR}/finished.env" ]; then
    # shellcheck source=/dev/null
    source "${RUN_DIR}/finished.env"
  fi
fi

case "$MODE" in
  send)
    ERROR_NOTE=""
    ;;
  fatal)
    STATUS="fatal"
    FINISHED_AT="$(date -Is)"
    ERROR_NOTE="backup.sh aborted at line ${ARG} - the run is in an unknown state and needs a manual check"
    nlog "sending fatal notification (line ${ARG})"
    ;;
  service-failure)
    STATUS="fatal"
    FINISHED_AT="$(date -Is)"
    ERROR_NOTE="systemd reported mbc-backup.service as failed - backup.sh was killed before it could report (OOM, TimeoutStartSec=7200 or an external kill). Check: journalctl -u mbc-backup -n 200"
    nlog "sending service-failure notification"
    ;;
  *)
    nlog "unknown mode '${MODE}'"
    exit 1
    ;;
esac

if [ -z "${FLOW_WEBHOOK_URL:-}" ]; then
  nlog "FLOW_WEBHOOK_URL is not set - cannot deliver the notification"
  exit 1
fi

LOG_TAIL="$(tail -n "$LOG_TAIL_LINES" "$LOG_FILE" 2>/dev/null || echo "")"

PAYLOAD_FILE="$(mktemp /tmp/mbc-backup-payload.XXXXXX.json)"
# The payload can contain database names and error text; keep it private and
# remove it whatever happens.
chmod 600 "$PAYLOAD_FILE"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

python3 - "$RUN_ID" "$STATUS" "$HOSTNAME_VAL" "$STARTED_AT" "$FINISHED_AT" \
           "$DURATION_SEC" "$SCRIPT_VERSION" "$SITES_DIR" "$LOG_TAIL" \
           "$ERROR_NOTE" > "$PAYLOAD_FILE" <<'PY'
import glob, json, os, sys

(run_id, status, hostname, started_at, finished_at, duration_sec,
 script_version, sites_dir, log_tail, error_note) = sys.argv[1:11]

sites = []
if sites_dir and os.path.isdir(sites_dir):
    for path in sorted(glob.glob(os.path.join(sites_dir, "*.json"))):
        try:
            with open(path, encoding="utf-8") as handle:
                sites.append(json.load(handle))
        except (OSError, ValueError) as exc:
            sites.append({
                "site": os.path.basename(path),
                "status": "failed",
                "step_failed": "notify",
                "file_name": None,
                "size_mb": None,
                "sha256": None,
                "duration_sec": None,
                "encrypted": False,
                "sharepoint_url": None,
                "error": "unreadable site result file: %s" % exc,
            })

success = [s for s in sites if s.get("status") == "success"]
failed = [s for s in sites if s.get("status") != "success"]
total_size = round(sum(s.get("size_mb") or 0 for s in success), 1)

if error_note:
    log_tail = (error_note + "\n" + log_tail).strip()

json.dump({
    "run_id": run_id,
    "status": status,
    "hostname": hostname,
    "started_at": started_at,
    "finished_at": finished_at,
    "duration_sec": int(duration_sec or 0),
    "script_version": script_version,
    "summary": {
        "total_sites": len(sites),
        "success_count": len(success),
        "failed_count": len(failed),
        "total_size_mb": total_size,
    },
    "sites": sites,
    "log_tail": log_tail,
}, sys.stdout, ensure_ascii=False)
PY

# --retry covers transient network problems; --max-time bounds the whole call
# so a hung endpoint cannot keep the backup service running for hours.
RESPONSE_FILE="$(mktemp /tmp/mbc-backup-response.XXXXXX)"
HTTP_CODE="$(curl -sS -X POST "$FLOW_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  --max-time 30 \
  --retry 3 --retry-delay 5 \
  -d @"$PAYLOAD_FILE" \
  -o "$RESPONSE_FILE" -w '%{http_code}' 2>>"$LOG_FILE" || echo "000")"

# curl writes the -w template once per attempt, so with --retry the output can
# be several codes concatenated. Only the last attempt matters.
HTTP_CODE="${HTTP_CODE: -3}"

if [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 300 ]; then
  nlog "payload delivered (HTTP ${HTTP_CODE}, status=${STATUS})"
  rm -f "$RESPONSE_FILE"
  exit 0
fi

# Never echo FLOW_WEBHOOK_URL: it carries the `sig=` secret (spec 6.1).
nlog "delivery failed with HTTP ${HTTP_CODE}: $(head -c 500 "$RESPONSE_FILE" 2>/dev/null || true)"
rm -f "$RESPONSE_FILE"
exit 1
