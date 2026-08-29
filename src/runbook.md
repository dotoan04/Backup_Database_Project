# Runbook — restoring an MBC database from backup

Spec: MBC-SPEC-BACKUP-001 v0.2, section 11.

This is written so that somebody who has never touched this system can carry
out a restore at 02:00 without calling anyone. Follow it top to bottom.

---

## 0. Before you touch anything

| Question | Where to look |
|---|---|
| Which site is broken? | The Teams alert, or the `DB_Backup_Log` SharePoint list |
| When was the last good backup? | `DB_Backup_Log`, filter `Status = success` for that site |
| Where is the file? | `/var/backups/mbc/` on the VPS (last 7 days) or SharePoint `/DB_Backups/{site}_db_backup/{year}/` (last 30 days) |
| Is it encrypted? | The file ends in `.age`, and `Encrypted = Yes` in the log list |

Site → container → database mapping is in `/opt/mbc-backup/sites.conf`.

**Which kind of database is it?** Two site types are backed up, and they
restore completely differently. Check which inventory the site is listed in:

| Inventory | Type | Backup file | Restore procedure |
|---|---|---|---|
| `/opt/mbc-backup/sites.conf` | PostgreSQL in a container | `*.dump` | Steps 1-8 below |
| `/opt/mbc-backup/sites-files.conf` | File database (SQLite) | `*.db` | **"Restoring a file database"** at the end of this runbook |

Do not follow steps 1-8 for a `.db` file. There is no server to restore into:
the backup file *is* the database.

---

## Step 1 — Stop writes to the database

Restoring underneath a running application mixes new rows into restored data
and leaves the result impossible to reason about.

```bash
# Put the website in maintenance mode, or stop the application container
docker stop <app_container>
```

---

## Step 2 — Pick the backup to restore

```bash
# Local copies are fastest, keep 7 days
ls -lht /var/backups/mbc/
```

If nothing local is usable, fetch the set back from SharePoint. The checksum is
verified as part of the download, so this replaces step 3's first command:

```bash
/opt/mbc-backup/download.py --site <sitename> --list
/opt/mbc-backup/download.py --site <sitename> --run-id YYYYMMDD_HHMM
# -> /var/backups/mbc/restore/, dump + .sha256 + .meta.json + globals together
```

**Take the newest backup from BEFORE the incident**, not simply the newest
file. If corruption has been running for days, the most recent backup contains
it too.

Read the `.meta.json` next to the dump — it records the exact PostgreSQL
version that produced the file, which decides the image you restore into at
step 6.

---

## Step 3 — Verify the file before relying on it

```bash
cd /var/backups/mbc
sha256sum -c mbc_tool_ads_backup_20260731_0200.dump.sha256

# Can the dump actually be read? Run pg_restore inside a container -
# the host has no postgresql-client installed.
docker exec -i <any_pg16_container> pg_restore --list \
  < mbc_tool_ads_backup_20260731_0200.dump | head -40
```

A checksum failure or a `pg_restore --list` error means: **stop, use an older
backup.** Do not attempt to restore a file that fails these checks.

---

## Step 4 — Decrypt (only when the file ends in `.age` or `.gpg`)

The private key is **not on SharePoint and not on this server**. It lives in
the organisation password manager / Azure Key Vault — see the contacts table
at the bottom.

```bash
# age
age -d -i ~/.age/mbc-backup.key -o restored.dump backup.dump.age

# GPG
gpg --decrypt --output restored.dump backup.dump.gpg
```

---

## Step 5 — Back up the CURRENT state first

**Do not skip this.** If you restore the wrong file, or the current database
turns out to hold something important, this dump is the only way back.

```bash
PGPASS=$(docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}' \
         | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)

docker exec -e PGPASSWORD="$PGPASS" <container> \
  pg_dump -U postgres -d <db> -Fc \
  > /var/backups/mbc/PRE_RESTORE_$(date +%Y%m%d_%H%M).dump
```

---

## Step 6 — Restore

### Use the right image

`pg_restore` cannot read a dump produced by a newer `pg_dump`, and a dump that
uses an extension fails if the image does not ship it.

| Sitename | Image to restore into |
|---|---|
| `timesheet_misa` | `postgres:15-alpine` |
| `mbc360` | `postgres:17-alpine` |
| `mbc_ocr` | `pgvector/pgvector:pg16` — **not** `postgres:16-alpine`; the dump contains `CREATE EXTENSION vector` |
| the other 6 sites | `postgres:16-alpine` |

### Restore into a new database, then rename

Safer than overwriting in place: if the result is wrong, the original is still
there.

```bash
docker cp restored.dump <container>:/tmp/restore.dump

docker exec -e PGPASSWORD="$PGPASS" <container> \
  createdb -U postgres <db>_restore

docker exec -e PGPASSWORD="$PGPASS" <container> \
  pg_restore -U postgres -d <db>_restore --no-owner -j 4 /tmp/restore.dump

# Check the data before switching anything over
docker exec -e PGPASSWORD="$PGPASS" <container> \
  psql -U postgres -d <db>_restore -c "\dt+"
```

Once the contents look right, swap the names. All connections to the old
database must be closed first or `ALTER DATABASE` blocks.

```sql
ALTER DATABASE <db>         RENAME TO <db>_old;
ALTER DATABASE <db>_restore RENAME TO <db>;
```

---

## Step 7 — Restore globals if roles are missing

`pg_dump` carries table data only. Roles, passwords and tablespaces live in
the separate globals file.

```bash
gunzip -c mbc_tool_ads_globals_20260731_0200.sql.gz \
  | docker exec -i -e PGPASSWORD="$PGPASS" <container> psql -U postgres
```

Errors of the form `role "x" already exists` are expected and harmless.

If the globals file is absent, the backup ran with a non-superuser database
user (this affects `skuapp`, `mbc360` and `mbc_ocr`, whose containers use a
dedicated role). Recreate the roles by hand:

```sql
CREATE ROLE <role> LOGIN PASSWORD '<password>';
GRANT ALL PRIVILEGES ON DATABASE <db> TO <role>;
```

---

## Step 8 — Bring it back up and check

```bash
docker start <app_container>
```

- [ ] The website loads and login works
- [ ] Row counts in the main tables match expectations
- [ ] No errors in the application log
- [ ] `/opt/mbc-backup/backup.sh` runs successfully once, so there is a fresh
      restore point on top of the restored state
- [ ] Drop `<db>_old` only after a few days of stable running

---

## Restoring a file database (SQLite)

For any site listed in `/opt/mbc-backup/sites-files.conf`. These databases
belong to other teams' applications, so read the whole section before typing
anything.

### What makes this different

The backup is one ordinary file and restoring it is copying that file into
place. Two things make it easy to get wrong:

- **The application must be stopped first.** SQLite has no server to disconnect
  clients from. Swapping the file underneath a running application gives it a
  file handle to a database that no longer exists.
- **The stale `-wal` and `-shm` sidecars must be deleted.** This is the step
  that destroys restores. If you drop the restored `app.db` next to the old
  `app.db-wal`, SQLite replays that write-ahead log on top of it at startup.
  The result is a mix of restored and pre-incident data, or an unreadable
  file, and it happens silently.

### Procedure

```bash
SITE=po_app_rm_price
APP_DIR=/home/po_app/app                      # from sites-files.conf, third field
DB=${APP_DIR}/data/app.db

# 1. Pick the backup. Newest local copy:
ls -lt /var/backups/mbc/${SITE}_backup_*.db
SNAP=/var/backups/mbc/${SITE}_backup_YYYYMMDD_HHMM.db

# Older than 7 days, or this host lost its disk - fetch it back from SharePoint.
# The checksum is verified as part of the download.
/opt/mbc-backup/download.py --site "$SITE" --list
/opt/mbc-backup/download.py --site "$SITE" --run-id YYYYMMDD_HHMM
SNAP=/var/backups/mbc/restore/${SITE}_backup_YYYYMMDD_HHMM.db

# 2. Verify it BEFORE trusting it. Never skip this.
cd "$(dirname "$SNAP")" && sha256sum -c "$(basename "$SNAP").sha256"
/opt/mbc-backup/test-restore.sh "$SITE" "$SNAP"
# Must print: RESULT: restore verified

# 3. Decrypt first if the file ends in .age
#    age -d -i /path/to/key.txt -o "${SNAP%.age}" "$SNAP"

# 4. Stop the application.
cd "$APP_DIR" && docker compose stop

# 5. Keep the current state. It is the only copy of everything written since
#    the last backup, and you may need it to reconcile afterwards.
mkdir -p /var/backups/mbc/pre-restore-$(date +%Y%m%d_%H%M)
mv "$DB" "$DB"-wal "$DB"-shm /var/backups/mbc/pre-restore-*/ 2>/dev/null

# 6. Put the snapshot in place. The -wal and -shm files must NOT exist.
cp "$SNAP" "$DB"
ls -la "$(dirname "$DB")"          # expect app.db only, no -wal, no -shm

# 7. Match the ownership the application container expects. Check what the
#    files in the pre-restore directory had - usually root:root, mode 644.
chown root:root "$DB" && chmod 644 "$DB"

# 8. Start it and confirm.
docker compose start
docker compose logs --tail 50
```

Then check the data in the application itself before telling anyone it is
fixed, and record what was lost between the backup timestamp and the incident.

### If the application will not start

Ninety percent of the time it is step 6 or step 7: a leftover `-wal` file, or
the file is owned by the wrong user. Compare against the pre-restore directory:
those files show exactly what ownership and mode the container was happy with.

---

## Quarterly restore drill

Automatic verification proves a dump is readable. It does not prove it
restores, and it does not prove the data is right. Once a quarter, run:

```bash
/opt/mbc-backup/test-restore.sh mbc_ocr        # pgvector, highest risk
/opt/mbc-backup/test-restore.sh mbc360         # PostgreSQL 17, highest risk
/opt/mbc-backup/test-restore.sh po_app_rm_price   # file database
/opt/mbc-backup/test-restore.sh <one other site>
```

The drill picks the right procedure from the site name, and never touches the
running application: a file database is restored into a scratch directory,
checked, and thrown away.

Also run it after every PostgreSQL upgrade: a major version change can break
dump compatibility.

Record the results here.

| Date | Site | Restore | Row counts vs production | Run by |
|---|---|---|---|---|
| | | | | |

---

## Diagnosing a failed backup

```bash
systemctl status mbc-backup.service
journalctl -u mbc-backup -n 200 --no-pager
tail -100 /var/log/mbc-backup.log
systemctl list-timers mbc-backup.timer     # is the schedule even armed?
```

| Exit code | Meaning | What to do |
|---|---|---|
| 0 | every site backed up | nothing |
| 10 | some sites failed, or failures of mixed kinds | read the notification for the site and step |
| 20 | dump failed | container down, or `POSTGRES_PASSWORD` changed |
| 30 | **dump is corrupt** | most serious — check the disk and the database, the file is kept for investigation |
| 40 | upload failed | token/network; local files are kept, safe to re-run |
| 50 | not enough free disk | free space, then re-run; the dump was deliberately skipped |
| 60 | backup fine, notification not delivered | check `FLOW_WEBHOOK_URL` — the backup itself is good |
| 99 | unexpected error | read the log, this is a bug |

Re-running is always safe: every step is idempotent.

```bash
systemctl start mbc-backup.service     # run now, do not wait for 02:00
```

---

## Contacts

| Role | Person | Notes |
|---|---|---|
| Technical owner | Đỗ Thế Toàn | owns the backup system |
| SharePoint / M365 admin | _(to be filled in)_ | permissions, certificate renewal |
| Holder of the decryption key | _(to be filled in)_ | password manager / Azure Key Vault |
