#!/usr/bin/env python3
"""Take a consistent snapshot of a file-based SQLite database and verify it.

Spec: MBC-SPEC-BACKUP-001 v0.2, sections 5.2 and 5.3, applied to the
file-database site type (see docs/file-database-backup.md).

Why this exists instead of `cp`
-------------------------------
A SQLite database in WAL mode is three files, and the main .db file can hold
almost none of the data: committed transactions live in the -wal sidecar until
a checkpoint moves them across. A production example measured on this fleet had
app.db at 4 KB and app.db-wal at 2.2 MB - copying app.db alone would have
produced an empty database, with no error at any point.

Copying all three files is not a fix either: they are read at different
instants while the application keeps writing, so the set can be mutually
inconsistent.

The SQLite online backup API solves both problems. It reads through the WAL and
produces one self-contained file, while the application keeps running.

Read-only by design
-------------------
The source is opened with mode=ro. A read-only connection cannot checkpoint on
close, which guarantees this never modifies the files of the application being
backed up, and it does not need the application to pause. That matters when the
database belongs to a team that did not ask to be backed up.

Usage:
    sqlite-snapshot.py --source /home/po_app/app/data/app.db \
                       --dest   /var/backups/mbc/po_app_backup_20260828_0200.db \
                       [--previous-meta <path>] [--min-size 8192]

stdout carries exactly one JSON object and nothing else, so backup.sh can read
it. All progress and diagnostics go to stderr.
"""

import argparse
import json
import os
import sqlite3
import sys

# Exit codes mirror backup.sh so the caller can pass them straight through
# (spec 7.1).
EXIT_OK = 0
EXIT_SNAPSHOT = 20   # could not read the source or write the snapshot
EXIT_VERIFY = 30     # snapshot taken but it does not hold up

SQLITE_MAGIC = b"SQLite format 3\x00"

# Below this a snapshot is treated as empty rather than small. A SQLite file
# holding one header page and nothing else is 4096 bytes on the default page
# size, so the floor has to sit above that.
DEFAULT_MIN_SIZE = 8192

# Same threshold as verify_not_shrunk() for PostgreSQL dumps: a warning, never
# a failure, because legitimate bulk deletions do happen.
SHRINK_RATIO = 0.5

# The backup API copies the whole database in one step while holding a read
# lock. For the databases in scope that is sub-millisecond; page-by-page
# copying would only add restarts under concurrent writes.
BACKUP_PAGES = -1


class VerifyError(Exception):
    """The snapshot exists but does not hold up - exit 30, keep the file."""


def log(message):
    print("[sqlite-snapshot] %s" % message, file=sys.stderr)


def looks_like_sqlite(path):
    with open(path, "rb") as handle:
        return handle.read(16) == SQLITE_MAGIC


def open_source(path):
    """Open the live database, read-only if at all possible.

    Returns (connection, warnings). Read-only needs a writable -shm sidecar to
    join the WAL readers, which root always has. If that fails the fallback is
    a normal connection: a failed backup is worse than the checkpoint a
    read-write close may trigger, but it is worth saying out loud.
    """
    quoted = path.replace("?", "%3f").replace("#", "%23")
    try:
        return sqlite3.connect("file:%s?mode=ro" % quoted, uri=True, timeout=30), []
    except sqlite3.Error as exc:
        log("read-only open failed (%s), falling back to read-write" % exc)
        return sqlite3.connect(path, timeout=30), [
            "source opened read-write because read-only failed (%s); closing the "
            "connection may checkpoint the WAL of the live database" % exc
        ]


def quote_ident(name):
    return '"%s"' % name.replace('"', '""')


def table_row_counts(conn):
    """Row count per user table. Internal sqlite_* tables are left out."""
    query = ("SELECT name FROM sqlite_master WHERE type='table' "
             "AND name NOT LIKE 'sqlite_%' ORDER BY name")
    names = [row[0] for row in conn.execute(query)]
    counts = {}
    for name in names:
        counts[name] = conn.execute(
            "SELECT count(*) FROM %s" % quote_ident(name)).fetchone()[0]
    return counts


def compare_with_previous(previous_meta, tables, total_rows):
    """Shrink detection, the file-database counterpart of verify_not_shrunk.

    Row counts are compared rather than file size: SQLite reuses freed pages,
    so a database can lose every row without the file getting any smaller.
    """
    warnings = []
    if not previous_meta or not os.path.isfile(previous_meta):
        return warnings
    try:
        with open(previous_meta, encoding="utf-8") as handle:
            previous = json.load(handle)
    except (OSError, ValueError) as exc:
        log("could not read the previous metadata (%s), skipping the shrink check" % exc)
        return warnings

    for name in previous.get("tables") or {}:
        if name not in tables:
            warnings.append(
                "table %s was present in the previous run and is now gone" % name)

    previous_total = previous.get("total_rows")
    if isinstance(previous_total, int) and previous_total > 0:
        if total_rows < previous_total * SHRINK_RATIO:
            warnings.append(
                "row count dropped to %d from %d in the previous run "
                "(more than 50%% smaller) - worth checking"
                % (total_rows, previous_total))
    return warnings


def remove_snapshot_files(dest):
    for suffix in ("", "-wal", "-shm"):
        try:
            os.remove(dest + suffix)
        except OSError:
            pass


def snapshot(source, dest, previous_meta, min_size):
    if not os.path.isfile(source):
        raise RuntimeError("source database %s does not exist" % source)
    if not os.access(source, os.R_OK):
        raise RuntimeError("source database %s is not readable by this user" % source)
    if not looks_like_sqlite(source):
        raise RuntimeError("%s is not a SQLite database (magic header missing)" % source)

    # A leftover snapshot from a crashed run would otherwise be backed into.
    remove_snapshot_files(dest)

    src, warnings = open_source(source)
    try:
        journal_mode = src.execute("PRAGMA journal_mode").fetchone()[0]
        page_size = src.execute("PRAGMA page_size").fetchone()[0]
        log("source %s: journal_mode=%s page_size=%s"
            % (source, journal_mode, page_size))
        dst = sqlite3.connect(dest)
        try:
            src.backup(dst, pages=BACKUP_PAGES)
        finally:
            dst.close()
    except sqlite3.Error as exc:
        raise RuntimeError("SQLite backup failed: %s" % exc)
    finally:
        src.close()

    # Closing the destination cleanly checkpoints and removes its own -wal, so
    # what is left is a single self-contained file. Assert that, because an
    # orphaned sidecar would mean uploading an incomplete backup.
    for suffix in ("-wal", "-shm"):
        if os.path.exists(dest + suffix):
            raise RuntimeError(
                "snapshot left a %s sidecar behind - it is not self-contained" % suffix)

    size = os.path.getsize(dest)

    # ---- verification (spec 5.3.1) -----------------------------------------
    # integrity_check is the counterpart of `pg_restore --list`: it walks every
    # page and index of the file that was actually written to disk.
    check = sqlite3.connect(dest)
    try:
        result = check.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise VerifyError("integrity_check on the snapshot returned: %s" % result)
        tables = table_row_counts(check)
        sqlite_version = check.execute("SELECT sqlite_version()").fetchone()[0]
    except sqlite3.DatabaseError as exc:
        raise VerifyError("snapshot could not be read back: %s" % exc)
    finally:
        check.close()

    if size < min_size:
        raise VerifyError("snapshot is only %d bytes, below the %d byte minimum"
                          % (size, min_size))
    if not tables:
        raise VerifyError("snapshot contains no user tables")

    total_rows = sum(tables.values())
    warnings = warnings + compare_with_previous(previous_meta, tables, total_rows)

    return {
        "ok": True,
        "source": source,
        "dest": dest,
        "size_bytes": size,
        "page_size": page_size,
        "journal_mode": journal_mode,
        "sqlite_version": sqlite_version,
        "integrity": "ok",
        "tables": tables,
        "total_rows": total_rows,
        "warnings": warnings,
    }


def emit(payload):
    json.dump(payload, sys.stdout, ensure_ascii=False)
    print()


def main():
    parser = argparse.ArgumentParser(
        description="Snapshot and verify a file-based SQLite database")
    parser.add_argument("--source", required=True, help="path to the live .db file")
    parser.add_argument("--dest", required=True, help="path to write the snapshot to")
    parser.add_argument("--previous-meta", default="",
                        help="previous run's .meta.json, for the shrink check")
    parser.add_argument("--min-size", type=int,
                        default=int(os.environ.get("MIN_SQLITE_SIZE_BYTES",
                                                   DEFAULT_MIN_SIZE)))
    args = parser.parse_args()

    try:
        result = snapshot(args.source, args.dest, args.previous_meta, args.min_size)
    except VerifyError as exc:
        # Deliberately not deleted: a snapshot that fails verification is
        # evidence, and the runbook asks for it.
        log("VERIFY FAILED: %s" % exc)
        emit({"ok": False, "step": "verify", "error": str(exc)})
        return EXIT_VERIFY
    except (RuntimeError, OSError) as exc:
        log("SNAPSHOT FAILED: %s" % exc)
        remove_snapshot_files(args.dest)
        emit({"ok": False, "step": "snapshot", "error": str(exc)})
        return EXIT_SNAPSHOT

    for warning in result["warnings"]:
        log("WARNING: %s" % warning)
    log("snapshot ok: %d bytes, %d tables, %d rows"
        % (result["size_bytes"], len(result["tables"]), result["total_rows"]))
    emit(result)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
