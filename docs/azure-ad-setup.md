# Azure AD app registration and SharePoint permissions

Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.4.1.

The backup host authenticates to Microsoft Graph as an application, with write
access to exactly one SharePoint site and nothing else.

---

## 1. Register the application

Azure Portal → **Microsoft Entra ID** → App registrations → New registration

| Field | Value |
|---|---|
| Name | `MBC-DB-Backup` |
| Supported account types | Single tenant |
| Redirect URI | leave empty (this is a daemon, there is no sign-in) |

Note the **Application (client) ID** and **Directory (tenant) ID**.

---

## 2. Add the API permission

API permissions → Add a permission → Microsoft Graph → **Application
permissions** → `Sites.Selected` → Add → **Grant admin consent**.

> Do not use `Sites.ReadWrite.All`. That grants write access to *every*
> SharePoint site in the tenant, so a leaked credential becomes a
> tenant-wide problem. `Sites.Selected` grants nothing until it is explicitly
> pointed at a site, which keeps the blast radius to one site.

---

## 3. Find the site-id

```
GET https://graph.microsoft.com/v1.0/sites/maxbiocare.sharepoint.com:/sites/<site-name>
```

The `id` in the response has the form
`maxbiocare.sharepoint.com,<guid>,<guid>`. That whole string is `SP_SITE_ID`.

---

## 4. Grant write access on that one site

Run as a tenant administrator (Graph Explorer works):

```http
POST https://graph.microsoft.com/v1.0/sites/{site-id}/permissions
Content-Type: application/json

{
  "roles": ["write"],
  "grantedToIdentities": [{
    "application": {
      "id":          "{client-id}",
      "displayName": "MBC-DB-Backup"
    }
  }]
}
```

Verify:

```http
GET https://graph.microsoft.com/v1.0/sites/{site-id}/permissions
```

### A note on `write` vs `delete`

`rotate.py` deletes files past retention, which the `write` role covers.
Section 6.5 suggests splitting delete off into a separate identity so that a
compromised backup credential cannot wipe the backup history. Graph's
site-permission roles do not offer that split directly. The practical
mitigations are versioning plus the recycle bin, both of which are enabled in
step 6 below.

---

## 5. Credentials — certificate is strongly preferred

### 5a. Certificate (recommended)

A client secret expires after at most 24 months. When it does, uploads start
returning 401 and the backup dies quietly — which is exactly the failure mode
the whole dead-man switch exists to catch. A certificate can be issued with a
longer life and rotated on a schedule.

```bash
# On the VPS, as root
openssl req -x509 -newkey rsa:2048 -keyout /opt/mbc-backup/mbc-backup.key \
  -out /opt/mbc-backup/mbc-backup.crt -days 730 -nodes \
  -subj "/CN=MBC-DB-Backup"

# graph.py expects one PEM holding both the key and the certificate
cat /opt/mbc-backup/mbc-backup.key /opt/mbc-backup/mbc-backup.crt \
  > /opt/mbc-backup/mbc-backup.pem
chmod 600 /opt/mbc-backup/mbc-backup.pem
shred -u /opt/mbc-backup/mbc-backup.key
```

Upload **only** `mbc-backup.crt` under Certificates & secrets → Certificates →
Upload certificate. The private key never leaves the server.

In `.env`:

```
AZ_CERT_PATH=/opt/mbc-backup/mbc-backup.pem
AZ_CLIENT_SECRET=
```

### 5b. Client secret (fallback)

Certificates & secrets → New client secret. Copy the value immediately, it is
shown once.

```
AZ_CLIENT_SECRET=<value>
AZ_CERT_PATH=
```

**Put the expiry date in a shared calendar with a reminder 30 days ahead.**
Without that reminder, the first sign of expiry is a silent backup outage.

---

## 6. SharePoint library settings

Select the destination in `.env`:

```
# Empty means the site's default Documents library.
SP_LIBRARY_NAME=Backup_Database_Devs
# Folder inside that library.
SP_LIBRARY_PATH=DB_Backups
```

`SP_LIBRARY_PATH` does not select a document library. Graph exposes each
document library as a separate drive, so `upload.py` resolves
`SP_LIBRARY_NAME` to the correct drive before creating this folder path.

On the selected library holding `DB_Backups`:

| Setting | Value | Why |
|---|---|---|
| Folder permissions | IT security group only, break inheritance from the site | dump files are a full copy of the database |
| Sharing links | disabled for this library | a shared link is an unauthenticated copy of the whole database |
| Versioning | on, limited to 3 versions | unlimited versions of 40 MB dumps fills the quota quickly |
| Audit log | on | shows who downloaded a backup |
| Recycle bin | default 93 days | recovery path if ransomware deletes the backups |

---

## 7. Test before running the backup

```bash
cd /opt/mbc-backup
echo "graph connectivity test $(date -Is)" > /tmp/mbc-test.txt
./upload.py --remote-folder DB_Backups/_selftest --file /tmp/mbc-test.txt
```

Expected: `{"ok": true, ...}` and the file visible in the library. Delete the
`_selftest` folder afterwards.

Common failures:

| Symptom | Cause |
|---|---|
| `token request rejected (HTTP 401)` | wrong client secret, or the certificate was never uploaded |
| `HTTP 403` on the upload | `Sites.Selected` granted, but step 4 was skipped |
| `HTTP 404` on the site | `SP_SITE_ID` is wrong — re-read step 3 |
| `cannot sign with the private key` | `AZ_CERT_PATH` points at a file without the private key in it |
