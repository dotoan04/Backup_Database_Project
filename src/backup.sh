#!/usr/bin/env bash
#
# MBC Database Backup - main orchestrator
# Spec: MBC-SPEC-BACKUP-001 v0.2, sections 4 and 5.2
#
# Runs as root from systemd (mbc-backup.service). Per site it walks:
#   precheck -> dump -> globals -> verify -> encrypt -> upload -> rotate
# A failure in one site never stops the remaining sites; every failure is
# collected and reported in a single notification at the end.
#
# Exit codes: see section 7.1 of the spec, EXIT_* constants below.
#
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"

BASE_DIR="${MBC_BASE_DIR:-/opt/mbc-backup}"
BACKUP_DIR="${MBC_BACKUP_DIR:-/var/backups/mbc}"
LOG_FILE="${MBC_LOG_FILE:-/var/log/mbc-backup.log}"
STATE_DIR="${MBC_STATE_DIR:-/var/lib/mbc-backup}"
SITES_CONF="${BASE_DIR}/sites.conf"
# File-based databases (SQLite). Optional: absent means there are none.
FILES_CONF="${BASE_DIR}/sites-files.conf"

# --- exit codes (spec 7.1) ---------------------------------------------------
EXIT_OK=0        # every site backed up
EXIT_PARTIAL=10  # some sites failed, or failures of mixed kinds
EXIT_DUMP=20     # dump failed (container dead, wrong credentials)
EXIT_VERIFY=30   # dump is corrupt - most severe, file kept for investigation
EXIT_UPLOAD=40   # SharePoint upload failed, local file kept
EXIT_DISK=50     # not enough free disk, dump deliberately skipped
EXIT_NOTIFY=60   # backup fine but notification could not be delivered
EXIT_FATAL=99    # unexpected error caught by the ERR trap


# --- bootstrap ---------------------------------------------------------------
umask 077
mkdir -p "$BACKUP_DIR" "$STATE_DIR/runs" "$(dirname "$LOG_FILE")"
chmod 700 "$BACKUP_DIR" "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

log()  { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARN: $*"; }

if [ ! -f "${BASE_DIR}/.env" ]; then
  log "FATAL: ${BASE_DIR}/.env not found"
  exit "$EXIT_FATAL"
fi
if [ ! -f "$SITES_CONF" ]; then
  log "FATAL: ${SITES_CONF} not found"
  exit "$EXIT_FATAL"
fi

# Never `set -x` around this: .env holds the webhook signature (spec 6.1).
set -a
# shellcheck source=/dev/null
source "${BASE_DIR}/.env"
set +a

LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-7}"
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-30}"
MIN_DUMP_SIZE_BYTES="${MIN_DUMP_SIZE_BYTES:-10240}"
MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-5120}"
ENCRYPT_ENABLED="${ENCRYPT_ENABLED:-false}"
# An explicitly empty path means the root of SP_LIBRARY_NAME. Only fall back
# when older configurations omit SP_LIBRARY_PATH entirely.
SP_LIBRARY_PATH="${SP_LIBRARY_PATH-DB_Backups}"

TS="$(date +%Y%m%d_%H%M)"
RUN_ID="$TS"
YEAR="${TS:0:4}"
STARTED_AT="$(date -Is)"
STARTED_EPOCH="$(date +%s)"

RUN_DIR="${STATE_DIR}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}/sites"
export RUN_DIR

cat > "${RUN_DIR}/meta.env" <<EOF
RUN_ID="${RUN_ID}"
STARTED_AT="${STARTED_AT}"
RUN_HOSTNAME="$(hostname)"
SCRIPT_VERSION="${SCRIPT_VERSION}"
EOF

# From here on any unhandled error is a fatal: notify and bail out loudly
# rather than exiting 0 and letting everyone believe the backup ran.
#
# The marker file is not optional. With `set -E` the trap is inherited by
# command substitutions, where `exit 99` only ends the subshell; the parent
# then sees status 99 and fires the same trap again. Without the guard one
# fault produces a burst of identical FATAL alerts.
FATAL_MARKER="${RUN_DIR}/.fatal-notified"
on_fatal() {
  local rc=$1 line=$2
  log "FATAL: unhandled error at line ${line} (status ${rc})"
  if [ ! -e "$FATAL_MARKER" ]; then
    : > "$FATAL_MARKER"
    "${BASE_DIR}/notify.sh" fatal "$line" || true
  fi
  exit 99
}
trap 'on_fatal "$?" "$LINENO"' ERR

# shellcheck source=verify.sh
source "${BASE_DIR}/verify.sh"

log "=== backup run ${RUN_ID} started (script ${SCRIPT_VERSION}) ==="

# --- helpers -----------------------------------------------------------------

# Read POSTGRES_PASSWORD out of the container environment (spec 5.1.1). Avoids
# keeping a second copy of 9 passwords, and avoids depending on the per-project
# filesystem permissions of /home/<project>/.env.
get_pgpass() {
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1
}

# One JSON file per site, assembled into the final payload by notify.sh.
write_site_result() {
  local site="$1" status="$2" step="$3" file_name="$4" size_mb="$5" \
        sha="$6" duration="$7" encrypted="$8" url="$9" error="${10}"
  python3 - "$site" "$status" "$step" "$file_name" "$size_mb" "$sha" \
             "$duration" "$encrypted" "$url" "$error" \
    > "${RUN_DIR}/sites/${SITE_INDEX}_${site}.json" <<'PY'
import json, sys

site, status, step, file_name, size_mb, sha, duration, encrypted, url, error = sys.argv[1:11]


def nullable(value):
    return value if value else None


json.dump({
    "site": site,
    "status": status,
    "step_failed": nullable(step),
    "file_name": nullable(file_name),
    # Already rounded by bytes_to_mb, which keeps extra decimals for files too
    # small to show up at one. Rounding again here would undo that.
    "size_mb": float(size_mb) if size_mb else None,
    "sha256": nullable(sha),
    "duration_sec": int(duration) if duration else None,
    "encrypted": encrypted == "true",
    "sharepoint_url": nullable(url),
    "error": nullable(error),
}, sys.stdout, ensure_ascii=False)
PY
}

# Record a site failure and move on. Callers must `continue` right after.
fail() {
  local site="$1" step="$2" code="$3" msg="$4"
  log "ERROR [${site}] step=${step}: ${msg}"
  FAIL_CODES+=("$code")
  write_site_result "$site" "failed" "$step" "$SITE_FILE_NAME" "$SITE_SIZE_MB" \
                    "$SITE_SHA" "$(( $(date +%s) - SITE_START ))" \
                    "$SITE_ENCRYPTED" "" "$msg"
}

# One decimal is right for a 40 MB pg_dump but rounds a SQLite snapshot of a
# few hundred KB to 0.0, which reads in the notification as an empty backup.
# The size floors guarantee a real backup is never small enough to round to
# zero at three decimals.
bytes_to_mb() {
  python3 -c 'import sys
mb = int(sys.argv[1]) / 1048576
print(round(mb, 1) if round(mb, 1) > 0 else round(mb, 3))' "$1"
}

# maybe_encrypt <artifact> (spec 6.3)
# Shared by every site type. On success ENCRYPT_RESULT holds the path to
# upload - the original when encryption is off, the .age file when it is on.
# On failure ENCRYPT_ERROR holds the reason and the return status is 1.
maybe_encrypt() {
  local artifact="$1"
  ENCRYPT_RESULT="$artifact"
  ENCRYPT_ERROR=""
  [ "$ENCRYPT_ENABLED" = "true" ] || return 0

  if ! command -v age >/dev/null 2>&1; then
    ENCRYPT_ERROR="ENCRYPT_ENABLED=true but 'age' is not installed"
    return 1
  fi
  if [ -z "${AGE_RECIPIENT:-}" ]; then
    ENCRYPT_ERROR="ENCRYPT_ENABLED=true but AGE_RECIPIENT is empty"
    return 1
  fi
  if ! age -r "$AGE_RECIPIENT" -o "${artifact}.age" "$artifact" 2>>"$LOG_FILE"; then
    rm -f "${artifact}.age"
    ENCRYPT_ERROR="age encryption failed"
    return 1
  fi
  shred -u "$artifact" 2>>"$LOG_FILE" || rm -f "$artifact"
  ENCRYPT_RESULT="${artifact}.age"
  SITE_ENCRYPTED="true"
  return 0
}

# --- main loop ---------------------------------------------------------------

declare -a FAIL_CODES=()
declare -a OK_SITES=()

# `|| true` is load-bearing. When the file holds nothing but comments, grep
# exits 1; with `set -E` the ERR trap is inherited by the process substitution
# and fires there, and because log() writes through tee its FATAL line lands on
# the subshell's stdout - which is mapfile's input. The result is a phantom
# site whose name is a log line, plus a spurious FATAL alert. An inventory that
# is empty or fully commented out is a normal state, not an error.
read_inventory() {
  sed -e 's/\r$//' "$1" | grep -vE '^[[:space:]]*(#|$)' || true
}

mapfile -t SITE_LINES < <(read_inventory "$SITES_CONF")

# File-based databases are optional and live in their own inventory, so the
# nine PostgreSQL lines keep the format they already have.
declare -a FILE_LINES=()
if [ -f "$FILES_CONF" ]; then
  mapfile -t FILE_LINES < <(read_inventory "$FILES_CONF")
fi

TOTAL_SITES=$(( ${#SITE_LINES[@]} + ${#FILE_LINES[@]} ))
log "loaded ${#SITE_LINES[@]} PostgreSQL sites from ${SITES_CONF} and ${#FILE_LINES[@]} file databases from ${FILES_CONF}"

# Shared across both loops so the per-site JSON files sort in run order.
SITE_NUM=0
for LINE in "${SITE_LINES[@]}"; do
  SITE_NUM=$((SITE_NUM + 1))
  SITE_INDEX="$(printf '%02d' "$SITE_NUM")"

  IFS='|' read -r SITE CONTAINER DB_USER DB_NAME <<< "$LINE"
  SITE="${SITE//[[:space:]]/}"
  CONTAINER="${CONTAINER//[[:space:]]/}"
  DB_USER="${DB_USER//[[:space:]]/}"
  DB_NAME="${DB_NAME//[[:space:]]/}"

  # Per-site accumulators, read back by fail() if the site dies mid-way.
  SITE_START="$(date +%s)"
  SITE_FILE_NAME=""
  SITE_SIZE_MB=""
  SITE_SHA=""
  SITE_ENCRYPTED="false"

  if [ -z "$SITE" ] || [ -z "$CONTAINER" ] || [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
    log "ERROR: malformed sites.conf line: ${LINE}"
    FAIL_CODES+=("$EXIT_PARTIAL")
    continue
  fi

  log "--- [${SITE_NUM}/${TOTAL_SITES}] ${SITE} (container=${CONTAINER} db=${DB_NAME}) ---"

  # ---------- 1. preconditions (spec 5.2.2) ----------
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q '^true$'; then
    fail "$SITE" "precheck" "$EXIT_PARTIAL" "container ${CONTAINER} is not running"
    continue
  fi

  # Dumping into a full filesystem stops PostgreSQL writing WAL, which takes
  # production down. Refusing to dump is strictly better than that.
  FREE_MB="$(df -Pm "$BACKUP_DIR" | awk 'NR==2{print $4}')"
  if [ "$FREE_MB" -le "$MIN_FREE_DISK_MB" ]; then
    fail "$SITE" "precheck" "$EXIT_DISK" \
         "free disk ${FREE_MB}MB is at or below threshold ${MIN_FREE_DISK_MB}MB - dump skipped"
    continue
  fi

  PGPASS="$(get_pgpass "$CONTAINER" || true)"
  if [ -z "$PGPASS" ]; then
    fail "$SITE" "precheck" "$EXIT_PARTIAL" \
         "POSTGRES_PASSWORD not present in the environment of ${CONTAINER}"
    continue
  fi

  # ---------- 2. dump (spec 5.2.3) ----------
  OUTFILE="${BACKUP_DIR}/${SITE}_backup_${TS}.dump"
  SITE_FILE_NAME="$(basename "$OUTFILE")"

  log "[${SITE}] pg_dump -Fc -> ${SITE_FILE_NAME}"
  if ! docker exec -e PGPASSWORD="$PGPASS" "$CONTAINER" \
        pg_dump -U "$DB_USER" -d "$DB_NAME" \
                -Fc --no-owner --no-privileges --verbose \
        > "$OUTFILE" 2>>"$LOG_FILE"; then
    # Keep the partial file as evidence but rename it so nothing can mistake
    # it for a usable backup.
    [ -f "$OUTFILE" ] && mv -f "$OUTFILE" "${OUTFILE}.partial"
    fail "$SITE" "dump" "$EXIT_DUMP" \
         "pg_dump failed for ${DB_NAME} in ${CONTAINER} - see ${LOG_FILE}"
    continue
  fi

  SIZE_BYTES="$(stat -c%s "$OUTFILE")"
  SITE_SIZE_MB="$(bytes_to_mb "$SIZE_BYTES")"
  log "[${SITE}] dump ok: ${SIZE_BYTES} bytes (${SITE_SIZE_MB} MB)"

  # ---------- 3. globals (spec 5.2.4) ----------
  # pg_dump carries no roles/passwords/tablespaces. Without these a restore
  # stops on missing-role errors. Non-superuser db users cannot run
  # pg_dumpall, so treat a failure as a warning, not a lost backup.
  GLOBALS_FILE="${BACKUP_DIR}/${SITE}_globals_${TS}.sql.gz"
  if docker exec -e PGPASSWORD="$PGPASS" "$CONTAINER" \
       pg_dumpall -U "$DB_USER" --globals-only 2>>"$LOG_FILE" \
       | gzip > "$GLOBALS_FILE"; then
    log "[${SITE}] globals ok: $(stat -c%s "$GLOBALS_FILE") bytes"
  else
    rm -f "$GLOBALS_FILE"
    GLOBALS_FILE=""
    warn "[${SITE}] pg_dumpall --globals-only failed (needs a superuser role) - roles will have to be recreated by hand on restore"
  fi

  # ---------- 4. verify - mandatory, never skipped (spec 5.3.1) ----------
  if ! VMSG="$(verify_dump_readable "$CONTAINER" "$OUTFILE")"; then
    fail "$SITE" "verify" "$EXIT_VERIFY" "$VMSG"
    continue   # file deliberately kept for investigation, and not uploaded
  fi
  if ! VMSG="$(verify_min_size "$OUTFILE" "$MIN_DUMP_SIZE_BYTES")"; then
    fail "$SITE" "verify" "$EXIT_VERIFY" "$VMSG"
    continue
  fi
  SHRINK_WARN="$(verify_not_shrunk "$BACKUP_DIR" "$SITE" "$SIZE_BYTES" "$TS")"
  [ -n "$SHRINK_WARN" ] && warn "[${SITE}] ${SHRINK_WARN}"

  PLAIN_SHA="$(sha256_of "$OUTFILE")"
  SITE_SHA="$PLAIN_SHA"
  log "[${SITE}] verify ok, sha256=${PLAIN_SHA:0:12}..."

  # ---------- 5. encrypt (spec 6.3) ----------
  if ! maybe_encrypt "$OUTFILE"; then
    fail "$SITE" "encrypt" "$EXIT_PARTIAL" "$ENCRYPT_ERROR"
    continue
  fi
  ARTIFACT="$ENCRYPT_RESULT"
  if [ "$SITE_ENCRYPTED" = "true" ]; then
    SITE_FILE_NAME="$(basename "$ARTIFACT")"
    log "[${SITE}] encrypted -> ${SITE_FILE_NAME}"
  fi

  # Checksum of exactly what gets uploaded, in `sha256sum -c` format so the
  # runbook can verify it without extra steps.
  write_checksum "$ARTIFACT"
  ARTIFACT_SHA="$(sha256_of "$ARTIFACT")"

  # ---------- 6. metadata (spec 5.2.5) ----------
  PG_VERSION="$(docker exec -e PGPASSWORD="$PGPASS" "$CONTAINER" \
                  psql -U "$DB_USER" -d "$DB_NAME" -tAc 'SHOW server_version' 2>/dev/null \
                | tr -d '[:space:]' || true)"
  PG_DUMP_VERSION="$(docker exec "$CONTAINER" pg_dump --version 2>/dev/null \
                     | awk '{print $NF}' || true)"
  METAFILE="${BACKUP_DIR}/${SITE}_backup_${TS}.meta.json"
  python3 - "$SITE" "$CONTAINER" "$DB_NAME" "${PG_VERSION:-unknown}" \
             "${PG_DUMP_VERSION:-unknown}" "$STARTED_AT" "$SIZE_BYTES" \
             "$PLAIN_SHA" "$ARTIFACT_SHA" "$SITE_ENCRYPTED" "$SCRIPT_VERSION" \
             "$(basename "$ARTIFACT")" > "$METAFILE" <<'PY'
import json, sys

(site, container, database, pg_version, pg_dump_version, created_at, size_bytes,
 sha_plain, sha_artifact, encrypted, script_version, artifact_name) = sys.argv[1:13]

is_encrypted = encrypted == "true"
json.dump({
    "site": site,
    "container": container,
    "database": database,
    "pg_version": pg_version,
    "dump_format": "custom",
    "pg_dump_version": pg_dump_version,
    "created_at": created_at,
    "size_bytes": int(size_bytes),
    # sha256 is always the hash of the plaintext dump: that is what a restore
    # can check after decrypting. sha256_uploaded covers the uploaded artifact.
    "sha256": sha_plain,
    "sha256_uploaded": sha_artifact,
    "uploaded_file": artifact_name,
    "encrypted": is_encrypted,
    "script_version": script_version,
}, sys.stdout, indent=2, ensure_ascii=False)
PY
  log "[${SITE}] metadata written (pg ${PG_VERSION:-unknown}, pg_dump ${PG_DUMP_VERSION:-unknown})"

  # ---------- 7. upload (spec 5.4) ----------
  UPLOAD_ARGS=(--site "$SITE" --year "$YEAR"
               --file "$ARTIFACT"
               --file "${ARTIFACT}.sha256"
               --file "$METAFILE")
  [ -n "$GLOBALS_FILE" ] && UPLOAD_ARGS+=(--file "$GLOBALS_FILE")

  if ! UPLOAD_JSON="$("${BASE_DIR}/upload.py" "${UPLOAD_ARGS[@]}" 2>>"$LOG_FILE")"; then
    fail "$SITE" "upload" "$EXIT_UPLOAD" \
         "SharePoint upload failed - local files kept in ${BACKUP_DIR}"
    continue
  fi
  SITE_URL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("primary_web_url") or "")' "$UPLOAD_JSON")"
  log "[${SITE}] upload ok -> ${SITE_URL:-no url returned}"

  # ---------- 8. local rotation (spec 5.7.1) ----------
  # Only reached once upload AND post-upload verification succeeded, so old
  # local copies are safe to drop.
  find "$BACKUP_DIR" -maxdepth 1 -type f \
       \( -name "${SITE}_backup_*" -o -name "${SITE}_globals_*" \) \
       -mtime "+${LOCAL_RETENTION_DAYS}" -delete 2>>"$LOG_FILE" || \
    warn "[${SITE}] local rotation reported an error"

  OK_SITES+=("$SITE")
  write_site_result "$SITE" "success" "" "$SITE_FILE_NAME" "$SITE_SIZE_MB" \
                    "$ARTIFACT_SHA" "$(( $(date +%s) - SITE_START ))" \
                    "$SITE_ENCRYPTED" "$SITE_URL" ""
  log "[${SITE}] done in $(( $(date +%s) - SITE_START ))s"
done

# --- file-based databases (SQLite) -------------------------------------------
# Same contract as the loop above: one result JSON per site in RUN_DIR, the
# same file naming, the same SharePoint layout. Everything downstream -
# notify.sh, rotate.py, both Power Automate flows - therefore needs no change.
#
# These databases belong to applications that are not part of this project.
# The whole path is read-only: no container is stopped, no file of theirs is
# written, nothing needs to be installed on their side.
for LINE in "${FILE_LINES[@]}"; do
  SITE_NUM=$((SITE_NUM + 1))
  SITE_INDEX="$(printf '%02d' "$SITE_NUM")"

  IFS='|' read -r SITE ENGINE DB_PATH <<< "$LINE"
  SITE="${SITE//[[:space:]]/}"
  ENGINE="${ENGINE//[[:space:]]/}"
  # Trim the ends only. Unlike a container name, a filesystem path is allowed
  # to contain spaces.
  DB_PATH="$(printf '%s' "$DB_PATH" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  SITE_START="$(date +%s)"
  SITE_FILE_NAME=""
  SITE_SIZE_MB=""
  SITE_SHA=""
  SITE_ENCRYPTED="false"

  if [ -z "$SITE" ] || [ -z "$ENGINE" ] || [ -z "$DB_PATH" ]; then
    log "ERROR: malformed sites-files.conf line: ${LINE}"
    FAIL_CODES+=("$EXIT_PARTIAL")
    continue
  fi
  if [ "$ENGINE" != "sqlite" ]; then
    fail "$SITE" "precheck" "$EXIT_PARTIAL" \
         "unsupported engine '${ENGINE}' - only sqlite is implemented"
    continue
  fi

  log "--- [${SITE_NUM}/${TOTAL_SITES}] ${SITE} (sqlite ${DB_PATH}) ---"

  # ---------- 1. preconditions ----------
  FREE_MB="$(df -Pm "$BACKUP_DIR" | awk 'NR==2{print $4}')"
  if [ "$FREE_MB" -le "$MIN_FREE_DISK_MB" ]; then
    fail "$SITE" "precheck" "$EXIT_DISK" \
         "free disk ${FREE_MB}MB is at or below threshold ${MIN_FREE_DISK_MB}MB - snapshot skipped"
    continue
  fi

  # ---------- 2. snapshot and verify ----------
  # sqlite-snapshot.py does both in one pass: it has to open the database to
  # copy it, so checking the copy afterwards costs nothing extra. Its exit
  # codes are the same 20/30 used here.
  OUTFILE="${BACKUP_DIR}/${SITE}_backup_${TS}.db"
  SITE_FILE_NAME="$(basename "$OUTFILE")"
  PREV_META="$(ls -t "${BACKUP_DIR}/${SITE}_backup_"*.meta.json 2>/dev/null \
               | grep -v "_${TS}\.meta\.json$" | head -1 || true)"

  log "[${SITE}] sqlite online backup -> ${SITE_FILE_NAME}"
  if SNAP_JSON="$("${BASE_DIR}/sqlite-snapshot.py" \
                    --source "$DB_PATH" --dest "$OUTFILE" \
                    --previous-meta "$PREV_META" 2>>"$LOG_FILE")"; then
    SNAP_RC=0
  else
    SNAP_RC=$?
  fi

  if [ "$SNAP_RC" -ne 0 ]; then
    SNAP_ERR="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1] or "{}").get("error",""))' \
                "$SNAP_JSON" 2>/dev/null || true)"
    if [ "$SNAP_RC" -eq "$EXIT_VERIFY" ]; then
      # File deliberately kept for investigation, and never uploaded.
      fail "$SITE" "verify" "$EXIT_VERIFY" "${SNAP_ERR:-snapshot failed verification}"
    else
      fail "$SITE" "snapshot" "$EXIT_DUMP" "${SNAP_ERR:-could not snapshot ${DB_PATH}}"
    fi
    continue
  fi

  SIZE_BYTES="$(stat -c%s "$OUTFILE")"
  SITE_SIZE_MB="$(bytes_to_mb "$SIZE_BYTES")"
  PLAIN_SHA="$(sha256_of "$OUTFILE")"
  SITE_SHA="$PLAIN_SHA"
  log "[${SITE}] snapshot ok: ${SIZE_BYTES} bytes, sha256=${PLAIN_SHA:0:12}..."

  # ---------- 3. encrypt (spec 6.3) ----------
  if ! maybe_encrypt "$OUTFILE"; then
    fail "$SITE" "encrypt" "$EXIT_PARTIAL" "$ENCRYPT_ERROR"
    continue
  fi
  ARTIFACT="$ENCRYPT_RESULT"
  if [ "$SITE_ENCRYPTED" = "true" ]; then
    SITE_FILE_NAME="$(basename "$ARTIFACT")"
    log "[${SITE}] encrypted -> ${SITE_FILE_NAME}"
  fi

  write_checksum "$ARTIFACT"
  ARTIFACT_SHA="$(sha256_of "$ARTIFACT")"

  # ---------- 4. metadata (spec 5.2.5) ----------
  # Row counts are part of the metadata because they are what the next run
  # compares against: SQLite reuses freed pages, so a database can lose every
  # row without the file shrinking by a single byte.
  METAFILE="${BACKUP_DIR}/${SITE}_backup_${TS}.meta.json"
  python3 - "$SNAP_JSON" "$SITE" "$STARTED_AT" "$PLAIN_SHA" "$ARTIFACT_SHA" \
             "$SITE_ENCRYPTED" "$SCRIPT_VERSION" "$(basename "$ARTIFACT")" \
    > "$METAFILE" <<'PY'
import json, os, sys

snap = json.loads(sys.argv[1])
(site, created_at, sha_plain, sha_artifact, encrypted,
 script_version, artifact_name) = sys.argv[2:9]

json.dump({
    "site": site,
    "engine": "sqlite",
    "source_path": snap["source"],
    "database": os.path.basename(snap["source"]),
    "dump_format": "sqlite-online-backup",
    "sqlite_version": snap["sqlite_version"],
    "journal_mode": snap["journal_mode"],
    "page_size": snap["page_size"],
    "created_at": created_at,
    "size_bytes": snap["size_bytes"],
    "tables": snap["tables"],
    "total_rows": snap["total_rows"],
    "integrity_check": snap["integrity"],
    "sha256": sha_plain,
    "sha256_uploaded": sha_artifact,
    "uploaded_file": artifact_name,
    "encrypted": encrypted == "true",
    "script_version": script_version,
}, sys.stdout, indent=2, ensure_ascii=False)
PY
  log "[${SITE}] metadata written (sqlite $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["total_rows"])' "$SNAP_JSON") rows)"

  # ---------- 5. upload (spec 5.4) ----------
  if ! UPLOAD_JSON="$("${BASE_DIR}/upload.py" --site "$SITE" --year "$YEAR" \
                        --file "$ARTIFACT" \
                        --file "${ARTIFACT}.sha256" \
                        --file "$METAFILE" 2>>"$LOG_FILE")"; then
    fail "$SITE" "upload" "$EXIT_UPLOAD" \
         "SharePoint upload failed - local files kept in ${BACKUP_DIR}"
    continue
  fi
  SITE_URL="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("primary_web_url") or "")' "$UPLOAD_JSON")"
  log "[${SITE}] upload ok -> ${SITE_URL:-no url returned}"

  # ---------- 6. local rotation (spec 5.7.1) ----------
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SITE}_backup_*" \
       -mtime "+${LOCAL_RETENTION_DAYS}" -delete 2>>"$LOG_FILE" || \
    warn "[${SITE}] local rotation reported an error"

  OK_SITES+=("$SITE")
  write_site_result "$SITE" "success" "" "$SITE_FILE_NAME" "$SITE_SIZE_MB" \
                    "$ARTIFACT_SHA" "$(( $(date +%s) - SITE_START ))" \
                    "$SITE_ENCRYPTED" "$SITE_URL" ""
  log "[${SITE}] done in $(( $(date +%s) - SITE_START ))s"
done

# --- SharePoint rotation (spec 5.7.2) ----------------------------------------
# Once per run, not per site: rotate.py walks sites.conf itself.
if ! "${BASE_DIR}/rotate.py" --days "$REMOTE_RETENTION_DAYS" >>"$LOG_FILE" 2>&1; then
  warn "SharePoint rotation failed - old files may exceed retention"
fi

# --- ship the log to SharePoint (spec 5.4.6, _logs/) -------------------------
# Best effort. If the host later becomes unreachable, this copy is the only
# record of what the last runs actually did.
LOG_COPY="${BACKUP_DIR}/mbc-backup-${TS:0:8}.log"
if cp "$LOG_FILE" "$LOG_COPY" 2>/dev/null; then
  if ! "${BASE_DIR}/upload.py" --remote-folder "${SP_LIBRARY_PATH}/_logs/${TS:0:4}-${TS:4:2}" \
        --file "$LOG_COPY" >>"$LOG_FILE" 2>&1; then
    warn "could not upload the log copy to SharePoint"
  fi
  rm -f "$LOG_COPY"
fi

# --- roll up the exit code (spec 7.1) ----------------------------------------
# A single kind of failure reports that specific code; mixed kinds report 10,
# because no single code describes the run.
FINAL_CODE="$EXIT_OK"
if [ ${#FAIL_CODES[@]} -gt 0 ]; then
  UNIQUE="$(printf '%s\n' "${FAIL_CODES[@]}" | sort -u)"
  if [ "$(printf '%s\n' "$UNIQUE" | wc -l)" -eq 1 ]; then
    FINAL_CODE="$UNIQUE"
  else
    FINAL_CODE="$EXIT_PARTIAL"
  fi
fi

FINISHED_AT="$(date -Is)"
DURATION=$(( $(date +%s) - STARTED_EPOCH ))
if [ "$FINAL_CODE" -eq "$EXIT_OK" ]; then STATUS="success"; else STATUS="failed"; fi

cat > "${RUN_DIR}/finished.env" <<EOF
FINISHED_AT="${FINISHED_AT}"
DURATION_SEC="${DURATION}"
STATUS="${STATUS}"
EXIT_CODE="${FINAL_CODE}"
TOTAL_SITES="${TOTAL_SITES}"
EOF

log "=== run ${RUN_ID} finished: ${#OK_SITES[@]}/${TOTAL_SITES} ok, status=${STATUS}, exit=${FINAL_CODE}, ${DURATION}s ==="

# --- notify (spec 5.5) -------------------------------------------------------
# A failing notification must never destroy an otherwise good backup result,
# so this is reported through exit code 60 and nothing else.
if ! "${BASE_DIR}/notify.sh" send; then
  warn "notification could not be delivered - the dead-man switch will report this tomorrow"
  [ "$FINAL_CODE" -eq "$EXIT_OK" ] && FINAL_CODE="$EXIT_NOTIFY"
fi

# Keep two weeks of run directories for debugging.
find "${STATE_DIR}/runs" -maxdepth 1 -mindepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null || true

exit "$FINAL_CODE"
