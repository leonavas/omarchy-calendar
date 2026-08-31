# Google Calendar for the Omarchy bar

Your next meeting in the bar, and Google Calendar's day/week grid behind it.
Click an event to open it, or to join its call.

```
August 2026  ‹ ›                                       [D][3][W] ⟳
        MON      TUE      WED      THU      FRI
         24       25       26      (27)      28
 09:00           ███ Standup ███
 10:00  ██ 1:1 ██   ▢ Design review        ← outline = not answered
 11:00  ─────────────●──────────────────   ← now
 12:00                    ███ Lunch ███
```

## What it does

- **Never miss the start.** The bar shows what is on now or next, turns to the
  accent colour a few minutes before, and sends a toast the moment a meeting
  begins — click it to land straight in the call.
- **Join without hunting for the link.** Middle click the bar to join the next
  meeting, or middle click any event in the grid to join that one.
- **Start a meeting in one gesture.** Right click the bar for a new Meet, opened
  as your calendar account with the link already on the clipboard.
- **The real grid, not a list.** Day, 3-day and week views, all-day band, week
  numbers, current-time line, your Google colours. Accepted invitations are
  solid, unanswered ones outlined, declined ones faded and struck through.
- **Works while it is closed.** A background sync keeps the cache warm, so the
  bar is right the instant you look at it — and if a sync fails, the last good
  day stays on screen with the error in the footer.
- **Several Google accounts.** Links are pinned to the right account, so you
  never open a meeting as the wrong you.

## Install

```bash
git clone https://github.com/leonavas/omarchy-calendar.git \
  ~/.config/omarchy/plugins/leonavas.calendar
omarchy bar put leonavas.calendar --before omarchy.clock
```

## Connect Google

Google needs an OAuth client to identify the app. One-time, ~5 minutes.

1. [Create a project](https://console.cloud.google.com/projectcreate) and
   [enable the Calendar API](https://console.cloud.google.com/apis/library/calendar-json.googleapis.com).
2. [**Google Auth Platform**](https://console.cloud.google.com/auth/overview)
   (the old *OAuth consent screen*):
   - **Audience** → **Internal** if your Workspace allows it, otherwise
     **External** and add yourself under *Test users*.
   - **Data Access** → add the scope `.../auth/calendar.readonly`.
3. [**Clients**](https://console.cloud.google.com/auth/clients) → **Create
   client** → **Desktop app** → download the JSON.
4. Run this and log in in the browser:

   ```bash
   ~/.config/omarchy/plugins/leonavas.calendar/bin/gcal-auth \
     --client-secret-file ~/Downloads/client_secret_*.json
   ```

`gcal-auth --status` shows the connected account, `--reset` forgets it. Only
the calendars ticked in Google Calendar's own sidebar are shown.

Nothing sensitive lands in this directory: tokens live in
`~/.local/state/omarchy/calendar/`.

## Use

| | |
|---|---|
| Click the bar | Open the grid |
| Middle click the bar | Join the next meeting |
| Right click the bar | New Meet, link on the clipboard |
| Click an event | Its card — join, copy link, guests, location, description |
| Middle click an event | Join that call |
| `d` `3` `w` | Day / 3-day / week |
| `t` `r` | Today / sync now |
| `←` `→` `↑` `↓` | Step period / scroll hours |
| `Esc` | Back out one layer |

Any of it can be bound to a key instead:

```bash
omarchy-shell leonavas.calendar newMeeting
omarchy-shell leonavas.calendar copyLink   # next meeting's URL to the clipboard
omarchy-shell leonavas.calendar toggle|today|day|week|refresh|openCalendar
```

## Settings

From the bar's settings panel, or in `~/.config/omarchy/shell.json`. Common
ones: `view`, `workweek`, `weekStartDay`, `use24Hour`, `hourHeight`,
`gridHeight`, `syncMinutes`, `meetingOpenMode`, `labelMode`, `warnMinutes`,
`showDeclined`, `googleAccounts`. The full list, with descriptions, is in
`manifest.json`.

## If something looks wrong

- **"Not connected to Google"** — run `bin/gcal-auth`, or click the footer.
- **Nothing after connecting** — run `bin/gcal-sync` by hand; it prints what it
  fetched, or why it failed.
- **Asked to log in every 7 days** — an *External* app left in *Testing*
  expires its token weekly. Publish the app to stop it.

## Licence

MIT.
