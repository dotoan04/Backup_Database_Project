#!/usr/bin/env bash
#
# MBC Database Backup - integrity checks
# Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.3
#
# Sourced by backup.sh, not executed directly.
#
# Core rule: a backup that has not been verified is not a backup. Without this
# step the system happily reports "success" for months while writing empty or
# corrupt dump files, and that only surfaces on the day a restore is needed.
#
# Convention for the functions below: on failure they print a one-line reason
# on stdout and return 1, so the caller can put the reason straight into the
# notification.

# All PostgreSQL client tools are run inside the container. The host has no
# postgresql-client installed on purpose - the VPS runs three different server
# versions at once (15.17, 16.13, 17.10) and a single host client would be the
# wrong version for at least two of them.

# verify_dump_readable <container> <dumpfile>
# Reads the whole custom-format header and table of contents. A truncated or
# corrupt file fails here.
verify_dump_readable() {
  local container="$1" dumpfile="$2"
  if ! docker exec -i "$container" pg_restore --list < "$dumpfile" >/dev/null 2>&1; then
    echo "dump is corrupt - pg_restore --list could not read ${dumpfile##*/}"
    return 1
  fi
  return 0
}

# verify_min_size <dumpfile> <min_bytes>
# Catches the empty-dump case, where pg_dump exits 0 having written nothing.
verify_min_size() {
  local dumpfile="$1" min_bytes="$2"
  local size
  size="$(stat -c%s "$dumpfile")"
  if [ "$size" -lt "$min_bytes" ]; then
    echo "dump is only ${size} bytes, below the ${min_bytes} byte minimum"
    return 1
  fi
  return 0
}

# verify_not_shrunk <backup_dir> <site> <current_size_bytes> <current_ts>
# A sudden drop against the previous run usually means a partially dropped
# schema or a dump that was cut short. Reported as a warning rather than a
# failure: legitimate large deletions do happen and must not block the backup.
#
# The comparison reads the previous .meta.json rather than measuring the
# previous .dump, because with ENCRYPT_ENABLED=true the plaintext dump is
# shredded and only the .age file remains on disk.
verify_not_shrunk() {
  local backup_dir="$1" site="$2" current="$3" current_ts="${4:-}"
  local prev_meta prev_size

  # Take the newest metadata file that is not from this run. This runs before
  # the current .meta.json is written, so normally the newest file already IS
  # the previous run - the filter only matters when a run is repeated within
  # the same minute and would otherwise compare against itself.
  #
  # `|| true` is required, not cosmetic: on the very first run for a site the
  # glob matches nothing, ls exits 2, and pipefail would turn that into a
  # fatal error for an entirely normal situation.
  prev_meta="$(ls -t "${backup_dir}/${site}_backup_"*.meta.json 2>/dev/null \
               | grep -v "_${current_ts}\.meta\.json$" | head -1 || true)"
  [ -z "$prev_meta" ] && return 0

  prev_size="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("size_bytes", 0))' \
               "$prev_meta" 2>/dev/null || echo 0)"
  [ "$prev_size" -le 0 ] && return 0

  if [ "$current" -lt $(( prev_size * 50 / 100 )) ]; then
    echo "dump shrank to ${current} bytes from ${prev_size} bytes in the previous run (more than 50% smaller) - worth checking"
  fi
  return 0
}

# sha256_of <file> - bare hex digest
sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

# write_checksum <file>
# Writes <file>.sha256 in the two-column format sha256sum expects, so the
# runbook can run `sha256sum -c <file>.sha256` directly. The file name inside
# is a bare basename so the check works from any directory.
write_checksum() {
  local target="$1" dir base
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  ( cd "$dir" && sha256sum "$base" > "${base}.sha256" )
}
