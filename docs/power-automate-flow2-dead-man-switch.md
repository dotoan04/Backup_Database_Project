# Power Automate flow 2 — "Backup Dead-man Switch"

Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.6.

Flow 1 reports what the backup *did*. This flow reports what it *failed to
do*.

If the server dies, the timer is disabled, the script is deleted, or the host
loses network, nothing is ever sent — the system goes quiet and everyone
assumes it is fine. That failure mode is only detectable by actively checking
for the absence of a signal, which is what this flow does.

It runs entirely inside Power Automate, so it keeps working when the VPS is
down. That is the whole point.

---

## Step 1 — Trigger: Recurrence

| Setting | Value |
|---|---|
| Frequency | Day |
| Interval | 1 |
| Time zone | (UTC+07:00) Bangkok, Hanoi, Jakarta |
| At these hours | 9 |
| At these minutes | 0 |

09:00 rather than, say, 03:00: an alert nobody is awake to read is not an
alert.

---

## Step 2 — Get items from `DB_Backup_Log`

- Site Address / List Name: the site holding `DB_Backup_Log`
- **Filter Query:**
  ```
  Created ge datetime'@{addHours(utcNow(), -26)}'
  ```
- **Top Count:** 100

### Why 26 hours

| Backup cadence | Window | Reason |
|---|---|---|
| Daily at 02:00 | **26 hours** | 24h + 2h of headroom for `RandomizedDelaySec=900` and the run time itself |
| Weekly | 8 days | 7 days + 1 day |
| Every 30 days | 32 days | far too long — up to 32 days before you learn the backup is dead. One more reason the cadence is daily. |

---

## Step 3 — Initialise the expected-sites array

Initialize variable → `ExpectedSites`, type Array:

```json
["marketplace_misa","skuapp","misa_sync_engine","mbc360","mbc_tool_ads",
 "powerapp_sku","timesheet_misa","mbc_ocr","product_database"]
```

Initialize variable → `MissingSites`, type Array, value `[]`.

> Better long-term: keep this list in its own small SharePoint list so adding
> a project does not mean editing the flow. Hard-coding it is acceptable to
> start with, but it will drift out of date the first time a project is added
> and nobody remembers this flow exists.

---

## Step 4 — For each expected site, look for a success row

Apply to each → `variables('ExpectedSites')`

Inside, **Condition**:

```
length(
  filter(
    body('Get_items')?['value'],
    and(
      equals(item()?['Site']?['Value'], items('Apply_to_each')),
      equals(item()?['Status']?['Value'], 'success')
    )
  )
) is greater than 0
```

- **If yes:** nothing to do.
- **If no:** Append to array variable → `MissingSites` ← `items('Apply_to_each')`

> The condition checks for a `success` row specifically, not for any row. A
> site that failed all night produces `failed` rows, and those must not be
> mistaken for a working backup.

---

## Step 5 — Alert when anything is missing

Condition: `length(variables('MissingSites'))` is greater than `0`

If yes — Teams message with @mention **and** email, high importance:

```
🚨 [MISSING BACKUP] — no successful backup in the last 26 hours

@{outputs('Get_an_@mention_token_for_a_user')?['body/atMention']}

Sites with no successful backup:
@{join(variables('MissingSites'), ', ')}

Check, in this order:
  1. Is the VPS up?
  2. systemctl list-timers mbc-backup.timer      - is the timer still armed?
  3. journalctl -u mbc-backup -n 200             - did the service run at all?
  4. Is FLOW_WEBHOOK_URL still valid?            - the backup may have run and
                                                   only the notification failed
Runbook: /opt/mbc-backup/runbook.md
```

Email subject: `[MISSING BACKUP] @{join(variables('MissingSites'), ', ')}`

---

## Limits of this design

The switch lives in Power Automate, separate from the host, so it survives the
host dying. It does not survive the whole M365 tenant going down — but if that
happens, backup notifications are not the first problem.

It also cannot tell "the backup did not run" apart from "the backup ran and
the notification failed" (exit code 60). The alert text above asks the reader
to check both.

---

## Testing (test case TC-08)

```bash
# On the VPS
systemctl stop mbc-backup.timer
systemctl disable mbc-backup.timer
```

Wait for 09:00 the next day: all nine sites should be reported missing.

Then restore it:

```bash
systemctl enable --now mbc-backup.timer
systemctl list-timers mbc-backup.timer
```

Faster alternative: temporarily change the trigger to run every 5 minutes and
narrow the filter window to `-1` hours. Set both back afterwards.
