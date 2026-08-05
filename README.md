# MBC Database Backup

Automated backup for the 9 internal PostgreSQL databases at Max Biocare.
Dumps every database daily, verifies each dump, uploads to SharePoint, and
reports the result through Power Automate — including when it fails to run at
all.

Implements **MBC-SPEC-BACKUP-001 v0.2**.

---

## What it does

Every night at 02:00 (± 15 minutes), for each of the 9 sites:

```
precheck  container up? disk free? password readable?
dump      docker exec … pg_dump -Fc --no-owner --no-privileges
globals   pg_dumpall --globals-only  (roles and permissions)
verify    pg_restore --list · minimum size · shrink check · sha256
encrypt   age, when ENCRYPT_ENABLED=true
upload    Microsoft Graph, chunked upload session with resume
verify    re-read the uploaded file and compare sha256
rotate    local older than 7 days, SharePoint older than 30 days
notify    one aggregated JSON payload to Power Automate
```

Three design rules drive everything else:

- **A dump that has not been verified is not a backup.** A file that is
  corrupt but reported as "success" is worse than an obvious failure: you find
  out on the day you need it.
- **Report success too, not only failure.** Silence has to be distinguishable
  from "all fine", which is what the dead-man switch depends on.
- **One broken site never stops the other eight.**

## What it does not do

Not high availability. It protects against deleted data, corruption and
ransomware. It does nothing for downtime when the server dies — that needs a
replica, which is a separate project.

Also out of scope: file/media uploads, point-in-time recovery via WAL
archiving, Docker images and volumes.

---

## Layout

```
src/                       -> installed into /opt/mbc-backup
  backup.sh                orchestrator
  verify.sh                integrity checks (sourced by backup.sh)
  notify.sh                builds and POSTs the Power Automate payload
  graph.py                 Microsoft Graph client (stdlib + openssl only)
  upload.py                chunked upload with resume and post-upload verify
  rotate.py                SharePoint retention
  test-restore.sh          quarterly restore drill
  runbook.md               what to do at 02:00 when something is broken
  .env.example             configuration template
  sites.conf.example       the 9 sites from the survey of 31/07/2026

systemd/                   timer, service, OnFailure handler
logrotate/                 90 days of logs
install.sh                 idempotent installer

vm/
  provision-ubuntu-24.04.sh  creates isolated developer accounts and Docker sudo policy
  verify-isolation.sh        checks account, directory and Docker permissions

docs/
  azure-ad-setup.md                            app registration, Sites.Selected
  sharepoint-list-schema.md                    DB_Backup_Log
  power-automate-flow1-backup-result-handler.md
  power-automate-flow2-dead-man-switch.md      detects a backup that never ran
  payload-schema.json                          paste into the flow 1 trigger
  test-plan.md                                 TC-01 … TC-12
  security-findings.md                         open port 5434 and friends
```

No pip packages and no `postgresql-client` on the host. Every PostgreSQL tool
runs inside the container that owns the database, so the client version always
matches the server — which matters here, because the VPS runs 15.17, 16.13 and
17.10 side by side.

---

## Install

```bash
git clone <repo> && cd Backup_Database_Project
sudo ./install.sh
```

Then:

1. Fill in `/opt/mbc-backup/.env` — see [docs/azure-ad-setup.md](docs/azure-ad-setup.md)
2. Check `/opt/mbc-backup/sites.conf` against `docker ps`
3. Dry run: `/opt/mbc-backup/backup.sh ; echo "exit=$?"`
4. Enable the schedule: `systemctl enable --now mbc-backup.timer`
5. Build the two flows and the `DB_Backup_Log` list

The installer deliberately does not enable the timer. Enable it after a manual
run has gone through end to end.

### Server-like development VM

On a clean Ubuntu 24.04 VM, create three private developer accounts with Docker
available only through `sudo`:

```bash
sudo bash ./vm/provision-ubuntu-24.04.sh dev1 dev2 dev3
sudo passwd dev1
sudo passwd dev2
sudo passwd dev3
sudo bash ./vm/verify-isolation.sh dev1 dev2 dev3
```

Each account owns a mode `0700` home and `~/source` directory. Accounts are not
members of the `docker` group, so direct `docker` commands fail while Docker
through `sudo` is allowed. This matches the requested server behavior but is
not a security boundary: arbitrary Docker access is root-equivalent and can be
used to read any host directory.

**Before going live**, read
[docs/security-findings.md](docs/security-findings.md): the survey found
`time-tracking-postgres` published on `0.0.0.0:5434`, reachable from the
internet. The spec marks that as handle-first, and it is the right call — the
backup copies a database that is currently exposed.

---

## Daily operation

```bash
systemctl list-timers mbc-backup.timer     # is the schedule armed?
journalctl -u mbc-backup -n 100 --no-pager
tail -f /var/log/mbc-backup.log
systemctl start mbc-backup.service         # run now
```

| Exit | Meaning |
|---|---|
| 0 | all sites backed up |
| 10 | some sites failed, or failures of mixed kinds |
| 20 | dump failed |
| 30 | **dump corrupt** — most serious, file kept for investigation |
| 40 | upload failed, local files kept |
| 50 | not enough disk, dump deliberately skipped |
| 60 | backup fine, notification not delivered |
| 99 | unexpected error |

Re-running is always safe; every step is idempotent.

---

## Restoring

[`src/runbook.md`](src/runbook.md), installed at `/opt/mbc-backup/runbook.md`.
Read it before you need it.

The trap most likely to catch you: `mbc_ocr` must be restored into
`pgvector/pgvector:pg16`, not `postgres:16-alpine` — its dump contains
`CREATE EXTENSION vector`.

Quarterly drill:

```bash
/opt/mbc-backup/test-restore.sh mbc_ocr
```

---

## Configuration

`/opt/mbc-backup/sites.conf` — `sitename|container|db_user|db_name`, one per
line, no passwords. Adding a project means adding a line; the script does not
change.

File names use the **sitename**, never the database name: `powerapp_sku` and
`product_database` both use a database called `master_product`, and naming by
database would make them silently overwrite each other on SharePoint.

Passwords are read from each container's environment with `docker inspect`, so
there is no second copy of 9 secrets to keep in sync, and no dependence on the
filesystem permissions of each project's `.env`.

`/opt/mbc-backup/.env` — credentials and tuning, `chmod 600`. Never committed.
`FLOW_WEBHOOK_URL` carries a `sig=` parameter and is a credential in its own
right.

---

## Testing

[docs/test-plan.md](docs/test-plan.md) covers TC-01 … TC-12 and the acceptance
criteria.

Development was validated offline against mocked `docker`, `curl` and Graph:
all nine exit-code paths, chunked upload with mid-transfer resume, the retry
table (401 refresh-once, 429 `Retry-After`, 5xx backoff), folder idempotency,
the retention floor, and the generated payload against the appendix A schema.
That covers the logic — it is not a substitute for running TC-01 … TC-12 on
the real VPS against the real tenant.
