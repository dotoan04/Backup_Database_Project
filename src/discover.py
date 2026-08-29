#!/usr/bin/env python3
"""Survey the host for databases and report which ones are not backed up yet.

Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.1 - keeping the inventory honest.

What it does
------------
Walks every running container, works out what kind of database each one has,
and cross-references the result against the two inventories. It answers the
question you actually have when a new project appears on the VPS:

    is this PostgreSQL or SQLite, what is the site name, what is the path,
    and is it already being backed up?

It prints paste-ready lines for sites.conf and sites-files.conf. It does NOT
write to them. Enrolling a database is a decision, not a side effect:

  - Nobody has classified the new data yet (spec 3.4, PII). Encryption is off
    by default, so auto-enrolling would copy unclassified data to SharePoint.
  - A 50 GB database appearing at 02:00 would hit the disk floor and then fail
    every night.
  - A site name can never be changed once used: file names and the SharePoint
    folder are built from it, so a bad guess splits the history in two.

Read-only. It runs `docker inspect`, one `SELECT datname` per PostgreSQL
container, and opens candidate SQLite files with mode=ro. It never writes, and
never stops or restarts anything.

Usage:
    discover.py                 # full report
    discover.py --new-only      # only what is missing from the inventories
    discover.py --scan-depth 6  # dig deeper for SQLite files (default 4)
"""

import argparse
import json
import os
import sqlite3
import subprocess
import sys

BASE_DIR = os.environ.get("MBC_BASE_DIR", "/opt/mbc-backup")

SQLITE_MAGIC = b"SQLite format 3\x00"

# Image name fragments that identify an engine. Checked as substrings against
# the lowercased image, so pgvector/pgvector:pg16 and postgis both land on
# postgres.
IMAGE_ENGINES = [
    ("postgres", "postgres"), ("pgvector", "postgres"),
    ("timescale", "postgres"), ("postgis", "postgres"),
    ("mariadb", "mysql"), ("mysql", "mysql"), ("percona", "mysql"),
    ("mongo", "mongodb"), ("redis", "redis"),
    ("clickhouse", "clickhouse"), ("mssql", "mssql"), ("sqlserver", "mssql"),
]

# Engines this project can back up today.
SUPPORTED = {"postgres", "sqlite"}

# Directories never worth walking when hunting for SQLite files. They are
# large, and anything in them is a cache or a dependency, not application data.
SKIP_DIRS = {
    "node_modules", ".git", ".cache", "__pycache__", ".next", ".nuxt",
    "dist", "build", "vendor", ".venv", "venv", "site-packages",
    ".pnpm-store", "tmp", "logs",
}

# A SQLite file this small holds nothing but a header. Almost always a leftover
# or a library's own scratch file rather than application data.
MIN_INTERESTING_SIZE = 4096

MAX_FILES_SCANNED = 20000

# Fragments in a file name that mark a SQLite database as scratch rather than
# data of record. Matched against the file name only, never the whole path: a
# real database living under a directory called `temp` is still a real
# database, and guessing from the path produces false alarms.
CACHE_HINTS = ("cache", "tmp", "temp", "session", "queue", "celery", "lock")

# Databases that are only one part of a larger store. Snapshotting the file on
# its own gives something that cannot be restored by itself, which is worse
# than not backing it up: it looks like a backup and is not one.
PARTIAL_STORES = {
    "chroma.sqlite3":
        "Chroma keeps its vectors in sibling directories of binary segment "
        "files; this database is only the catalogue, so a snapshot of it "
        "alone cannot rebuild the store",
}


def run(args, timeout=30):
    """Run a command, return (rc, stdout). stderr is folded into stdout."""
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, str(exc)
    return proc.returncode, proc.stdout.strip() or proc.stderr.strip()


def docker_json(args):
    rc, out = run(["docker"] + args)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def running_containers():
    rc, out = run(["docker", "ps", "--format", "{{.Names}}"])
    if rc != 0:
        print("Could not talk to Docker: %s" % out, file=sys.stderr)
        print("Run this as root, or as a user in the docker group.", file=sys.stderr)
        sys.exit(1)
    names = [n for n in out.splitlines() if n.strip()]
    return docker_json(["inspect"] + names) or [] if names else []


def env_map(details):
    result = {}
    for item in (details.get("Config") or {}).get("Env") or []:
        key, _, value = item.partition("=")
        result[key] = value
    return result


def classify(details, env):
    """Best guess at the engine this container serves.

    Returns (engine, certain). `certain` is False when the guess came only
    from environment variables, which is not enough on its own: every
    application that talks to PostgreSQL carries POSTGRES_PASSWORD in its
    environment so it can connect. Ten application containers on this fleet
    were misread as database servers that way. The caller confirms an
    uncertain guess by probing for the client binary.
    """
    image = ((details.get("Config") or {}).get("Image") or "").lower()
    for fragment, engine in IMAGE_ENGINES:
        if fragment in image:
            return engine, True

    # PGDATA points at a data directory, so only a server sets it. The others
    # are connection settings and prove nothing by themselves.
    if "PGDATA" in env:
        return "postgres", True
    if "POSTGRES_PASSWORD" in env or "POSTGRES_DB" in env:
        return "postgres", False
    if "MYSQL_ROOT_PASSWORD" in env or "MARIADB_ROOT_PASSWORD" in env:
        return "mysql", False
    if "MONGO_INITDB_ROOT_USERNAME" in env:
        return "mongodb", False
    return "application", True


def has_command(container, binary):
    """Is a binary on PATH inside the container?

    A PostgreSQL server image always ships psql; an application image almost
    never does. That is what separates the server from the things talking to
    it when the image name gives nothing away.
    """
    rc, _ = run(["docker", "exec", container, "sh", "-c",
                 "command -v %s >/dev/null 2>&1" % binary], timeout=15)
    return rc == 0


def compose_project(details, name):
    labels = (details.get("Config") or {}).get("Labels") or {}
    return labels.get("com.docker.compose.project") or name


def postgres_databases(name, user, password):
    """Every connectable database in the container, not just POSTGRES_DB.

    A container often holds more than one, and the inventory has historically
    assumed one per container.
    """
    query = ("SELECT datname FROM pg_database "
             "WHERE datallowconn AND NOT datistemplate "
             "AND datname <> 'postgres' ORDER BY datname")
    rc, out = run(["docker", "exec", "-e", "PGPASSWORD=%s" % password, name,
                   "psql", "-U", user, "-d", "postgres", "-tAc", query])
    if rc != 0:
        return None, out
    return [line.strip() for line in out.splitlines() if line.strip()], None


def mounts_of(details):
    """(type, host_path, container_path) for every mount, volumes included.

    Named volumes are worth scanning too: a SQLite file inside one needs
    backing up just as much as one on a bind mount.
    """
    result = []
    for mount in details.get("Mounts") or []:
        source = mount.get("Source")
        if source:
            result.append((mount.get("Type", "?"), source,
                           mount.get("Destination", "?")))
    return result


def looks_like_sqlite(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(16) == SQLITE_MAGIC
    except OSError:
        return False


def probe_sqlite(path):
    """Open read-only and list the tables. Returns (tables, error)."""
    quoted = path.replace("?", "%3f").replace("#", "%23")
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % quoted, uri=True, timeout=10)
        try:
            names = [r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name NOT LIKE 'sqlite_%' ORDER BY name")]
            return names, None
        finally:
            conn.close()
    except sqlite3.Error as exc:
        return None, str(exc)


def find_sqlite_files(root, max_depth, budget):
    """Walk a mount looking for SQLite databases.

    A mount can also be a single file - `./data/app.db:/app/app.db` is a
    perfectly ordinary compose line - so that case is handled before walking.
    """
    found = []
    if os.path.isfile(root):
        if looks_like_sqlite(root):
            found.append(root)
        return found, budget - 1
    if not os.path.isdir(root):
        return found, budget
    root_depth = root.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
        if dirpath.count(os.sep) - root_depth >= max_depth:
            dirnames[:] = []
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for filename in filenames:
            if budget <= 0:
                return found, 0
            budget -= 1
            # -wal and -shm are sidecars of a database already in the list.
            if filename.endswith(("-wal", "-shm", "-journal")):
                continue
            path = os.path.join(dirpath, filename)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            if size < MIN_INTERESTING_SIZE or not looks_like_sqlite(path):
                continue
            found.append(path)
    return found, budget


def review_reason(path, destination):
    """Why this file may not be data worth backing up. None means it is.

    A judgement call, so the answer is a sentence rather than a verdict: these
    are listed for a human to decide on, never silently dropped. Not knowing a
    database exists is the failure this whole tool is against.
    """
    name = os.path.basename(path)
    if name in PARTIAL_STORES:
        return PARTIAL_STORES[name]
    if name.startswith("."):
        return "a hidden file, which is usually a library's own scratch database"
    for hint in CACHE_HINTS:
        if hint in name.lower():
            return "the file name contains %r - confirm it is data and not a cache" % hint
    if destination.rstrip("/") == "/tmp" or destination.startswith("/tmp/"):
        return "mounted at %s, which applications treat as scratch space" % destination
    return None


def read_inventory(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            line = raw.strip()
            if line and not line.startswith("#"):
                rows.append([f.strip() for f in line.split("|")])
    return rows


def slug(text):
    out = "".join(c if c.isalnum() else "_" for c in text.lower())
    while "__" in out:
        out = out.replace("__", "_")
    return out.strip("_")


def unique_name(candidate, taken):
    name = candidate
    suffix = 2
    while name in taken:
        name = "%s_%d" % (candidate, suffix)
        suffix += 1
    taken.add(name)
    return name


def main():
    parser = argparse.ArgumentParser(
        description="Find databases on this host that are not backed up yet")
    parser.add_argument("--base-dir", default=BASE_DIR)
    parser.add_argument("--scan-depth", type=int, default=4,
                        help="how deep to walk each mount looking for SQLite files")
    parser.add_argument("--new-only", action="store_true",
                        help="skip the sites already covered")
    args = parser.parse_args()

    pg_rows = read_inventory(os.path.join(args.base_dir, "sites.conf"))
    file_rows = read_inventory(os.path.join(args.base_dir, "sites-files.conf"))

    known_pg = {(r[1], r[3]) for r in pg_rows if len(r) >= 4}
    known_paths = {os.path.realpath(r[2]) for r in file_rows if len(r) >= 3}
    taken_names = {r[0] for r in pg_rows + file_rows if r}

    containers = running_containers()
    covered, new_pg, new_sqlite, unsupported, unclear = [], [], [], [], []
    budget = MAX_FILES_SCANNED
    # The same file can be mounted into more than one container, and two mounts
    # of the same container can overlap. Report each database once.
    seen_files = set()

    for details in containers:
        name = (details.get("Name") or "").lstrip("/")
        env = env_map(details)
        engine, certain = classify(details, env)
        project = compose_project(details, name)
        image = (details.get("Config") or {}).get("Image") or "?"

        # An engine guessed from environment variables alone has to be
        # confirmed, or every application container that connects to a
        # database gets reported as one. When the client binary is absent this
        # is an application, and it falls through to the SQLite scan below -
        # which is also where its own database may be hiding.
        if not certain and engine in ("postgres", "mysql", "mongodb"):
            client = {"postgres": "psql", "mysql": "mysql", "mongodb": "mongosh"}[engine]
            if not has_command(name, client):
                engine = "application"

        if engine == "postgres":
            user = env.get("POSTGRES_USER", "postgres")
            password = env.get("POSTGRES_PASSWORD", "")
            if not password:
                unclear.append((name, image,
                                "POSTGRES_PASSWORD is not in the container environment - "
                                "backup.sh reads it from there, so this needs a look by hand"))
                continue
            databases, error = postgres_databases(name, user, password)
            if databases is None:
                unclear.append((name, image, "could not list databases: %s" % error))
                continue
            for database in databases:
                if (name, database) in known_pg:
                    covered.append(("postgres", name, database))
                    continue
                # analytics/analytics should be `analytics`, not
                # `analytics_analytics`. The database name is only added when
                # it carries information the project name does not.
                base = slug(project) if (len(databases) == 1
                                         or slug(database) == slug(project)) \
                    else slug("%s_%s" % (project, database))
                new_pg.append({
                    "sitename": unique_name(base, taken_names),
                    "container": name, "user": user, "database": database,
                    "image": image,
                })
            continue

        if engine in ("mysql", "mongodb", "mssql", "clickhouse"):
            unsupported.append((name, image, engine))
            continue
        if engine == "redis":
            continue   # a cache, not a database of record

        # Anything left is an application container. Its data may still be a
        # SQLite file sitting on one of its mounts.
        for mount_type, source, destination in mounts_of(details):
            files, budget = find_sqlite_files(source, args.scan_depth, budget)
            for path in files:
                real = os.path.realpath(path)
                if real in seen_files:
                    continue
                seen_files.add(real)
                if real in known_paths:
                    covered.append(("sqlite", name, path))
                    continue
                tables, error = probe_sqlite(path)
                if tables is None:
                    unclear.append((name, image,
                                    "%s looks like SQLite but could not be opened: %s"
                                    % (path, error)))
                    continue
                if not tables:
                    continue   # a real SQLite file, but empty - not data yet
                stem = os.path.splitext(os.path.basename(path))[0].lstrip(".")
                base = slug(project if stem in ("app", "db", "database", "data")
                            else "%s_%s" % (project, stem))
                new_sqlite.append({
                    "sitename": unique_name(base, taken_names),
                    "path": path, "tables": tables, "image": image,
                    "container": name, "mount": "%s %s -> %s" % (mount_type, source, destination),
                    "size": os.path.getsize(path),
                    "wal": os.path.exists(path + "-wal"),
                    "review": review_reason(path, destination),
                })

    # ---- report --------------------------------------------------------------
    print("Scanned %d running containers against %s" % (len(containers), args.base_dir))
    print()

    if covered and not args.new_only:
        print("ALREADY BACKED UP (%d)" % len(covered))
        for engine, container, what in sorted(covered):
            print("  %-9s %-32s %s" % (engine, container, what))
        print()

    if new_pg:
        print("NEW - PostgreSQL (%d)" % len(new_pg))
        for item in new_pg:
            print("  container %s  (%s)" % (item["container"], item["image"]))
            print("    database %s, user %s" % (item["database"], item["user"]))
        print()
        print("  Add to /opt/mbc-backup/sites.conf:")
        print()
        for item in new_pg:
            print("    %s|%s|%s|%s" % (item["sitename"], item["container"],
                                       item["user"], item["database"]))
        print()

    def describe_sqlite(item):
        print("  %s" % item["path"])
        print("    container %s  (%s)" % (item["container"], item["image"]))
        print("    mount     %s" % item["mount"])
        print("    %d bytes%s, tables: %s"
              % (item["size"], ", WAL active" if item["wal"] else "",
                 ", ".join(item["tables"][:8])
                 + (" ..." if len(item["tables"]) > 8 else "")))
        if item["review"]:
            print("    NOTE      %s" % item["review"])

    data_sqlite = [i for i in new_sqlite if not i["review"]]
    review_sqlite = [i for i in new_sqlite if i["review"]]

    if data_sqlite:
        print("NEW - SQLite (%d)" % len(data_sqlite))
        for item in data_sqlite:
            describe_sqlite(item)
        print()
        print("  Add to /opt/mbc-backup/sites-files.conf:")
        print()
        for item in data_sqlite:
            print("    %s|sqlite|%s" % (item["sitename"], item["path"]))
        print()

    if review_sqlite:
        print("NEW - SQLite, REVIEW BEFORE ADDING (%d)" % len(review_sqlite))
        for item in review_sqlite:
            describe_sqlite(item)
        print()
        print("  These look like scratch or partial data rather than a database")
        print("  of record. They are listed because not knowing a database exists")
        print("  is worse than deciding not to back it up. The lines below are")
        print("  commented out on purpose - uncomment only what you have checked:")
        print()
        for item in review_sqlite:
            print("    #%s|sqlite|%s" % (item["sitename"], item["path"]))
        print()

    if unsupported:
        print("FOUND BUT NOT SUPPORTED (%d)" % len(unsupported))
        for name, image, engine in unsupported:
            print("  %-32s %-14s %s" % (name, engine, image))
        print("  These are real databases with no backup. Deciding not to back")
        print("  them up is fine; not knowing about them is not.")
        print()

    if unclear:
        print("NEEDS A HUMAN (%d)" % len(unclear))
        for name, image, reason in unclear:
            print("  %s (%s)" % (name, image))
            print("    %s" % reason)
        print()

    if budget <= 0:
        print("NOTE: the file scan hit its %d-file budget and stopped early."
              % MAX_FILES_SCANNED)
        print("      Some SQLite databases may be missing from this report.")
        print()

    if not (new_pg or new_sqlite or unsupported or unclear):
        print("Nothing new. Every database found is already in an inventory.")
        return 0

    print("Nothing was written. Review the site names before pasting them in:")
    print("  - a site name can never change afterwards, so make it describe the")
    print("    application, not the database file")
    print("  - it must be unique across BOTH inventories")
    print("  - after adding, run backup.sh by hand, then test-restore.sh, then")
    print("    add the name to ExpectedApps in Flow 2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
