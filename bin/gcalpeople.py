"""Your organisation's directory, with photos, for the calendar's avatars.

Google Workspace keeps a profile per colleague — name, address, photo — that
the Calendar API does not carry. The People API's directory listing does,
under the `directory.readonly` scope. This keeps a local copy:

  ~/.local/state/omarchy/calendar/people.json   names, addresses, photo paths
  ~/.local/state/omarchy/calendar/photos/       one small JPEG per person

refreshed at most once a day by gcal-sync, or by hand with bin/gcal-people.
A personal @gmail.com account has no directory: the listing comes back empty
and the panel keeps drawing initials.
"""

import hashlib
import os
import time
import urllib.parse
import urllib.request
import ssl

from gcalcommon import (
    DIRECTORY_SCOPE, STATE_DIR, USER_AGENT, access_token, granted_scopes,
    http_json, read_json, write_json_private)

PEOPLE_FILE = os.path.join(STATE_DIR, "people.json")
PHOTOS_DIR = os.path.join(STATE_DIR, "photos")
PEOPLE_API = "https://people.googleapis.com/v1/people:listDirectoryPeople"
MAX_AGE = 24 * 3600


def can_read_directory():
    return DIRECTORY_SCOPE in granted_scopes()


def _photo_path(email):
    digest = hashlib.sha1(email.encode("utf-8")).hexdigest()[:20]
    return os.path.join(PHOTOS_DIR, digest + ".jpg")


def _sized(url, size=128):
    # Google photo URLs end in a size directive such as "=s100"; ask for one
    # crisp enough at 2x without pulling the full-size original.
    base = url.split("=")[0] if "googleusercontent.com" in url else url
    return base + "=s%d-c" % size if "googleusercontent.com" in url else url


def _download(url, path):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=20,
                                context=ssl.create_default_context()) as response:
        data = response.read()
    tmp = path + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


def _list_directory(token):
    people = []
    page = None
    while True:
        params = {
            "readMask": "names,emailAddresses,photos",
            "sources": "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE",
            "pageSize": 1000,
        }
        if page:
            params["pageToken"] = page
        response = http_json(PEOPLE_API + "?" + urllib.parse.urlencode(params),
                             headers={"Authorization": "Bearer " + token})
        people.extend(response.get("people") or [])
        page = response.get("nextPageToken")
        if not page:
            return people


def refresh_people(force=False):
    """Refresh people.json and the photos; returns how many people it holds.

    Never raises for an ordinary failure (no scope, People API off, offline):
    the error is written into people.json and the old copy stays usable.
    """
    previous = read_json(PEOPLE_FILE) or {}
    if not force and time.time() - float(previous.get("fetchedAt", 0)) < MAX_AGE:
        return len(previous.get("people") or [])
    if not can_read_directory():
        return len(previous.get("people") or [])

    os.makedirs(PHOTOS_DIR, mode=0o700, exist_ok=True)
    known = {p.get("email"): p for p in previous.get("people") or []}
    result = {"fetchedAt": time.time(), "error": None, "people": []}
    try:
        entries = _list_directory(access_token())
    except Exception as error:  # noqa: BLE001 - kept, reported, not fatal
        previous["error"] = str(error)
        previous["fetchedAt"] = time.time()
        write_json_private(PEOPLE_FILE, previous)
        return len(previous.get("people") or [])

    for entry in entries:
        emails = [e.get("value", "").lower() for e in entry.get("emailAddresses") or []]
        emails = [e for e in emails if e]
        if not emails:
            continue
        name = ((entry.get("names") or [{}])[0]).get("displayName", "")
        photo = ""
        source = ""
        for candidate in entry.get("photos") or []:
            # The generated letter avatar is "default"; the panel draws its
            # own initials, which match the theme.
            if candidate.get("url") and not candidate.get("default"):
                source = _sized(candidate["url"])
                break
        if source:
            path = _photo_path(emails[0])
            old = known.get(emails[0]) or {}
            try:
                if old.get("photoSource") != source or not os.path.exists(path):
                    _download(source, path)
                photo = path
            except Exception:  # noqa: BLE001 - a missing photo is initials
                photo = ""
        result["people"].append({
            "email": emails[0], "aliases": emails[1:], "name": name,
            "photo": photo, "photoSource": source,
        })

    write_json_private(PEOPLE_FILE, result)
    return len(result["people"])
