# Google Calendar for the Omarchy bar

The next meeting in your bar; Google Calendar's day/week grid behind it. Click
an event to open it, or to join its call.

```
August 2026  ‹ ›                                       [D][3][W] ⟳
        MON      TUE      WED      THU      FRI
         24       25       26      (27)      28
 09:00           ███ Standup ███
 10:00  ██ 1:1 ██   ▢ Design review        ← outline = not answered
 11:00  ─────────────●──────────────────   ← now
 12:00                    ███ Lunch ███
```

## Install

```bash
git clone <this-repo> ~/.config/omarchy/plugins/leonavas.calendar
omarchy bar put leonavas.calendar --before omarchy.clock
```

## Connect

Google needs an OAuth client to identify the app. One-time, ~5 minutes.

1. [Create a project](https://console.cloud.google.com/) and
   [enable the Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com).
2. **APIs & Services → OAuth consent screen** (now called *Google Auth
   Platform*):
   - **Audience** → user type **Internal** if your Workspace allows it, else
     **External** + add yourself under *Test users*.
   - **Data Access** → add the scope `.../auth/calendar.readonly`.
3. **Clients → Create client** → **Desktop app** → download the JSON.
4. Run, then log in in the browser:

   ```bash
   bin/gcal-auth --client-secret-file ~/Downloads/client_secret_*.json
   ```

`bin/gcal-auth --status` shows the connected account; `--reset` forgets it.
Only calendars ticked in Google Calendar's sidebar are shown.

## Use

| | |
|---|---|
| Click the bar | Open the grid |
| Middle click the bar | Join the next meeting |
| Click an event | Open its card — Join, guests, location, description |
| Middle click an event | Join its call directly |
| `d` `3` `w` | Day / 3-day / week |
| `t` `r` | Today / sync now |
| `←` `→` `↑` `↓` | Step period / scroll hours |
| `Esc` | Back out one layer |

Accepted invitations are solid, unanswered ones outlined, declined ones hidden.

**Multiple Google accounts.** Join and *Open in Google* ask which account to
open as. Links are pinned with `authuser=<address>` rather than `/u/<number>/`,
because the number is just sign-in order and shifts. List your other addresses
in the `googleAccounts` setting to have them offered too.

## Settings

Editable from the bar's settings panel, or in `~/.config/omarchy/shell.json`.
Notable ones: `view`, `workweek`, `weekStartDay`, `use24Hour`, `hourHeight`,
`gridHeight`, `syncMinutes`, `daysBack`/`daysAhead`, `meetingOpenMode`,
`googleAccounts`, `labelMode`, `warnMinutes`, `showDeclined`. Full list with
descriptions in `manifest.json`.

## How it works

`bin/gcal-sync` fetches the calendar and writes
`~/.local/state/omarchy/calendar/events.json`; the panel watches that file.
Split this way because the sync holds a refresh token and must keep working
while the panel is closed, and because a bar exists per monitor — one file
means one fetch, shared. Writes are atomic, so a watcher never sees a partial
one; errors are written into the same file, so the panel can report them and
keep showing the last good data.

Events are flattened to epoch milliseconds (QML never parses a timezone), a
resolved colour, and one meeting URL picked from `conferenceData`,
`hangoutLink`, the location, or the description, in that order.

The Python is stdlib-only — no `google-api-python-client`.

```
Calendar.qml   bar label + button        bin/gcal-auth      one-time login
Panel.qml      grid + event card         bin/gcal-sync      fetch → cache
Model.js       dates, layout, colour     bin/gcalcommon.py  token/HTTP
```

`Model.js` is pure and runs under node, which is where the layout packing and
date maths are tested.

## Credentials

Tokens live in `~/.local/state/omarchy/calendar/` (`0700`, files `0600`) —
never in this directory, so the repo is safe to publish. Your OAuth client
secret is not a password: for an installed app Google treats it as public,
which is why the flow also uses PKCE.

## Troubleshooting

**"Not connected to Google"** — run `bin/gcal-auth`, or click the footer.

**Nothing after connecting** — run `bin/gcal-sync` by hand; it prints what it
fetched or why it failed. `--include-hidden` also fetches unticked calendars.

**"Google issued no refresh token"** — Google only issues one on first consent.
Revoke at [Account permissions](https://myaccount.google.com/permissions) and
re-run.

**Re-auth every 7 days** — an *External* app in *Testing* expires refresh
tokens weekly. Publish the app to stop that.

**A code change does nothing** — the shell hot-reloads plugin files, but a live
panel can survive it. `omarchy restart shell` always applies.

## Licence

MIT.
