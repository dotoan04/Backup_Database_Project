# Power Automate flow 1 — "Backup Result Handler"

Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.5.2.

Receives one HTTP POST per backup run and turns it into log rows plus a Teams
message.

---

## Step 1 — Trigger: When an HTTP request is received

Paste the contents of [`payload-schema.json`](payload-schema.json) into
**Request Body JSON Schema**.

> Every nullable field is declared as `["string", "null"]`. Declaring them as
> plain `string` makes the flow fail schema validation the first time a
> successful site sends `"error": null` — which is every successful site.

Save the flow, then copy the generated **HTTP POST URL** into
`FLOW_WEBHOOK_URL` in `/opt/mbc-backup/.env`.

**That URL carries a `sig=` parameter and is a credential.** Anyone holding it
can invoke the flow. Never commit it, never paste it into a ticket or chat.

---

## Step 2 — Apply to each: write one row per site

Apply to each → `sites`

Inside it, **Create item** in `DB_Backup_Log`:

| Field | Expression |
|---|---|
| Title | `triggerBody()?['run_id']` |
| Site | `items('Apply_to_each')?['site']` |
| Status | `items('Apply_to_each')?['status']` |
| StepFailed | `items('Apply_to_each')?['step_failed']` |
| FileName | `items('Apply_to_each')?['file_name']` |
| SizeMB | `items('Apply_to_each')?['size_mb']` |
| DurationSec | `items('Apply_to_each')?['duration_sec']` |
| Sha256 | `items('Apply_to_each')?['sha256']` |
| Encrypted | `items('Apply_to_each')?['encrypted']` |
| SharePointUrl | `items('Apply_to_each')?['sharepoint_url']` |
| ErrorMessage | `items('Apply_to_each')?['error']` |
| Hostname | `triggerBody()?['hostname']` |

Set **Concurrency Control → On, Degree of parallelism 1** so the nine rows
land in a predictable order.

> Every site is logged, success included. Flow 2 detects a missing backup by
> looking for the absence of a success row; if only failures were logged there
> would be nothing to look for.

---

## Step 3 — Switch on `status`

Switch → `triggerBody()?['status']`

### Case `success` — one summary message to Teams

Post a message in a chat or channel → IT channel:

```
✅ Backup Database — @{formatDateTime(triggerBody()?['started_at'], 'dd/MM/yyyy HH:mm')}

@{join(select(triggerBody()?['sites'], concat(item()?['site'], ' — ', item()?['size_mb'], ' MB — ', item()?['duration_sec'], 's')), '
')}

Total: @{triggerBody()?['summary']?['total_size_mb']} MB · @{triggerBody()?['summary']?['success_count']}/@{triggerBody()?['summary']?['total_sites']} sites · verified · uploaded to SharePoint
Folder: /DB_Backups/ (30 day retention)
```

> One aggregated message per day, not nine. Nine success messages a day get
> muted within a fortnight, and a muted channel means the failure messages
> are missed too.

### Case `failed` — Teams with @mention plus email

Get an @mention token for a user → the technical owner.

Teams message:

```
🔴 Backup Database FAILED — @{formatDateTime(triggerBody()?['started_at'], 'dd/MM/yyyy HH:mm')}
@{outputs('Get_an_@mention_token_for_a_user')?['body/atMention']}

@{triggerBody()?['summary']?['success_count']}/@{triggerBody()?['summary']?['total_sites']} sites OK · @{triggerBody()?['summary']?['failed_count']} FAILED

Failed sites:
@{join(select(filter(triggerBody()?['sites'], equals(item()?['status'], 'failed')), concat(item()?['site'], ' — step: ', item()?['step_failed'], ' — ', item()?['error'])), '
')}

Last 20 log lines:
@{triggerBody()?['log_tail']}

⚠ The dump files are still in /var/backups/mbc on the server.
  Do NOT delete them until the upload has succeeded.
```

Send an email (V2) to the technical owner with the same content — Teams alone
is not enough at 02:00.

### Case `fatal` — high importance

Same as `failed`, but:
- Subject: `[FATAL] Backup Database — manual check required`
- Email importance: **High**
- Body adds: `The script died mid-run. The state is unknown — check
  journalctl -u mbc-backup -n 200 before the next scheduled run.`

### Default case

Should never fire. Send a Teams message saying `Unknown status:
@{triggerBody()?['status']}` so a payload change does not silently do nothing.

---

## Testing

```bash
# Success
curl -X POST "$FLOW_WEBHOOK_URL" -H "Content-Type: application/json" -d '{
  "run_id":"TEST_0001","status":"success","hostname":"test",
  "started_at":"2026-07-31T02:00:00+07:00","finished_at":"2026-07-31T02:00:58+07:00",
  "duration_sec":58,"script_version":"1.0.0",
  "summary":{"total_sites":1,"success_count":1,"failed_count":0,"total_size_mb":4.1},
  "sites":[{"site":"mbc_tool_ads","status":"success","step_failed":null,
            "file_name":"t.dump","size_mb":4.1,"sha256":"abc","duration_sec":6,
            "encrypted":false,"sharepoint_url":"https://example.com","error":null}],
  "log_tail":"test"}'

# Failure - check that the null fields do not break validation
curl -X POST "$FLOW_WEBHOOK_URL" -H "Content-Type: application/json" -d '{
  "run_id":"TEST_0002","status":"failed","hostname":"test",
  "started_at":"2026-07-31T02:00:00+07:00","finished_at":"2026-07-31T02:01:00+07:00",
  "duration_sec":60,"script_version":"1.0.0",
  "summary":{"total_sites":1,"success_count":0,"failed_count":1,"total_size_mb":0},
  "sites":[{"site":"misa_sync_engine","status":"failed","step_failed":"upload",
            "file_name":"t.dump","size_mb":2.2,"sha256":"def","duration_sec":4,
            "encrypted":false,"sharepoint_url":null,"error":"HTTP 401"}],
  "log_tail":"upload attempt 1/5 -> 401"}'
```

Delete the `TEST_*` rows from `DB_Backup_Log` afterwards.
