# leonavas.calendar

A Google Calendar bar widget for the Omarchy shell: your next meeting in the
bar, and a day / 3-day / week time grid behind a click. Click an event to see
it, or join its call in one gesture.

It is read-only: it never creates, edits or deletes an event in your calendar.

## What it does

- **What is on now or next, in the bar.** `10:00 Standup`, or `Standup in 12m`
  in countdown mode. The label turns the accent colour a few minutes before a
  meeting starts.
- **A toast when a meeting starts.** Click it to land straight in the call (or
  on the event in Google Calendar when it has no call). It stays for 20 seconds.
  Declined and all-day events never toast.
- **Join without hunting for the link.** Middle click the bar to join the next
  meeting, or middle click any event in the grid. Meet, Zoom, Teams, Webex,
  Whereby, Chime, GoToMeeting, BlueJeans and Around links are recognised —
  including links pasted into the location or description.
- **Start a meeting in one gesture.** Right click the bar opens a new Google
  Meet as your calendar's account, and puts the link on the clipboard once the
  room exists.
- **The real grid, not a list.** Day, 3-day and week views, an all-day band,
  ISO week numbers, a current-time line, and your Google colours. Accepted
  invitations are solid, unanswered ones outlined, declined ones faded and
  struck through.
- **Right the instant you look.** A background sync keeps a local cache warm.
  If a sync fails (offline, token expired), the last good data stays on screen
  and the error shows in the popup's footer.
- **Several Google accounts.** Links are pinned to the right account with
  `authuser=`, so you never open a meeting as the wrong you.
- **Vacation mode.** See [below](#vacation-mode).

## Interactions

In the bar:

| Gesture | What it does |
|---|---|
| Left click | Opens the grid (or the beach, on vacation) |
| Middle click | Joins the next meeting; syncs instead when it has no call |
| Right click | New Google Meet, link copied (configurable: sync, or open Google Calendar) |
| Wheel, popup open | Previous / next period |

In the popup:

| Key / gesture | What it does |
|---|---|
| Click an event | Opens its card: join, copy link, open in Google, guests, location, description |
| Middle click an event | Joins that call |
| `d` `3` `w` | Day / 3-day / week view |
| `t` | Back to today |
| `r` | Sync now |
| `v` | Vacation mode: pick an end, or end it if already on |
| `←` `→` | Previous / next period |
| `↑` `↓` | Scroll the hours |
| `Esc` | Back out one layer (card, dialog, popup) |

Everything can also be bound to a Hyprland key through the shell's IPC:

```bash
omarchy-shell leonavas.calendar toggle        # open / close the popup
omarchy-shell leonavas.calendar today         # also: day, week
omarchy-shell leonavas.calendar refresh       # sync now
omarchy-shell leonavas.calendar newMeeting    # new Meet, link on the clipboard
omarchy-shell leonavas.calendar copyLink      # next meeting's link to the clipboard
omarchy-shell leonavas.calendar openCalendar  # Google Calendar in the browser
omarchy-shell leonavas.calendar vacation      # vacation on (no end date) / off
omarchy-shell leonavas.calendar endVacation   # vacation off
```

## Vacation mode

For when you are away and do not want meetings in your face.

**What changes while it is on:**

- The bar shows a palm tree `󱁕` instead of the next meeting. Its tooltip says
  when you are back.
- The popup shows a beach — sea coming and going — instead of the grid, with
  when it ends, how long is left, **Change end** and **End vacation**.
- Meeting-start toasts are muted. Nothing is replayed when you come back.
- The label no longer lights up before meetings.

**What does not change:** your calendar. Nothing is declined, no out-of-office
is set, and Google is not told anything. The background sync keeps running, so
the grid is up to date the moment you return. Middle click on the bar still
joins the next meeting and right click still starts one.

**Turn it on:** the palm button in the popup's header, or `v`. Pick when it
ends:

| Choice | Ends |
|---|---|
| Rest of today | Today at 18:00 (only offered before 17:30) |
| Tomorrow morning | Tomorrow at 08:00 |
| Next Monday | Next Monday at 08:00 |
| One week | Same weekday next week, 08:00 |
| Until I say so | Only when you end it |
| A date of your own | Type `2026-12-24 08:00`, `2026-12-24` (08:00 assumed) or `24/12/2026 08:00` |

**Turn it off:** **End vacation** on the beach, `v` in the popup, or
`omarchy-shell leonavas.calendar endVacation`. A timed vacation ends by itself
with a "Vacation over" notification, even if the shell was off at the time —
it ends on the next start.

The state lives in `~/.local/state/omarchy/calendar/vacation.json`, so every
monitor's bar agrees and it survives restarts. There are no settings for it.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell` bar
- `python3` — the sync and auth scripts use the standard library only, no pip
  packages
- A Google account and a Google Cloud project with your own OAuth client (free;
  setup below)
- Used from the system: `notify-send`, `omarchy-notification-send`,
  `omarchy-launch-webapp`, `omarchy-launch-floating-terminal-with-presentation`,
  `xdg-open`, `wl-copy` — all part of a standard Omarchy install
- Optional: the [`gcloud` CLI](https://cloud.google.com/sdk/docs/install), only
  to do setup steps 1–2 from the terminal. The console works just as well.

No sudo or pkexec is required.

## Install

```bash
omarchy plugin add https://github.com/leonavas/omarchy-calendar.git
omarchy plugin enable leonavas.calendar --section right
```

`omarchy bar move leonavas.calendar --section center` moves it elsewhere. The
widget shows **calendar** until you connect Google.

## Connect Google (one time, ~10 minutes)

Google only lets an app read your calendar through an OAuth client that *you*
own. So you create a small Google Cloud project with one client in it; the
plugin uses that client to ask you for read-only access. It costs nothing and
needs no billing account.

> Google renamed these screens in 2025: what older guides call the
> **OAuth consent screen** is now **Google Auth Platform**, split into
> *Branding*, *Audience*, *Data Access* and *Clients*.

### 1. Create a project

**Console:** open <https://console.cloud.google.com/projectcreate>, give it a
name (e.g. `omarchy-calendar`), **Create**, and make sure it is selected in the
project picker at the top.

**Or with gcloud:**

```bash
gcloud auth login                                  # opens a browser once
gcloud projects create omarchy-calendar-12345 --name="Omarchy Calendar"
gcloud config set project omarchy-calendar-12345
```

Project IDs are global across all of Google Cloud, so add a few digits to make
yours unique. Using an existing project is fine too.

### 2. Enable the Google Calendar API

**Console:** open
<https://console.cloud.google.com/apis/library/calendar-json.googleapis.com>
and click **Enable**.

**Or with gcloud:**

```bash
gcloud services enable calendar-json.googleapis.com
gcloud services list --enabled | grep calendar    # should print calendar-json.googleapis.com
```

### 3. Configure Google Auth Platform (console only)

`gcloud` cannot configure this for a personal app — use the console.

1. Open <https://console.cloud.google.com/auth/overview> and click
   **Get started** (only shown the first time).
2. **App information:** any name (e.g. `Omarchy Calendar`) and your email as
   the support email. **Next**.
3. **Audience:**
   - **Internal** — if your account is a Google Workspace account and your admin
     allows it. Only people in your organisation can use it, no test users, and
     tokens do not expire weekly. Pick this if it is offered.
   - **External** — for a personal `@gmail.com` account, or when Internal is
     greyed out. **Next**.
4. **Contact information:** your email. **Next**, accept the policy,
   **Create**.
5. **External only — add yourself as a test user:** open
   <https://console.cloud.google.com/auth/audience>, under **Test users** click
   **Add users**, enter the Google address whose calendar you want in the bar,
   **Save**.
6. **Add the scope:** open <https://console.cloud.google.com/auth/scopes>,
   click **Add or remove scopes**, filter for `calendar.readonly`, tick
   `https://www.googleapis.com/auth/calendar.readonly`
   (*See and download any calendar you can access using your Google Calendar*),
   **Update**, then **Save** at the bottom of the page.

### 4. Create the OAuth client (console only)

1. Open <https://console.cloud.google.com/auth/clients> and click
   **Create client**.
2. **Application type:** **Desktop app**. Any name. **Create**.
3. In the dialog that follows, click **Download JSON**. Google now shows the
   client secret only at this moment — if you close the dialog without
   downloading, create a new client.

You get a file such as
`~/Downloads/client_secret_1234-abcd.apps.googleusercontent.com.json`. No
redirect URI needs to be registered: a Desktop app client accepts any
`127.0.0.1` port, which is what the plugin uses.

### 5. Authorize the plugin

```bash
~/.config/omarchy/plugins/leonavas.calendar/bin/gcal-auth \
  --client-secret-file ~/Downloads/client_secret_*.json
```

(If you have several `client_secret_*.json` files, give the exact file name.)

A browser tab opens on Google's sign-in:

1. Pick the account you added as a test user.
2. **External** apps show *Google hasn't verified this app*. That is expected —
   it is your own app. Click **Continue**.
3. Allow *See and download any calendar you can access*.
4. The tab says **Calendar connected**. Close it.

The terminal then prints something like:

```
Authorized. Fetching your calendars…

client id : 1234-abcd.apps.googleusercontent.com
token file: /home/you/.local/state/omarchy/calendar/credentials.json
account   : you@example.com
calendars : 6 (3 shown in Google Calendar)
  • you@example.com
  • Holidays
  • Team
```

The bar picks it up at the next sync (at most `syncMinutes`), or press `r` in
the popup. Clicking **Not connected to Google — click to set up** in the
popup's footer also runs `gcal-auth` in a terminal; without
`--client-secret-file` it asks you to paste the client ID and secret instead.

Only calendars ticked in Google Calendar's own left sidebar are shown — tick or
untick them there.

### 6. Optional: stop the weekly re-login (External apps)

An **External** app left in **Testing** gets tokens that Google expires after
**7 days**, so you would have to run `gcal-auth` again every week. To avoid it:

1. Open <https://console.cloud.google.com/auth/audience>.
2. Under **Publishing status**, click **Publish app** → **Confirm**.
3. Run `bin/gcal-auth` once more (it reuses the stored client).

You do not need to submit the app for Google's verification: it stays
unverified, keeps showing the *hasn't verified this app* warning at sign-in,
and is limited to 100 users — none of which matters for personal use.
**Internal** apps never have this problem.

### gcal-auth reference

```bash
bin/gcal-auth --client-secret-file <file.json>   # first-time setup
bin/gcal-auth                                    # re-authorize, reusing the stored client
bin/gcal-auth --client-id <id> --client-secret <secret>
bin/gcal-auth --no-browser                       # print the URL instead of opening it
bin/gcal-auth --status                           # which account, which calendars
bin/gcal-auth --reset                            # delete the stored tokens
bin/gcal-sync                                    # sync by hand, print the result
```

## Settings

Set them in Setup > Plugins, or inline on the widget's entry in
`~/.config/omarchy/shell.json`.

| Key | Default | What it does |
|---|---|---|
| `view` | `week` | View the popup opens on: `day`, `3day`, `week` |
| `workweek` | `false` | Week view shows Monday to Friday only |
| `weekStartDay` | `Locale` | `Locale`, `Sunday` or `Monday` |
| `use24Hour` | `true` | 24-hour clock |
| `showWeekNumbers` | `true` | ISO week number above the hour labels |
| `showDeclined` | `true` | Show declined events, faded and struck through |
| `contentScale` | `125` | Scale of everything in the popup (%) |
| `hourHeight` | `40` | Height of one hour row (px, before scaling) |
| `gridHeight` | `540` | Visible grid height before it scrolls (px, before scaling) |
| `scrollToHour` | `8` | Hour the grid opens on for days other than today |
| `syncMinutes` | `5` | Background sync interval |
| `daysBack` | `14` | Days of history fetched |
| `daysAhead` | `90` | Days ahead fetched |
| `meetingOpenMode` | `App window` | `App window` (own window via `omarchy-launch-webapp`) or `Browser tab` |
| `googleAccounts` | `""` | Other Google accounts you are signed into, comma-separated, offered when joining |
| `labelMode` | `Next event` | `Next event`, `Countdown` or `Icon only` |
| `glyph` | `󰃭` | Nerd Font glyph before the label |
| `maxLabelChars` | `22` | Longest event title in the bar before it is cut |
| `warnMinutes` | `5` | Colour the label this many minutes before a meeting |
| `hideWhenEmpty` | `false` | Hide the widget when nothing is scheduled |
| `joinOnMiddleClick` | `true` | Middle click joins the next meeting |
| `rightClickAction` | `New meeting` | `New meeting`, `Sync now` or `Open Google Calendar` |
| `copyMeetingLink` | `true` | Copy the link of a meeting started from the bar |
| `notifyAtStart` | `true` | Toast when a meeting starts |

## Update

```bash
omarchy plugin update leonavas.calendar
```

Your Google connection and settings are kept.

## Remove

```bash
omarchy plugin disable leonavas.calendar   # off the bar, files kept
omarchy plugin remove leonavas.calendar    # deletes ~/.config/omarchy/plugins/leonavas.calendar/
```

Then clean up what lives outside the plugin folder:

```bash
rm -rf ~/.local/state/omarchy/calendar     # tokens, event cache, vacation state
```

And revoke Google's side:

1. <https://myaccount.google.com/connections> → your app → **Delete all
   connections** (this invalidates the refresh token everywhere).
2. Optional: delete the Cloud project at
   <https://console.cloud.google.com/iam-admin/settings> → **Shut down**, or
   `gcloud projects delete <project-id>`.

## What it writes

All under `~/.local/state/omarchy/calendar/` (or `$XDG_STATE_HOME/omarchy/calendar/`),
directory `0700`, files `0600`:

- `credentials.json` — your OAuth client ID and secret and the refresh token.
  Written by `gcal-auth`; deleted by `gcal-auth --reset`.
- `token.json` — the current access token (valid one hour). Written by the sync.
- `events.json` — the event cache the widget draws from: titles, times,
  locations, descriptions, guests and meeting links for the fetched window.
  Rewritten on every sync.
- `vacation.json` — vacation on/off and its end. Written when you start or end
  vacation.

The widget does not change `~/.config/omarchy/shell.json` on its own; settings
are only written when you change them in Setup. Nothing in `~/.config/hypr/` is
touched, and nothing is written into the plugin folder.

## Privacy

- **Scope:** `calendar.readonly` only. The plugin cannot create, change or
  delete events, and cannot read your email or anything else.
- **Network:** only Google — `accounts.google.com` and `oauth2.googleapis.com`
  for sign-in and token refresh, `www.googleapis.com/calendar/v3` for calendars
  and events. No other server, no telemetry.
- **Your own client:** the OAuth client is yours, so no third party ever holds
  a token for your calendar. Sign-in uses PKCE over a one-off `127.0.0.1`
  listener.
- **Local data:** tokens and the event cache stay on disk in the directory
  above, readable only by your user.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Bar says **calendar**, footer says *Not connected to Google* | Run `bin/gcal-auth` (setup above), or click the footer |
| `Error 403: access_denied` in the browser | External app in Testing and this account is not a test user — add it (step 3.5) |
| *This app is blocked* / scope not shown on consent | The `calendar.readonly` scope was not saved under Data Access (step 3.6) |
| `Google Calendar API has not been used in project … or it is disabled` | Enable the API (step 2) in the *same* project as the client; wait a minute |
| `HTTP 400: invalid_grant` after about a week | Testing-mode token expired — run `bin/gcal-auth`, then publish the app (step 6) |
| `Google issued no refresh token` | Delete the app's access at <https://myaccount.google.com/connections> and run `gcal-auth` again |
| `timed out waiting for the browser redirect` | The browser never reached `127.0.0.1`. Use `--no-browser`, open the URL in a browser on this machine, and finish within 5 minutes |
| `invalid_client` / `redirect_uri_mismatch` | The client is not a **Desktop app** — create a new one of that type (step 4) |
| Connected, but a calendar is missing | Tick it in Google Calendar's left sidebar; `gcal-auth --status` lists what is shown |
| Nothing after connecting | Run `bin/gcal-sync` — it prints what it fetched or why it failed |
| New Meet opens but no link is copied | The room code is read from the browser window title; copy it from the address bar |

## License

MIT — see [LICENSE](LICENSE).
