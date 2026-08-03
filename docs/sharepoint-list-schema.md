# SharePoint list `DB_Backup_Log`

Spec: MBC-SPEC-BACKUP-001 v0.2, appendix B.

Every backup run writes one row per site into this list — successes included.
That matters: the dead-man switch (flow 2) works by looking for the *absence*
of a success row, so a list that only recorded failures would be useless.

Create the list on the same site that holds the `DB_Backups` library.

---

## Columns

| Column | Type | Notes |
|---|---|---|
| `Title` | Single line of text | holds `run_id`, e.g. `20260731_0200` |
| `Site` | Choice | `marketplace_misa`, `skuapp`, `misa_sync_engine`, `mbc360`, `mbc_tool_ads`, `powerapp_sku`, `timesheet_misa`, `mbc_ocr`, `product_database` |
| `Status` | Choice | `success`, `failed`, `fatal` — **the column the dead-man switch filters on** |
| `StepFailed` | Single line of text | `precheck` / `dump` / `verify` / `encrypt` / `upload` / `rotate` |
| `FileName` | Single line of text | dump file name |
| `SizeMB` | Number, 1 decimal | tracks how the database is growing |
| `DurationSec` | Number | a dump that keeps getting slower is an early warning |
| `Sha256` | Single line of text | checked at restore time |
| `Encrypted` | Yes/No | tells you up front whether a decryption key is needed |
| `SharePointUrl` | Hyperlink | direct link to the file |
| `ErrorMessage` | Multiple lines of text | error detail |
| `Hostname` | Single line of text | useful once there is more than one host |
| `Created` | (built in) | the dead-man switch filters on this |

## Additional configuration

- **Indexed columns:** `Site`, `Status`, `Created`. Without indexes the
  dead-man switch query slows down badly once the list passes 5,000 items —
  and at 9 rows a day that happens inside two years.
- **Default view:** sort `Created` descending, filter `Status ne success`, so
  failures are the first thing visible on opening the list.
- **List retention:** keep 12 months, then export to Excel and delete the old
  items.

---

## Creating it with PnP PowerShell

```powershell
Connect-PnPOnline -Url "https://maxbiocare.sharepoint.com/sites/<site>" -Interactive

New-PnPList -Title "DB_Backup_Log" -Template GenericList

$choices = @("marketplace_misa","skuapp","misa_sync_engine","mbc360",
             "mbc_tool_ads","powerapp_sku","timesheet_misa","mbc_ocr",
             "product_database")

Add-PnPField -List "DB_Backup_Log" -DisplayName "Site" -InternalName "Site" `
  -Type Choice -Choices $choices -AddToDefaultView
Add-PnPField -List "DB_Backup_Log" -DisplayName "Status" -InternalName "Status" `
  -Type Choice -Choices "success","failed","fatal" -AddToDefaultView
Add-PnPField -List "DB_Backup_Log" -DisplayName "StepFailed" -InternalName "StepFailed" -Type Text
Add-PnPField -List "DB_Backup_Log" -DisplayName "FileName" -InternalName "FileName" -Type Text
Add-PnPField -List "DB_Backup_Log" -DisplayName "SizeMB" -InternalName "SizeMB" -Type Number -AddToDefaultView
Add-PnPField -List "DB_Backup_Log" -DisplayName "DurationSec" -InternalName "DurationSec" -Type Number
Add-PnPField -List "DB_Backup_Log" -DisplayName "Sha256" -InternalName "Sha256" -Type Text
Add-PnPField -List "DB_Backup_Log" -DisplayName "Encrypted" -InternalName "Encrypted" -Type Boolean
Add-PnPField -List "DB_Backup_Log" -DisplayName "SharePointUrl" -InternalName "SharePointUrl" -Type URL
Add-PnPField -List "DB_Backup_Log" -DisplayName "ErrorMessage" -InternalName "ErrorMessage" -Type Note
Add-PnPField -List "DB_Backup_Log" -DisplayName "Hostname" -InternalName "Hostname" -Type Text

# Indexes - do this now, not after the list has grown
Set-PnPField -List "DB_Backup_Log" -Identity "Site"    -Values @{Indexed=$true}
Set-PnPField -List "DB_Backup_Log" -Identity "Status"  -Values @{Indexed=$true}
Set-PnPField -List "DB_Backup_Log" -Identity "Created" -Values @{Indexed=$true}
```
