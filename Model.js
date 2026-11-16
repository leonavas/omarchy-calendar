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
  if (view === "month") return monthDays(anchorMs, weekStart, workweek)
  if (view === "3day") {
    for (var j = 0; j < 3; j++) days.push(addDays(startOfDay(anchorMs), j))
    return days
  }
  return [startOfDay(anchorMs)]
}

// The month grid: whole weeks from the one holding the 1st to the one holding
// the last day, so it is five or six rows. A work week drops the weekend
// columns rather than shifting the grid.
function monthDays(anchorMs, weekStart, workweek) {
  var first = new Date(anchorMs)
  first.setDate(1)
  first.setHours(0, 0, 0, 0)
  var firstMs = first.getTime()
  var lastMs = addDays(addMonths(firstMs, 1), -1)
  var start = startOfWeek(firstMs, workweek ? 1 : weekStart)
  var end = addDays(startOfWeek(lastMs, workweek ? 1 : weekStart), 6)
  var days = []
  for (var d = start; d <= end; d = addDays(d, 1)) {
    var weekday = new Date(d).getDay()
    if (workweek && (weekday === 0 || weekday === 6)) continue
    days.push(d)
  }
  return days
}

function sameMonth(a, b) {
  var x = new Date(a), y = new Date(b)
  return x.getFullYear() === y.getFullYear() && x.getMonth() === y.getMonth()
}

// One day's events for a month cell: all-day first, then by start time.
function monthDayEvents(events, dayStartMs) {
  var list = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!overlapsDay(event, dayStartMs)) continue
    // A timed event belongs to the day it starts on — a 22:15 game is not
    // also tomorrow's first item — unless it really spans whole days.
    if (!isAllDay(event) && event.start < dayStartMs && event.end - event.start < DAY) continue
    list.push(event)
  }
  list.sort(function(a, b) {
    var aa = isAllDay(a) ? 0 : 1, bb = isAllDay(b) ? 0 : 1
    if (aa !== bb) return aa - bb
    if (a.start !== b.start) return a.start - b.start
    return (b.end - b.start) - (a.end - a.start)
  })
  return list
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

// The heading split in two, so the year can sit quieter than the month:
// { main: "November", year: "2026" }. A range across years keeps it whole.
function rangeTitleParts(days, view, anchorMs) {
  if (view === "month")
    return { main: monthName(anchorMs), year: String(new Date(anchorMs).getFullYear()) }
  if (!days || days.length === 0) return { main: "", year: "" }
  var first = new Date(days[0])
  var last = new Date(days[days.length - 1])
  if (first.getFullYear() !== last.getFullYear()) return { main: rangeTitle(days), year: "" }
  if (days.length === 1)
    return { main: longWeekday(days[0]) + ", " + monthName(days[0]) + " " + first.getDate(),
             year: String(first.getFullYear()) }
  if (first.getMonth() !== last.getMonth())
    return { main: shortMonth(days[0]) + " – " + shortMonth(days[days.length - 1]),
             year: String(last.getFullYear()) }
  return { main: monthName(days[0]), year: String(first.getFullYear()) }
}

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

// -------------------------------------------------------------------- style
//
// Colour itself is mixed in QML (Panel.tone), against the theme's surface;
// all the model decides is which treatment an event gets.

// How an event is painted follows Google's own convention: a meeting you
// accepted is a solid block, one you have not answered is an outline, a
// "maybe" a fainter outline, and one you declined is struck through.
function blockStyle(event) {
  if (!event) return "filled"
  if (isBlockedTime(event)) return "away"
  if (event.response === "declined") return "declined"
  if (event.response === "tentative") return "maybe"
  if (event.response === "needsAction") return "outlined"
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

// "Maybe" is a hedge and "no answer yet" is not a yes: both keep their place
// in the grid but never take the bar or raise a toast.
function isMaybe(event) {
  return event && event.response === "tentative"
}

function isUnanswered(event) {
  return event && event.response === "needsAction"
}

// Time you blocked off for yourself in Google — out of office (a lunch with
// auto-decline), focus time, working location. Not a meeting: no call, no
// bar, no toast, and drawn as a quiet block of its own.
function isBlockedTime(event) {
  var type = event ? event.eventType : ""
  return type === "outOfOffice" || type === "focusTime" || type === "workingLocation"
}

// Whether an event may speak for itself outside the grid — the bar label, its
// hover card, middle click and the toast at its start. Only what you said yes
// to (or what is yours, with no invitation to answer).
function isAnnounceable(event) {
  return event && !isAllDay(event) && !isDeclined(event) && !isMaybe(event) &&
    !isUnanswered(event) && !isBlockedTime(event)
}

// What follows `after` today, for the hover card's "then" rows.
function laterToday(events, after, nowMs, limit) {
  var out = []
  var dayEnd = addDays(startOfDay(nowMs), 1)
  var from = after ? after.start : nowMs
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!isAnnounceable(event)) continue
    if (after && event.id === after.id) continue
    if (event.start <= from || event.start >= dayEnd) continue
    out.push(event)
  }
  out.sort(function(a, b) { return a.start - b.start })
  return out.slice(0, limit || 2)
}

function currentEvent(events, nowMs) {
  var best = null
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!isAnnounceable(event)) continue
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
    if (!isAnnounceable(event)) continue
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

// The event the bar label shows: only from leadMs before it starts until
// graceMs after (or its end, if sooner). When two overlap, the one whose start
// is nearest to now wins, so a meeting about to begin takes over from one
// that began a few minutes ago. Null means the bar shows just the glyph.
function barSubject(events, nowMs, leadMs, graceMs) {
  var best = null
  var bestDistance = 0
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!isAnnounceable(event)) continue
    if (event.start - leadMs > nowMs) continue
    if (nowMs >= Math.min(event.start + graceMs, event.end)) continue
    var distance = Math.abs(event.start - nowMs)
    if (!best || distance < bestDistance ||
        (distance === bestDistance && event.start > best.start)) {
      best = event
      bestDistance = distance
    }
  }
  return best
}

// Where an event stands against the clock, for the card: a kind the UI can
// colour by and a phrase that reads at a glance.
//   soon    — starts within 15 minutes ("Starts in 4 min")
//   running — under way ("On now · 18 min left")
//   later   — further out ("In 2h 10m", "Tomorrow at 09:00", "Thu at 14:00")
//   past    — over ("Ended 40 min ago", "Ended")
function eventStatus(event, nowMs, use24Hour) {
  if (!event) return { kind: "later", label: "" }
  if (isAllDay(event)) {
    if (event.start <= nowMs && event.end > nowMs) return { kind: "running", label: "Today" }
    if (event.end <= nowMs) return { kind: "past", label: "" }
    return { kind: "later", label: "" }
  }
  if (event.end <= nowMs) {
    var ago = Math.round((nowMs - event.end) / MINUTE)
    if (ago < 60) return { kind: "past", label: ago <= 1 ? "Just ended" : "Ended " + ago + " min ago" }
    return { kind: "past", label: sameDay(event.end, nowMs) ? "Ended at " + formatTime(event.end, use24Hour) : "Ended" }
  }
  if (event.start <= nowMs) {
    var left = Math.max(1, Math.round((event.end - nowMs) / MINUTE))
    return { kind: "running", label: "On now · " + (left < 60 ? left + " min left" : formatDuration(left * MINUTE) + " left") }
  }
  var minutes = Math.max(1, Math.round((event.start - nowMs) / MINUTE))
  if (minutes <= 15) return { kind: "soon", label: "Starts in " + minutes + " min" }
  if (minutes < 60) return { kind: "later", label: "In " + minutes + " min" }
  if (sameDay(event.start, nowMs)) {
    var hours = Math.floor(minutes / 60), rest = minutes % 60
    return { kind: "later", label: "In " + hours + "h" + (rest ? " " + rest + "m" : "") }
  }
  if (sameDay(event.start, nowMs + DAY)) return { kind: "later", label: "Tomorrow at " + formatTime(event.start, use24Hour) }
  return { kind: "later", label: "" }
}

// The bare host and path of a meeting link, for showing under the button:
// "meet.google.com/abc-defg-hij".
function displayUrl(url) {
  var value = String(url || "").replace(/^https?:\/\//i, "")
  var q = value.search(/[?#]/)
  if (q >= 0) value = value.substr(0, q)
  return value.replace(/\/$/, "")
}

// Up to two initials for a guest's avatar.
function initials(attendee) {
  var name = attendeeName(attendee).replace(/[._-]+/g, " ").trim()
  if (name.length === 0) return "?"
  var parts = name.split(/\s+/)
  var first = parts[0].charAt(0)
  var last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : ""
  return (first + last).toUpperCase()
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

// ------------------------------------------------------------- composing
//
// People to invite come from the calendar itself: everyone who has been on an
// invitation with you, ranked by how often. No directory API, no extra
// permission — and the people you meet are the people you invite.

function isEmail(text) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(text || "").trim())
}

var FOLD = { "á": "a", "à": "a", "â": "a", "ã": "a", "ä": "a", "é": "e", "ê": "e",
             "è": "e", "í": "i", "ì": "i", "ó": "o", "ô": "o", "õ": "o", "ö": "o",
             "ú": "u", "ü": "u", "ç": "c", "ñ": "n" }

function fold(text) {
  var value = String(text || "").toLowerCase()
  var out = ""
  for (var i = 0; i < value.length; i++) {
    var ch = value.charAt(i)
    out += FOLD[ch] !== undefined ? FOLD[ch] : ch
  }
  return out
}

// `directory`: the Workspace copy from bin/gcalpeople.py — everyone in the
// organisation, with names and photos. Merged in so search reaches people you
// have never met, and the people you have met get their real names and faces.
function peopleIndex(events, selfEmail, directory) {
  var me = String(selfEmail || "").toLowerCase()
  var byEmail = {}
  var dir = directory || []
  for (var d = 0; d < dir.length; d++) {
    var known = String(dir[d].email || "").toLowerCase()
    if (!known || known === me) continue
    byEmail[known] = { email: known, name: dir[d].name || "", count: 0, photo: dir[d].photo || "" }
  }
  for (var i = 0; i < events.length; i++) {
    var attendees = events[i].attendees || []
    for (var j = 0; j < attendees.length; j++) {
      var a = attendees[j]
      var email = String(a.email || "").toLowerCase()
      if (!email || email === me || a.self) continue
      // Meeting rooms and group calendars are not people.
      if (email.indexOf("resource.calendar.google.com") >= 0) continue
      if (email.indexOf("group.calendar.google.com") >= 0) continue
      var entry = byEmail[email]
      if (!entry) entry = byEmail[email] = { email: email, name: "", count: 0, photo: "" }
      entry.count++
      if (a.name && !entry.name) entry.name = a.name
    }
  }
  var list = []
  for (var key in byEmail) {
    var person = byEmail[key]
    person.label = person.name || attendeeName(person)
    person.search = fold(person.label + " " + person.email)
    list.push(person)
  }
  list.sort(function(x, y) {
    if (x.count !== y.count) return y.count - x.count
    return x.label < y.label ? -1 : x.label > y.label ? 1 : 0
  })
  return list
}

function escapeHtml(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// The label with what was typed picked out in bold, so a match explains
// itself: "Mi<b>kail</b> Ajukas". Accents are folded for the match only.
function highlightMatch(label, query) {
  var text = String(label || "")
  var folded = fold(text)
  var words = fold(query).trim().split(/\s+/).filter(function(w) { return w.length > 0 })
  var marks = []
  for (var i = 0; i < text.length; i++) marks.push(false)
  for (var w = 0; w < words.length; w++) {
    var at = folded.indexOf(words[w])
    if (at < 0) continue
    for (var k = at; k < at + words[w].length && k < text.length; k++) marks[k] = true
  }
  var out = "", open = false
  for (var j = 0; j < text.length; j++) {
    if (marks[j] && !open) { out += "<b>"; open = true }
    if (!marks[j] && open) { out += "</b>"; open = false }
    out += escapeHtml(text.charAt(j))
  }
  return open ? out + "</b>" : out
}

// Best matches for what was typed: every word must appear in the name or the
// address; a name that starts with it ranks above one that merely contains
// it, then whoever you meet most.
function searchPeople(index, query, exclude, limit) {
  var words = fold(query).trim().split(/\s+/).filter(function(w) { return w.length > 0 })
  if (words.length === 0) return []
  var skip = {}
  for (var i = 0; i < (exclude || []).length; i++) skip[String(exclude[i]).toLowerCase()] = true
  var scored = []
  for (var p = 0; p < index.length; p++) {
    var person = index[p]
    if (skip[person.email]) continue
    var score = 0
    var ok = true
    for (var w = 0; w < words.length; w++) {
      var at = person.search.indexOf(words[w])
      if (at < 0) { ok = false; break }
      score += (at === 0 || person.search.charAt(at - 1) === " " ||
                person.search.charAt(at - 1) === ".") ? 2 : 1
    }
    if (ok) scored.push({ person: person, score: score })
  }
  scored.sort(function(a, b) {
    if (a.score !== b.score) return b.score - a.score
    return b.person.count - a.person.count
  })
  var out = []
  for (var k = 0; k < scored.length && k < (limit || 5); k++) out.push(scored[k].person)
  return out
}

// The next quarter hour from now, where a new meeting starts by default.
function nextQuarter(nowMs) {
  var step = 15 * MINUTE
  return Math.ceil((nowMs + MINUTE) / step) * step
}

// Whether this calendar may change the event: you organise it, or the
// organiser let guests modify it. Out-of-office and the like are yours too.
function canEdit(event) {
  if (!event || isAllDay(event)) return false
  if (isBlockedTime(event)) return event.organizerSelf === true
  return event.organizerSelf === true || event.guestsCanModify === true
}

// Whether you can answer the invitation from here: you are a guest on it and
// not the one who sent it.
function canRespond(event) {
  if (!event || event.organizerSelf === true || isBlockedTime(event)) return false
  var list = event.attendees || []
  for (var i = 0; i < list.length; i++) if (list[i].self) return true
  return false
}

// Guests other than you, for editing (rooms and yourself are kept by the
// script without being shown).
function editableGuests(event) {
  var out = []
  var list = (event && event.attendees) || []
  for (var i = 0; i < list.length; i++) {
    var a = list[i]
    if (a.self || a.organizer) continue
    var email = String(a.email || "").toLowerCase()
    if (!email || email.indexOf("resource.calendar.google.com") >= 0) continue
    out.push({ email: email, name: a.name || "", label: attendeeName(a) })
  }
  return out
}

// A click in the grid, as the quarter hour it falls in.
function floorQuarter(ms) {
  var date = new Date(ms)
  date.setMinutes(Math.floor(date.getMinutes() / 15) * 15, 0, 0)
  return date.getTime()
}

// "15m", "1h", "1h30", "2h".
function shortDuration(minutes) {
  var m = Math.round(minutes)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60), rest = m % 60
  return rest === 0 ? h + "h" : h + "h" + pad2(rest)
}

// "Mon, Nov 16 · 10:45 – 11:15".
function composeSummary(startMs, endMs, use24Hour) {
  return shortWeekday(startMs) + ", " + shortMonth(startMs) + " " + new Date(startMs).getDate() +
    "  ·  " + formatTime(startMs, use24Hour) + " – " + formatTime(endMs, use24Hour)
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

// ------------------------------------------------------------ theme colours
//
// "Omarchy theme" colouring repaints every event from the active theme's
// palette instead of Google's: your own calendar takes the theme's accent, and
// every other calendar (or an event coloured by hand) takes the theme colour
// nearest its Google hue, so calendars stay apart but look like the desktop.

function hexHsl(hex) {
  var m = String(hex || "").match(/^#?([0-9a-fA-F]{6})/)
  if (!m) return null
  var n = parseInt(m[1], 16)
  var r = ((n >> 16) & 255) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2
  var d = max - min
  if (d === 0) return { h: 0, s: 0, l: l }
  var s = d / (1 - Math.abs(2 * l - 1))
  var h
  if (max === r) h = ((g - b) / d) % 6
  else if (max === g) h = (b - r) / d + 2
  else h = (r - g) / d + 4
  h = h * 60
  if (h < 0) h += 360
  return { h: h, s: s, l: l }
}

// colors.toml as a palette. Newer themes name their hues (red, blue, ...);
// older ones only carry the terminal's color1..color14, which mean the same.
function themePalette(raw) {
  var values = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (match) values[match[1]] = match[2]
  }
  var slots = [
    ["red", "color1"], ["orange", ""], ["yellow", "color3"], ["green", "color2"],
    ["cyan", "color6"], ["blue", "color4"], ["magenta", "color5"]
  ]
  var bright = { red: "color9", yellow: "color11", green: "color10",
                 cyan: "color14", blue: "color12", magenta: "color13" }
  var hues = []
  for (var j = 0; j < slots.length; j++) {
    var name = slots[j][0]
    var base = values[name] || (slots[j][1] ? values[slots[j][1]] : "")
    var hsl = hexHsl(base)
    if (!hsl) continue
    hues.push({
      name: name, hex: base, h: hsl.h,
      bright: values["bright_" + name] || (bright[name] ? values[bright[name]] || "" : "") || base
    })
  }
  return {
    hues: hues,
    accent: values.accent || values.color4 || "",
    muted: values.muted || values.color8 || values.foreground || ""
  }
}

// One Google colour in the theme's terms: greys go to the theme's muted
// tone, everything else to the nearest hue, its bright variant when the
// Google colour was a pale one (Flamingo, Lavender) so pairs stay apart.
function themeColor(hex, palette) {
  if (!palette || !palette.hues || palette.hues.length === 0) return hex
  var hsl = hexHsl(hex)
  if (!hsl) return palette.accent || hex
  if (hsl.s < 0.18) return palette.muted || hex
  var best = null, bestDistance = 999
  for (var i = 0; i < palette.hues.length; i++) {
    var d = Math.abs(palette.hues[i].h - hsl.h)
    if (d > 180) d = 360 - d
    if (d < bestDistance) { bestDistance = d; best = palette.hues[i] }
  }
  return hsl.l > 0.6 ? best.bright : best.hex
}

// The cache's events with their colours swapped for the theme's. Copies, so
// switching back to Google's colours needs no re-read.
function recolorEvents(events, palette, calendars) {
  if (!palette || !palette.hues || palette.hues.length === 0) return events
  var primary = null
  for (var c = 0; c < (calendars || []).length; c++) {
    if (calendars[c].primary) { primary = calendars[c]; break }
  }
  var out = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    // Your own calendar is the accent, unless the event was coloured by hand.
    var own = primary && palette.accent && event.calendarId === primary.id &&
              String(event.color).toLowerCase() === String(primary.color).toLowerCase()
    var copy = {}
    for (var key in event) copy[key] = event[key]
    copy.googleColor = event.color
    copy.color = own ? palette.accent : themeColor(event.color, palette)
    out.push(copy)
  }
  return out
}

// -------------------------------------------------------------------- state

function parseCache(raw) {
  var empty = {
    events: [], calendars: [], account: "", syncedAt: 0,
    error: "", needsAuth: false, canWrite: false, loaded: false
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
      canWrite: parsed.canWrite === true,
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

// ----------------------------------------------------------------- vacation
//
// Vacation mode swaps the bar's "next meeting" for a palm tree and the grid
// for a beach. It lives in its own small state file next to the event cache,
// so every monitor's copy of the widget agrees on whether you are away.

function emptyVacation() {
  return { active: false, until: 0, since: 0 }
}

// Null when the text is not a whole JSON object — an empty or half-written
// file — so a caller can keep what it already knows rather than reset.
function parseVacation(raw) {
  if (!raw || String(raw).trim().length === 0) return null
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object") return null
    return {
      active: parsed.active === true,
      until: Number(parsed.until || 0),
      since: Number(parsed.since || 0)
    }
  } catch (e) {
    return null
  }
}

function serializeVacation(state) {
  return JSON.stringify({
    active: state.active === true,
    until: Number(state.until || 0),
    since: Number(state.since || 0)
  }, null, 2) + "\n"
}

// The one-click ways to end a vacation. `until: 0` means "when I say so".
function vacationPresets(nowMs, use24Hour) {
  var out = []
  var today = startOfDay(nowMs)
  var endOfDay = today + 18 * HOUR
  if (endOfDay - nowMs > 30 * MINUTE)
    out.push({ label: "Rest of today", detail: "back at " + formatTime(endOfDay, use24Hour), until: endOfDay })
  var tomorrow = addDays(today, 1) + 8 * HOUR
  out.push({ label: "Tomorrow morning", detail: shortWeekday(tomorrow) + " " + formatTime(tomorrow, use24Hour), until: tomorrow })
  var weekday = new Date(today).getDay()
  var daysToMonday = ((8 - weekday) % 7) || 7
  var monday = addDays(today, daysToMonday) + 8 * HOUR
  out.push({ label: "Next Monday", detail: shortMonth(monday) + " " + new Date(monday).getDate() + ", " + formatTime(monday, use24Hour), until: monday })
  var week = addDays(today, 7) + 8 * HOUR
  out.push({ label: "One week", detail: shortWeekday(week) + " " + shortMonth(week) + " " + new Date(week).getDate() + ", " + formatTime(week, use24Hour), until: week })
  out.push({ label: "Until I say so", detail: "end it by hand", until: 0 })
  return out
}

// "2026-09-29 08:00", "2026-09-29" (08:00 assumed), or day-first
// "29/09/2026 08:00". Returns NaN for anything else.
function parseDateTimeInput(text) {
  var value = String(text || "").trim()
  var year, month, day, hour = 8, minute = 0
  var iso = value.match(/^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?$/)
  var br = value.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s+(\d{1,2}):(\d{2}))?$/)
  if (iso) {
    year = Number(iso[1]); month = Number(iso[2]); day = Number(iso[3])
    if (iso[4] !== undefined) { hour = Number(iso[4]); minute = Number(iso[5]) }
  } else if (br) {
    day = Number(br[1]); month = Number(br[2]); year = Number(br[3])
    if (br[4] !== undefined) { hour = Number(br[4]); minute = Number(br[5]) }
  } else {
    return NaN
  }
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) return NaN
  var date = new Date(year, month - 1, day, hour, minute, 0, 0)
  // Reject "31 February" rather than letting Date roll it into March.
  if (date.getMonth() !== month - 1 || date.getDate() !== day) return NaN
  return date.getTime()
}

function formatDateTimeInput(ms) {
  var d = new Date(ms)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()) +
         " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// "until 18:00" / "until tomorrow 08:00" / "until Mon Sep 29, 08:00".
function vacationUntilLabel(untilMs, nowMs, use24Hour) {
  if (!untilMs) return "until you say so"
  var time = formatTime(untilMs, use24Hour)
  if (sameDay(untilMs, nowMs)) return "until " + time
  if (sameDay(untilMs, nowMs + DAY)) return "until tomorrow " + time
  var d = new Date(untilMs)
  var label = "until " + shortWeekday(untilMs) + " " + shortMonth(untilMs) + " " + d.getDate()
  if (d.getFullYear() !== new Date(nowMs).getFullYear()) label += " " + d.getFullYear()
  return label + ", " + time
}

// "3 days left" / "6h left" / "back in 40m" — the beach's own clock.
function vacationRemainingLabel(untilMs, nowMs) {
  if (!untilMs) return ""
  var delta = untilMs - nowMs
  if (delta <= 0) return "time to head back"
  var minutes = Math.round(delta / MINUTE)
  if (minutes < 60) return "back in " + minutes + "m"
  var hours = Math.round(delta / HOUR)
  if (hours < 36) return hours + "h left"
  var days = Math.round(delta / DAY)
  return days + (days === 1 ? " day left" : " days left")
}
