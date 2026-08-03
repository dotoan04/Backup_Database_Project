# Test plan and acceptance criteria

Spec: MBC-SPEC-BACKUP-001 v0.2, section 10.

Run these on the VPS after installation. Record the result and the date in the
table at the bottom — section 10.2 requires a written record.

Useful throughout:

```bash
tail -f /var/log/mbc-backup.log
journalctl -u mbc-backup -f
/opt/mbc-backup/backup.sh ; echo "exit=$?"
```

---

## TC-01 — Normal run, all 9 sites

```bash
/opt/mbc-backup/backup.sh ; echo "exit=$?"
```

Expected: exit 0 · 9 dumps on SharePoint with matching checksums · one
aggregated success message · 9 rows in `DB_Backup_Log`, all `success`.

Check the folder layout:
`/DB_Backups/{site}_db_backup/{year}/{site}_backup_{YYYYMMDD}_{HHMM}.dump`
plus `.sha256`, `.meta.json` and the globals file.

---

## TC-02 — A container is down

```bash
docker stop misa_sync_db
/opt/mbc-backup/backup.sh ; echo "exit=$?"
docker start misa_sync_db
```

Expected: **exit 10** · the other 8 sites succeed · the notification names
`misa_sync_engine`, step `precheck`, reason "container is not running".

Proves the rule from section 4.1: one broken site never stops the rest.

---

## TC-03 — Wrong database password

```bash
# Do not touch the real container. Use a throwaway with a bad password.
docker run -d --name tc03-test -e POSTGRES_PASSWORD=correct postgres:16-alpine
sleep 10
docker exec tc03-test psql -U postgres -c "ALTER USER postgres PASSWORD 'changed'"
# add to sites.conf:  tc03|tc03-test|postgres|postgres
```

Expected: the dump fails · **no empty file is uploaded** · notification
`failed`, step `dump`.

Cleanup: `docker rm -f tc03-test` and remove the line from `sites.conf`.

---

## TC-04 — Network cut during upload

```bash
/opt/mbc-backup/backup.sh &
sleep 20 && ip link set eth0 down
sleep 60 && ip link set eth0 up
```

> Only do this with console access to the VPS. Bringing the interface down
> over SSH locks you out.

Expected: retry with backoff · if it still fails, exit 40 and
**the local dump files are kept** in `/var/backups/mbc/`.

---

## TC-05 — Deliberately corrupted dump

```bash
/opt/mbc-backup/backup.sh                      # produce a good dump first
F=$(ls -t /var/backups/mbc/*.dump | head -1)
printf 'GARBAGE' | dd of="$F" bs=1 seek=100 conv=notrunc

docker exec -i mbc_tool_ads_postgres pg_restore --list < "$F"   # must fail
```

Expected: `pg_restore --list` reports an error · **exit 30** on a run that
produces such a file · nothing is uploaded · the file is kept for
investigation.

This is the single most important test in the list. Everything else the system
does is pointless if a corrupt dump can be reported as a success.

---

## TC-06 — Not enough free disk

```bash
sudo sed -i 's/^MIN_FREE_DISK_MB=.*/MIN_FREE_DISK_MB=999999/' /opt/mbc-backup/.env
/opt/mbc-backup/backup.sh ; echo "exit=$?"
sudo sed -i 's/^MIN_FREE_DISK_MB=.*/MIN_FREE_DISK_MB=5120/' /opt/mbc-backup/.env
```

Expected: **exit 50** · no dump file created · notification `failed`, step
`precheck`.

Refusing to dump is the correct behaviour: filling the filesystem stops
PostgreSQL writing WAL, which takes production down.

---

## TC-07 — Broken webhook URL

```bash
sudo cp /opt/mbc-backup/.env /root/env.bak
sudo sed -i 's#^FLOW_WEBHOOK_URL=.*#FLOW_WEBHOOK_URL=https://invalid.example.com/x#' /opt/mbc-backup/.env
/opt/mbc-backup/backup.sh ; echo "exit=$?"
sudo cp /root/env.bak /opt/mbc-backup/.env && sudo rm /root/env.bak
```

Expected: **the backup and upload still succeed** · exit 60 · the notify
failure appears in the log · the dead-man switch reports it the next morning.

A notification problem must never destroy a good backup result.

---

## TC-08 — Dead-man switch

```bash
systemctl stop mbc-backup.timer && systemctl disable mbc-backup.timer
# wait 2 days
systemctl enable --now mbc-backup.timer
```

Expected: a `[MISSING BACKUP]` alert at 09:00 the following day naming all
nine sites.

---

## TC-09 — Idempotency

```bash
/opt/mbc-backup/backup.sh ; echo "exit=$?"
/opt/mbc-backup/backup.sh ; echo "exit=$?"
```

Expected: both runs exit 0 · no duplicated folders · no `file 1.dump` style
names on SharePoint.

If the two runs land in the same minute, the second overwrites the first —
that is what `conflictBehavior: replace` is for on files. Folder creation uses
`fail` instead, because replacing a folder would discard its contents.

---

## TC-10 — Restore mbc_ocr with pgvector

```bash
/opt/mbc-backup/test-restore.sh mbc_ocr
```

Expected: restores into `pgvector/pgvector:pg16` · `\dx` lists `vector` · row
counts match production.

Also confirm it *fails* in the wrong image — this is the trap the runbook
warns about:

```bash
docker run -d --name wrong-image -e POSTGRES_PASSWORD=t postgres:16-alpine
# pg_restore here should fail on CREATE EXTENSION vector
docker rm -f wrong-image
```

---

## TC-11 — Retention

```bash
# Local: a fake file older than the local window
touch -d "40 days ago" /var/backups/mbc/faketest_backup_20260601_0200.dump
/opt/mbc-backup/backup.sh
ls /var/backups/mbc/faketest*        # must be gone
```

For SharePoint, check with a dry run first — it never deletes anything:

```bash
/opt/mbc-backup/rotate.py --days 30 --dry-run
```

Expected: files past 30 days are listed · the newest 3 sets per site are never
listed, whatever their age.

That floor is deliberate: if the backup job has been broken for two months,
retention must not finish the job by deleting the last working copy.

---

## TC-12 — Load while dumping

Run the backup during working hours and watch application response times.

Expected: no noticeable increase, thanks to `Nice=10` and
`IOSchedulingClass=idle` in the service unit, and because `pg_dump` works
inside an MVCC snapshot and does not lock ordinary reads or writes.

---

## Definition of Done (spec 10.2)

- [ ] TC-01 … TC-12 all pass, with a written record
- [ ] At least **one** real restore into a scratch container, with row counts compared
- [ ] `runbook.md` has been read and followed by **somebody else**, without needing to ask questions
- [ ] No credential anywhere in the git history
- [ ] The dead-man switch has been proven by actually disabling the timer
- [ ] A calendar reminder exists for certificate/secret expiry (if using a secret)
- [ ] The quarterly restore drill is in the calendar

---

## Record

| TC | Date | Result | By | Notes |
|---|---|---|---|---|
| TC-01 | | | | |
| TC-02 | | | | |
| TC-03 | | | | |
| TC-04 | | | | |
| TC-05 | | | | |
| TC-06 | | | | |
| TC-07 | | | | |
| TC-08 | | | | |
| TC-09 | | | | |
| TC-10 | | | | |
| TC-11 | | | | |
| TC-12 | | | | |
