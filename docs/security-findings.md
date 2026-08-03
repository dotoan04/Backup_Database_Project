# Security findings from the survey of 31/07/2026

Spec: MBC-SPEC-BACKUP-001 v0.2, sections 6.4 and 6.5.

These are **outside the scope of the backup system** but were found while
surveying the VPS. The spec marks the first one as *handle before deploying
the backup*, and that ordering matters: a backup is a full copy of a database
that is currently reachable from the internet.

---

## 1. PRIORITY — `time-tracking-postgres` is exposed to the internet

Container `time-tracking-postgres` (PostgreSQL 15.17, site `timesheet_misa`)
publishes `0.0.0.0:5434→5432`. It listens on every interface including the
public IP, not just `127.0.0.1`. This is a database holding employee
timekeeping data, directly reachable from the internet.

### Confirm

```bash
# From outside the VPS. A successful connection means it is open.
nc -zv <public_ip_vps> 5434

# Rules Docker inserted
sudo iptables -S DOCKER-USER
```

### Why `ufw status` looks fine but is not

Docker inserts its own rules into the `DOCKER-USER` chain and `nat
PREROUTING`, both of which run **before** the `INPUT` chain where UFW
operates. A published port therefore bypasses UFW entirely. `ufw status`
showing `deny` gives false reassurance here — this catches people out
regularly.

### Fix (needs coordination, it changes `docker-compose.yml`)

```yaml
ports:
  - "127.0.0.1:5434:5432"    # add the 127.0.0.1 prefix
```

Then `docker compose up -d` for that project. Access from outside becomes an
SSH tunnel:

```bash
ssh -L 5434:127.0.0.1:5434 user@vps
```

### Immediate mitigation, no compose change needed

Block the port at the **cloud firewall / security group of the VPS
provider**. That layer sits outside the machine, so Docker cannot bypass it.
Do this today; do the compose fix properly afterwards.

---

## 2. Other services bound to `0.0.0.0`

All of these are commonly deployed with default credentials.

| Port | Service | Risk |
|---|---|---|
| 5434 | `time-tracking-postgres` | **direct database access — highest priority** |
| 9090 | prometheus | no authentication by default; exposes every infrastructure metric |
| 9000–9001 | minio | default `minioadmin` / `minioadmin` if never changed |
| 3001 | grafana | default `admin` / `admin` if never changed |
| 3000 | open-webui | AI chat interface, may contain internal data |

Same treatment: bind to `127.0.0.1` in compose, or block at the cloud
firewall, and reach them over an SSH tunnel.

## 3. `max-biocare-ai-adminer-1`

Currently in state `Created` (not running). Adminer is a web database admin
interface — starting it with a published port opens a direct door into the
database. Leave it stopped, or bind it to `127.0.0.1` only.

---

## 4. Ransomware resistance of the backups themselves

Spec 6.5. Modern ransomware looks for backups and encrypts or deletes them
too.

| Measure | Status in this implementation |
|---|---|
| Versioning + recycle bin on SharePoint | must be enabled by hand — see `azure-ad-setup.md` step 6 |
| App registration limited to one site | done, `Sites.Selected` |
| Separate identity for delete | **not implemented.** Graph site permissions do not split `write` from `delete`, so `rotate.py` uses the same credential. Versioning and the 93-day recycle bin are the compensating controls. |
| Offline copy, quarterly | operational task, not automated. An external disk, disconnected after copying, is the only true air gap. |
| SharePoint not mounted on the database server | respected — everything goes through the Graph API, so a compromised host cannot reach the backup library as a filesystem |

---

## 5. Where the encryption key lives

If `ENCRYPT_ENABLED=true`, the private key must **not** be on the backup
server and **not** on SharePoint. Storing the key next to the ciphertext makes
the encryption decorative.

Store it in the organisation password manager or Azure Key Vault, with a
paper copy in the safe. Record the location in `runbook.md` under Contacts —
a key nobody can find during an incident is the same as no backup at all.
