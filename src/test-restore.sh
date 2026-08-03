#!/usr/bin/env bash
#
# MBC Database Backup - quarterly restore drill
# Spec: MBC-SPEC-BACKUP-001 v0.2, sections 5.3.2 and 11.1 step 6
#
# Automatic verification only proves the dump is READABLE. It says nothing
# about whether it RESTORES and whether the data is right. This script proves
# that, into a throwaway container - never into production.
#
# Usage:
#   ./test-restore.sh <sitename> [dumpfile]
#   ./test-restore.sh mbc_ocr
#   ./test-restore.sh mbc360 /var/backups/mbc/mbc360_backup_20260731_0200.dump
#
# Without a dumpfile the newest local dump for that site is used.
#
set -Eeuo pipefail

BASE_DIR="${MBC_BASE_DIR:-/opt/mbc-backup}"
BACKUP_DIR="${MBC_BACKUP_DIR:-/var/backups/mbc}"
SCRATCH="pg-scratch-restore-test"
SCRATCH_PASSWORD="temp_test_pw"

usage() { sed -n '2,20p' "$0"; exit 2; }
[ $# -ge 1 ] || usage
SITE="$1"
DUMPFILE="${2:-}"

# pg_restore cannot read a dump produced by a NEWER pg_dump, and mbc_ocr needs
# the pgvector image because its dump contains CREATE EXTENSION vector.
# Restoring mbc_ocr into postgres:16-alpine fails (spec 11.1 step 6).
restore_image_for() {
  case "$1" in
    timesheet_misa) echo "postgres:15-alpine" ;;
    mbc360)         echo "postgres:17-alpine" ;;
    mbc_ocr)        echo "pgvector/pgvector:pg16" ;;
    *)              echo "postgres:16-alpine" ;;
  esac
}

if [ -z "$DUMPFILE" ]; then
  DUMPFILE="$(ls -t "${BACKUP_DIR}/${SITE}_backup_"*.dump 2>/dev/null | head -1 || true)"
fi
if [ -z "$DUMPFILE" ] || [ ! -f "$DUMPFILE" ]; then
  echo "No dump found for '${SITE}'." >&2
  echo "Download one from SharePoint first, or pass the path as the second argument." >&2
  echo "Encrypted (.age) backups must be decrypted before running this." >&2
  exit 1
fi

IMAGE="$(restore_image_for "$SITE")"
echo "site      : ${SITE}"
echo "dump      : ${DUMPFILE} ($(stat -c%s "$DUMPFILE") bytes)"
echo "image     : ${IMAGE}"
echo

if [ -f "${DUMPFILE}.sha256" ]; then
  echo "--- checksum ---"
  ( cd "$(dirname "$DUMPFILE")" && sha256sum -c "$(basename "$DUMPFILE").sha256" )
  echo
fi

if [ -f "${DUMPFILE%.dump}.meta.json" ]; then
  echo "--- metadata ---"
  cat "${DUMPFILE%.dump}.meta.json"
  echo
fi

cleanup() {
  echo
  echo "--- cleaning up scratch container ---"
  docker rm -f "$SCRATCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- starting scratch container ---"
docker rm -f "$SCRATCH" >/dev/null 2>&1 || true
docker run -d --name "$SCRATCH" \
  -e POSTGRES_PASSWORD="$SCRATCH_PASSWORD" \
  "$IMAGE" >/dev/null

echo -n "waiting for postgres to accept connections"
for _ in $(seq 1 60); do
  if docker exec -e PGPASSWORD="$SCRATCH_PASSWORD" "$SCRATCH" \
       pg_isready -U postgres >/dev/null 2>&1; then
    echo " - ready"
    break
  fi
  echo -n "."
  sleep 1
done

echo "--- restoring ---"
docker cp "$DUMPFILE" "${SCRATCH}:/tmp/test.dump"
docker exec -e PGPASSWORD="$SCRATCH_PASSWORD" "$SCRATCH" createdb -U postgres restore_test

# -j 4 restores in parallel; --no-owner because the roles do not exist here.
# A non-zero exit is worth reading rather than trusting blindly: pg_restore
# also returns non-zero for harmless warnings such as a missing role grant.
RESTORE_RC=0
docker exec -e PGPASSWORD="$SCRATCH_PASSWORD" "$SCRATCH" \
  pg_restore -U postgres -d restore_test --no-owner -j 4 /tmp/test.dump || RESTORE_RC=$?

echo
echo "--- tables and sizes ---"
docker exec -e PGPASSWORD="$SCRATCH_PASSWORD" "$SCRATCH" \
  psql -U postgres -d restore_test -c "\dt+"

echo
echo "--- row counts of the 10 largest tables ---"
# Compare these against production. This is the step that actually proves the
# backup holds the right data; record the numbers in the runbook.
docker exec -e PGPASSWORD="$SCRATCH_PASSWORD" "$SCRATCH" \
  psql -U postgres -d restore_test -tAc "
    SELECT relname || ' = ' || n_live_tup
    FROM pg_stat_user_tables
    ORDER BY n_live_tup DESC
    LIMIT 10;"

echo
echo "--- installed extensions ---"
docker exec -e PGPASSWORD="$SCRATCH_PASSWORD" "$SCRATCH" \
  psql -U postgres -d restore_test -c "\dx"

echo
if [ "$RESTORE_RC" -eq 0 ]; then
  echo "RESULT: restore completed with no errors."
else
  echo "RESULT: pg_restore exited ${RESTORE_RC}. Read the messages above -"
  echo "        missing-role warnings are expected in a scratch container,"
  echo "        anything else is a real problem."
fi
echo "Record the row counts above in runbook.md next to today's date."
