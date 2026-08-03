#!/usr/bin/env python3
"""Delete SharePoint backup files past the retention window.

Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.7.2.

Usage:
    rotate.py [--days 30] [--dry-run] [--site mbc_tool_ads]

Files are grouped into backup sets by the run timestamp embedded in the file
name, so a dump is never deleted while its .sha256 and .meta.json survive.

Two safety rules on top of the plain age check:
  - REMOTE_MIN_KEEP_SETS newest sets per site are always kept, whatever their
    age. If the backup job has been broken for two months, retention must not
    finish the job by deleting the last working copy.
  - A file whose timestamp cannot be parsed is left alone.

Note on quota: Graph DELETE moves items to the SharePoint recycle bin, where
they keep counting against the site quota for 93 days (spec 5.7.2).
"""

import argparse
import datetime
import json
import os
import re
import sys

from graph import GraphError, client_from_env, log, site_id_from_env

# mbc_tool_ads_backup_20260731_0200.dump  /  mbc_tool_ads_globals_20260731_0200.sql.gz
TIMESTAMP_RE = re.compile(r"_(?:backup|globals)_(\d{8}_\d{4})\b")


def parse_run_id(name):
    match = TIMESTAMP_RE.search(name)
    return match.group(1) if match else None


def read_sites(path):
    sites = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            sites.append(line.split("|")[0].strip())
    return sites


def list_children(client, site_id, path):
    url = "/sites/%s/drive/root:/%s:/children?$select=id,name,folder,createdDateTime,size&$top=200" % (
        site_id, client.encode_path(path))
    items = []
    while url:
        status, body = client.request("GET", url, allow_404=True)
        if status == 404 or body is None:
            return []
        items.extend(body.get("value", []))
        url = body.get("@odata.nextLink")
    return items


def _newest_created(items):
    """Latest createdDateTime in a backup set, as an aware UTC datetime."""
    stamps = []
    for item in items:
        raw = item.get("createdDateTime")
        if not raw:
            continue
        try:
            stamps.append(datetime.datetime.fromisoformat(raw.replace("Z", "+00:00")))
        except ValueError:
            continue
    return max(stamps) if stamps else None


def rotate_site(client, site_id, library, site, cutoff, min_keep_sets, dry_run):
    """Return (deleted_count, freed_bytes, kept_sets) for one site."""
    site_folder = "%s/%s_db_backup" % (library, site)
    year_folders = [item for item in list_children(client, site_id, site_folder)
                    if "folder" in item]
    if not year_folders:
        log("%s: no year folders yet, nothing to rotate" % site)
        return 0, 0, 0

    # run_id -> list of (year_folder_name, item)
    sets = {}
    unparsed = 0
    for year in year_folders:
        for item in list_children(client, site_id, "%s/%s" % (site_folder, year["name"])):
            if "folder" in item:
                continue
            run_id = parse_run_id(item["name"])
            if run_id is None:
                unparsed += 1
                continue
            sets.setdefault(run_id, []).append(item)

    if unparsed:
        log("%s: %d file(s) with an unrecognised name left untouched" % (site, unparsed))

    ordered = sorted(sets.keys(), reverse=True)
    protected = set(ordered[:min_keep_sets])
    deleted = 0
    freed = 0

    for run_id in ordered:
        if run_id in protected:
            continue
        # Age comes from createdDateTime, which Graph reports in UTC. The run
        # id in the file name is server-local time and would be off by the
        # timezone offset.
        created = _newest_created(sets[run_id])
        if created is None:
            log("%s: set %s has no usable createdDateTime, skipping" % (site, run_id))
            continue
        if created >= cutoff:
            continue

        for item in sets[run_id]:
            if dry_run:
                log("%s: would delete %s (%d bytes)" % (site, item["name"], item.get("size", 0)))
            else:
                client.request("DELETE", "/sites/%s/drive/items/%s" % (site_id, item["id"]),
                               parse_json=False)
                log("%s: deleted %s" % (site, item["name"]))
            deleted += 1
            freed += int(item.get("size", 0) or 0)

    return deleted, freed, len(ordered)


def main():
    parser = argparse.ArgumentParser(description="Rotate old backups on SharePoint")
    parser.add_argument("--days", type=int,
                        default=int(os.environ.get("REMOTE_RETENTION_DAYS", "30")))
    parser.add_argument("--site", action="append", dest="sites",
                        help="limit to these sites, repeatable")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--base-dir",
                        default=os.environ.get("MBC_BASE_DIR", "/opt/mbc-backup"))
    args = parser.parse_args()

    try:
        client = client_from_env(args.base_dir)
        site_id = site_id_from_env()
        library = os.environ.get("SP_LIBRARY_PATH", "DB_Backups").strip("/")
        min_keep = int(os.environ.get("REMOTE_MIN_KEEP_SETS", "3"))

        sites = args.sites or read_sites(os.path.join(args.base_dir, "sites.conf"))
        cutoff = datetime.datetime.now(datetime.timezone.utc) - \
            datetime.timedelta(days=args.days)
        log("retention %d days, cutoff %s, keeping at least %d sets per site"
            % (args.days, cutoff.date(), min_keep))

        report = []
        total_deleted = 0
        total_freed = 0
        failures = []

        for site in sites:
            try:
                deleted, freed, kept = rotate_site(
                    client, site_id, library, site, cutoff, min_keep, args.dry_run)
            except GraphError as exc:
                # One unhealthy site must not stop the others from rotating.
                log("%s: rotation failed: %s" % (site, exc))
                failures.append({"site": site, "error": str(exc)})
                continue
            total_deleted += deleted
            total_freed += freed
            report.append({"site": site, "deleted": deleted,
                           "freed_bytes": freed, "sets_present": kept})

        json.dump({
            "ok": not failures,
            "dry_run": args.dry_run,
            "retention_days": args.days,
            "deleted": total_deleted,
            "freed_mb": round(total_freed / 1048576, 1),
            "sites": report,
            "failures": failures,
        }, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1 if failures else 0

    except GraphError as exc:
        log("rotation failed: %s" % exc)
        json.dump({"ok": False, "error": str(exc)}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
