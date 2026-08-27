.pragma library

// Pure helpers for the calendar widget: date arithmetic, the day/week
// bucketing, and the column packing that lets overlapping events sit side by
// side the way they do in Google Calendar.
//
// Nothing here touches QML objects, so it stays testable with plain node and
// cheap to call from a binding.

var MINUTE = 60000
var HOUR = 3600000
var DAY = 86400000

// ----------------------------------------------------------------- calendar
//
// Day boundaries go through Date rather than modulo arithmetic on the epoch:
// a day is not always 86400s long, and Brazil has enough DST history that
// rounding to the millisecond would put events an hour off twice a year.

function startOfDay(ms) {
  var date = new Date(ms)
  date.setHours(0, 0, 0, 0)
  return date.getTime()
}

function addDays(ms, count) {
  var date = new Date(ms)
  date.setDate(date.getDate() + count)
  date.setHours(0, 0, 0, 0)
  return date.getTime()
}

function addMonths(ms, count) {
  var date = new Date(ms)
  date.setDate(1)
  date.setMonth(date.getMonth() + count)
  return startOfDay(date.getTime())
}

// weekStart: 0 = Sunday, 1 = Monday.
function startOfWeek(ms, weekStart) {
  var start = startOfDay(ms)
  var weekday = new Date(start).getDay()
  var delta = (weekday - weekStart + 7) % 7
  return addDays(start, -delta)
}

function sameDay(a, b) {
  return startOfDay(a) === startOfDay(b)
}

function dayLength(dayStartMs) {
  // The real length of this particular day, DST transitions included, so the
  // grid's vertical scale never drifts from the clock.
  return addDays(dayStartMs, 1) - dayStartMs
}

// The columns the grid draws: one day, or a full week from its first day.
function visibleDays(anchorMs, view, weekStart, workweek) {
  var days = []
  if (view === "week") {
    var first = startOfWeek(anchorMs, weekStart)
    var count = workweek ? 5 : 7
    if (workweek) {
      // A work week always means Mon–Fri, whichever day the week nominally
      // starts on, so a Sunday-start week does not render Sun–Thu.
      first = addDays(startOfWeek(anchorMs, 1), 0)
    }
    for (var i = 0; i < count; i++) days.push(addDays(first, i))
    return days
  }
  if (view === "3day") {
    for (var j = 0; j < 3; j++) days.push(addDays(startOfDay(anchorMs), j))
    return days
  }
  return [startOfDay(anchorMs)]
}

function stepFor(view, workweek) {
  if (view === "week") return workweek ? 7 : 7
  if (view === "3day") return 3
  return 1
}

// -------------------------------------------------------------------- events

function isAllDay(event) {
  return event && event.allDay === true
}

// An event belongs to a day when it overlaps it at all, so something running
// from 23:00 to 01:00 is drawn in both columns, clipped to each.
function overlapsDay(event, dayStartMs) {
  var dayEnd = dayStartMs + dayLength(dayStartMs)
  return event.start < dayEnd && event.end > dayStartMs
}

function timedEventsForDay(events, dayStartMs) {
  var list = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (isAllDay(event)) continue
    if (overlapsDay(event, dayStartMs)) list.push(event)
  }
  return list
}

function allDayEventsForDay(events, dayStartMs) {
  var list = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!isAllDay(event)) continue
    if (overlapsDay(event, dayStartMs)) list.push(event)
  }
  return list
}

function eventsInRange(events, fromMs, toMs) {
  var list = []
  for (var i = 0; i < events.length; i++) {
    if (events[i].start < toMs && events[i].end > fromMs) list.push(events[i])
  }
  return list
}

// ------------------------------------------------------------------- layout
//
// The packing Google uses: events that overlap in time share the width of
// their cluster, each in its own column, and an event then grows rightwards
// across any column that happens to be free for its whole duration. That last
// step is what keeps a lone 09:00 meeting full width even when an unrelated
// pair overlaps later in the same cluster.

function layoutDay(events, dayStartMs) {
  var span = dayLength(dayStartMs)
  var dayEnd = dayStartMs + span
  var blocks = []

  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    var start = Math.max(event.start, dayStartMs)
    var end = Math.min(event.end, dayEnd)
    // A block still has to be tappable when the event is a minute long, so a
    // floor of 15 minutes is applied to the drawn height only — `event` keeps
    // its true times for the detail view.
    if (end - start < 15 * MINUTE) end = Math.min(dayEnd, start + 15 * MINUTE)
    blocks.push({
      event: event,
      startMs: start,
      endMs: end,
      top: (start - dayStartMs) / span,
      height: (end - start) / span,
      column: 0,
      columns: 1,
      span: 1,
      continuesBefore: event.start < dayStartMs,
      continuesAfter: event.end > dayEnd
    })
  }

  blocks.sort(function(a, b) {
    if (a.startMs !== b.startMs) return a.startMs - b.startMs
    return b.endMs - a.endMs
  })

  // Cluster: a run of blocks joined transitively by overlap.
  var cluster = []
  var clusterEnd = -1
  for (var b = 0; b < blocks.length; b++) {
    if (cluster.length > 0 && blocks[b].startMs >= clusterEnd) {
      packCluster(cluster)
      cluster = []
    }
    cluster.push(blocks[b])
    clusterEnd = Math.max(clusterEnd, blocks[b].endMs)
  }
  if (cluster.length > 0) packCluster(cluster)

  return blocks
}

function packCluster(cluster) {
  var columnEnds = []
  for (var i = 0; i < cluster.length; i++) {
    var block = cluster[i]
    var placed = false
    for (var c = 0; c < columnEnds.length; c++) {
      if (columnEnds[c] <= block.startMs) {
        block.column = c
        columnEnds[c] = block.endMs
        placed = true
        break
      }
    }
    if (!placed) {
      block.column = columnEnds.length
      columnEnds.push(block.endMs)
    }
  }

  var total = Math.max(1, columnEnds.length)
  for (var j = 0; j < cluster.length; j++) {
    cluster[j].columns = total
    cluster[j].span = freeSpan(cluster, cluster[j], total)
  }
}

// How many columns to the right this block can grow into before it would
// collide with something.
function freeSpan(cluster, block, total) {
  var span = 1
  for (var column = block.column + 1; column < total; column++) {
    for (var i = 0; i < cluster.length; i++) {
      var other = cluster[i]
      if (other === block || other.column !== column) continue
      if (other.startMs < block.endMs && other.endMs > block.startMs) return span
    }
    span++
  }
  return span
}

// All-day events get their own band above the grid, drawn as bars that span
// the columns they cover — a three-day trip is one bar, not three chips. Bars
// are packed into lanes so overlapping ones stack instead of colliding.
function layoutAllDay(events, days) {
  if (!days || days.length === 0) return { bars: [], lanes: 0 }
  var rangeStart = days[0]
  var rangeEnd = days[days.length - 1] + dayLength(days[days.length - 1])

  var candidates = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!isAllDay(event)) continue
    if (event.start >= rangeEnd || event.end <= rangeStart) continue
    candidates.push(event)
  }
  // Longest first, so a week-long bar takes the top lane and the one-day
  // chips tuck underneath it rather than pushing it down.
  candidates.sort(function(a, b) {
    if (a.start !== b.start) return a.start - b.start
    return (b.end - b.start) - (a.end - a.start)
  })

  var bars = []
  var lanes = []
  for (var c = 0; c < candidates.length; c++) {
    var candidate = candidates[c]
    var startCol = -1
    var endCol = -1
    for (var d = 0; d < days.length; d++) {
      if (overlapsDay(candidate, days[d])) {
        if (startCol < 0) startCol = d
        endCol = d
      }
    }
    if (startCol < 0) continue

    var lane = 0
    while (lane < lanes.length && lanes[lane] >= startCol) lane++
    if (lane === lanes.length) lanes.push(-1)
    lanes[lane] = endCol

    bars.push({
      event: candidate,
      startCol: startCol,
      endCol: endCol,
      lane: lane,
      continuesBefore: candidate.start < rangeStart,
      continuesAfter: candidate.end > rangeEnd
    })
  }
  return { bars: bars, lanes: lanes.length }
}

// ---------------------------------------------------------------- formatting

function pad2(value) {
  return value < 10 ? "0" + value : String(value)
}

function formatTime(ms, use24Hour) {
  var date = new Date(ms)
  var hours = date.getHours()
  var minutes = date.getMinutes()
  if (use24Hour) return pad2(hours) + ":" + pad2(minutes)
  var suffix = hours >= 12 ? "pm" : "am"
  var hour12 = hours % 12
  if (hour12 === 0) hour12 = 12
  return minutes === 0
    ? hour12 + suffix
    : hour12 + ":" + pad2(minutes) + suffix
}

function formatHourLabel(hour, use24Hour) {
  if (use24Hour) return pad2(hour) + ":00"
  if (hour === 0) return "12am"
  if (hour === 12) return "12pm"
  return hour > 12 ? (hour - 12) + "pm" : hour + "am"
}

function formatRange(event, use24Hour) {
  if (isAllDay(event)) return "All day"
  return formatTime(event.start, use24Hour) + " – " + formatTime(event.end, use24Hour)
}

function formatDuration(ms) {
  var minutes = Math.round(ms / MINUTE)
  if (minutes < 60) return minutes + " min"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (minutes % 1440 === 0) {
    var days = minutes / 1440
    return days + (days === 1 ? " day" : " days")
  }
  return rest === 0 ? hours + "h" : hours + "h " + rest + "m"
}

// "in 12m" / "now" / "in 3h" / "Tue 09:00" — the bar has room for one of these,
// so it gets progressively coarser as the event moves away.
function relativeLabel(startMs, nowMs, use24Hour) {
  var delta = startMs - nowMs
  if (delta <= 0) return "now"
  var minutes = Math.round(delta / MINUTE)
  if (minutes < 60) return "in " + minutes + "m"
  if (sameDay(startMs, nowMs)) {
    var hours = Math.floor(minutes / 60)
    var rest = minutes % 60
    return rest === 0 ? "in " + hours + "h" : "in " + hours + "h" + rest + "m"
  }
  if (sameDay(startMs, nowMs + DAY)) return "tomorrow " + formatTime(startMs, use24Hour)
  return shortWeekday(startMs) + " " + formatTime(startMs, use24Hour)
}

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var WEEKDAYS_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December"]
var MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
                    "Sep", "Oct", "Nov", "Dec"]

function shortWeekday(ms) { return WEEKDAYS[new Date(ms).getDay()] }
function longWeekday(ms) { return WEEKDAYS_LONG[new Date(ms).getDay()] }
function monthName(ms) { return MONTHS[new Date(ms).getMonth()] }
function shortMonth(ms) { return MONTHS_SHORT[new Date(ms).getMonth()] }

// The heading over the grid, in Google's own phrasing: one date for a day
// view, a collapsed range for a week that straddles months or years.
function rangeTitle(days) {
  if (!days || days.length === 0) return ""
  var first = days[0]
  var last = days[days.length - 1]
  if (days.length === 1) {
    return monthName(first) + " " + new Date(first).getDate() + ", " + new Date(first).getFullYear()
  }
  var firstDate = new Date(first)
  var lastDate = new Date(last)
  if (firstDate.getFullYear() !== lastDate.getFullYear()) {
    return shortMonth(first) + " " + firstDate.getFullYear() + " – " +
           shortMonth(last) + " " + lastDate.getFullYear()
  }
  if (firstDate.getMonth() !== lastDate.getMonth()) {
    return shortMonth(first) + " – " + shortMonth(last) + " " + lastDate.getFullYear()
  }
  return monthName(first) + " " + firstDate.getFullYear()
}

// ISO-8601 week number, the one European calendars print in the gutter.
function isoWeek(ms) {
  var date = new Date(ms)
  date.setHours(0, 0, 0, 0)
  // Thursday decides which year the week belongs to.
  date.setDate(date.getDate() + 3 - ((date.getDay() + 6) % 7))
  var firstThursday = new Date(date.getFullYear(), 0, 4)
  firstThursday.setDate(firstThursday.getDate() + 3 - ((firstThursday.getDay() + 6) % 7))
  return 1 + Math.round((date - firstThursday) / (7 * DAY))
}

// -------------------------------------------------------------------- colour
//
// Google hands out event colours as plain "#rrggbb". Rather than route those
// through Qt's colour helpers — which take a string but return an opaque
// object that is awkward to tint — the few operations the grid needs are done
// on the hex directly, and handed back as strings QML assigns to a `color`.

function hexChannels(hex) {
  var value = String(hex || "").replace("#", "")
  if (value.length === 3) {
    value = value.charAt(0) + value.charAt(0) + value.charAt(1) +
            value.charAt(1) + value.charAt(2) + value.charAt(2)
  }
  if (value.length < 6) return { r: 3, g: 155, b: 229 }
  return {
    r: parseInt(value.substr(0, 2), 16),
    g: parseInt(value.substr(2, 2), 16),
    b: parseInt(value.substr(4, 2), 16)
  }
}

function luminance(hex) {
  var c = hexChannels(hex)
  // Perceived brightness, the cheap sRGB approximation — enough to pick
  // between black and white text.
  return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255
}

// Black or white, whichever stays legible on the event's own colour.
function textOn(hex) {
  return luminance(hex) > 0.62 ? "#1a1a1a" : "#ffffff"
}

function pad2Hex(value) {
  var v = Math.max(0, Math.min(255, Math.round(value)))
  var s = v.toString(16)
  return s.length < 2 ? "0" + s : s
}

// "#rrggbb" + alpha -> "#aarrggbb", the form QML colour properties accept.
function withAlpha(hex, alpha) {
  var c = hexChannels(hex)
  return "#" + pad2Hex(alpha * 255) + pad2Hex(c.r) + pad2Hex(c.g) + pad2Hex(c.b)
}

// How an event is painted follows Google's own convention: a meeting you
// accepted is a solid block, one you have not answered is an outline, and one
// you declined fades out and gets struck through.
function blockStyle(event) {
  if (!event) return "filled"
  if (event.response === "declined") return "declined"
  if (event.response === "needsAction" || event.response === "tentative") return "outlined"
  return "filled"
}

// ------------------------------------------------------------------ the bar
//
// What the bar label speaks for: whatever is on now, else the next thing
// today or soon after. Declined events are skipped — an invitation you turned
// down is not your next meeting.

function isDeclined(event) {
  return event && event.response === "declined"
}

function currentEvent(events, nowMs) {
  var best = null
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (isAllDay(event) || isDeclined(event)) continue
    if (event.start <= nowMs && event.end > nowMs) {
      if (!best || event.end < best.end) best = event
    }
  }
  return best
}

function nextEvent(events, nowMs, horizonMs) {
  var limit = nowMs + (horizonMs || 7 * DAY)
  var best = null
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (isAllDay(event) || isDeclined(event)) continue
    if (event.start <= nowMs || event.start > limit) continue
    if (!best || event.start < best.start) best = event
  }
  return best
}

// The event the bar speaks for, and how urgent it is.
function barEvent(events, nowMs) {
  var running = currentEvent(events, nowMs)
  var upcoming = nextEvent(events, nowMs)
  // While something is running, the next one still wins once it is close
  // enough to need leaving for — that is the moment the bar is useful.
  if (running && upcoming && upcoming.start - nowMs <= 5 * MINUTE) return upcoming
  return running || upcoming
}

function truncate(text, limit) {
  var value = String(text || "")
  if (limit <= 0 || value.length <= limit) return value
  return value.substr(0, Math.max(1, limit - 1)) + "…"
}

// ------------------------------------------------------------------ accounts
//
// A browser signed into more than one Google account opens a link as whichever
// account sits at index 0, which is rarely the one the meeting belongs to.
// Google honours `authuser` on its own domains to override that.
//
// The email form is used rather than `/u/<n>/`: the index is just the order the
// accounts were signed in, so it shifts whenever one is added or removed, while
// the address always names the same account.

function isGoogleUrl(url) {
  var value = String(url || "")
  return /^https?:\/\/([a-z0-9-]+\.)*google\.com(\/|\?|$)/i.test(value)
}

// Strip an authuser Google (or a calendar invite) already put there, so ours is
// the only one and the last writer does not win by accident.
function stripAccount(url) {
  var value = String(url || "")
  var hash = ""
  var hashAt = value.indexOf("#")
  if (hashAt >= 0) { hash = value.substr(hashAt); value = value.substr(0, hashAt) }
  var queryAt = value.indexOf("?")
  if (queryAt < 0) return value + hash
  var base = value.substr(0, queryAt)
  var parts = value.substr(queryAt + 1).split("&")
  var kept = []
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].length === 0) continue
    if (/^authuser=/i.test(parts[i])) continue
    kept.push(parts[i])
  }
  return base + (kept.length > 0 ? "?" + kept.join("&") : "") + hash
}

// Pin a link to one Google account. Non-Google links (Zoom, Teams, Webex) have
// no such concept and are handed back untouched.
function withAccount(url, account) {
  var value = String(url || "")
  if (value.length === 0) return value
  if (!isGoogleUrl(value)) return value
  var cleaned = stripAccount(value)
  var name = String(account || "")
  if (name.length === 0) return cleaned
  var hash = ""
  var hashAt = cleaned.indexOf("#")
  if (hashAt >= 0) { hash = cleaned.substr(hashAt); cleaned = cleaned.substr(0, hashAt) }
  var separator = cleaned.indexOf("?") >= 0 ? "&" : "?"
  return cleaned + separator + "authuser=" + encodeURIComponent(name) + hash
}

// A Meet room code is three-four-three lowercase letters. It has to be read
// out of the browser window title, because meet.google.com/new is a redirect:
// the room does not exist until the browser has followed it, so nothing the
// shell can ask beforehand knows the link.
var MEET_CODE_RE = /\b([a-z]{3}-[a-z]{4}-[a-z]{3})\b/

function meetCodeFromTitle(title) {
  var match = String(title || "").match(MEET_CODE_RE)
  return match ? match[1] : ""
}

function meetUrlFromCode(code) {
  var value = String(code || "")
  return value.length > 0 ? "https://meet.google.com/" + value : ""
}

// The code out of a link already on an event, so "copy link" and the watcher
// speak about rooms in the same terms.
function meetCodeFromUrl(url) {
  var value = String(url || "")
  if (value.indexOf("meet.google.com") < 0) return ""
  return meetCodeFromTitle(value)
}

// Google's instant-meeting entry point: it mints a room and drops you into it.
// Pinned to an account like any other Google link, so the call is created by
// the identity the calendar belongs to rather than whichever account happens
// to be first in the browser — a meeting created as the wrong account invites
// people from the wrong directory.
function newMeetingUrl(account) {
  return withAccount("https://meet.google.com/new", account)
}

// Google Calendar itself, as the same account.
function calendarHomeUrl(account) {
  return withAccount("https://calendar.google.com/", account)
}

// The accounts the Join button offers. The calendar's own account leads, then
// anything the user listed in settings, and finally the browser's own choice
// for when none of them is the one already signed in.
function accountOptions(connected, configured) {
  var out = []
  var seen = {}

  function add(account, label, note) {
    var key = String(account || "")
    if (seen[key] !== undefined) return
    seen[key] = true
    out.push({ account: key, label: label, note: note || "" })
  }

  var owner = String(connected || "")
  if (owner.length > 0) add(owner, owner, "calendar account")

  var extras = String(configured || "").split(",")
  for (var i = 0; i < extras.length; i++) {
    var entry = extras[i].replace(/^\s+|\s+$/g, "")
    if (entry.length > 0) add(entry, entry, "")
  }

  add("", "Browser default", "whichever account is signed in")
  return out
}

// ------------------------------------------------------------------ people

function attendeeName(attendee) {
  if (!attendee) return ""
  if (attendee.name) return attendee.name
  var email = String(attendee.email || "")
  var at = email.indexOf("@")
  return at > 0 ? email.substr(0, at) : email
}

function responseGlyph(response) {
  if (response === "accepted") return "✓"
  if (response === "declined") return "✕"
  if (response === "tentative") return "?"
  return "·"
}

function responseLabel(response) {
  if (response === "accepted") return "Going"
  if (response === "declined") return "Not going"
  if (response === "tentative") return "Maybe"
  return "Awaiting reply"
}

function attendeeSummary(attendees) {
  if (!attendees || attendees.length === 0) return ""
  var yes = 0, no = 0, maybe = 0, waiting = 0
  for (var i = 0; i < attendees.length; i++) {
    var response = attendees[i].response
    if (response === "accepted") yes++
    else if (response === "declined") no++
    else if (response === "tentative") maybe++
    else waiting++
  }
  var parts = [attendees.length + (attendees.length === 1 ? " guest" : " guests")]
  var detail = []
  if (yes) detail.push(yes + " yes")
  if (no) detail.push(no + " no")
  if (maybe) detail.push(maybe + " maybe")
  if (waiting) detail.push(waiting + " awaiting")
  if (detail.length > 0) parts.push(detail.join(", "))
  return parts.join(" · ")
}

// Booleans out of shell.json arrive as real booleans from the settings panel,
// but as strings from `omarchy bar set <id> <key> true` without --json. Both
// spellings have to mean the same thing, or a setting toggled from the command
// line silently does nothing.
function truthy(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback === true
  if (typeof value === "boolean") return value
  var text = String(value).toLowerCase()
  if (text === "true" || text === "1" || text === "yes" || text === "on") return true
  if (text === "false" || text === "0" || text === "no" || text === "off") return false
  return fallback === true
}

// -------------------------------------------------------------------- state

function parseCache(raw) {
  var empty = {
    events: [], calendars: [], account: "", syncedAt: 0,
    error: "", needsAuth: false, loaded: false
  }
  if (!raw || String(raw).length === 0) return empty
  try {
    var parsed = JSON.parse(raw)
    return {
      events: parsed.events || [],
      calendars: parsed.calendars || [],
      account: String(parsed.account || ""),
      syncedAt: Number(parsed.syncedAt || 0),
      error: String(parsed.error || ""),
      needsAuth: parsed.needsAuth === true,
      loaded: true
    }
  } catch (e) {
    return empty
  }
}

function syncAgeLabel(syncedAt, nowMs) {
  if (!syncedAt) return "never synced"
  var seconds = Math.max(0, Math.round((nowMs - syncedAt) / 1000))
  if (seconds < 60) return "synced just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return "synced " + minutes + "m ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return "synced " + hours + "h ago"
  return "synced " + Math.round(hours / 24) + "d ago"
}
