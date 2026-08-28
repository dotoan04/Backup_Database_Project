# Backing up file databases (SQLite)

Spec: MBC-SPEC-BACKUP-001 v0.2 covers nine PostgreSQL databases in containers.
This document covers the second site type: applications whose database is a
file on the host rather than a server.

---

## 1. Why this is a separate site type

`pg_dump` talks to a database server over a protocol. A SQLite database has no
server — the file *is* the database, and the application opens it directly.
Nothing in the PostgreSQL path applies.

The first such application found on the VPS is the PO app in `~po_app/app`.
Its `docker-compose.yml` bind-mounts a host directory into the container:

```yaml
volumes:
  # Persists the SQLite DB (RM Price + synced Raw Materials) across redeploys
  - ./data:/app/server/data
```

A bind mount is still Docker. The only difference from a named volume is
*where the bytes live*: a path the compose file chose, instead of a directory
Docker manages under `/var/lib/docker/volumes/`. That difference does not
affect how the database is backed up. It affects how easily it can be deleted
by accident, which is section 6.

---

## 2. The trap: the main .db file can be almost empty

Measured on the live PO app database:

```
-rw-r--r-- 1 root root       4096  app.db
-rw-r--r-- 1 root root      32768  app.db-shm
-rw-r--r-- 1 root root    2257792  app.db-wal
```

`app.db` is 4096 bytes — one page, the header and nothing else. Every table
and every row lives in `app.db-wal`.

This is normal for SQLite in WAL mode. Committed transactions are appended to
the write-ahead log and only moved into the main file by a *checkpoint*, which
happens when the last connection closes. The application container holds a
connection open permanently, so that checkpoint never comes.

Two consequences that matter:

- **`cp app.db` produces an empty database.** Not a corrupt one — an empty one,
  which opens without error and reports no tables. Verified: restoring such a
  copy gives `no such table: rm_prices`.
- **This is not a transient state.** As long as the container runs, `app.db`
  stays at 4096 bytes. There is no later moment at which a file copy would
  start working.

Copying all three files is not a fix either. They are read at slightly
different instants while the application keeps writing, so the set can be
mutually inconsistent.

---

## 3. How it is actually done

[`src/sqlite-snapshot.py`](../src/sqlite-snapshot.py) uses the SQLite **online
backup API** through Python's standard-library `sqlite3` module. It reads
through the WAL and writes one self-contained file, while the application keeps
running and writing.

```
sqlite-snapshot.py --source /home/po_app/app/data/app.db \
                   --dest   /var/backups/mbc/po_app_rm_price_backup_<ts>.db \
                   --previous-meta <last run's .meta.json>
```

Four properties were deliberate:

| Property | Why |
|---|---|
| Nothing is installed on the host | `python3` already ships the SQLite library. The `sqlite3` CLI is absent on this VPS and adding packages to a production database host is its own risk |
| The source is opened `mode=ro` | A read-only connection **cannot checkpoint on close**, so this can never modify the files of an application that did not ask to be backed up |
| No container is stopped | The backup API holds a brief read lock; for a database of this size it is sub-millisecond |
| Verification is built in | `PRAGMA integrity_check` on the snapshot — the counterpart of `pg_restore --list`. A snapshot that fails is kept as evidence and never uploaded |

Everything after the snapshot is the existing pipeline, unchanged: checksum,
optional `age` encryption, chunked upload to the same SharePoint layout,
retention, and one entry in the same notification payload. Flow 1, Flow 2 and
`rotate.py` needed no changes for this site type.

### Shrink detection uses row counts, not file size

The PostgreSQL path warns when a dump is more than 50% smaller than the
previous one. That check is useless here: **SQLite reuses freed pages**, so a
database can lose every row without the file shrinking by a single byte.
Measured — deleting 95% of the rows left the file at exactly 24576 bytes.

So `.meta.json` records a row count per table, and each run compares against
the previous one. Two warnings are raised (never failures, because legitimate
bulk deletions happen):

- a table that existed in the previous run is gone
- the total row count dropped by more than half

---

## 4. Adding another application

One line in `/opt/mbc-backup/sites-files.conf`:

```
sitename|engine|absolute_path_on_the_host
```

Find the path of a bind-mounted database:

```bash
docker inspect <container> --format '{{json .Mounts}}' | python3 -m json.tool
```

Take `Source` from the entry whose `Type` is `bind` — that is the host side.
`Destination` is the path inside the container and is not what goes in the
inventory.

Then, before the first scheduled run:

```bash
# 1. Prove it can be read and is really SQLite
/opt/mbc-backup/sqlite-snapshot.py --source <path> --dest /tmp/probe.db && rm /tmp/probe.db

# 2. Run the backup by hand and read the log
/opt/mbc-backup/backup.sh ; echo "exit=$?"

# 3. Prove the restore, into a scratch directory
/opt/mbc-backup/test-restore.sh <sitename>

# 4. Add <sitename> to ExpectedApps in Flow 2, or the dead-man switch will
#    never notice if this site stops being backed up
```

Rules that are not optional:

- **`sitename` must be unique across both inventories** and must never change.
  File names and the SharePoint folder are built from it; renaming splits the
  history in two.
- **Do not name the site after the database file.** Three applications with an
  `app.db` would overwrite each other. Name it after the application.
- The path must be the host path, not the in-container path.

### What is not supported yet

`engine` currently accepts only `sqlite`. The field exists so a second
file-based engine can be added without changing the format again. A line with
any other engine fails that one site with a clear message and leaves the rest
of the run alone.

MySQL, MongoDB and other servers are out of scope. If one appears, it belongs
in a third inventory with its own dump tool, following the same shape:
snapshot, verify, hand the artifact to the existing upload path.

---

## 5. Backup frequency

File databases are small — the PO app snapshot is around 100 KB against 40 MB
for a typical `pg_dump`. Backing one up costs almost nothing, so the daily
02:00 schedule is more conservative than it needs to be.

If a shorter RPO is wanted for a specific application, an hourly timer running
only the file-database inventory costs roughly 2.5 MB of SharePoint traffic a
day and cuts worst-case data loss from 24 hours to 1. Not implemented, because
nobody has asked for it yet and an unused schedule is another thing to
maintain — but the shape of the change is a second systemd timer plus a
`--only-files` flag on `backup.sh`.

---

## 6. Risks that backup does not solve

Worth recording, because they belong to the application team rather than to
this project, and none of them are fixed by having backups:

| Risk | Detail |
|---|---|
| The database lives inside a git working tree | `~po_app/app/data` is untracked but **not** in `.gitignore`. One `git add -A && git commit && git push` puts the pricing database on GitHub. `git clean -fd` deletes it |
| Fresh clone starts empty and silently | Clone the project into a new directory and start it: `./data` is empty, SQLite creates a new file, the application starts normally with no data and no error |
| Same filesystem as the local backups | A single failed disk takes both. The SharePoint copy is the one that survives, which is why this site must not be left out of the inventory |

What the setup gets *right*, and is worth not breaking: `/home/po_app` is mode
`0700`, so no other account on the VPS can read the database, even though the
files themselves are world-readable. Permissions on the file alone would
suggest otherwise; the directory is what actually protects it.

Moving the database out of the git working tree — for example to
`/var/lib/po_app/data` — would close the first two rows of that table with a
one-line compose change. It is not required for backups to work, and it is the
application team's call.
