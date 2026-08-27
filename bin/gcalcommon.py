"""Shared plumbing for the leonavas.calendar bar plugin.

Stdlib only, on purpose: the plugin has to keep working after a `pacman -Syu`
rebuilds python, and pulling google-api-python-client in for what amounts to
four HTTPS calls would put the widget at the mercy of a dependency tree it
does not otherwise need.
"""

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
API_BASE = "https://www.googleapis.com/calendar/v3"

# Read-only is all the widget ever needs: it draws the calendar and opens
# meeting links, it never writes an event back.
SCOPE = "https://www.googleapis.com/auth/calendar.readonly"

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy", "calendar")
CREDENTIALS_FILE = os.path.join(STATE_DIR, "credentials.json")
TOKEN_FILE = os.path.join(STATE_DIR, "token.json")
EVENTS_FILE = os.path.join(STATE_DIR, "events.json")

USER_AGENT = "omarchy-leonavas.calendar/1.0"


class AuthError(Exception):
    """Raised when the stored credentials are missing, revoked, or rejected."""


def ensure_state_dir():
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def write_json_private(path, payload):
    """Write 0600 and rename into place.

    The QML side watches these files, so a reader must never catch a half
    written one: it would parse as invalid JSON and blank the panel for a
    frame. Writing to a sibling temp file and renaming makes the swap atomic.
    """
    ensure_state_dir()
    tmp = path + ".tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    handle = os.fdopen(os.open(tmp, flags, 0o600), "w", encoding="utf-8")
    with handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def http_json(url, data=None, headers=None, method=None, timeout=20):
    """One request, JSON in and JSON out, with Google's error body preserved.

    Google reports an expired grant as a 400 whose body says which of the
    several 400s it is, so the body has to survive the HTTPError to be
    classifiable upstream.
    """
    body = None
    request_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if headers:
        request_headers.update(headers)
    if data is not None:
        if isinstance(data, dict):
            body = urllib.parse.urlencode(data).encode("utf-8")
            request_headers.setdefault(
                "Content-Type", "application/x-www-form-urlencoded")
        else:
            body = data

    request = urllib.request.Request(
        url, data=body, headers=request_headers, method=method)
    context = ssl.create_default_context()
    try:
        with urllib.request.urlopen(request, timeout=timeout,
                                    context=context) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = {"error": raw[:400]}
        message = parsed.get("error_description") or parsed.get("error")
        if isinstance(message, dict):
            message = message.get("message", str(message))
        detail = "HTTP %s: %s" % (error.code, message or "request failed")
        if error.code in (400, 401) and _is_grant_failure(parsed):
            raise AuthError(detail) from error
        raise RuntimeError(detail) from error


def _is_grant_failure(parsed):
    """Tell a dead refresh token apart from an ordinary bad request."""
    code = str(parsed.get("error") or "")
    if code in ("invalid_grant", "invalid_client", "unauthorized_client"):
        return True
    nested = parsed.get("error")
    if isinstance(nested, dict):
        return str(nested.get("status") or "") == "UNAUTHENTICATED"
    return False


def load_credentials():
    credentials = read_json(CREDENTIALS_FILE)
    if not credentials or not credentials.get("refresh_token"):
        raise AuthError(
            "not authorized yet — run the plugin's bin/gcal-auth once")
    return credentials


def access_token(force=False):
    """Return a live access token, refreshing only when the cached one aged out.

    Google's access tokens last an hour while the widget syncs every few
    minutes, so caching the token is the difference between one token request
    an hour and one per sync.
    """
    credentials = load_credentials()
    cached = read_json(TOKEN_FILE) or {}
    if (not force and cached.get("access_token")
            and float(cached.get("expires_at", 0)) > time.time() + 120):
        return cached["access_token"]

    payload = {
        "client_id": credentials["client_id"],
        "client_secret": credentials.get("client_secret", ""),
        "refresh_token": credentials["refresh_token"],
        "grant_type": "refresh_token",
    }
    response = http_json(TOKEN_ENDPOINT, data=payload)
    token = response.get("access_token")
    if not token:
        raise AuthError("Google returned no access token")
    write_json_private(TOKEN_FILE, {
        "access_token": token,
        "expires_at": time.time() + float(response.get("expires_in", 3600)),
    })
    return token


def api_get(path, params=None, token=None, retry_auth=True):
    """GET against the Calendar API, refreshing the token once on a 401."""
    url = API_BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    bearer = token or access_token()
    try:
        return http_json(url, headers={"Authorization": "Bearer " + bearer})
    except AuthError:
        if not retry_auth:
            raise
        # A token can be rejected before its cached expiry — password change,
        # session revoke, clock skew. One forced refresh separates that from
        # a genuinely dead grant.
        return api_get(path, params=params, token=access_token(force=True),
                       retry_auth=False)


def eprint(*args):
    print(*args, file=sys.stderr)
