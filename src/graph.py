#!/usr/bin/env python3
"""Minimal Microsoft Graph client shared by upload.py and rotate.py.

Spec: MBC-SPEC-BACKUP-001 v0.2, section 5.4.

Deliberately built on the Python standard library plus the openssl binary and
nothing else. This runs as root on a production database host; adding pip
packages there means adding an update surface for very little gain.

Supports both authentication methods from section 5.4.1:
  - client secret        (AZ_CLIENT_SECRET)
  - certificate / JWT    (AZ_CERT_PATH, signed via openssl, RS256)

Certificate authentication is preferred. A client secret expires after at most
24 months, and when it does, uploads start returning 401 and the backup dies
quietly (spec 5.4.1).
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

GRAPH_ROOT = "https://graph.microsoft.com/v1.0"
LOGIN_ROOT = "https://login.microsoftonline.com"

# Retry policy, spec 5.4.5
MAX_RETRIES = 5
BACKOFF_SECONDS = [2, 4, 8, 16, 32]
TOKEN_REFRESH_MARGIN = 300  # refresh a token with less than 5 minutes to live


class GraphError(Exception):
    """A Graph call failed in a way that is not worth retrying."""

    def __init__(self, message, status=None, body=None):
        super().__init__(message)
        self.status = status
        self.body = body


def log(message):
    """Diagnostics go to stderr; stdout is reserved for machine-readable JSON."""
    print("[graph] %s" % message, file=sys.stderr, flush=True)


def load_env(path):
    """Read KEY=VALUE lines from an .env file without overwriting the environment.

    backup.sh already exports everything before calling these scripts, so this
    only matters when upload.py or rotate.py is run by hand.
    """
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if value[:1] in ('"', "'") and value[-1:] == value[:1] and len(value) > 1:
                value = value[1:-1]
            else:
                # Strip a trailing ` # comment`, the way bash does when sourcing.
                for marker in (" #", "\t#"):
                    if marker in value:
                        value = value.split(marker, 1)[0].rstrip()
            if key and key not in os.environ:
                os.environ[key] = value


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


class GraphClient:
    """Token handling plus a request helper that implements the retry table."""

    def __init__(self, tenant_id, client_id, client_secret=None, cert_path=None):
        if not tenant_id or not client_id:
            raise GraphError("AZ_TENANT_ID and AZ_CLIENT_ID must both be set")
        if not client_secret and not cert_path:
            raise GraphError("set either AZ_CLIENT_SECRET or AZ_CERT_PATH")
        self.tenant_id = tenant_id
        self.client_id = client_id
        self.client_secret = client_secret
        self.cert_path = cert_path
        self._token = None
        self._expires_at = 0

    # -- authentication -----------------------------------------------------

    def _client_assertion(self):
        """Build an RS256 JWT signed with the certificate private key.

        openssl does the signing so that no third-party crypto library is
        required. AZ_CERT_PATH must be one PEM file holding both the private
        key and the certificate.
        """
        try:
            der = subprocess.run(
                ["openssl", "x509", "-in", self.cert_path, "-outform", "der"],
                capture_output=True, check=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as exc:
            raise GraphError("cannot read certificate %s: %s" % (self.cert_path, exc))

        header = {
            "alg": "RS256",
            "typ": "JWT",
            # Entra ID identifies the key by the SHA-256 thumbprint of the DER
            # encoded certificate.
            "x5t#S256": _b64url(hashlib.sha256(der).digest()),
        }
        now = int(time.time())
        payload = {
            "aud": "%s/%s/oauth2/v2.0/token" % (LOGIN_ROOT, self.tenant_id),
            "iss": self.client_id,
            "sub": self.client_id,
            "jti": str(uuid.uuid4()),
            "nbf": now - 60,
            "exp": now + 600,
        }
        signing_input = "%s.%s" % (
            _b64url(json.dumps(header, separators=(",", ":")).encode()),
            _b64url(json.dumps(payload, separators=(",", ":")).encode()),
        )
        try:
            signature = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", self.cert_path],
                input=signing_input.encode(), capture_output=True, check=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as exc:
            raise GraphError("cannot sign with the private key in %s: %s"
                             % (self.cert_path, exc))
        return "%s.%s" % (signing_input, _b64url(signature))

    def _acquire_token(self):
        data = {
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "scope": "https://graph.microsoft.com/.default",
        }
        if self.client_secret:
            data["client_secret"] = self.client_secret
        else:
            data["client_assertion_type"] = \
                "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
            data["client_assertion"] = self._client_assertion()

        url = "%s/%s/oauth2/v2.0/token" % (LOGIN_ROOT, self.tenant_id)
        request = urllib.request.Request(
            url, data=urllib.parse.urlencode(data).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:600]
            raise GraphError("token request rejected (HTTP %s): %s" % (exc.code, detail),
                             status=exc.code, body=detail)
        except urllib.error.URLError as exc:
            raise GraphError("cannot reach the token endpoint: %s" % exc.reason)

        self._token = body["access_token"]
        self._expires_at = time.time() + int(body.get("expires_in", 3600))
        log("access token acquired, valid for %ss" % body.get("expires_in", "?"))

    def token(self, force_refresh=False):
        """A token is good for about an hour; refresh before it lapses so a long
        chunked upload does not fail halfway through (spec 5.4.2)."""
        if force_refresh or not self._token or \
                time.time() > self._expires_at - TOKEN_REFRESH_MARGIN:
            self._acquire_token()
        return self._token

    # -- HTTP ---------------------------------------------------------------

    def request(self, method, url, data=None, headers=None, auth=True,
                parse_json=True, timeout=300, retries=MAX_RETRIES,
                allow_404=False):
        """Perform a Graph call, applying the error table from spec 5.4.5.

        401  -> refresh the token and retry once; a second 401 means the
                credential itself is wrong or expired, so fail immediately
        429  -> honour Retry-After exactly, never retry sooner
        5xx  -> exponential backoff 2, 4, 8, 16, 32 seconds
        """
        if not url.startswith("http"):
            url = GRAPH_ROOT + url

        attempt = 0
        token_refreshed = False
        while True:
            attempt += 1
            request_headers = dict(headers or {})
            if auth:
                request_headers["Authorization"] = "Bearer %s" % self.token()

            request = urllib.request.Request(url, data=data, method=method,
                                             headers=request_headers)
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    raw = response.read()
                    if not parse_json:
                        return response.status, raw
                    if not raw:
                        return response.status, None
                    return response.status, json.loads(raw.decode("utf-8"))

            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", "replace")
                status = exc.code

                if status == 404 and allow_404:
                    return 404, None

                if status == 401 and not token_refreshed:
                    log("401 on %s - refreshing the access token and retrying once" % url)
                    self.token(force_refresh=True)
                    token_refreshed = True
                    continue

                if status == 401:
                    raise GraphError(
                        "HTTP 401 - the access token was rejected twice; check "
                        "whether the client secret or certificate has expired",
                        status=status, body=body[:600])

                if status == 429:
                    wait = int(exc.headers.get("Retry-After", "10") or 10)
                    if attempt > retries:
                        raise GraphError("HTTP 429 - still throttled after %d attempts"
                                         % retries, status=status, body=body[:600])
                    log("429 throttled, waiting %ss as instructed by Retry-After" % wait)
                    time.sleep(wait)
                    continue

                if 500 <= status < 600:
                    if attempt > retries:
                        raise GraphError("HTTP %s after %d attempts: %s"
                                         % (status, retries, body[:300]),
                                         status=status, body=body[:600])
                    wait = BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)]
                    log("HTTP %s on attempt %d, retrying in %ss" % (status, attempt, wait))
                    time.sleep(wait)
                    continue

                raise GraphError("HTTP %s on %s %s: %s"
                                 % (status, method, url, body[:400]),
                                 status=status, body=body[:600])

            except urllib.error.URLError as exc:
                if attempt > retries:
                    raise GraphError("network error after %d attempts: %s"
                                     % (retries, exc.reason))
                wait = BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)]
                log("network error (%s) on attempt %d, retrying in %ss"
                    % (exc.reason, attempt, wait))
                time.sleep(wait)

    # -- drive helpers ------------------------------------------------------

    @staticmethod
    def encode_path(path):
        """Percent-encode a drive path, keeping the separators intact."""
        return urllib.parse.quote(path.strip("/"), safe="/")

    def resolve_drive(self, site_id, library_name=None):
        """Return the Graph base path for the selected document library.

        `/sites/{site-id}/drive` is only the site's default library. Resolve a
        named library to its drive id so uploads do not silently become a
        folder in Documents.
        """
        if not library_name:
            return "/sites/%s/drive" % site_id

        wanted = library_name.casefold()
        url = "/sites/%s/drives?$select=id,name,webUrl&$top=200" % site_id
        available = []
        while url:
            _, body = self.request("GET", url)
            for drive in body.get("value", []):
                name = str(drive.get("name", ""))
                if name:
                    available.append(name)
                if name.casefold() == wanted:
                    log("using SharePoint document library %s" % name)
                    return "/drives/%s" % drive["id"]
            url = body.get("@odata.nextLink")

        suffix = "; available: %s" % ", ".join(sorted(available)) if available else ""
        raise GraphError("SharePoint document library '%s' was not found%s"
                         % (library_name, suffix))

    def get_item_by_path(self, drive, path, select=None):
        url = "%s/root:/%s" % (drive, self.encode_path(path))
        if select:
            url += "?$select=%s" % select
        status, body = self.request("GET", url, allow_404=True)
        return body if status != 404 else None

    def ensure_folder(self, drive, path):
        """Create every missing segment of `path`, idempotently (spec 5.4.3).

        conflictBehavior is "fail" rather than "replace": replacing an existing
        folder would discard the backups already in it. A 409 simply means a
        parallel run created the folder first, which is fine.
        """
        segments = [s for s in path.strip("/").split("/") if s]
        walked = ""
        for segment in segments:
            parent = walked
            walked = "%s/%s" % (walked, segment) if walked else segment

            if self.get_item_by_path(drive, walked, select="id") is not None:
                continue

            if parent:
                url = "%s/root:/%s:/children" % (drive, self.encode_path(parent))
            else:
                url = "%s/root/children" % drive

            payload = json.dumps({
                "name": segment,
                "folder": {},
                "@microsoft.graph.conflictBehavior": "fail",
            }).encode()
            try:
                self.request("POST", url, data=payload,
                             headers={"Content-Type": "application/json"})
                log("created folder /%s" % walked)
            except GraphError as exc:
                if exc.status == 409:
                    log("folder /%s already existed" % walked)
                    continue
                raise
        return path


def client_from_env(base_dir="/opt/mbc-backup"):
    load_env(os.path.join(base_dir, ".env"))
    return GraphClient(
        tenant_id=os.environ.get("AZ_TENANT_ID", "").strip(),
        client_id=os.environ.get("AZ_CLIENT_ID", "").strip(),
        client_secret=os.environ.get("AZ_CLIENT_SECRET", "").strip() or None,
        cert_path=os.environ.get("AZ_CERT_PATH", "").strip() or None,
    )


def site_id_from_env():
    site_id = os.environ.get("SP_SITE_ID", "").strip()
    if not site_id:
        raise GraphError("SP_SITE_ID is not set")
    return site_id
