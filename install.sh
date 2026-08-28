#!/usr/bin/env bash
#
# MBC Database Backup - installer
# Spec: MBC-SPEC-BACKUP-001 v0.2, section 8
#
# Run as root on the VPS, from a checkout of this repository:
#   sudo ./install.sh
#
# Idempotent: safe to re-run after every change. Existing .env and sites.conf
# are never overwritten.
#
set -Eeuo pipefail

BASE_DIR="/opt/mbc-backup"
BACKUP_DIR="/var/backups/mbc"
STATE_DIR="/var/lib/mbc-backup"
LOG_FILE="/var/log/mbc-backup.log"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "This installer must run as root." >&2; exit 1; }

say "Checking prerequisites"
MISSING=()
for tool in docker python3 curl sha256sum openssl find; do
  command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Missing required tools: ${MISSING[*]}" >&2
  exit 1
fi
echo "docker  $(docker --version | head -1)"
echo "python3 $(python3 --version)"
# Only needed when ENCRYPT_ENABLED=true, so this is a note rather than an error.
command -v age >/dev/null 2>&1 \
  && echo "age     $(age --version 2>&1 | head -1)" \
  || echo "age     not installed - required only if ENCRYPT_ENABLED=true (spec 6.3)"

say "Installing scripts into ${BASE_DIR}"
mkdir -p "$BASE_DIR"
chmod 700 "$BASE_DIR"
for f in backup.sh verify.sh notify.sh test-restore.sh upload.py rotate.py graph.py \
         sqlite-snapshot.py discover.py runbook.md; do
  install -m 0755 -o root -g root "${REPO_DIR}/src/${f}" "${BASE_DIR}/${f}"
done
# Sourced and imported, never executed directly.
chmod 0644 "${BASE_DIR}/verify.sh" "${BASE_DIR}/graph.py" "${BASE_DIR}/runbook.md"
install -m 0644 -o root -g root "${REPO_DIR}/src/.env.example" "${BASE_DIR}/.env.example"
install -m 0644 -o root -g root "${REPO_DIR}/src/sites.conf.example" "${BASE_DIR}/sites.conf.example"
install -m 0644 -o root -g root "${REPO_DIR}/src/sites-files.conf.example" "${BASE_DIR}/sites-files.conf.example"

say "Preparing configuration"
if [ ! -f "${BASE_DIR}/.env" ]; then
  install -m 0600 -o root -g root "${REPO_DIR}/src/.env.example" "${BASE_DIR}/.env"
  echo "Created ${BASE_DIR}/.env from the template - fill it in before the first run."
else
  echo "${BASE_DIR}/.env already exists, left untouched."
fi
if [ ! -f "${BASE_DIR}/sites.conf" ]; then
  install -m 0600 -o root -g root "${REPO_DIR}/src/sites.conf.example" "${BASE_DIR}/sites.conf"
  echo "Created ${BASE_DIR}/sites.conf from the survey of 31/07/2026 - check it still matches."
else
  echo "${BASE_DIR}/sites.conf already exists, left untouched."
fi
if [ ! -f "${BASE_DIR}/sites-files.conf" ]; then
  install -m 0600 -o root -g root "${REPO_DIR}/src/sites-files.conf.example" "${BASE_DIR}/sites-files.conf"
  echo "Created ${BASE_DIR}/sites-files.conf - check every path still resolves."
else
  echo "${BASE_DIR}/sites-files.conf already exists, left untouched."
fi
# Credentials and the site inventories are root-only (spec 6.1). The file
# inventory holds paths into other teams' home directories, which is not
# something every account on the box needs to be able to read.
chmod 600 "${BASE_DIR}/.env" "${BASE_DIR}/sites.conf" "${BASE_DIR}/sites-files.conf"
chown root:root "${BASE_DIR}/.env" "${BASE_DIR}/sites.conf" "${BASE_DIR}/sites-files.conf"

say "Creating data directories"
mkdir -p "$BACKUP_DIR" "${STATE_DIR}/runs"
chmod 700 "$BACKUP_DIR" "$STATE_DIR"
chown -R root:root "$BACKUP_DIR" "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
chown root:root "$LOG_FILE"

say "Installing systemd units"
install -m 0644 -o root -g root "${REPO_DIR}/systemd/mbc-backup.service" /etc/systemd/system/
install -m 0644 -o root -g root "${REPO_DIR}/systemd/mbc-backup.timer" /etc/systemd/system/
install -m 0644 -o root -g root "${REPO_DIR}/systemd/mbc-backup-failure.service" /etc/systemd/system/
systemctl daemon-reload

say "Installing logrotate configuration"
install -m 0644 -o root -g root "${REPO_DIR}/logrotate/mbc-backup" /etc/logrotate.d/mbc-backup
logrotate --debug /etc/logrotate.d/mbc-backup >/dev/null && echo "logrotate config parses cleanly"

say "Done"
cat <<'EOF'

Next steps:

  1. Fill in /opt/mbc-backup/.env
       - AZ_TENANT_ID, AZ_CLIENT_ID and either AZ_CLIENT_SECRET or AZ_CERT_PATH
       - SP_SITE_ID          (see docs/azure-ad-setup.md)
       - FLOW_WEBHOOK_URL    (see docs/power-automate-flow1-backup-result-handler.md)

  2. Check /opt/mbc-backup/sites.conf against the containers actually running:
       docker ps --format '{{.Names}}'
     and /opt/mbc-backup/sites-files.conf against the paths on disk:
       cut -d'|' -f3 /opt/mbc-backup/sites-files.conf | grep -v '^#' | xargs -r ls -la

     Or let the host tell you what it is running, and what is not covered yet:
       /opt/mbc-backup/discover.py

  3. Dry run, watching the log:
       /opt/mbc-backup/backup.sh ; echo "exit=$?"
       tail -f /var/log/mbc-backup.log

  4. Enable the schedule once the dry run is clean:
       systemctl enable --now mbc-backup.timer
       systemctl list-timers mbc-backup.timer

  5. Build the two Power Automate flows and the DB_Backup_Log list
     (docs/power-automate-flow1-backup-result-handler.md,
      docs/power-automate-flow2-dead-man-switch.md,
      docs/sharepoint-list-schema.md)

Note: the timer is deliberately NOT enabled automatically. Enable it only
after a manual run has succeeded end to end.
EOF
