#!/usr/bin/env python3
"""Upload backup artifacts to SharePoint through Microsoft Graph.

Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.4.

Usage:
    upload.py --site mbc_tool_ads --year 2026 \
              --file /var/backups/mbc/mbc_tool_ads_backup_20260731_0200.dump \
              --file ...

    upload.py --remote-folder DB_Backups/_logs/2026-07 --file /var/log/...

stdout carries exactly one JSON object and nothing else, so backup.sh can read
it. All progress and diagnostics go to stderr.

    {"ok": true, "folder": "...", "primary_web_url": "...", "files": [...]}
"""

import argparse
import hashlib
import json
import os
import sys

from graph import GraphClient, GraphError, client_from_env, log, site_id_from_env

SIMPLE_UPLOAD_LIMIT = 4 * 1024 * 1024      # Graph cutoff for a plain PUT
CHUNK_SIZE = 10 * 1024 * 1024              # 10 MiB, a multiple of 320 KiB as required
MAX_SESSION_ATTEMPTS = 3
MAX_CHUNK_RESUMES = 10

# Only the real backup artifact is worth reporting back as the site link.
PRIMARY_SUFFIXES = (".dump", ".dump.age", ".dump.gpg")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def upload_small(client, drive, folder, name, path):
    """Single PUT. Only used for the sidecar files (.sha256, .meta.json)."""
    with open(path, "rb") as handle:
        payload = handle.read()
    url = "%s/root:/%s/%s:/content" % (
        drive, client.encode_path(folder), client.encode_path(name))
    _, body = client.request(
        "PUT", url, data=payload,
        headers={"Content-Type": "application/octet-stream"})
    return body


def upload_session(client, drive, folder, name, path, size):
    """Chunked upload with resume (spec 5.4.4).

    Database dumps are comfortably over the 4 MB simple-upload limit, so this
    is the path that actually matters. When a chunk fails, the session is asked
    which byte it got to and the upload continues from there rather than
    starting over.
    """
    create_url = "%s/root:/%s/%s:/createUploadSession" % (
        drive, client.encode_path(folder), client.encode_path(name))
    # "replace" is right here: re-running the backup for the same timestamp
    # should overwrite its own partial file, not create "file 1.dump".
    body = json.dumps({"item": {"@microsoft.graph.conflictBehavior": "replace"}}).encode()

    for session_attempt in range(1, MAX_SESSION_ATTEMPTS + 1):
        _, session = client.request("POST", create_url, data=body,
                                    headers={"Content-Type": "application/json"})
        upload_url = session["uploadUrl"]
        log("upload session created for %s (%d bytes, %d chunks)"
            % (name, size, (size + CHUNK_SIZE - 1) // CHUNK_SIZE))

        offset = 0
        # Bounded so a chunk that keeps failing ends the run with a clear
        # error instead of looping until TimeoutStartSec kills the service.
        resume_budget = MAX_CHUNK_RESUMES
        try:
            with open(path, "rb") as handle:
                while offset < size:
                    handle.seek(offset)
                    chunk = handle.read(min(CHUNK_SIZE, size - offset))
                    end = offset + len(chunk) - 1
                    headers = {
                        "Content-Length": str(len(chunk)),
                        "Content-Range": "bytes %d-%d/%d" % (offset, end, size),
                    }
                    try:
                        # The upload URL is pre-authenticated; sending a bearer
                        # token with it is rejected by some Graph front ends.
                        status, result = client.request(
                            "PUT", upload_url, data=chunk, headers=headers,
                            auth=False, timeout=600)
                    except GraphError as exc:
                        if exc.status == 404:
                            # Session expired - start a fresh one (spec 5.4.5).
                            log("upload session expired, creating a new one")
                            raise _SessionExpired()
                        resume_budget -= 1
                        if resume_budget <= 0:
                            raise GraphError(
                                "upload of %s stalled at byte %d: %s"
                                % (name, offset, exc))
                        # Ask the service how far it actually got instead of
                        # blindly repeating the same chunk.
                        offset = _resume_offset(client, upload_url, offset)
                        continue

                    if status in (200, 201):
                        log("%s uploaded" % name)
                        return result
                    offset = end + 1
            raise GraphError("upload of %s sent every byte but Graph never "
                             "confirmed the item" % name)
        except _SessionExpired:
            if session_attempt == MAX_SESSION_ATTEMPTS:
                raise GraphError("upload session for %s expired %d times"
                                 % (name, MAX_SESSION_ATTEMPTS))
            continue

    raise GraphError("upload of %s did not complete" % name)


class _SessionExpired(Exception):
    pass


def _resume_offset(client, upload_url, current):
    """Ask the session for nextExpectedRanges and continue from there."""
    try:
        _, state = client.request("GET", upload_url, auth=False, retries=2)
    except GraphError as exc:
        if exc.status == 404:
            raise _SessionExpired()
        raise
    ranges = (state or {}).get("nextExpectedRanges") or []
    if not ranges:
        raise GraphError("upload session reports no expected range and no completion")
    resumed = int(str(ranges[0]).split("-")[0])
    log("resuming upload at byte %d (was %d)" % (resumed, current))
    return resumed


def verify_upload(client, drive, folder, name, local_path, local_size, mode):
    """Post-upload check (spec 5.4.7). Mandatory: without it the run reports
    success for a file that may never have landed intact."""
    item = client.get_item_by_path(drive, "%s/%s" % (folder, name),
                                   select="id,name,size,webUrl,file")
    if item is None:
        raise GraphError("%s is not present on SharePoint after upload" % name)

    remote_size = int(item.get("size", -1))
    if remote_size != local_size:
        raise GraphError("size mismatch for %s: local %d bytes, SharePoint %d bytes"
                         % (name, local_size, remote_size))

    if mode == "download":
        # SharePoint exposes quickXorHash rather than sha256, so the only way
        # to compare against our own checksum is to read the file back. At
        # 20-40 MB per run that is cheap and removes all doubt.
        url = "%s/items/%s/content" % (drive, item["id"])
        _, raw = client.request("GET", url, parse_json=False, timeout=600)
        remote_sha = hashlib.sha256(raw).hexdigest()
        local_sha = sha256_file(local_path)
        if remote_sha != local_sha:
            raise GraphError("sha256 mismatch for %s: local %s, SharePoint %s"
                             % (name, local_sha[:16], remote_sha[:16]))
        log("%s verified by sha256 re-download" % name)
    else:
        log("%s verified by size" % name)

    return item


def main():
    parser = argparse.ArgumentParser(description="Upload backup files to SharePoint")
    parser.add_argument("--site", help="site name, used to build the folder path")
    parser.add_argument("--year", help="year folder, e.g. 2026")
    parser.add_argument("--remote-folder",
                        help="explicit folder path, overrides --site/--year")
    parser.add_argument("--file", action="append", dest="files", required=True,
                        help="local file to upload, repeatable")
    parser.add_argument("--base-dir", default=os.environ.get("MBC_BASE_DIR", "/opt/mbc-backup"))
    args = parser.parse_args()

    try:
        client = client_from_env(args.base_dir)
        site_id = site_id_from_env()
        library_name = os.environ.get("SP_LIBRARY_NAME", "").strip()
        drive = client.resolve_drive(site_id, library_name)
        library = os.environ.get("SP_LIBRARY_PATH", "DB_Backups").strip("/")
        verify_mode = os.environ.get("REMOTE_VERIFY", "download").strip().lower()

        if args.remote_folder:
            folder = args.remote_folder.strip("/")
        else:
            if not args.site or not args.year:
                raise GraphError("--site and --year are required without --remote-folder")
            # Split by year so no single folder collects thousands of items,
            # which makes the SharePoint view painfully slow (spec 5.4.6).
            folder = "%s/%s_db_backup/%s" % (library, args.site, args.year)

        client.ensure_folder(drive, folder)

        results = []
        primary_url = None
        for path in args.files:
            if not os.path.isfile(path):
                raise GraphError("local file not found: %s" % path)
            name = os.path.basename(path)
            size = os.path.getsize(path)

            if size < SIMPLE_UPLOAD_LIMIT:
                upload_small(client, drive, folder, name, path)
            else:
                upload_session(client, drive, folder, name, path, size)

            item = verify_upload(client, drive, folder, name, path, size, verify_mode)
            results.append({
                "name": name,
                "size": size,
                "item_id": item.get("id"),
                "web_url": item.get("webUrl"),
            })
            if name.endswith(PRIMARY_SUFFIXES) and primary_url is None:
                primary_url = item.get("webUrl")

        json.dump({
            "ok": True,
            "folder": folder,
            "primary_web_url": primary_url or (results[0]["web_url"] if results else None),
            "files": results,
        }, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    except GraphError as exc:
        log("upload failed: %s" % exc)
        json.dump({"ok": False, "error": str(exc)}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1
    except Exception as exc:  # noqa: BLE001 - must never leave backup.sh guessing
        log("unexpected upload error: %r" % exc)
        json.dump({"ok": False, "error": repr(exc)}, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
