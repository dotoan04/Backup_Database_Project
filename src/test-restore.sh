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

# --- file databases (SQLite) -------------------------------------------------
# There is no server to start: the snapshot IS the database, so restoring is
# copying the file. The drill still has to prove the copy is readable and holds
# the expected rows, which is the part that actually matters.
FILES_CONF="${BASE_DIR}/sites-files.conf"

is_file_database() {
  [ -f "$FILES_CONF" ] || return 1
  sed -e 's/\r$//' "$FILES_CONF" | grep -vE '^[[:space:]]*(#|$)' \
    | cut -d'|' -f1 | tr -d '[:space:]' | grep -Fqx "$1"
}

restore_sqlite() {
  local site="$1" snapshot="$2" scratch meta
  scratch="$(mktemp -d /tmp/mbc-restore-test.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '${scratch}'" EXIT

  echo "site      : ${site}"
  echo "snapshot  : ${snapshot} ($(stat -c%s "$snapshot") bytes)"
  echo "engine    : sqlite - restored into ${scratch}, never into the application"
  echo

  if [ -f "${snapshot}.sha256" ]; then
    echo "--- checksum ---"
    ( cd "$(dirname "$snapshot")" && sha256sum -c "$(basename "$snapshot").sha256" )
    echo
  fi

  meta="${snapshot%.db}.meta.json"
  [ -f "$meta" ] || meta=""

  cp "$snapshot" "${scratch}/restored.db"

  echo "--- integrity and row counts ---"
  # `|| rc=$?` rather than a bare call: under `set -e` a failing drill would
  # otherwise abort the script before it can print the RESULT line.
  local rc=0
  python3 - "${scratch}/restored.db" "$meta" <<'PY' || rc=$?
import json, sqlite3, sys

path, meta_path = sys.argv[1], sys.argv[2]
problems = []
counts = {}

# A truncated or overwritten file never reaches integrity_check - SQLite
# cannot read the header at all. Catch that here: at 02:00 a plain sentence is
# worth more than a traceback.
try:
    conn = sqlite3.connect(path)
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    print("integrity_check: %s" % integrity)
    if integrity != "ok":
        problems.append("integrity_check returned %r" % integrity)

    names = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    counts = {n: conn.execute('SELECT count(*) FROM "%s"'
                              % n.replace('"', '""')).fetchone()[0] for n in names}
    conn.close()

    for name in names:
        print("  %-40s %d" % (name, counts[name]))
    print("total rows: %d" % sum(counts.values()))
except sqlite3.DatabaseError as exc:
    problems.append("the file could not be read as a SQLite database: %s" % exc)

if not counts and not problems:
    problems.append("the restored database has no user tables")

# The metadata was written at backup time from the source database. Comparing
# against it proves the snapshot survived encryption, upload and download
# unchanged - not just that it is a valid SQLite file.
if meta_path:
    with open(meta_path, encoding="utf-8") as handle:
        expected = json.load(handle).get("tables") or {}
    for name, want in sorted(expected.items()):
        got = counts.get(name)
        if got is None:
            problems.append("table %s is missing (expected %d rows)" % (name, want))
        elif got != want:
            problems.append("table %s has %d rows, metadata says %d" % (name, got, want))
    if expected and not problems:
        print("\nrow counts match the metadata written at backup time.")

if problems:
    print("\nPROBLEMS:")
    for item in problems:
        print("  - %s" % item)
    sys.exit(1)
PY

  echo
  if [ "$rc" -eq 0 ]; then
    echo "RESULT: restore verified - the snapshot is readable and complete."
  else
    echo "RESULT: FAILED. Read the problems above before trusting this backup."
  fi
  echo
  echo "To restore for real, see the SQLite section of runbook.md. The step"
  echo "everyone forgets: delete the stale app.db-wal and app.db-shm, or SQLite"
  echo "replays the old WAL over the restored file and corrupts it."
  return "$rc"
}

if [ -z "$DUMPFILE" ] && is_file_database "$SITE"; then
  DUMPFILE="$(ls -t "${BACKUP_DIR}/${SITE}_backup_"*.db 2>/dev/null | head -1 || true)"
  if [ -z "$DUMPFILE" ]; then
    echo "No snapshot found for '${SITE}' in ${BACKUP_DIR}." >&2
    echo "Download one from SharePoint first, or pass the path as the second argument." >&2
    exit 1
  fi
fi
case "$DUMPFILE" in
  *.db)
    restore_sqlite "$SITE" "$DUMPFILE"
    exit $?
    ;;
esac

# --- PostgreSQL --------------------------------------------------------------
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
