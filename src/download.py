#!/usr/bin/env python3
"""Fetch a backup set back from SharePoint.

Spec: MBC-SPEC-BACKUP-001 v0.2, section 11 - the restore path.

The rest of the system pushes files to SharePoint. This pulls them back, which
is the direction that matters on the day something is broken. Without it the
runbook's "download it from SharePoint" means a browser on somebody's laptop
and then scp onto a server that may be the thing that just died.

A backup set is every file sharing one run timestamp: the dump or snapshot,
its .sha256, its .meta.json, and for PostgreSQL the globals. They are fetched
together because a dump without its checksum cannot be trusted and a dump
without its metadata cannot be checked against the row counts it started with.

The checksum is verified after every download. A file that does not match is
kept, with a loud message: it is evidence about what went wrong, and deleting
evidence during an incident is its own mistake.

Usage:
    download.py --site max_biocare_ai_webui --list
    download.py --site max_biocare_ai_webui                       # newest set
    download.py --site max_biocare_ai_webui --run-id 20260829_0137
    download.py --site mbc_ocr --year 2026 --dest-dir /var/backups/mbc/restore
"""

import argparse
import hashlib
import os
import re
import sys

from graph import GraphError, client_from_env, log, site_id_from_env

# Same grouping rule as rotate.py: files belong to one backup set when they
# carry the same run timestamp.
TIMESTAMP_RE = re.compile(r"_(?:backup|globals)_(\d{8}_\d{4})\b")

DEFAULT_DEST = "/var/backups/mbc/restore"


def parse_run_id(name):
    match = TIMESTAMP_RE.search(name)
    return match.group(1) if match else None


def list_children(client, drive, path):
    url = "%s/root:/%s:/children?$select=id,name,folder,size,createdDateTime&$top=200" % (
        drive, client.encode_path(path))
    items = []
    while url:
        status, body = client.request("GET", url, allow_404=True)
        if status == 404 or body is None:
            return []
        items.extend(body.get("value", []))
        url = body.get("@odata.nextLink")
    return items


def pick_year(client, drive, site_folder, wanted):
    # `"folder" in item`, not item.get("folder"): the facet is a dict, and
    # testing it for truth would drop any folder Graph describes with an empty
    # one. rotate.py checks it the same way.
    years = sorted(item["name"] for item in list_children(client, drive, site_folder)
                   if "folder" in item)
    if not years:
        raise GraphError("no backups found under %s - check the site name" % site_folder)
    if wanted:
        if wanted not in years:
            raise GraphError("no folder %s under %s; available: %s"
                             % (wanted, site_folder, ", ".join(years)))
        return wanted
    return years[-1]


def group_into_sets(items):
    """{run_id: [file items]}, ignoring anything without a run timestamp."""
    sets = {}
    for item in items:
        if "folder" in item:
            continue
        run_id = parse_run_id(item["name"])
        if run_id:
            sets.setdefault(run_id, []).append(item)
    return sets


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download_file(client, drive, folder, name, dest_dir):
    url = "%s/root:/%s/%s:/content" % (
        drive, client.encode_path(folder), client.encode_path(name))
    status, raw = client.request("GET", url, parse_json=False, allow_404=True)
    # The listing and the download are separate calls, so a file can be removed
    # in between - by retention, or by somebody tidying the library.
    if status == 404 or raw is None:
        raise GraphError("%s disappeared from %s between listing and download"
                         % (name, folder))
    path = os.path.join(dest_dir, name)
    with open(path, "wb") as handle:
        handle.write(raw)
    return path, len(raw)


def verify_against_checksum(paths):
    """Check every downloaded file that has a .sha256 next to it.

    Returns the list of failures. The .sha256 files are the two-column format
    sha256sum writes, so the digest is the first field.
    """
    failures = []
    by_name = {os.path.basename(p): p for p in paths}
    for name, path in sorted(by_name.items()):
        if not name.endswith(".sha256"):
            continue
        target = by_name.get(name[:-len(".sha256")])
        if not target:
            continue
        # A .sha256 that arrived damaged is itself a failed download. Reading
        # it strictly would raise UnicodeDecodeError and end the restore in a
        # traceback, which is the last thing anyone needs at this point.
        try:
            with open(path, encoding="utf-8") as handle:
                expected = handle.read().split()[0].strip()
        except (UnicodeDecodeError, IndexError):
            failures.append(os.path.basename(target))
            log("%s: its .sha256 file is not readable - the download was damaged"
                % os.path.basename(target))
            continue
        if len(expected) != 64 or not all(c in "0123456789abcdefABCDEF" for c in expected):
            failures.append(os.path.basename(target))
            log("%s: its .sha256 file does not contain a sha256 digest" % os.path.basename(target))
            continue
        actual = sha256_file(target)
        if actual == expected:
            log("%s: checksum OK" % os.path.basename(target))
        else:
            failures.append(os.path.basename(target))
            log("%s: CHECKSUM MISMATCH" % os.path.basename(target))
            log("  expected %s" % expected)
            log("  actual   %s" % actual)
    return failures


def main():
    parser = argparse.ArgumentParser(description="Download a backup set from SharePoint")
    parser.add_argument("--site", required=True)
    parser.add_argument("--year", help="defaults to the newest year folder")
    parser.add_argument("--run-id", help="e.g. 20260829_0137; defaults to the newest set")
    parser.add_argument("--dest-dir", default=DEFAULT_DEST)
    parser.add_argument("--list", action="store_true",
                        help="show the available backup sets and exit")
    parser.add_argument("--base-dir",
                        default=os.environ.get("MBC_BASE_DIR", "/opt/mbc-backup"))
    args = parser.parse_args()

    try:
        client = client_from_env(args.base_dir)
        site_id = site_id_from_env()
        library_name = os.environ.get("SP_LIBRARY_NAME", "").strip()
        drive = client.resolve_drive(site_id, library_name)
        library = os.environ.get("SP_LIBRARY_PATH", "DB_Backups").strip("/")

        site_folder = ("%s/%s_db_backup" % (library, args.site)).strip("/")
        year = pick_year(client, drive, site_folder, args.year)
        folder = "%s/%s" % (site_folder, year)

        sets = group_into_sets(list_children(client, drive, folder))
        if not sets:
            raise GraphError("no backup files in %s" % folder)

        if args.list:
            print("Backup sets in %s\n" % folder)
            for run_id in sorted(sets, reverse=True):
                files = sets[run_id]
                total = sum(int(f.get("size") or 0) for f in files)
                print("  %s  %2d files  %8.2f MB  %s"
                      % (run_id, len(files), total / 1048576,
                         files[0].get("createdDateTime", "")))
            return 0

        run_id = args.run_id or sorted(sets)[-1]
        if run_id not in sets:
            raise GraphError("no set %s in %s; run with --list to see what is there"
                             % (run_id, folder))

        os.makedirs(args.dest_dir, exist_ok=True)
        log("downloading set %s from %s" % (run_id, folder))
        paths = []
        for item in sorted(sets[run_id], key=lambda i: i["name"]):
            path, size = download_file(client, drive, folder, item["name"], args.dest_dir)
            log("  %s (%d bytes)" % (item["name"], size))
            paths.append(path)

        failures = verify_against_checksum(paths)

    except GraphError as exc:
        log("FAILED: %s" % exc)
        return 1

    print()
    if failures:
        # Kept on purpose: a corrupt download is evidence, and it is also worth
        # retrying before concluding the stored backup itself is bad.
        print("CHECKSUM FAILED for: %s" % ", ".join(failures))
        print("The files were kept in %s. Download again before concluding the"
              % args.dest_dir)
        print("backup on SharePoint is damaged - a truncated transfer looks the same.")
        return 1

    print("Downloaded %d files to %s, all checksums verified." % (len(paths), args.dest_dir))
    print()
    print("Next, prove it restores:")
    print("  %s/test-restore.sh %s %s"
          % (args.base_dir, args.site,
             os.path.join(args.dest_dir, next(
                 (os.path.basename(p) for p in paths
                  if p.endswith((".dump", ".db", ".dump.age", ".db.age"))), ""))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
