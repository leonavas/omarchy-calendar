import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The calendar popup: Google Calendar's time grid, in the bar.
//
// Hour rows down the side, one column per visible day, events drawn as blocks
// at their real position and height with overlaps packed side by side. A red
// line marks now. Clicking a block opens the event, which is where the Join
// button lives.
//
// Data comes from bin/gcal-sync via a JSON cache rather than from QML doing
// its own HTTP: the sync has to hold a refresh token and survive the panel
// being closed, and a file the shell watches is also what lets every monitor's
// copy of the widget share one fetch.
Panel {
  id: root
  moduleName: "leonavas.calendar"
  ipcTarget: "leonavas.calendar"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // the popout coordinator has to be handed that widget as the identity.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------- settings
  readonly property string defaultView: String(setting("view", "week"))
  readonly property bool workweek: Model.truthy(setting("workweek", false), false)
  readonly property bool use24Hour: Model.truthy(setting("use24Hour", true), true)
  readonly property bool showWeekNumbers: Model.truthy(setting("showWeekNumbers", true), true)
  readonly property bool showDeclined: Model.truthy(setting("showDeclined", true), true)
  readonly property int hourHeightSetting: Math.max(18, Number(setting("hourHeight", 40)))
  readonly property int scrollToHour: Math.max(0, Math.min(23, Number(setting("scrollToHour", 8))))
  readonly property int syncMinutes: Math.max(1, Number(setting("syncMinutes", 5)))
  readonly property int daysBack: Math.max(0, Number(setting("daysBack", 14)))
  readonly property int daysAhead: Math.max(1, Number(setting("daysAhead", 90)))
  readonly property string meetingOpenMode: String(setting("meetingOpenMode", "App window"))
  readonly property string extraAccounts: String(setting("googleAccounts", ""))
  readonly property bool copyMeetingLink: Model.truthy(setting("copyMeetingLink", true), true)
  readonly property bool notifyAtStart: Model.truthy(setting("notifyAtStart", true), true)
  readonly property bool themeColors: String(setting("eventColors", "Google Calendar")) === "Omarchy theme"
  readonly property int panelGridHeight: root.sp(Math.max(160, Number(setting("gridHeight", 420))))

  // Unset follows the system locale, so a fresh install starts out agreeing
  // with the rest of the desktop about where a week begins. The settings panel
  // writes the day by name, a hand-edited shell.json may hold the number, and
  // both mean the same thing here.
  readonly property int weekStart: {
    var configured = setting("weekStartDay", null)
    if (configured === null || configured === undefined || configured === "")
      return Qt.locale().firstDayOfWeek
    var name = String(configured).toLowerCase()
    if (name === "sunday" || name === "0") return 0
    if (name === "monday" || name === "1") return 1
    return Qt.locale().firstDayOfWeek
  }

  // -------------------------------------------------------------- theming
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dimForeground: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color faintForeground: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.32)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color strongHairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.22)
  readonly property color accent: bar ? bar.urgent : Color.urgent
  readonly property color surface: Color.popups.background
  readonly property color yellowTone: "#e0af68"
  // A whisper of the foreground over the surface: hover rows, today's column,
  // the segmented control's track.
  readonly property color wash: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.045)
  readonly property color washStrong: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.09)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // An event's colour laid over the popup's own surface at `amount`, so a
  // block reads as a deep tone of its calendar in a dark theme and a pale one
  // in a light theme, with the theme's own text legible on both.
  function tone(hex, amount) {
    var c = Qt.color(hex || "#039be5")
    var base = Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1)
    return Qt.tint(base, Qt.rgba(c.r, c.g, c.b, amount))
  }

  // How a block is painted, by your answer to the invitation: accepted is a
  // deep tone of its calendar, unanswered a pale wash with an outline, "maybe"
  // paler still, declined only an outline. Past events step back further.
  function blockFill(event, style) {
    if (style === "filled") return root.tone(event.color, 0.46)
    if (style === "outlined") return root.tone(event.color, 0.13)
    if (style === "maybe") return root.tone(event.color, 0.06)
    if (style === "away") return Qt.tint(Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1),
                                         Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07))
    return "transparent"
  }
  function blockBorder(event, style) {
    var c = Qt.color(event.color || "#039be5")
    if (style === "filled") return Qt.rgba(c.r, c.g, c.b, 0.55)
    if (style === "outlined") return Qt.rgba(c.r, c.g, c.b, 0.7)
    if (style === "maybe") return Qt.rgba(c.r, c.g, c.b, 0.38)
    if (style === "away") return root.hairline
    return root.strongHairline
  }
  // The event's colour pushed toward the foreground, for small text and rules
  // drawn on its tone.
  function ink(hex) {
    var c = Qt.color(hex || "#039be5")
    return Qt.tint(c, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45))
  }

  // -------------------------------------------------------------- the clock
  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  readonly property double nowMs: clock.date ? clock.date.getTime() : Date.now()
  readonly property double todayMs: Model.startOfDay(nowMs)

  // ------------------------------------------------------------------ data
  //
  // One cache file, written atomically by the sync script and watched here,
  // so every bar surface repaints off the same fetch.
  // Same directory the scripts in bin/ resolve, XDG_STATE_HOME included.
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") ||
    Quickshell.env("HOME") + "/.local/state") + "/omarchy/calendar"
  property var cache: Model.parseCache("")
  readonly property var allEvents: root.themeColors
    ? Model.recolorEvents(cache.events || [], root.themePalette, root.calendars)
    : (cache.events || [])

  // The active theme's palette, for "Omarchy theme" event colours. A theme
  // switch reaches the shell over IPC rather than as a file change, so the
  // file is re-read whenever the shell's own colours move.
  property var themePalette: Model.themePalette("")
  FileView {
    id: themeColorsFile
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themePalette = Model.themePalette(text())
  }
  Connections {
    target: Color
    function onAccentChanged() { themeColorsFile.reload() }
    function onBackgroundChanged() { themeColorsFile.reload() }
  }
  readonly property var calendars: cache.calendars || []
  readonly property bool needsAuth: cache.needsAuth === true

  // The address the calendars belong to, and the accounts the Join button can
  // open as. A browser signed into several Google accounts opens a link as
  // whichever one is first, which is rarely the one the meeting is on.
  readonly property string account: String(cache.account || "")
  readonly property var accountOptions: Model.accountOptions(root.account, root.extraAccounts)
  readonly property string defaultAccount: root.accountOptions.length > 0
    ? root.accountOptions[0].account : ""

  property bool accountPickerOpen: false
  property string pendingAction: ""
  readonly property string syncError: String(cache.error || "")
  readonly property bool everSynced: Number(cache.syncedAt || 0) > 0

  // Declined invitations are shown by default — a meeting you turned down
  // still explains why that hour looks busy — and drop out when the setting
  // is off, the way Google hides them.
  readonly property var events: {
    if (root.showDeclined) return root.allEvents
    var list = []
    for (var i = 0; i < root.allEvents.length; i++) {
      if (root.allEvents[i].response !== "declined") list.push(root.allEvents[i])
    }
    return list
  }

  FileView {
    id: eventsFile
    path: root.statePath + "/events.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.cache = Model.parseCache(text())
    onLoadFailed: root.cache = Model.parseCache("")
  }

  // -------------------------------------------------------------- vacation
  //
  // Away: the bar shows a palm tree instead of the next meeting, the popup
  // shows a beach instead of the grid, and meetings start without a toast.
  // Kept in its own file beside the cache so every monitor's copy of the
  // widget — and the next shell restart — agrees on whether you are away.
  property var vacation: Model.emptyVacation()
  readonly property bool vacationActive: root.vacation.active === true
  readonly property double vacationUntil: Number(root.vacation.until || 0)

  // The "start vacation" card, and whether its date field holds the keyboard.
  property bool vacationDialogOpen: false
  property bool vacationFieldFocused: false
  property bool vacationLoaded: false

  FileView {
    id: vacationFile
    path: root.statePath + "/vacation.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      // A torn read — another writer caught mid-file — parses to null and
      // changes nothing; the next change event brings the whole file.
      var parsed = Model.parseVacation(text())
      if (parsed !== null) root.vacation = parsed
      else if (!root.vacationLoaded) root.vacation = Model.emptyVacation()
      root.vacationLoaded = true
      // Deferred: a vacation whose end passed while the shell was down
      // should end now, not at the next minute tick — but not from inside
      // this handler's own assignment.
      Qt.callLater(root.checkVacationEnd)
    }
    onLoadFailed: {
      // A failure after the first load is an atomic replace caught
      // mid-rename, not a change of heart: keep the state already held.
      if (root.vacationLoaded) return
      root.vacationLoaded = true
      root.vacation = Model.emptyVacation()
      // First run: write the file, so there is something for the watcher
      // to watch. A path that does not exist yet cannot be watched, and the
      // next start would otherwise be missed until the panel reloads it.
      root.saveVacation(root.vacation)
    }
  }

  function saveVacation(state) {
    root.vacation = state
    vacationFile.setText(Model.serializeVacation(state))
  }

  // `untilMs` of 0 means it ends when you end it.
  function startVacation(untilMs) {
    root.vacationDialogOpen = false
    root.vacationFieldFocused = false
    keyCatcher.forceActiveFocus()
    root.clearSelection()
    root.saveVacation({ active: true, until: Number(untilMs || 0), since: Date.now() })
  }

  function endVacation() {
    root.vacationDialogOpen = false
    root.vacationFieldFocused = false
    root.saveVacation({ active: false, until: 0, since: 0 })
    // Back to the working day, wherever the grid was left before leaving.
    root.goToday()
  }

  function toggleVacation() {
    if (root.vacationActive) root.endVacation()
    else root.startVacation(0)
  }

  function openVacationDialog() {
    root.clearSelection()
    root.vacationDialogOpen = true
  }

  function closeVacationDialog() {
    root.vacationDialogOpen = false
    root.vacationFieldFocused = false
    // The date field may have held focus; the shortcuts want it back.
    keyCatcher.forceActiveFocus()
  }

  // A timed vacation ends itself. Only the first bar surface may do the
  // ending, or every monitor writes the file and sends the toast.
  //
  // Never called from inside vacationChanged: ending writes `vacation`, and a
  // handler on that signal can run before the derived vacationActive binding
  // has caught up, which recursed until the stack ran out. The check reads
  // the raw object, runs from the clock tick and from a deferred call after a
  // load, and remembers which end it already announced.
  property double vacationEndedUntil: 0

  function checkVacationEnd() {
    var state = root.vacation
    if (!state || state.active !== true) return
    var until = Number(state.until || 0)
    if (until <= 0 || Date.now() < until) return
    if (!root.isPrimaryInstance()) return
    if (root.vacationEndedUntil === until) return
    root.vacationEndedUntil = until
    root.endVacation()
    root.notify("Vacation over", "The calendar is back in the bar")
  }
  onNowMsChanged: root.checkVacationEnd()

  // ------------------------------------------------------------------ sync
  //
  // Resolved off this file's own location so the plugin keeps working from
  // wherever it is cloned or symlinked.
  readonly property string scriptPath: {
    var url = String(Qt.resolvedUrl("bin/gcal-sync"))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  property bool syncing: false
  property string syncMessage: ""

  // A bar surface exists per monitor, so this panel exists N times. Only the
  // first may run the sync; the rest read the file it writes.
  function isPrimaryInstance() {
    var peers = root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : []
    return peers.length === 0 || peers[0] === root.barIdentity
  }

  function sync(force) {
    if (root.syncing) return
    if (!force && !isPrimaryInstance()) return
    root.syncing = true
    root.syncMessage = ""
    syncProcess.command = [
      root.scriptPath,
      "--days-back", String(root.daysBack),
      "--days-ahead", String(root.daysAhead)
    ]
    syncProcess.running = true
  }

  Process {
    id: syncProcess
    running: false
    onExited: function(exitCode) {
      root.syncing = false
      // The script writes its own error into the cache file, which is what
      // the panel renders; this is only for the transient footer note.
      if (exitCode !== 0 && exitCode !== 2) root.syncMessage = "sync failed"
      else root.syncMessage = ""
      eventsFile.reload()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim().length > 0) root.syncMessage = String(text).trim()
    }
  }

  Timer {
    id: syncTimer
    interval: root.syncMinutes * 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.sync(false)
  }

  // ------------------------------------------------------------ navigation
  property string view: root.defaultView
  property double anchorDay: Model.startOfDay(Date.now())

  readonly property bool monthView: root.view === "month"
  readonly property var days: Model.visibleDays(root.anchorDay, root.view, root.weekStart, root.workweek)
  readonly property bool showingToday: {
    if (root.monthView) return Model.sameMonth(root.anchorDay, root.todayMs)
    for (var i = 0; i < root.days.length; i++) if (root.days[i] === root.todayMs) return true
    return false
  }
  readonly property int todayColumn: {
    if (root.monthView) return -1
    for (var i = 0; i < root.days.length; i++) if (root.days[i] === root.todayMs) return i
    return -1
  }

  // The month grid's shape, and each cell's events in reading order.
  readonly property int monthColumns: root.workweek ? 5 : 7
  readonly property int monthRows: root.monthView
    ? Math.max(1, Math.ceil(root.days.length / root.monthColumns)) : 0
  readonly property var monthModels: {
    if (!root.monthView) return []
    var out = []
    for (var i = 0; i < root.days.length; i++)
      out.push({ day: root.days[i], events: Model.monthDayEvents(root.events, root.days[i]) })
    return out
  }

  // Everything the grid draws, recomputed as one pass whenever the visible
  // range or the event list moves.
  readonly property var dayModels: {
    if (root.monthView) return []
    var out = []
    for (var i = 0; i < root.days.length; i++) {
      var day = root.days[i]
      out.push({
        day: day,
        blocks: Model.layoutDay(Model.timedEventsForDay(root.events, day), day)
      })
    }
    return out
  }
  readonly property var allDayLayout: root.monthView ? { bars: [], lanes: 0 }
    : Model.layoutAllDay(root.events, root.days)
  readonly property int allDayLanes: Math.min(3, root.allDayLayout.lanes)

  function step(direction) {
    if (root.monthView) {
      root.anchorDay = Model.addMonths(root.anchorDay, direction)
    } else {
      var count = Model.stepFor(root.view, root.workweek)
      root.anchorDay = Model.addDays(root.anchorDay, direction * count)
    }
    root.selectedEvent = null
  }

  function goToday() {
    root.anchorDay = Model.startOfDay(Date.now())
    root.selectedEvent = null
    Qt.callLater(root.scrollToRelevantHour)
  }

  function setView(next) {
    if (root.view === next) return
    // Leaving the current month for a closer view lands on today, not on
    // the 1st the month view was anchored to.
    if (root.monthView && Model.sameMonth(root.anchorDay, root.todayMs))
      root.anchorDay = root.todayMs
    root.view = next
    root.selectedEvent = null
    Qt.callLater(root.scrollToRelevantHour)
  }

  // ------------------------------------------------------------- selection
  property var selectedEvent: null

  function selectEvent(event) {
    root.selectedEvent = event
  }

  function clearSelection() {
    root.cancelAccountPicker()
    root.confirmingDelete = false
    root.pendingResponse = ""
    root.detailError = ""
    root.selectedEvent = null
  }

  // The card's "delete?" step, open.
  property bool confirmingDelete: false

  // Your answer as just clicked, shown until the sync brings it back.
  property string pendingResponse: ""

  function respondTo(event, response, scope) {
    if (!event || root.composerBusy) return
    root.pendingResponse = response
    root.runEventAction({
      action: "respond", calendarId: event.calendarId, eventId: event.id,
      recurringEventId: event.recurringEventId || "", scope: scope || "instance",
      response: response, summary: event.summary
    })
  }

  // ------------------------------------------------------------ composing
  //
  // "New meeting": a card over the grid to schedule a call and invite people,
  // written to Google by bin/gcal-event. People come from your own calendar
  // (Model.peopleIndex), so search needs no extra permission.
  property bool composerOpen: false
  property double composerStart: 0
  property bool composerBusy: false
  property string composerError: ""
  // Read-only grant: known from the cache up front, or learnt from a failed
  // create. Clears itself once a sync reports the write permission.
  property bool composerScopeError: false
  readonly property bool canWrite: root.cache.canWrite === true
  readonly property bool composerNeedsScope: root.composerScopeError ||
    (root.everSynced && !root.canWrite)
  onCanWriteChanged: if (root.canWrite) root.composerScopeError = false
  readonly property var people: Model.peopleIndex(root.allEvents, root.account, root.directory)

  // Colleagues from the Workspace directory, with photos (bin/gcalpeople.py,
  // refreshed daily by the sync). Empty until the directory permission is
  // granted; everything falls back to initials.
  property var directory: []
  readonly property var photos: {
    var map = {}
    for (var i = 0; i < root.directory.length; i++) {
      var person = root.directory[i]
      if (!person.photo) continue
      map[String(person.email).toLowerCase()] = person.photo
      var aliases = person.aliases || []
      for (var j = 0; j < aliases.length; j++) map[String(aliases[j]).toLowerCase()] = person.photo
    }
    return map
  }
  function photoFor(email) {
    return root.photos[String(email || "").toLowerCase()] || ""
  }

  // The directory's name for an address, so "mikail.ajukas" reads as the
  // person: Calendar only carries names it was given on the invitation.
  readonly property var directoryNames: {
    var map = {}
    for (var i = 0; i < root.directory.length; i++)
      if (root.directory[i].name) map[String(root.directory[i].email).toLowerCase()] = root.directory[i].name
    return map
  }
  function nameFor(attendee) {
    if (!attendee) return ""
    if (attendee.name) return attendee.name
    return root.directoryNames[String(attendee.email || "").toLowerCase()] || Model.attendeeName(attendee)
  }

  FileView {
    path: root.statePath + "/people.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.directory = JSON.parse(text()).people || [] } catch (e) {}
    }
  }

  // A face, or its initials while there is none: round, any size.
  component Avatar: Item {
    id: avatar
    property string email: ""
    property string label: ""
    property string photo: ""
    property real size: 20
    property color fill: "#33ffffff"
    property color ink: "#ccffffff"
    property string family: ""
    property bool ring: false
    property color ringColor: "#88ffffff"
    width: size
    height: size

    readonly property bool hasPhoto: photoImage.status === Image.Ready

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: avatar.fill
      visible: !avatar.hasPhoto

      Text {
        anchors.centerIn: parent
        text: Model.initials({ name: avatar.label, email: avatar.email })
        color: avatar.ink
        font.family: avatar.family
        font.pixelSize: Math.max(7, Math.round(avatar.size * 0.4))
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    Image {
      id: photoImage
      anchors.fill: parent
      source: avatar.photo !== "" ? "file://" + avatar.photo : ""
      sourceSize: Qt.size(avatar.size * 2, avatar.size * 2)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      smooth: true
      visible: false
    }

    Item {
      id: avatarMask
      anchors.fill: parent
      layer.enabled: true
      visible: false
      Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
    }

    MultiEffect {
      anchors.fill: parent
      source: photoImage
      visible: avatar.hasPhoto
      maskEnabled: true
      maskSource: avatarMask
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
    }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      visible: avatar.ring
      border.width: 1
      border.color: avatar.ringColor
    }
  }

  // The event being edited, or null for a new one.
  property var composerEdit: null

  function openComposer(startMs) {
    root.clearSelection()
    root.closeVacationDialog()
    root.composerEdit = null
    root.composerStart = startMs && startMs > 0 ? startMs : Model.nextQuarter(Date.now())
    root.composerError = ""
    root.composerOpen = true
  }

  // The same card, filled in from an event you may change.
  property bool composerFocusGuests: false

  function editEvent(event, focusGuests) {
    if (!event || !Model.canEdit(event)) return
    root.composerFocusGuests = focusGuests === true
    root.selectedEvent = null
    root.closeVacationDialog()
    root.composerEdit = event
    root.composerStart = event.start
    root.composerError = ""
    root.composerOpen = true
  }

  function closeComposer() {
    if (root.composerBusy) return
    root.composerOpen = false
    root.composerEdit = null
    keyCatcher.forceActiveFocus()
  }

  // Every write goes through bin/gcal-event: { action: create | update |
  // delete, ... } — see the script for the fields.
  function runEventAction(request) {
    if (root.composerBusy) return
    root.composerBusy = true
    root.composerError = ""
    root.detailError = ""
    console.info("leonavas.calendar: " + request.action + " " + (request.eventId || request.summary || ""))
    eventProcess.request = request
    eventProcess.handled = false
    eventProcess.command = [root.scriptPath.replace("gcal-sync", "gcal-event"),
                            JSON.stringify(request)]
    eventProcess.running = true
  }

  function createMeeting(request) {
    request.action = "create"
    root.runEventAction(request)
  }

  // Deleting an event from the card: { scope, notify }.
  function deleteEvent(event, scope, notify) {
    if (!event) return
    root.runEventAction({
      action: "delete", calendarId: event.calendarId, eventId: event.id,
      recurringEventId: event.recurringEventId || "", scope: scope || "instance",
      notify: notify === true, summary: event.summary
    })
  }

  property string detailError: ""

  Process {
    id: eventProcess
    property var request: null
    property bool handled: false
    running: false
    stdout: StdioCollector {
      id: eventOutput
      waitForEnd: true
      onStreamFinished: root.handleEventResult(String(text))
    }
    // Belt and braces: whichever of exit and end-of-output comes last.
    onExited: Qt.callLater(function() { root.handleEventResult(String(eventOutput.text)) })
  }

  function handleEventResult(text) {
    if (eventProcess.handled || eventProcess.running) return
    eventProcess.handled = true
    root.composerBusy = false
    var result = null
    try { result = JSON.parse(String(text).trim()) } catch (e) { result = null }
    var request = eventProcess.request || {}

    if (!result || !result.ok) {
      console.warn("leonavas.calendar: " + request.action + " failed: " + String(text).trim())
      root.composerScopeError = !!(result && result.needsScope)
      var message = root.composerScopeError
        ? "Google has not allowed changing events yet."
        : (result && result.error ? result.error : "Google did not accept the change")
      if (request.action === "delete" || request.action === "respond") root.detailError = message
      if (request.action === "respond") root.pendingResponse = ""
      else root.composerError = message
      return
    }

    root.sync(true)
    var guests = (request.attendees || []).length

    if (request.action === "respond") return

    if (request.action === "delete") {
      root.clearSelection()
      root.notify(request.summary || "Event", request.notify
        ? "Deleted — guests were emailed" : "Deleted")
      return
    }

    root.composerOpen = false
    root.composerEdit = null
    root.clearSelection()
    keyCatcher.forceActiveFocus()

    if (request.action === "update") {
      root.notify(request.summary || "Event", request.notify && guests > 0
        ? "Saved — guests were emailed" : "Saved")
      return
    }

    // Created. Starting now: straight into the room, as the right account.
    if (result.meetingUrl && request.start - Date.now() <= 5 * 60000) {
      root.openUrl(Model.withAccount(result.meetingUrl, root.defaultAccount))
      if (root.opened) root.close()
    }
    root.notify(request.summary || "Meeting created",
      (guests > 0 ? (request.notify ? "Invitations sent to " + guests + (guests === 1 ? " guest" : " guests")
                                    : "Created with " + guests + (guests === 1 ? " guest" : " guests") + ", no email")
                  : "Created") +
      (result.meetingUrl ? "\n" + Model.displayUrl(result.meetingUrl) : ""))
    if (result.meetingUrl && request.start - Date.now() > 5 * 60000)
      root.copyToClipboard(result.meetingUrl)
  }

  // --------------------------------------------------------------- actions
  function openUrl(url) {
    var value = String(url || "")
    if (value.length === 0) return
    // A meeting is a place you sit for an hour, so it gets its own window by
    // default rather than a tab that goes missing behind the browser.
    if (root.meetingOpenMode === "App window")
      Util.execArgv(["omarchy-launch-webapp", value])
    else
      Util.execArgv(["xdg-open", value])
  }

  // `account` left out means the calendar's own account — the fast paths
  // (middle click on a block, middle click on the bar) use that.
  function joinMeeting(event, account) {
    if (!event || !event.meetingUrl) return
    var as = account === undefined ? root.defaultAccount : account
    root.openUrl(Model.withAccount(event.meetingUrl, as))
    root.close()
  }

  function openInGoogle(event, account) {
    var url = event && event.htmlLink ? event.htmlLink : "https://calendar.google.com/"
    var as = account === undefined ? root.defaultAccount : account
    Util.execArgv(["xdg-open", Model.withAccount(url, as)])
    root.close()
  }

  // The card's buttons act at once, as the calendar's own account — the same
  // path as middle click. Another account is one step further, behind the
  // "as…" button, and only offered when there is one to choose.
  // "Browser default" is always on the list, so a second real account only
  // exists once one is configured in settings.
  readonly property bool hasOtherAccounts: root.accountOptions.length > 2

  function requestAction(action) {
    root.performAction(action, root.defaultAccount)
  }

  function chooseAccountFor(action) {
    if (root.accountPickerOpen && root.pendingAction === action) {
      root.cancelAccountPicker()
      return
    }
    root.pendingAction = action
    root.accountPickerOpen = true
  }

  // Enter / Space on an open card: the call if there is one, else the event.
  function activateSelection() {
    var event = root.selectedEvent
    if (!event) return
    root.performAction(event.meetingUrl ? "join" : "open", root.defaultAccount)
  }

  function performAction(action, account) {
    var event = root.selectedEvent
    root.cancelAccountPicker()
    if (!event) return
    if (action === "join") root.joinMeeting(event, account)
    else root.openInGoogle(event, account)
  }

  function cancelAccountPicker() {
    root.accountPickerOpen = false
    root.pendingAction = ""
  }

  // ------------------------------------------------ the meeting is starting
  //
  // A toast at the moment an event begins, which opens the call when clicked.
  // The click action rides along as the `omarchy-exec-argv` hint rather than a
  // libnotify action: the daemon runs it detached, so it still works after the
  // sending process is gone and after a shell restart.

  // Events already announced, so a repeat poll — or a cache rewritten in place
  // by a sync — cannot fire the same toast twice.
  property var notifiedEvents: ({})
  property bool notifyArmed: false

  // Everything already under way when the watcher starts is marked as seen: a
  // shell restart at midday must not replay every meeting since breakfast.
  function armNotifications() {
    var seen = {}
    var now = Date.now()
    for (var i = 0; i < root.events.length; i++) {
      if (root.events[i].start <= now) seen[root.events[i].id] = true
    }
    root.notifiedEvents = seen
    root.notifyArmed = true
  }

  function checkStartingEvents() {
    if (!root.notifyAtStart) return
    // A bar surface exists per monitor, so this panel exists N times. Only the
    // first may speak, or a meeting announces itself once per screen.
    if (!root.isPrimaryInstance()) return
    if (!root.cache.loaded) return
    // Away: nothing is announced, and the watcher re-arms on return so the
    // meetings that passed on the beach are not replayed as a burst.
    if (root.vacationActive) { root.notifyArmed = false; return }
    if (!root.notifyArmed) { root.armNotifications(); return }

    var now = Date.now()
    for (var i = 0; i < root.events.length; i++) {
      var event = root.events[i]
      // All-day, declined, "maybe" and unanswered events never toast.
      if (!Model.isAnnounceable(event)) continue
      if (root.notifiedEvents[event.id]) continue
      if (event.start > now) continue
      root.notifiedEvents[event.id] = true
      // Only just started. Something that began long ago — a laptop resumed
      // from sleep, a first sync that arrived late — is stale news rather than
      // a call to join, so it is marked seen above and skipped here.
      if (now - event.start > 120000) continue
      root.announceEvent(event)
    }
  }

  function announceEvent(event) {
    // Prefer the call; fall back to the event in Google Calendar so the toast
    // is still worth clicking for something without a conference attached.
    var meeting = String(event.meetingUrl || "")
    var target = meeting.length > 0
      ? Model.withAccount(meeting, root.defaultAccount)
      : Model.withAccount(String(event.htmlLink || ""), root.defaultAccount)

    var body = Model.formatRange(event, root.use24Hour)
    if (event.meetingProvider) body += "  ·  " + event.meetingProvider
    else if (event.location) body += "  ·  " + Model.truncate(event.location, 40)

    var argv = [
      "omarchy-notification-send",
      "--app-name", "Calendar",
      "-g", "󰃭",
      // Normal urgency so the daemon honours the timeout: critical would pin
      // the toast until clicked. Twenty seconds is long enough to read and
      // click, short enough not to linger through the meeting.
      "-u", "normal",
      "-t", "20000",
      String(event.summary || "(no title)"),
      body
    ]
    if (target.length > 0) {
      argv.push("--exec")
      if (meeting.length > 0 && root.meetingOpenMode === "App window")
        argv.push("omarchy-launch-webapp", target)
      else
        argv.push("xdg-open", target)
    }
    Util.execArgv(argv)
  }

  Timer {
    id: startWatcher
    // Ten seconds is close enough to "on the hour" for a meeting, and cheap:
    // the check is a loop over an array already in memory.
    interval: 10000
    repeat: true
    running: root.notifyAtStart
    triggeredOnStart: true
    onTriggered: root.checkStartingEvents()
  }

  function copyToClipboard(text) {
    var value = String(text || "")
    if (value.length === 0) return
    // Same shape the shell's own panels use to reach the Wayland clipboard.
    Quickshell.execDetached(["bash", "-c",
      "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  function notify(title, body) {
    Util.execArgv(["notify-send", "-a", "Calendar", String(title), String(body)])
  }

  function copyMeetingFor(event) {
    if (!event || !event.meetingUrl) return
    root.copyToClipboard(event.meetingUrl)
    root.notify(event.summary, "Meeting link copied")
  }

  // Every Meet room currently on screen, so the watcher can tell the room it
  // just opened from calls that were already running.
  function collectMeetCodes() {
    var found = {}
    var list = Hyprland.toplevels ? (Hyprland.toplevels.values || []) : []
    for (var i = 0; i < list.length; i++) {
      var code = root.meetCodeOf(list[i])
      if (code.length > 0) found[code] = true
    }
    return found
  }

  // A room code is only trusted from a window that is actually Meet: three
  // short letter groups would otherwise match ordinary words in a title.
  function meetCodeOf(toplevel) {
    if (!toplevel) return ""
    var title = String(toplevel.title || "")
    var wayland = toplevel.wayland
    var appId = String((wayland && wayland.appId) || "")
    if ((title + " " + appId).toLowerCase().indexOf("meet") < 0) return ""
    return Model.meetCodeFromTitle(title)
  }

  function findNewMeetCode() {
    var list = Hyprland.toplevels ? (Hyprland.toplevels.values || []) : []
    for (var i = 0; i < list.length; i++) {
      var code = root.meetCodeOf(list[i])
      if (code.length > 0 && !root.knownMeetCodes[code]) return code
    }
    return ""
  }

  property var knownMeetCodes: ({})

  // meet.google.com/new is a redirect, so at launch there is no link to copy
  // yet — the room is minted by the browser. The code turns up in the window
  // title once the room is open, which is where this reads it from.
  Timer {
    id: meetLinkWatcher
    property int attempts: 0
    interval: 700
    repeat: true
    running: false

    onTriggered: {
      meetLinkWatcher.attempts += 1
      var code = root.findNewMeetCode()
      if (code.length > 0) {
        meetLinkWatcher.running = false
        var url = Model.meetUrlFromCode(code)
        root.copyToClipboard(url)
        root.notify("Meeting ready", url + "\ncopied to the clipboard")
        return
      }
      // ~35s, enough for a cold browser plus the Meet lobby. Giving up says so
      // rather than leaving a stale clipboard silently in place.
      if (meetLinkWatcher.attempts >= 50) {
        meetLinkWatcher.running = false
        root.notify("Meeting started",
          "Could not read the link from the window title — copy it from the address bar.")
      }
    }
  }

  // Start a call now, as the calendar's own account. No account picker here:
  // this is the quick gesture, and "the same account as my calendar" is the
  // whole point of it.
  function startMeeting(account) {
    var as = account === undefined ? root.defaultAccount : account
    if (root.copyMeetingLink) {
      root.knownMeetCodes = root.collectMeetCodes()
      meetLinkWatcher.attempts = 0
      meetLinkWatcher.restart()
    }
    root.openUrl(Model.newMeetingUrl(as))
    if (root.opened) root.close()
  }

  function openCalendarHome(account) {
    var as = account === undefined ? root.defaultAccount : account
    Util.execArgv(["xdg-open", Model.calendarHomeUrl(as)])
    if (root.opened) root.close()
  }

  function runAuth() {
    // Interactive by nature — it prints instructions and waits on a browser
    // round trip — so it gets a terminal rather than a detached process.
    var script = root.scriptPath.replace("gcal-sync", "gcal-auth")
    Util.execArgv(["omarchy-launch-floating-terminal-with-presentation", script])
    root.close()
  }

  // ------------------------------------------------------------- lifecycle
  function open() {
    root.selectedEvent = null
    // Cheap insurance against a watcher that missed a write: what you see on
    // opening is what the file says.
    vacationFile.reload()
    root.controller.show()
    root.sync(false)
    Qt.callLater(root.scrollToRelevantHour)
  }

  function openOnNext() {
    root.openOnEvent(Model.barEvent(root.events, root.nowMs))
  }

  // The popup, on the day of `event` with its card open.
  function openOnEvent(event) {
    root.openFromHotkey()
    if (!event) return
    root.anchorDay = Model.startOfDay(event.start)
    Qt.callLater(function() {
      root.scrollToRelevantHour()
      root.selectEvent(event)
    })
  }

  function openFromHotkey() {
    root.open()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    root.setCenterHoverRevealSuppressed(false)
    root.selectedEvent = null
    root.closeVacationDialog()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    // Omarchy 4.0.3 moved third-party widgets onto the PluginBarApi facade,
    // where this property is readonly. Prefer the setter it exposes; the
    // direct assignment remains for hosts predating that facade.
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Open on the working day, not on midnight. Today opens with the now line
  // halfway down the viewport — it is the thing you came to read, and it wants
  // what is behind it as much as what is ahead. Browsing another day has no
  // now line to aim at, so it starts at the hour the day tends to begin.
  // A day in the month grid, opened as its own day view.
  function openDay(dayMs) {
    root.anchorDay = Model.startOfDay(dayMs)
    root.selectedEvent = null
    root.view = "day"
    Qt.callLater(root.scrollToRelevantHour)
  }

  function scrollToRelevantHour() {
    if (!gridFlick || root.monthView) return
    // Called from a callLater on open, when the flickable may not have been
    // laid out yet; the configured height is what it is about to become.
    var viewport = gridFlick.height > 0 ? gridFlick.height : root.panelGridHeight
    var target
    if (root.showingToday) {
      // The same measure the now line itself is drawn at, so the two cannot
      // drift apart across a DST boundary. The line sits about a quarter of
      // the way down — a little of what just happened, mostly what is next —
      // and never above the hour the working day starts, so a 10:00 open
      // shows the day rather than the small hours.
      var start = Model.startOfDay(root.nowMs)
      var nowY = ((root.nowMs - start) / Model.dayLength(start)) * grid.height
      target = nowY - Math.min(viewport / 4, 1.5 * grid.hourHeight)
      var dayStartY = root.scrollToHour * grid.hourHeight
      // Early in the working day, open on its start: the morning so far
      // fits above the line anyway.
      if (nowY >= dayStartY && nowY - dayStartY < viewport / 2) target = dayStartY
      else if (nowY >= dayStartY) target = Math.max(target, dayStartY)
    } else {
      target = root.scrollToHour * grid.hourHeight
    }
    var maxY = Math.max(0, grid.height - viewport)
    gridFlick.contentY = Math.max(0, Math.min(target, maxY))
  }

  // ----------------------------------------------------------------- scale
  // A dense grid of small type inside a popup this size reads thin, and the
  // shell's own tokens are sized for the bar, not for a window-sized panel.
  // Every length and type size the panel draws goes through sp()/fs(), so one
  // number grows the whole thing in proportion rather than leaving the text
  // marooned in the middle of larger blocks.
  readonly property real uiScale: {
    var n = Number(setting("contentScale", 125))
    if (!isFinite(n) || n <= 0) return 1.25
    return Math.max(0.8, Math.min(2.0, n / 100))
  }
  function sp(px) {
    var n = Style.spaceReal(px) * root.uiScale
    return n <= 0 ? 0 : Math.max(1, Math.round(n))
  }
  function fs(px) {
    var n = Number(px) * root.uiScale
    return isFinite(n) && n > 0 ? Math.max(1, Math.round(n)) : 1
  }
  readonly property int fontCaption: root.fs(Style.font.caption)
  readonly property int fontBodySmall: root.fs(Style.font.bodySmall)
  readonly property int fontBody: root.fs(Style.font.body)
  readonly property int fontSubtitle: root.fs(Style.font.subtitle)
  readonly property int fontTitle: root.fs(Style.font.title)
  readonly property int fontHeading: root.fs(Style.font.heading)
  readonly property int fontIcon: root.fs(Style.font.icon)

  // --------------------------------------------------------------- metrics
  // The month grid has no hours, so its gutter only carries week numbers.
  readonly property int gutterWidth: root.monthView
    ? (root.showWeekNumbers ? root.sp(40) : 0)
    : root.sp(root.showWeekNumbers && root.view !== "day" ? 54 : 46)
  readonly property int headerHeight: root.sp(34)
  readonly property int dayHeaderHeight: root.monthView ? root.sp(28) : root.sp(44)
  readonly property int monthChipHeight: root.fontCaption + root.sp(4)
  readonly property int allDayRowHeight: root.sp(20)
  readonly property int allDayHeight: root.allDayLanes > 0
    ? root.allDayLanes * root.allDayRowHeight + root.sp(6) : 0
  readonly property int footerHeight: root.sp(24)

  readonly property int beachWidth: root.sp(640)
  readonly property int beachHeight: root.sp(400)

  readonly property int desiredWidth: {
    if (root.vacationActive) return root.beachWidth
    if (root.view === "day") return root.sp(560)
    if (root.view === "3day") return root.sp(840)
    return root.sp(workweek ? 1000 : 1260)
  }
  readonly property int desiredHeight: {
    if (root.vacationActive) return root.beachHeight
    var body = root.monthView ? root.monthRows * root.sp(118) : root.allDayHeight + root.panelGridHeight
    var natural = root.headerHeight + root.dayHeaderHeight + body + root.footerHeight + root.sp(18)
    // A calendar that climbs to the top of the screen buries everything it
    // was opened over; the grid scrolls, so the card can stay low.
    // The month gets a little more: its cells have nowhere to scroll to.
    var room = panel.availableCardHeight
    return room > 0 ? Math.min(natural, Math.round(room * (root.monthView ? 0.7 : 0.62))) : natural
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.sync(true) }
    function today(): void { root.goToday() }
    function day(): void { root.setView("day") }
    function newMeeting(): void { root.startMeeting() }
    function copyLink(): void { root.copyMeetingFor(Model.barEvent(root.events, root.nowMs)) }
    function announceNext(): void {
      var e = Model.barEvent(root.events, root.nowMs)
      if (e) root.announceEvent(e)
    }
    function openCalendar(): void { root.openCalendarHome() }
    // The popup, opened straight on the card of what is on now or next, so
    // Enter joins it. Bind it to a key for a one-keystroke way into a call.
    function next(): void { root.openOnNext() }
    function week(): void { root.setView("week") }
    function month(): void { root.setView("month") }
    // The popup, straight on the "New meeting" card.
    function compose(): void { root.openFromHotkey(); Qt.callLater(function() { root.openComposer(0) }) }
    function vacation(): void { root.toggleVacation() }
    function endVacation(): void { root.endVacation() }
  }

  // ============================================================== the popup
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.desiredWidth)
    contentHeight: panel.fittedContentHeight(root.desiredHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The vacation card's date field needs its letters more than the
      // shortcuts do.
      blocked: root.vacationFieldFocused || root.composerOpen

      onCloseRequested: {
        // Escape unwinds one layer at a time — vacation card or account
        // picker, then the event, then the panel. The grid behind is still
        // where you left it, and dismissing straight to the bar would lose that.
        if (root.composerOpen) root.closeComposer()
        else if (root.confirmingDelete) root.confirmingDelete = false
        else if (root.vacationDialogOpen) root.closeVacationDialog()
        else if (root.accountPickerOpen) root.cancelAccountPicker()
        else if (root.selectedEvent) root.clearSelection()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Enter / Space on an open card does its main thing: join the call.
      onActivateRequested: if (root.selectedEvent && !root.confirmingDelete) root.activateSelection()
      // Delete / x on an open card asks first (see the card's confirm row).
      onDeleteRequested: if (root.selectedEvent) root.confirmingDelete = true
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.step(dx > 0 ? 1 : -1)
        else if (dy !== 0 && root.monthView) root.step(dy > 0 ? 1 : -1)
        else if (dy !== 0) gridFlick.contentY = Math.max(
          0, Math.min(gridFlick.contentY + dy * grid.hourHeight,
                      Math.max(0, grid.height - gridFlick.height)))
      }
      onTextKey: function(text) {
        var key = String(text).toLowerCase()
        if (root.selectedEvent && key === "c" && root.selectedEvent.meetingUrl) {
          root.copyMeetingFor(root.selectedEvent)
          root.close()
          return
        }
        if (root.selectedEvent && key === "o") {
          root.requestAction("open")
          return
        }
        if (root.selectedEvent && key === "e" && Model.canEdit(root.selectedEvent)) {
          root.editEvent(root.selectedEvent)
          return
        }
        if (key === "n") { root.openComposer(0); return }
        if (key === "t") root.goToday()
        else if (key === "d") root.setView("day")
        else if (key === "w") root.setView("week")
        else if (key === "m") root.setView("month")
        else if (key === "3") root.setView("3day")
        else if (key === "r") root.sync(true)
        else if (key === "v") {
          if (root.vacationActive) root.endVacation()
          else if (root.vacationDialogOpen) root.closeVacationDialog()
          else root.openVacationDialog()
        }
      }

      // ------------------------------------------------------------ header
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.headerHeight

        readonly property var titleParts: Model.rangeTitleParts(root.days, root.view, root.anchorDay)

        Row {
          id: titleRow
          anchors.left: parent.left
          anchors.leftMargin: root.sp(2)
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(7)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: header.titleParts.main
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontHeading
            font.bold: true
            renderType: Text.NativeRendering
          }

          Text {
            id: yearText
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: header.titleParts.year
            color: root.faintForeground
            font.family: root.fontFamily
            font.pixelSize: root.fontHeading
            renderType: Text.NativeRendering
          }
        }

        Row {
          anchors.left: titleRow.right
          anchors.leftMargin: root.sp(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(1)

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅁"  // nf-md-chevron_left
            tooltipText: "Previous (←)"
            foreground: root.dimForeground
            accent: root.accent
            fontFamily: root.fontFamily
            iconSize: root.fontIcon
            verticalPadding: root.sp(3)
            horizontalPadding: root.sp(5)
            onClicked: root.step(-1)
          }
          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅂"  // nf-md-chevron_right
            tooltipText: "Next (→)"
            foreground: root.dimForeground
            accent: root.accent
            fontFamily: root.fontFamily
            iconSize: root.fontIcon
            verticalPadding: root.sp(3)
            horizontalPadding: root.sp(5)
            onClicked: root.step(1)
          }
          Item { width: root.sp(4); height: 1 }
          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: "Today"
            tooltipText: "Back to today (t)"
            visible: !root.showingToday
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.fontCaption
            verticalPadding: root.sp(3)
            horizontalPadding: root.sp(8)
            onClicked: root.goToday()
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(6)

          // One segmented control rather than three loose boxes: a single
          // track, the current view lifted out of it.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: viewSegments.implicitWidth + root.sp(4)
            height: viewSegments.implicitHeight + root.sp(4)
            radius: Style.cornerRadius > 0 ? Style.cornerRadius + root.sp(2) : root.sp(5)
            color: root.wash
            border.width: 1
            border.color: root.hairline

            Row {
              id: viewSegments
              anchors.centerIn: parent
              spacing: 0

              Repeater {
                model: [
                  { id: "day", label: "Day", key: "d" },
                  { id: "3day", label: "3 days", key: "3" },
                  { id: "week", label: "Week", key: "w" },
                  { id: "month", label: "Month", key: "m" }
                ]

                Rectangle {
                  required property var modelData
                  readonly property bool current: root.view === modelData.id
                  width: segLabel.implicitWidth + root.sp(18)
                  height: segLabel.implicitHeight + root.sp(8)
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(4)
                  color: current ? root.surface
                    : segMouse.containsMouse ? root.wash : "transparent"
                  border.width: current ? 1 : 0
                  border.color: root.strongHairline
                  Behavior on color { ColorAnimation { duration: Style.duration(120) } }

                  Text {
                    id: segLabel
                    anchors.centerIn: parent
                    text: parent.modelData.label
                    color: parent.current ? root.foreground : root.dimForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    font.bold: parent.current
                    renderType: Text.NativeRendering
                  }

                  MouseArea {
                    id: segMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setView(parent.modelData.id)
                  }
                }
              }
            }
          }

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: root.sp(16)
            color: root.hairline
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: "New"
            iconText: "󰐕"  // nf-md-plus
            tooltipText: "New meeting (n)"
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.fontCaption
            iconSize: root.fontBodySmall
            verticalPadding: root.sp(3)
            horizontalPadding: root.sp(8)
            onClicked: root.openComposer(0)
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"  // nf-md-refresh
            tooltipText: root.syncing ? "Syncing…" : "Sync now (r)"
            foreground: root.syncing ? root.foreground : root.dimForeground
            accent: root.accent
            fontFamily: root.fontFamily
            iconSize: root.fontIcon
            // Button spins its own icon while a fetch is in flight, which is
            // the only feedback a sync gives before the grid repaints.
            iconSpinning: root.syncing
            verticalPadding: root.sp(3)
            horizontalPadding: root.sp(5)
            onClicked: root.sync(true)
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󱁕"  // nf-md-palm_tree
            tooltipText: "Vacation mode (v)"
            selected: root.vacationDialogOpen
            foreground: root.vacationDialogOpen ? root.foreground : root.dimForeground
            accent: root.accent
            fontFamily: root.fontFamily
            iconSize: root.fontIcon
            verticalPadding: root.sp(3)
            horizontalPadding: root.sp(5)
            onClicked: {
              if (root.vacationDialogOpen) root.closeVacationDialog()
              else root.openVacationDialog()
            }
          }
        }
      }

      // ------------------------------------------------------ day headings
      Item {
        id: dayHeader
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.dayHeaderHeight

        // Stepping by wheel over the headings, where the grid's own vertical
        // scroll is not in the way.
        WheelHandler {
          onWheel: function(wheel) { root.step(wheel.angleDelta.y > 0 ? -1 : 1) }
        }

        Text {
          visible: root.showWeekNumbers && root.view !== "day" && !root.monthView
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: root.gutterWidth
          horizontalAlignment: Text.AlignHCenter
          text: root.days.length > 0 ? "W" + Model.isoWeek(root.days[0]) : ""
          color: root.faintForeground
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          renderType: Text.NativeRendering
        }

        Row {
          anchors.left: parent.left
          anchors.leftMargin: root.gutterWidth
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: parent.height

          Repeater {
            model: root.monthView ? root.days.slice(0, root.monthColumns) : root.days

            Item {
              id: dayCell
              required property var modelData
              required property int index
              readonly property bool isToday: modelData === root.todayMs && !root.monthView
              width: (dayHeader.width - root.gutterWidth) /
                Math.max(1, root.monthView ? root.monthColumns : root.days.length)
              height: parent.height

              readonly property bool isPast: modelData < root.todayMs && !root.monthView

              // Weekday and date on one baseline, Google-style: "MON 16".
              Row {
                anchors.centerIn: parent
                spacing: root.sp(6)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.shortWeekday(dayCell.modelData).toUpperCase()
                  color: dayCell.isToday ? root.accent
                    : dayCell.isPast ? root.faintForeground : root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                  font.letterSpacing: 1.2
                  font.bold: dayCell.isToday
                  renderType: Text.NativeRendering
                }

                // Today's date sits in a filled pip, the way Google marks it.
                Rectangle {
                  visible: !root.monthView
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(dayNumber.implicitWidth + root.sp(10), root.sp(26))
                  height: root.sp(26)
                  radius: height / 2
                  color: dayCell.isToday ? root.accent : "transparent"

                  Text {
                    id: dayNumber
                    anchors.centerIn: parent
                    text: new Date(dayCell.modelData).getDate()
                    color: dayCell.isToday
                      ? Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
                      : dayCell.isPast ? root.dimForeground : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontHeading
                    font.bold: dayCell.isToday
                    renderType: Text.NativeRendering
                  }
                }
              }
            }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.leftMargin: root.gutterWidth
          anchors.right: parent.right
          height: 1
          color: root.hairline
        }
      }

      // ------------------------------------------------------- all-day band
      Item {
        id: allDayBand
        anchors.top: dayHeader.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.allDayHeight
        visible: height > 0
        clip: true

        readonly property real columnWidth: (width - root.gutterWidth) / Math.max(1, root.days.length)

        Text {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.topMargin: root.sp(3)
          height: root.allDayRowHeight - root.sp(3)
          verticalAlignment: Text.AlignVCenter
          width: root.gutterWidth
          horizontalAlignment: Text.AlignRight
          rightPadding: root.sp(8)
          text: "all day"
          color: root.faintForeground
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          renderType: Text.NativeRendering
        }

        Repeater {
          model: root.allDayLayout.bars

          Rectangle {
            id: allDayBar
            required property var modelData
            readonly property var event: modelData.event
            readonly property string style: Model.blockStyle(event)

            visible: modelData.lane < root.allDayLanes
            x: root.gutterWidth + modelData.startCol * allDayBand.columnWidth + root.sp(2)
            y: root.sp(3) + modelData.lane * root.allDayRowHeight
            width: Math.max(root.sp(10),
              (modelData.endCol - modelData.startCol + 1) * allDayBand.columnWidth - root.sp(4))
            height: root.allDayRowHeight - root.sp(3)
            radius: root.sp(4)
            color: allDayHover.hovered ? Qt.lighter(root.blockFill(event, style), 1.18)
                                       : root.blockFill(event, style)
            border.width: 1
            border.color: root.blockBorder(event, style)
            opacity: style === "declined" ? 0.5 : (event.end <= root.todayMs ? 0.55 : 1)

            Text {
              anchors.fill: parent
              anchors.leftMargin: root.sp(7)
              anchors.rightMargin: root.sp(5)
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
              text: (allDayBar.modelData.continuesBefore ? "‹ " : "") + allDayBar.event.summary +
                    (allDayBar.modelData.continuesAfter ? " ›" : "")
              color: allDayBar.style === "filled" ? root.foreground : root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: allDayBar.style === "filled"
              font.strikeout: allDayBar.style === "declined"
              renderType: Text.NativeRendering
            }

            HoverHandler {
              id: allDayHover
              cursorShape: Qt.PointingHandCursor
            }

            MouseArea {
              anchors.fill: parent
              onClicked: root.selectEvent(allDayBar.event)
            }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: root.hairline
        }
      }

      // -------------------------------------------------------- the time grid
      Flickable {
        id: gridFlick
        anchors.top: allDayBand.visible ? allDayBand.bottom : dayHeader.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: root.sp(4)
        visible: !root.monthView
        contentWidth: width
        contentHeight: grid.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Item {
          id: grid
          width: gridFlick.width
          height: 24 * hourHeight

          readonly property real hourHeight: root.sp(root.hourHeightSetting)
          readonly property real columnWidth: (width - root.gutterWidth) / Math.max(1, root.days.length)

          // Today's column, washed a shade lighter so the eye lands on it.
          Rectangle {
            visible: root.todayColumn >= 0 && root.days.length > 1
            x: root.gutterWidth + root.todayColumn * grid.columnWidth
            width: grid.columnWidth
            height: grid.height
            color: root.wash
            z: -1
          }

          // Weekend tint, so Saturday and Sunday read as different at a glance.
          Repeater {
            model: root.days

            Rectangle {
              required property var modelData
              required property int index
              readonly property int weekday: new Date(modelData).getDay()
              visible: weekday === 0 || weekday === 6
              x: root.gutterWidth + index * grid.columnWidth
              width: grid.columnWidth
              height: grid.height
              color: Qt.rgba(0, 0, 0, 0.10)
              z: -1
            }
          }

          // Hour rules and their labels, with a fainter half-hour rule between.
          Repeater {
            model: 24

            Item {
              required property int index
              y: index * grid.hourHeight
              width: grid.width
              height: grid.hourHeight

              Text {
                anchors.right: parent.left
                anchors.rightMargin: -root.gutterWidth + root.sp(9)
                anchors.verticalCenter: parent.top
                text: index === 0 ? "" : Model.formatHourLabel(index, root.use24Hour)
                // Steps aside for the now pill when the two would collide.
                visible: !(nowLine.visible && Math.abs(nowLine.y - parent.y) < root.sp(11))
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }

              Rectangle {
                x: root.gutterWidth
                width: parent.width - root.gutterWidth
                height: 1
                color: root.hairline
              }

              Rectangle {
                visible: grid.hourHeight >= root.sp(36)
                x: root.gutterWidth
                y: Math.round(grid.hourHeight / 2)
                width: parent.width - root.gutterWidth
                height: 1
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)
              }
            }
          }

          // Day separators.
          Repeater {
            model: root.days.length

            Rectangle {
              required property int index
              x: root.gutterWidth + index * grid.columnWidth
              width: 1
              height: grid.height
              color: root.hairline
            }
          }

          // ---- events, one delegate per day column
          Repeater {
            model: root.dayModels

            Item {
              id: dayColumn
              required property var modelData
              required property int index
              z: 2
              x: root.gutterWidth + index * grid.columnWidth
              width: grid.columnWidth
              height: grid.height

              // An empty slot is where a new meeting goes: click it to start
              // one there. Blocks sit above and keep their own clicks.
              MouseArea {
                id: slotMouse
                anchors.fill: parent
                z: -1
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                readonly property double slotMs: containsMouse
                  ? Model.floorQuarter(dayColumn.modelData.day +
                      (mouseY / grid.height) * Model.dayLength(dayColumn.modelData.day))
                  : 0
                onClicked: root.openComposer(slotMs)
              }

              // Where the click would put the meeting: an hour, outlined.
              Rectangle {
                visible: slotMouse.containsMouse && slotMouse.slotMs > 0
                z: 0
                x: root.sp(2)
                y: ((slotMouse.slotMs - dayColumn.modelData.day) /
                    Model.dayLength(dayColumn.modelData.day)) * grid.height + 1
                width: dayColumn.width - root.sp(4)
                height: grid.hourHeight - root.sp(2)
                radius: root.sp(4)
                color: root.wash
                border.width: 1
                border.color: root.strongHairline

                Text {
                  x: root.sp(6)
                  y: root.sp(4)
                  text: "+ " + Model.formatTime(slotMouse.slotMs, root.use24Hour)
                  color: root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                  font.bold: true
                  renderType: Text.NativeRendering
                }
              }

              Repeater {
                model: dayColumn.modelData.blocks

                Rectangle {
                  id: block
                  required property var modelData
                  readonly property var event: modelData.event
                  readonly property string style: Model.blockStyle(event)
                  readonly property bool selected: root.selectedEvent !== null &&
                    root.selectedEvent.id === event.id && root.selectedEvent.start === event.start
                  readonly property bool past: event.end <= root.nowMs
                  readonly property bool live: event.start <= root.nowMs && event.end > root.nowMs &&
                    style !== "declined"
                  readonly property real slot: (dayColumn.width - root.sp(4)) / Math.max(1, modelData.columns)
                  // Short blocks put the time beside the title instead of under it.
                  readonly property bool compact: height < root.sp(32)
                  readonly property color fill: root.blockFill(event, style)
                  readonly property color textColor: style === "filled" ? root.foreground
                    : style === "declined" || style === "away" ? root.faintForeground : root.dimForeground

                  x: root.sp(2) + modelData.column * slot
                  y: modelData.top * grid.height + 1
                  width: Math.max(root.sp(14), slot * modelData.span - root.sp(2))
                  height: Math.max(root.sp(13), modelData.height * grid.height - root.sp(2))
                  radius: root.sp(4)
                  clip: true
                  z: hover.hovered || selected ? 3 : 1

                  color: hover.hovered ? Qt.lighter(fill, style === "filled" ? 1.16 : 1.5) : fill
                  border.width: selected ? 2 : 1
                  border.color: selected ? root.foreground
                    : live ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.6)
                    : root.blockBorder(event, style)
                  opacity: style === "declined" ? 0.5 : (past && !selected ? 0.62 : 1)
                  Behavior on color { ColorAnimation { duration: Style.duration(110) } }

                  Text {
                    id: blockTime
                    visible: block.compact && block.width > root.sp(132)
                    anchors.right: parent.right
                    anchors.rightMargin: root.sp(6)
                    anchors.verticalCenter: blockTitle.verticalCenter
                    text: Model.formatTime(block.event.start, root.use24Hour)
                    color: Qt.rgba(block.textColor.r, block.textColor.g, block.textColor.b, 0.7)
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    renderType: Text.NativeRendering
                  }

                  Text {
                    id: blockTitle
                    x: root.sp(6)
                    y: block.compact ? Math.max(0, (block.height - implicitHeight) / 2) : root.sp(4)
                    width: block.width - root.sp(10) -
                      (blockTime.visible ? blockTime.implicitWidth + root.sp(6) : 0)
                    elide: Text.ElideRight
                    maximumLineCount: block.compact ? 1 : (block.height > root.sp(52) ? 2 : 1)
                    wrapMode: block.compact ? Text.NoWrap : Text.Wrap
                    text: block.event.summary
                    color: block.textColor
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    font.bold: block.style !== "maybe" && block.style !== "away"
                    font.italic: block.style === "away"
                    font.strikeout: block.style === "declined"
                    renderType: Text.NativeRendering
                  }

                  Row {
                    visible: !block.compact
                    x: root.sp(6)
                    anchors.top: blockTitle.bottom
                    anchors.topMargin: root.sp(1)
                    width: block.width - root.sp(10)
                    spacing: root.sp(5)

                    Text {
                      text: Model.formatTime(block.event.start, root.use24Hour) +
                            (block.height > root.sp(44) && !block.event.allDay
                              ? " – " + Model.formatTime(block.event.end, root.use24Hour) : "")
                      color: Qt.rgba(block.textColor.r, block.textColor.g, block.textColor.b, 0.72)
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      renderType: Text.NativeRendering
                    }

                    Text {
                      visible: !!block.event.meetingUrl
                      text: "󰕧"  // nf-md-video
                      color: Qt.rgba(block.textColor.r, block.textColor.g, block.textColor.b, 0.6)
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      renderType: Text.NativeRendering
                    }
                  }

                  HoverHandler {
                    id: hover
                    cursorShape: Qt.PointingHandCursor
                  }

                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    onClicked: function(mouse) {
                      // Middle click is the shortcut for what you usually
                      // want from a meeting block: be in the meeting.
                      if (mouse.button === Qt.MiddleButton && block.event.meetingUrl)
                        root.joinMeeting(block.event)
                      else
                        root.selectEvent(block.event)
                    }
                  }
                }
              }
            }
          }

          // ---- now
          //
          // Solid across today's column, a faint thread across the others, and
          // the time itself in the gutter, so "where am I in the day" is read
          // rather than worked out from the hour labels.
          Item {
            id: nowLine
            visible: root.todayColumn >= 0
            y: {
              var start = Model.startOfDay(root.nowMs)
              return Math.round(((root.nowMs - start) / Model.dayLength(start)) * grid.height)
            }
            x: 0
            width: grid.width
            height: 1
            // Behind the blocks, so it never strikes through a title; the dot
            // and the time below ride above them.
            z: 1

            Rectangle {
              x: root.gutterWidth
              width: parent.width - root.gutterWidth
              height: 1
              color: root.accent
              opacity: 0.28
            }

            Rectangle {
              x: root.gutterWidth + root.todayColumn * grid.columnWidth
              y: -0.5
              width: grid.columnWidth
              height: 2
              color: root.accent
            }
          }

          Item {
            visible: nowLine.visible
            y: nowLine.y
            width: grid.width
            height: 1
            z: 5

            Rectangle {
              x: root.gutterWidth + root.todayColumn * grid.columnWidth - width / 2
              y: -height / 2 + 0.5
              width: root.sp(8)
              height: root.sp(8)
              radius: width / 2
              color: root.accent
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              x: root.gutterWidth - width - root.sp(3)
              width: nowLabel.implicitWidth + root.sp(8)
              height: nowLabel.implicitHeight + root.sp(2)
              radius: height / 2
              color: root.accent

              Text {
                id: nowLabel
                anchors.centerIn: parent
                text: Model.formatTime(root.nowMs, root.use24Hour)
                color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                font.bold: true
                renderType: Text.NativeRendering
              }
            }
          }
        }
      }

      // ------------------------------------------------------- the month
      //
      // Five or six weeks of cells, each listing its day in reading order:
      // all-day bars first, then timed events as a dot, a time and a title.
      // What does not fit folds into "+N more", which — like the date itself —
      // opens that day on its own.
      Item {
        id: monthGrid
        visible: root.monthView
        anchors.top: dayHeader.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: root.sp(4)

        readonly property real cellWidth: (width - root.gutterWidth) / Math.max(1, root.monthColumns)
        readonly property real cellHeight: height / Math.max(1, root.monthRows)

        WheelHandler {
          onWheel: function(wheel) { root.step(wheel.angleDelta.y > 0 ? -1 : 1) }
        }

        // Week numbers down the gutter, one per row.
        Repeater {
          model: root.showWeekNumbers ? root.monthRows : 0

          Text {
            required property int index
            x: 0
            y: index * monthGrid.cellHeight + root.sp(6)
            width: root.gutterWidth
            horizontalAlignment: Text.AlignHCenter
            text: "W" + Model.isoWeek(root.days[index * root.monthColumns] || 0)
            color: root.faintForeground
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            renderType: Text.NativeRendering
          }
        }

        Repeater {
          model: root.monthModels

          Item {
            id: monthCell
            required property var modelData
            required property int index
            readonly property double day: modelData.day
            readonly property bool inMonth: Model.sameMonth(day, root.anchorDay)
            readonly property bool isToday: day === root.todayMs
            readonly property bool isPast: day < root.todayMs
            readonly property int weekday: new Date(day).getDay()
            readonly property var dayEvents: modelData.events
            // Rows the cell can show under its date; the last one turns into
            // "+N more" when the day holds more than that.
            readonly property int capacity: Math.max(0, Math.floor(
              (height - cellHead.y - cellHead.height - root.sp(3)) / (root.monthChipHeight + root.sp(1))))
            readonly property int shown: dayEvents.length <= capacity
              ? dayEvents.length : Math.max(0, capacity - 1)

            x: root.gutterWidth + (index % root.monthColumns) * monthGrid.cellWidth
            y: Math.floor(index / root.monthColumns) * monthGrid.cellHeight
            width: monthGrid.cellWidth
            height: monthGrid.cellHeight

            Rectangle {
              anchors.fill: parent
              color: cellHover.hovered ? root.wash
                : (monthCell.weekday === 0 || monthCell.weekday === 6) ? Qt.rgba(0, 0, 0, 0.10)
                : "transparent"
              Behavior on color { ColorAnimation { duration: Style.duration(110) } }
            }

            // Grid rules: top and left of every cell, which closes the grid
            // against the header line and the gutter.
            Rectangle { width: parent.width; height: 1; color: root.hairline }
            Rectangle { width: 1; height: parent.height; color: root.hairline }

            HoverHandler { id: cellHover }

            // The empty part of a cell opens the day.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openDay(monthCell.day)
            }

            Item {
              id: cellHead
              x: root.sp(4)
              y: root.sp(3)
              width: parent.width - root.sp(8)
              height: root.sp(18)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(dateText.implicitWidth + root.sp(10), height)
                height: root.sp(18)
                radius: height / 2
                color: monthCell.isToday ? root.accent : "transparent"

                Text {
                  id: dateText
                  anchors.centerIn: parent
                  // The 1st carries its month, so the grid reads across the
                  // seam between two months.
                  text: new Date(monthCell.day).getDate() === 1
                    ? Model.shortMonth(monthCell.day) + " 1"
                    : String(new Date(monthCell.day).getDate())
                  color: monthCell.isToday
                    ? Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
                    : !monthCell.inMonth ? root.faintForeground
                    : monthCell.isPast ? root.dimForeground : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBodySmall
                  font.bold: monthCell.isToday || new Date(monthCell.day).getDate() === 1
                  renderType: Text.NativeRendering
                }
              }
            }

            Column {
              x: root.sp(3)
              y: cellHead.y + cellHead.height + root.sp(1)
              width: parent.width - root.sp(6)
              spacing: root.sp(1)
              opacity: monthCell.inMonth ? 1 : 0.55

              Repeater {
                model: monthCell.dayEvents.slice(0, monthCell.shown)

                Rectangle {
                  id: chip
                  required property var modelData
                  readonly property var event: modelData
                  readonly property string style: Model.blockStyle(event)
                  readonly property bool allDay: event.allDay === true
                  readonly property bool past: event.end <= root.nowMs
                  readonly property bool live: !allDay && event.start <= root.nowMs &&
                    event.end > root.nowMs && style !== "declined"
                  width: parent.width
                  height: root.monthChipHeight
                  radius: root.sp(3)
                  color: allDay ? root.blockFill(event, style)
                    : chipHover.hovered ? root.washStrong
                    : live ? root.wash : "transparent"
                  border.width: allDay || live ? 1 : 0
                  border.color: live ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.4)
                    : root.blockBorder(event, style)
                  opacity: style === "declined" ? 0.5 : (past ? 0.62 : 1)
                  Behavior on color { ColorAnimation { duration: Style.duration(110) } }

                  // The calendar's colour as a dot, filled when you are going,
                  // a ring while unanswered or "maybe".
                  Rectangle {
                    id: chipDot
                    visible: !chip.allDay
                    x: root.sp(4)
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.sp(7)
                    height: width
                    radius: width / 2
                    color: chip.style === "filled" ? chip.event.color : "transparent"
                    border.width: chip.style === "filled" ? 0 : 1
                    border.color: chip.event.color
                  }

                  Text {
                    id: chipTime
                    visible: !chip.allDay && monthGrid.cellWidth > root.sp(120)
                    x: chipDot.x + chipDot.width + root.sp(5)
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.formatTime(chip.event.start, root.use24Hour)
                    color: root.faintForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    renderType: Text.NativeRendering
                  }

                  Text {
                    x: chip.allDay ? root.sp(6)
                      : chipTime.visible ? chipTime.x + chipTime.implicitWidth + root.sp(5)
                      : chipDot.x + chipDot.width + root.sp(5)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x - root.sp(4)
                    elide: Text.ElideRight
                    text: chip.event.summary
                    color: chip.style === "away" ? root.faintForeground
                      : chip.style === "filled" ? root.foreground : root.dimForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    font.bold: chip.style === "filled" && chip.allDay
                    font.italic: chip.style === "away"
                    font.strikeout: chip.style === "declined"
                    renderType: Text.NativeRendering
                  }

                  HoverHandler {
                    id: chipHover
                    cursorShape: Qt.PointingHandCursor
                  }

                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.MiddleButton && chip.event.meetingUrl)
                        root.joinMeeting(chip.event)
                      else
                        root.selectEvent(chip.event)
                    }
                  }
                }
              }

              Rectangle {
                visible: monthCell.dayEvents.length > monthCell.shown
                width: moreText.implicitWidth + root.sp(10)
                height: root.monthChipHeight
                radius: root.sp(3)
                color: moreHover.hovered ? root.washStrong : "transparent"

                Text {
                  id: moreText
                  x: root.sp(5)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "+" + (monthCell.dayEvents.length - monthCell.shown) + " more"
                  color: root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                  font.bold: true
                  renderType: Text.NativeRendering
                }

                HoverHandler {
                  id: moreHover
                  cursorShape: Qt.PointingHandCursor
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.openDay(monthCell.day)
                }
              }
            }
          }
        }

        // Closing rules on the right and bottom edges.
        Rectangle {
          x: root.gutterWidth + root.monthColumns * monthGrid.cellWidth - 1
          width: 1
          height: root.monthRows * monthGrid.cellHeight
          color: root.hairline
        }
        Rectangle {
          x: root.gutterWidth
          y: root.monthRows * monthGrid.cellHeight - 1
          width: parent.width - root.gutterWidth
          height: 1
          color: root.hairline
        }
      }

      // ------------------------------------------------------------ footer
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.footerHeight

        readonly property bool problem: root.needsAuth || root.syncError.length > 0 ||
          root.syncMessage.length > 0

        Row {
          id: footerStatus
          anchors.left: parent.left
          anchors.leftMargin: root.sp(2)
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - footerKeys.implicitWidth - root.sp(20)
          spacing: root.sp(7)

          // Green-ish when the data is fresh, the alarm colour when it is not.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: root.sp(6)
            height: width
            radius: width / 2
            color: footer.problem ? root.accent
              : root.syncing ? root.dimForeground : Color.accent
            opacity: root.syncing ? 0.5 : 1
            Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - root.sp(13)
            elide: Text.ElideRight
            text: {
              if (root.needsAuth) return "Not connected to Google — click to set up"
              if (root.syncError.length > 0) return root.syncError
              if (root.syncMessage.length > 0) return root.syncMessage
              if (root.syncing && !root.everSynced) return "Syncing for the first time…"
              if (!root.everSynced) return "Waiting for the first sync…"
              return Model.syncAgeLabel(root.cache.syncedAt, root.nowMs) + "  ·  " +
                     root.calendars.length +
                     (root.calendars.length === 1 ? " calendar" : " calendars")
            }
            color: footer.problem ? root.accent : root.faintForeground
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            renderType: Text.NativeRendering

            MouseArea {
              anchors.fill: parent
              enabled: root.needsAuth
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runAuth()
            }
          }
        }

        // The keys that work right now: the grid's, or the open card's.
        Row {
          id: footerKeys
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(12)

          Repeater {
            model: root.selectedEvent
              ? (root.selectedEvent.meetingUrl
                  ? [{ keys: ["↵"], label: "join" }, { keys: ["c"], label: "copy link" },
                     { keys: ["e"], label: "edit" }, { keys: ["del"], label: "delete" },
                     { keys: ["esc"], label: "back" }]
                  : [{ keys: ["↵"], label: "open in Google" }, { keys: ["e"], label: "edit" },
                     { keys: ["del"], label: "delete" }, { keys: ["esc"], label: "back" }])
              : [{ keys: ["n"], label: "new meeting" }, { keys: ["d", "3", "w", "m"], label: "view" }, { keys: ["t"], label: "today" },
                 { keys: ["r"], label: "sync" }, { keys: ["v"], label: "vacation" }]

            Row {
              required property var modelData
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(3)

              Repeater {
                model: parent.modelData.keys

                Rectangle {
                  required property string modelData
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(height, keyText.implicitWidth + root.sp(7))
                  height: keyText.implicitHeight + root.sp(1)
                  radius: root.sp(3)
                  color: root.wash
                  border.width: 1
                  border.color: root.hairline

                  Text {
                    id: keyText
                    anchors.centerIn: parent
                    text: parent.modelData
                    color: root.dimForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption - 1
                    renderType: Text.NativeRendering
                  }
                }
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: root.sp(2)
                text: parent.modelData.label
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }
            }
          }
        }
      }

      // -------------------------------------------------- the event detail
      //
      // Drawn over the grid rather than in a second popup window: the grid
      // stays where it was, and Escape steps back to it.
      Loader {
        anchors.fill: parent
        active: root.selectedEvent !== null
        z: 20
        sourceComponent: eventDetail
      }

      // ---------------------------------------------------- a new meeting
      Loader {
        anchors.fill: parent
        active: root.composerOpen
        z: 21
        sourceComponent: composerCard
      }

      // ------------------------------------------------ going on vacation
      Loader {
        anchors.fill: parent
        active: root.vacationDialogOpen
        z: 22
        sourceComponent: vacationDialog
      }

      // ------------------------------------------------------- the beach
      //
      // Covers the grid entirely while away. It is loaded only while the
      // popup is open, so nothing animates behind a closed panel.
      Loader {
        anchors.fill: parent
        active: root.vacationActive && root.opened
        z: 30
        sourceComponent: beachScene
      }
    }
  }

  Component {
    id: beachScene

    Item {
      // The beach is opaque: the header and grid under it are not part of
      // the holiday.
      Rectangle {
        anchors.fill: parent
        color: Color.popups.background
        radius: Style.cornerRadius
      }

      // Swallows clicks so nothing reaches the grid underneath.
      MouseArea {
        anchors.fill: parent
      }

      Beach {
        anchors.fill: parent
        host: root
      }
    }
  }

  Component {
    id: vacationDialog

    Item {
      readonly property var presets: Model.vacationPresets(root.nowMs, root.use24Hour)

      // Where the typed date lands, or NaN while it does not parse.
      property double customUntil: NaN
      readonly property bool customValid: !isNaN(customUntil) && customUntil > root.nowMs

      function parseCustom(text) {
        customUntil = Model.parseDateTimeInput(text)
      }

      MouseArea {
        anchors.fill: parent
        onClicked: root.closeVacationDialog()
      }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                       Color.popups.background.b, 0.88)
      }

      Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - root.sp(24), root.sp(380))
        height: Math.min(parent.height - root.sp(16),
                         vacationColumn.implicitHeight + root.sp(28))
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(4)
        color: Color.popups.background
        border.width: 1
        border.color: root.strongHairline

        MouseArea {
          anchors.fill: parent
        }

        Button {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: root.sp(6)
          z: 2
          iconText: "󰅖"  // nf-md-close
          tooltipText: "Close (Esc)"
          foreground: root.faintForeground
          accent: root.accent
          fontFamily: root.fontFamily
          iconSize: root.fontBodySmall
          verticalPadding: root.sp(2)
          horizontalPadding: root.sp(4)
          onClicked: root.closeVacationDialog()
        }

        Column {
          id: vacationColumn
          anchors.fill: parent
          anchors.margins: root.sp(14)
          spacing: root.sp(10)

          Text {
            width: parent.width - root.sp(22)
            text: "󱁕  Vacation mode"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.fontHeading
            font.bold: true
            renderType: Text.NativeRendering
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.vacationActive
              ? "You are on vacation — choose a new end."
              : "A palm tree takes the meeting's place in the bar, and meetings start without a toast. Click the palm for the beach."
            color: root.dimForeground
            font.family: root.fontFamily
            font.pixelSize: root.fontBodySmall
            lineHeight: 1.2
            renderType: Text.NativeRendering
          }

          Text {
            text: "COMING BACK"
            color: root.faintForeground
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            font.letterSpacing: 0.6
            renderType: Text.NativeRendering
          }

          Column {
            width: parent.width
            spacing: root.sp(3)

            Repeater {
              model: presets

              Button {
                required property var modelData
                width: parent.width
                text: modelData.label + "   — " + modelData.detail
                iconText: modelData.until > 0 ? "󰃰" : "󰐿"  // calendar_clock / hand
                leftAlign: true
                bordered: true
                selected: root.vacationActive && root.vacationUntil === modelData.until
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                verticalPadding: root.sp(4)
                onClicked: root.startVacation(modelData.until)
              }
            }
          }

          Text {
            text: "OR A DATE OF YOUR OWN"
            color: root.faintForeground
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            font.letterSpacing: 0.6
            renderType: Text.NativeRendering
          }

          Row {
            width: parent.width
            spacing: root.sp(6)

            TextField {
              id: untilField
              width: parent.width - startButton.width - root.sp(6)
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: Model.formatDateTimeInput(
                Model.addDays(root.todayMs, 7) + 8 * 3600000)
              text: root.vacationActive && root.vacationUntil > 0
                ? Model.formatDateTimeInput(root.vacationUntil) : ""
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontBodySmall
              verticalPadding: root.sp(4)
              onTextChanged: parseCustom(text)
              onActiveFocusChanged: root.vacationFieldFocused = activeFocus
              onAccepted: if (customValid) root.startVacation(customUntil)
              // The catcher is blocked while typing, so Escape is handled here.
              Keys.onEscapePressed: root.closeVacationDialog()
              Component.onCompleted: parseCustom(text)
            }

            Button {
              id: startButton
              anchors.verticalCenter: parent.verticalCenter
              text: root.vacationActive ? "Save" : "Start"
              bordered: true
              enabled: customValid
              opacity: customValid ? 1 : 0.4
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.fontBodySmall
              onClicked: if (customValid) root.startVacation(customUntil)
            }
          }

          Text {
            width: parent.width
            visible: untilField.text.length > 0 && !customValid
            text: isNaN(customUntil)
              ? "Use YYYY-MM-DD HH:MM or DD/MM/YYYY HH:MM, e.g. 2026-12-24 08:00"
              : "That is already in the past"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: root.fontCaption
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  Component {
    id: composerCard

    Item {
      id: composer

      readonly property var editing: root.composerEdit
      readonly property bool isEdit: !!editing
      property var guests: []          // [{ email, label }]
      property int duration: 60        // minutes
      property bool withMeet: true
      // Google's sendUpdates: email the guests about this, or change quietly.
      property bool notify: true
      // A recurring event: this occurrence, or the whole series.
      property string scope: "instance"
      property int highlight: 0
      property double startMs: root.composerStart
      property bool startValid: true
      readonly property double endMs: startMs + duration * 60000
      readonly property bool startsNow: startValid && startMs - root.nowMs <= 5 * 60000
      readonly property var suggestions: {
        var exclude = guests.map(function(g) { return g.email })
        return Model.searchPeople(root.people, guestField.text, exclude, 4)
      }
      readonly property bool typedEmail: Model.isEmail(guestField.text)
      readonly property bool canSubmit: startValid && !root.composerBusy

      function addGuest(person) {
        if (!person) return
        var email = String(person.email || "").toLowerCase()
        for (var i = 0; i < guests.length; i++) if (guests[i].email === email) return
        guests = guests.concat([{ email: email, label: person.label || Model.attendeeName(person) }])
        guestField.text = ""
        highlight = 0
      }

      function removeGuest(email) {
        guests = guests.filter(function(g) { return g.email !== email })
      }

      // Enter in the guest field: the highlighted match, else what was typed
      // when it is an address.
      function acceptGuest() {
        if (suggestions.length > 0) addGuest(suggestions[Math.min(highlight, suggestions.length - 1)])
        else if (typedEmail) addGuest({ email: guestField.text.trim(), label: guestField.text.trim() })
      }

      function submit() {
        if (!canSubmit) return
        if (isEdit) {
          root.runEventAction({
            action: "update", calendarId: editing.calendarId, eventId: editing.id,
            recurringEventId: editing.recurringEventId || "", scope: scope,
            summary: titleField.text.trim(), start: startMs, end: endMs,
            attendees: guests.map(function(g) { return g.email }),
            notify: notify
          })
          return
        }
        root.createMeeting({
          notify: notify,
          summary: titleField.text.trim(),
          start: startMs,
          end: endMs,
          attendees: guests.map(function(g) { return g.email }),
          meet: withMeet,
          description: notesField.text.trim()
        })
      }

      function setStart(ms) {
        startMs = ms
        startValid = true
        whenField.text = Model.formatDateTimeInput(ms)
      }

      // Every field shares the same exits: Escape backs out, Ctrl+Enter sends.
      function fieldKeys(event) {
        if (event.key === Qt.Key_Escape) { root.closeComposer(); event.accepted = true }
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) &&
                 (event.modifiers & Qt.ControlModifier)) { submit(); event.accepted = true }
      }

      property real reveal: 0
      Component.onCompleted: {
        reveal = 1
        if (isEdit) {
          titleField.text = editing.summary || ""
          duration = Math.max(5, Math.round((editing.end - editing.start) / 60000))
          guests = Model.editableGuests(editing).map(function(g) {
            return { email: g.email, label: root.nameFor(g) }
          })
          withMeet = false
        }
        whenField.text = Model.formatDateTimeInput(startMs)
        if (root.composerFocusGuests) guestField.forceActiveFocus()
        else titleField.forceActiveFocus()
      }
      Behavior on reveal {
        enabled: !Style.reduceMotion
        NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
      }

      MouseArea {
        anchors.fill: parent
        onClicked: root.closeComposer()
      }

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                       Color.popups.background.b, 0.78)
        opacity: composer.reveal
      }

      Rectangle {
        id: composeCard
        // Pinned to the top so it only ever grows downward: a guest chip
        // that wraps adds a line below, it never moves the title.
        anchors.top: parent.top
        anchors.topMargin: root.sp(14) + (1 - composer.reveal) * root.sp(8)
        anchors.horizontalCenter: parent.horizontalCenter
        opacity: composer.reveal
        width: Math.min(parent.width - root.sp(32), root.sp(480))
        // Tall enough, always, for the guest matches to float over: the
        // card never grows when they appear, and they are never cut off.
        readonly property real dropdownRoom: guestBox.y + guestBox.height + root.sp(4) +
          4 * root.sp(33) + root.sp(12)
        height: Math.min(parent.height - root.sp(28),
                         Math.max(composeColumn.implicitHeight, dropdownRoom) + root.sp(36))
        radius: Style.cornerRadius > 0 ? Style.cornerRadius + root.sp(2) : root.sp(6)
        color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1)
        border.width: 1
        border.color: root.strongHairline

        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 0.55)
          shadowBlur: 0.9
          shadowVerticalOffset: root.sp(6)
        }

        MouseArea { anchors.fill: parent }

        Button {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: root.sp(8)
          z: 2
          iconText: "󰅖"  // nf-md-close
          tooltipText: "Close (Esc)"
          foreground: root.faintForeground
          accent: root.accent
          fontFamily: root.fontFamily
          iconSize: root.fontBodySmall
          verticalPadding: root.sp(3)
          horizontalPadding: root.sp(5)
          onClicked: root.closeComposer()
        }

        Flickable {
          id: composeFlick
          anchors.fill: parent
          anchors.margins: root.sp(18)
          contentWidth: width
          contentHeight: composeColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: composeColumn
            width: parent.width
            spacing: root.sp(12)

            Text {
              text: composer.isEdit ? "Edit event" : "New meeting"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fontHeading
              font.bold: true
              renderType: Text.NativeRendering
            }

            // Not allowed to write yet: say so first, with the one fix.
            Rectangle {
              visible: root.composerNeedsScope
              width: parent.width
              height: scopeColumn.implicitHeight + root.sp(20)
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(5)
              color: Qt.rgba(root.yellowTone.r, root.yellowTone.g, root.yellowTone.b, 0.10)
              border.width: 1
              border.color: Qt.rgba(root.yellowTone.r, root.yellowTone.g, root.yellowTone.b, 0.45)

              Column {
                id: scopeColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: root.sp(12)
                spacing: root.sp(8)

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "The calendar is connected read-only. Reconnect once to let it create meetings and send invitations — the same Google sign-in, one more permission."
                  color: root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                  lineHeight: 1.2
                  renderType: Text.NativeRendering
                }

                Button {
                  text: "Reconnect Google"
                  iconText: "󰌆"  // nf-md-key
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontCaption
                  verticalPadding: root.sp(4)
                  horizontalPadding: root.sp(9)
                  onClicked: root.runAuth()
                }
              }
            }

            TextField {
              id: titleField
              width: parent.width
              placeholderText: "Title"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontBody
              font.bold: true
              verticalPadding: root.sp(6)
              Keys.onPressed: function(event) {
                composer.fieldKeys(event)
                if (!event.accepted && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                  guestField.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            // ---- when, and for how long
            Column {
              width: parent.width
              spacing: root.sp(6)

              // A recurring event chooses first what the change is for.
              Rectangle {
                visible: composer.isEdit && composer.editing.recurring === true
                width: scopeRow.implicitWidth + root.sp(4)
                height: scopeRow.implicitHeight + root.sp(4)
                radius: Style.cornerRadius > 0 ? Style.cornerRadius + root.sp(2) : root.sp(5)
                color: root.wash
                border.width: 1
                border.color: root.hairline

                Row {
                  id: scopeRow
                  anchors.centerIn: parent

                  Repeater {
                    model: [{ id: "instance", label: "This event" }, { id: "series", label: "All events in the series" }]

                    Rectangle {
                      required property var modelData
                      readonly property bool current: composer.scope === modelData.id
                      width: scopeText.implicitWidth + root.sp(16)
                      height: scopeText.implicitHeight + root.sp(7)
                      radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(4)
                      color: current ? root.surface : scopeMouse.containsMouse ? root.wash : "transparent"
                      border.width: current ? 1 : 0
                      border.color: root.strongHairline

                      Text {
                        id: scopeText
                        anchors.centerIn: parent
                        text: parent.modelData.label
                        color: parent.current ? root.foreground : root.dimForeground
                        font.family: root.fontFamily
                        font.pixelSize: root.fontCaption
                        font.bold: parent.current
                        renderType: Text.NativeRendering
                      }

                      MouseArea {
                        id: scopeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: composer.scope = parent.modelData.id
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: root.sp(6)
                // The series keeps its own times; only this event can move.
                enabled: composer.scope !== "series"
                opacity: enabled ? 1 : 0.4

                TextField {
                  id: whenField
                  width: root.sp(150)
                  anchors.verticalCenter: parent.verticalCenter
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBodySmall
                  verticalPadding: root.sp(4)
                  onTextChanged: {
                    var ms = Model.parseDateTimeInput(text)
                    composer.startValid = !isNaN(ms)
                    if (composer.startValid) composer.startMs = ms
                  }
                  Keys.onPressed: function(event) { composer.fieldKeys(event) }
                }

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Now"
                  tooltipText: "Start right away"
                  selected: composer.startsNow
                  bordered: true
                  foreground: root.dimForeground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontCaption
                  verticalPadding: root.sp(4)
                  horizontalPadding: root.sp(8)
                  onClicked: {
                    var d = new Date()
                    d.setSeconds(0, 0)
                    composer.setStart(d.getTime())
                  }
                }

                Item { width: root.sp(2); height: 1 }

                // Duration as a segmented control, the same as the views.
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: durationRow.implicitWidth + root.sp(4)
                  height: durationRow.implicitHeight + root.sp(4)
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius + root.sp(2) : root.sp(5)
                  color: root.wash
                  border.width: 1
                  border.color: root.hairline

                  Row {
                    id: durationRow
                    anchors.centerIn: parent

                    Repeater {
                      model: [15, 30, 45, 60, 90].indexOf(composer.duration) >= 0
                        ? [15, 30, 45, 60, 90] : [15, 30, 45, 60, 90, composer.duration]

                      Rectangle {
                        required property int modelData
                        readonly property bool current: composer.duration === modelData
                        width: durText.implicitWidth + root.sp(12)
                        height: durText.implicitHeight + root.sp(7)
                        radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(4)
                        color: current ? root.surface : durMouse.containsMouse ? root.wash : "transparent"
                        border.width: current ? 1 : 0
                        border.color: root.strongHairline

                        Text {
                          id: durText
                          anchors.centerIn: parent
                          text: Model.shortDuration(parent.modelData)
                          color: parent.current ? root.foreground : root.dimForeground
                          font.family: root.fontFamily
                          font.pixelSize: root.fontCaption
                          font.bold: parent.current
                          renderType: Text.NativeRendering
                        }

                        MouseArea {
                          id: durMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: composer.duration = parent.modelData
                        }
                      }
                    }
                  }
                }
              }

              Text {
                text: composer.scope === "series"
                  ? "The series keeps its times — title and guests change for every event"
                  : composer.startValid
                  ? Model.composeSummary(composer.startMs, composer.endMs, root.use24Hour) +
                    (composer.startsNow && !composer.isEdit ? "  ·  starts now" : "")
                  : "Use YYYY-MM-DD HH:MM or DD/MM/YYYY HH:MM"
                color: composer.startValid ? root.faintForeground : root.accent
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }
            }

            // ---- who
            //
            // Guests live inside the field as tokens, and matches float over
            // what is below: typing and adding people never shifts the card.
            Item {
              id: guestBox
              width: parent.width
              height: guestFrame.height
              z: 10

              Rectangle {
                id: guestFrame
                width: parent.width
                height: guestFlow.implicitHeight + root.sp(10)
                radius: Style.cornerRadius
                color: guestField.activeFocus ? root.washStrong : root.wash
                border.width: 1
                border.color: guestField.activeFocus
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
                  : root.strongHairline
                Behavior on color { ColorAnimation { duration: Style.duration(110) } }
                Behavior on height {
                  enabled: !Style.reduceMotion
                  NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.IBeamCursor
                  onClicked: guestField.forceActiveFocus()
                }

                Flow {
                  id: guestFlow
                  x: root.sp(6)
                  y: root.sp(5)
                  width: parent.width - root.sp(12)
                  spacing: root.sp(4)

                  Repeater {
                    model: composer.guests

                    Rectangle {
                      id: guestChip
                      required property var modelData
                      width: guestChipRow.implicitWidth + root.sp(10)
                      height: root.sp(24)
                      radius: height / 2
                      color: root.washStrong
                      border.width: 1
                      border.color: root.hairline

                      // Settles in rather than appearing: the one bit of
                      // motion that says "added".
                      scale: 0.85
                      opacity: 0
                      Component.onCompleted: { scale = 1; opacity = 1 }
                      Behavior on scale {
                        enabled: !Style.reduceMotion
                        NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutBack; easing.overshoot: 1.6 }
                      }
                      Behavior on opacity {
                        enabled: !Style.reduceMotion
                        NumberAnimation { duration: Style.duration(120) }
                      }

                      Row {
                        id: guestChipRow
                        anchors.left: parent.left
                        anchors.leftMargin: root.sp(3)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: root.sp(6)

                        Avatar {
                          anchors.verticalCenter: parent.verticalCenter
                          size: root.sp(18)
                          email: guestChip.modelData.email
                          label: guestChip.modelData.label
                          photo: root.photoFor(guestChip.modelData.email)
                          fill: root.wash
                          ink: root.dimForeground
                          family: root.fontFamily
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: guestChip.modelData.label
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: root.fontCaption
                          renderType: Text.NativeRendering
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: "󰅖"
                          color: removeMouse.containsMouse ? root.foreground : root.faintForeground
                          font.family: root.fontFamily
                          font.pixelSize: root.fontCaption
                          renderType: Text.NativeRendering

                          MouseArea {
                            id: removeMouse
                            anchors.fill: parent
                            anchors.margins: -root.sp(3)
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: composer.removeGuest(guestChip.modelData.email)
                          }
                        }
                      }
                    }
                  }

                  // The text input rides at the end of the tokens; it keeps a
                  // usable minimum and takes the rest of the line.
                  Item {
                    id: guestInputSlot
                    width: guestFlow.width - guestFlow.chipsLineEnd >= root.sp(96)
                      ? guestFlow.width - guestFlow.chipsLineEnd : guestFlow.width
                    height: root.sp(24)

                    TextInput {
                      id: guestField
                      anchors.left: parent.left
                      anchors.leftMargin: root.sp(4)
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.foreground
                      selectionColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
                      selectedTextColor: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontBodySmall
                      clip: true
                      onTextChanged: composer.highlight = 0
                      Keys.onPressed: function(event) {
                        composer.fieldKeys(event)
                        if (event.accepted) return
                        if (event.key === Qt.Key_Down) {
                          composer.highlight = Math.min(composer.highlight + 1, Math.max(0, composer.suggestions.length - 1))
                          event.accepted = true
                        } else if (event.key === Qt.Key_Up) {
                          composer.highlight = Math.max(0, composer.highlight - 1)
                          event.accepted = true
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
                          if (text.length > 0) { composer.acceptGuest(); event.accepted = true }
                        } else if (event.key === Qt.Key_Backspace && text.length === 0 && composer.guests.length > 0) {
                          composer.removeGuest(composer.guests[composer.guests.length - 1].email)
                          event.accepted = true
                        }
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: guestField.text.length === 0
                        text: composer.guests.length > 0 ? "Add more people" : "Invite people — name or email"
                        color: root.faintForeground
                        font: guestField.font
                        renderType: Text.NativeRendering
                      }
                    }
                  }

                  // Where the chips end on their last line, worked out from
                  // their widths alone (not from the input's own position, which
                  // would loop), so the input takes what is left of that line.
                  readonly property real chipsLineEnd: {
                    var x = 0
                    for (var i = 0; i < children.length; i++) {
                      var child = children[i]
                      if (child === guestInputSlot || child.width === 0) continue
                      if (x > 0 && x + child.width > width) x = 0
                      x += child.width + spacing
                    }
                    return x
                  }
                }
              }

              // Matches, floating over the fields below. Your own calendar's
              // people first, then the rest of the organisation.
              Rectangle {
                id: dropdown
                visible: guestField.activeFocus && guestField.text.length > 0
                y: guestFrame.height + root.sp(4)
                width: parent.width
                height: dropdownColumn.implicitHeight + root.sp(8)
                radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(5)
                color: Qt.tint(Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1),
                               Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05))
                border.width: 1
                border.color: root.strongHairline

                Column {
                  id: dropdownColumn
                  x: root.sp(4)
                  y: root.sp(4)
                  width: parent.width - root.sp(8)
                  spacing: root.sp(1)

                  Repeater {
                    model: composer.suggestions

                    Rectangle {
                      id: suggestion
                      required property var modelData
                      required property int index
                      readonly property bool current: index === composer.highlight
                      width: parent.width
                      height: root.sp(32)
                      radius: root.sp(4)
                      color: current || suggestionMouse.containsMouse ? root.washStrong : "transparent"

                      Avatar {
                        id: suggestionAvatar
                        x: root.sp(6)
                        anchors.verticalCenter: parent.verticalCenter
                        size: root.sp(22)
                        email: suggestion.modelData.email
                        label: suggestion.modelData.label
                        photo: suggestion.modelData.photo || root.photoFor(suggestion.modelData.email)
                        fill: root.wash
                        ink: root.dimForeground
                        family: root.fontFamily
                      }

                      Text {
                        id: suggestionName
                        x: suggestionAvatar.x + suggestionAvatar.width + root.sp(9)
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.StyledText
                        text: Model.highlightMatch(suggestion.modelData.label, guestField.text)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: root.fontBodySmall
                        renderType: Text.NativeRendering
                      }

                      Text {
                        x: suggestionName.x + suggestionName.implicitWidth + root.sp(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x - (enterHint.visible ? enterHint.width + root.sp(12) : root.sp(8))
                        elide: Text.ElideRight
                        text: suggestion.modelData.email
                        color: root.faintForeground
                        font.family: root.fontFamily
                        font.pixelSize: root.fontCaption
                        renderType: Text.NativeRendering
                      }

                      Text {
                        id: enterHint
                        visible: suggestion.current
                        anchors.right: parent.right
                        anchors.rightMargin: root.sp(8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "↵"
                        color: root.faintForeground
                        font.family: root.fontFamily
                        font.pixelSize: root.fontCaption
                        renderType: Text.NativeRendering
                      }

                      MouseArea {
                        id: suggestionMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: composer.highlight = suggestion.index
                        onClicked: {
                          // Focus first: adding rebuilds this very row.
                          guestField.forceActiveFocus()
                          composer.addGuest(suggestion.modelData)
                        }
                      }
                    }
                  }

                  Text {
                    visible: composer.suggestions.length === 0
                    height: root.sp(28)
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: root.sp(8)
                    text: composer.typedEmail ? "↵  invite " + guestField.text.trim()
                      : "No one matches — type the full address"
                    color: composer.typedEmail ? root.dimForeground : root.faintForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    renderType: Text.NativeRendering
                  }
                }
              }
            }

            TextField {
              id: notesField
              visible: !composer.isEdit
              width: parent.width
              placeholderText: "Description (optional)"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontBodySmall
              verticalPadding: root.sp(5)
              Keys.onPressed: function(event) {
                composer.fieldKeys(event)
                if (!event.accepted && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                  composer.submit()
                  event.accepted = true
                }
              }
            }

            Row {
              spacing: root.sp(6)

              Button {
                visible: !composer.isEdit
                text: composer.withMeet ? "Google Meet link added" : "No video call"
                iconText: composer.withMeet ? "󰕧" : "󰕨"  // video / video_off
                tooltipText: "Toggle the Meet link"
                selected: composer.withMeet
                foreground: composer.withMeet ? root.foreground : root.dimForeground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                iconSize: root.fontBodySmall
                verticalPadding: root.sp(4)
                horizontalPadding: root.sp(8)
                onClicked: composer.withMeet = !composer.withMeet
              }

              // Whether Google emails the guests — invitations, or the update.
              Button {
                visible: composer.guests.length > 0 ||
                  (composer.isEdit && Model.editableGuests(composer.editing).length > 0)
                text: composer.notify ? "Email guests" : "Don't email guests"
                iconText: composer.notify ? "󰇮" : "󰇯"  // email / email_off
                tooltipText: composer.notify
                  ? "Google sends the invitation or update to every guest"
                  : "The calendar changes, nobody gets an email"
                selected: composer.notify
                foreground: composer.notify ? root.foreground : root.dimForeground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                iconSize: root.fontBodySmall
                verticalPadding: root.sp(4)
                horizontalPadding: root.sp(8)
                onClicked: composer.notify = !composer.notify
              }
            }

            Text {
              width: parent.width
              visible: root.composerError.length > 0 && !root.composerNeedsScope
              wrapMode: Text.Wrap
              text: root.composerError
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              renderType: Text.NativeRendering
            }

            // ---- send
            Rectangle {
              id: createButton
              readonly property bool hot: createMouse.containsMouse && composer.canSubmit
              readonly property color base: composer.canSubmit
                ? Qt.tint(Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1),
                          Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5))
                : root.wash
              width: parent.width
              height: createLabel.implicitHeight + root.sp(16)
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(5)
              color: createMouse.pressed ? Qt.darker(base, 1.1) : hot ? Qt.lighter(base, 1.12) : base
              border.width: 1
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, hot ? 0.35 : 0.18)
              opacity: composer.canSubmit ? 1 : 0.6
              Behavior on color { ColorAnimation { duration: Style.duration(110) } }

              Row {
                anchors.centerIn: parent
                spacing: root.sp(9)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.composerBusy ? "󰔟" : composer.isEdit ? "󰄬"
                    : composer.startsNow ? "󰕧" : "󰃭"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontIcon
                  renderType: Text.NativeRendering
                }

                Text {
                  id: createLabel
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.composerBusy ? (composer.isEdit ? "Saving…" : "Creating…")
                    : composer.isEdit ? (composer.notify && composer.guests.length > 0 ? "Save & email guests" : "Save")
                    : (composer.startsNow ? "Start now" : "Create") +
                      (composer.guests.length > 0
                        ? (composer.notify ? " & invite " : " with ") + composer.guests.length +
                          (composer.guests.length === 1 ? " person" : " people")
                        : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontBody
                  font.bold: true
                  renderType: Text.NativeRendering
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "ctrl ↵"
                  color: root.faintForeground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                  renderType: Text.NativeRendering
                }
              }

              MouseArea {
                id: createMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: composer.canSubmit ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: composer.submit()
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: eventDetail

    Item {
      id: detail
      readonly property var event: root.selectedEvent
      readonly property bool canEdit: Model.canEdit(event)
      // Guests marked for removal, waiting for Save.
      property var removing: []
      property string removalScope: "instance"

      function toggleRemoval(email) {
        removing = removing.indexOf(email) >= 0
          ? removing.filter(function(e) { return e !== email })
          : removing.concat([email])
      }

      function saveRemovals(notify) {
        if (!event || removing.length === 0) return
        var keep = Model.editableGuests(event)
          .map(function(g) { return g.email })
          .filter(function(e) { return removing.indexOf(e) < 0 })
        root.runEventAction({
          action: "update", calendarId: event.calendarId, eventId: event.id,
          recurringEventId: event.recurringEventId || "", scope: removalScope,
          attendees: keep, notify: notify, summary: event.summary
        })
      }
      readonly property bool hasCall: !!(event && event.meetingUrl)
      readonly property var status: Model.eventStatus(event, root.nowMs, root.use24Hour)
      readonly property bool urgent: status.kind === "soon" || status.kind === "running"

      // Arrives rather than appears: the scrim settles and the card rises a
      // few pixels into place. Instant under reduced motion.
      property real reveal: 0
      Component.onCompleted: reveal = 1
      Behavior on reveal {
        enabled: !Style.reduceMotion
        NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
      }

      // Catches the click that dismisses, and stops it reaching the grid.
      MouseArea {
        anchors.fill: parent
        onClicked: root.clearSelection()
      }

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                       Color.popups.background.b, 0.78)
        opacity: detail.reveal
      }

      Rectangle {
        id: card
        // Pinned to the top: marking a guest or opening the delete step
        // grows the card downward, never shifts what you were looking at.
        anchors.top: parent.top
        anchors.topMargin: root.sp(14) + (1 - detail.reveal) * root.sp(8)
        anchors.horizontalCenter: parent.horizontalCenter
        opacity: detail.reveal
        width: Math.min(parent.width - root.sp(32), root.sp(440))
        height: Math.min(parent.height - root.sp(24),
                         detailColumn.implicitHeight + root.sp(36))
        radius: Style.cornerRadius > 0 ? Style.cornerRadius + root.sp(2) : root.sp(6)
        color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1)
        border.width: 1
        border.color: root.strongHairline

        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: Qt.rgba(0, 0, 0, 0.55)
          shadowBlur: 0.9
          shadowVerticalOffset: root.sp(6)
          shadowHorizontalOffset: 0
        }

        // Swallows clicks so they do not fall through to the dismiss layer.
        MouseArea {
          anchors.fill: parent
        }

        Button {
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: root.sp(8)
          z: 2
          iconText: "󰅖"  // nf-md-close
          tooltipText: "Close (Esc)"
          foreground: root.faintForeground
          accent: root.accent
          fontFamily: root.fontFamily
          iconSize: root.fontBodySmall
          verticalPadding: root.sp(3)
          horizontalPadding: root.sp(5)
          onClicked: root.clearSelection()
        }

        Flickable {
          anchors.fill: parent
          anchors.margins: root.sp(18)
          contentWidth: width
          contentHeight: detailColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: detailColumn
            width: parent.width
            spacing: root.sp(12)

            // ---- the calendar it lives in
            Row {
              width: parent.width - root.sp(28)
              spacing: root.sp(8)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: root.sp(9)
                height: root.sp(9)
                radius: root.sp(2)
                color: detail.event ? detail.event.color : root.accent
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - root.sp(17)
                elide: Text.ElideRight
                text: detail.event ? detail.event.calendar : ""
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }
            }

            // ---- what and when
            Column {
              width: parent.width
              spacing: root.sp(5)

              Text {
                width: parent.width - root.sp(20)
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                text: detail.event ? detail.event.summary : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fs(Style.font.heading * 1.15)
                font.bold: true
                font.strikeout: detail.event && detail.event.response === "declined"
                lineHeight: 1.1
                renderType: Text.NativeRendering
              }

              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: detail.event ? (Model.longWeekday(detail.event.start) + ", " +
                  Model.monthName(detail.event.start) + " " + new Date(detail.event.start).getDate() +
                  "  ·  " + Model.formatRange(detail.event, root.use24Hour)) : ""
                color: root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontBodySmall
                renderType: Text.NativeRendering
              }

              // Live where it stands against the clock, plus your own answer.
              Flow {
                width: parent.width
                spacing: root.sp(6)
                topPadding: root.sp(3)

                Repeater {
                  model: {
                    var e = detail.event
                    if (!e) return []
                    var chips = []
                    if (detail.status.label !== "")
                      chips.push({ text: detail.status.label, strong: detail.urgent })
                    if (!e.allDay) chips.push({ text: Model.formatDuration(e.end - e.start), strong: false })
                    if (e.recurring) chips.push({ text: "󰑖 repeats", strong: false })
                    if (e.attendees && e.attendees.length > 0 && !Model.canRespond(e))
                      chips.push({ text: Model.responseLabel(e.response), strong: false,
                                   maybe: e.response === "tentative" || e.response === "needsAction" })
                    return chips
                  }

                  Rectangle {
                    required property var modelData
                    width: chipText.implicitWidth + root.sp(14)
                    height: chipText.implicitHeight + root.sp(5)
                    radius: height / 2
                    color: modelData.strong
                      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16) : root.wash
                    border.width: 1
                    border.color: modelData.strong
                      ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5) : root.hairline

                    Text {
                      id: chipText
                      anchors.centerIn: parent
                      text: parent.modelData.text
                      color: parent.modelData.strong ? root.accent
                        : parent.modelData.maybe ? root.dimForeground : root.dimForeground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      font.bold: parent.modelData.strong === true
                      font.italic: parent.modelData.maybe === true
                      renderType: Text.NativeRendering
                    }
                  }
                }
              }
            }

            // ---- your answer
            //
            // Yes / Maybe / No, the way Google asks it; the current answer is
            // lifted out of the track and tinted by what it means.
            Row {
              id: rsvp
              visible: Model.canRespond(detail.event) && !root.confirmingDelete
              spacing: root.sp(10)
              readonly property string current: root.pendingResponse !== ""
                ? root.pendingResponse : (detail.event ? detail.event.response : "")
              property string scope: "instance"

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: rsvp.current === "needsAction" ? "Going?" : "Your answer"
                color: rsvp.current === "needsAction" ? root.foreground : root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontBodySmall
                font.bold: rsvp.current === "needsAction"
                renderType: Text.NativeRendering
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: rsvpRow.implicitWidth + root.sp(4)
                height: rsvpRow.implicitHeight + root.sp(4)
                radius: Style.cornerRadius > 0 ? Style.cornerRadius + root.sp(2) : root.sp(5)
                color: root.wash
                border.width: 1
                border.color: root.hairline

                Row {
                  id: rsvpRow
                  anchors.centerIn: parent

                  Repeater {
                    model: [
                      { id: "accepted", label: "Yes", glyph: "󰄬" },
                      { id: "tentative", label: "Maybe", glyph: "󰘥" },
                      { id: "declined", label: "No", glyph: "󰅖" }
                    ]

                    Rectangle {
                      id: answer
                      required property var modelData
                      readonly property bool chosen: rsvp.current === modelData.id
                      readonly property color tint: modelData.id === "accepted" ? Color.accent
                        : modelData.id === "declined" ? root.accent : root.foreground
                      width: answerRow.implicitWidth + root.sp(18)
                      height: answerRow.implicitHeight + root.sp(9)
                      radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(4)
                      color: chosen
                        ? Qt.tint(Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1),
                                  Qt.rgba(tint.r, tint.g, tint.b, modelData.id === "tentative" ? 0.12 : 0.28))
                        : answerMouse.containsMouse ? root.wash : "transparent"
                      border.width: chosen ? 1 : 0
                      border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.6)
                      Behavior on color { ColorAnimation { duration: Style.duration(140) } }

                      Row {
                        id: answerRow
                        anchors.centerIn: parent
                        spacing: root.sp(5)

                        Text {
                          visible: answer.chosen
                          anchors.verticalCenter: parent.verticalCenter
                          text: answer.modelData.glyph
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: root.fontCaption
                          renderType: Text.NativeRendering
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: answer.modelData.label
                          color: answer.chosen ? root.foreground : root.dimForeground
                          font.family: root.fontFamily
                          font.pixelSize: root.fontCaption
                          font.bold: answer.chosen
                          renderType: Text.NativeRendering
                        }
                      }

                      MouseArea {
                        id: answerMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: answer.chosen ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: if (!answer.chosen)
                          root.respondTo(detail.event, answer.modelData.id, rsvp.scope)
                      }
                    }
                  }
                }
              }

              // A series answers once for every event, or just for this one.
              Button {
                visible: !!detail.event && detail.event.recurring === true
                anchors.verticalCenter: parent.verticalCenter
                text: "All events"
                tooltipText: rsvp.scope === "series"
                  ? "Answering for every event in the series"
                  : "Answering for this event only — click to answer for the whole series"
                selected: rsvp.scope === "series"
                bordered: true
                foreground: root.dimForeground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: root.fontCaption
                verticalPadding: root.sp(3)
                horizontalPadding: root.sp(8)
                onClicked: rsvp.scope = rsvp.scope === "series" ? "instance" : "series"
              }
            }

            Text {
              width: parent.width
              visible: rsvp.visible && root.detailError.length > 0 && !root.confirmingDelete
              wrapMode: Text.Wrap
              text: root.detailError
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              renderType: Text.NativeRendering
            }

            // ---- the one thing you came to do
            Column {
              width: parent.width
              spacing: root.sp(8)
              visible: !root.confirmingDelete

              Row {
                width: parent.width
                spacing: root.sp(6)

                Rectangle {
                  id: primary
                  readonly property bool hot: primaryMouse.containsMouse
                  readonly property color base: detail.hasCall
                    ? root.tone(detail.event ? detail.event.color : "#039be5", detail.urgent ? 0.95 : 0.7)
                    : root.washStrong
                  width: parent.width - (asButton.visible ? asButton.width + parent.spacing : 0)
                  height: primaryLabel.implicitHeight + root.sp(16)
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(5)
                  color: primaryMouse.pressed ? Qt.darker(base, 1.1) : hot ? Qt.lighter(base, 1.12) : base
                  border.width: 1
                  border.color: detail.hasCall
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, hot ? 0.35 : 0.18)
                    : root.strongHairline
                  scale: primaryMouse.pressed ? 0.985 : 1
                  Behavior on color { ColorAnimation { duration: Style.duration(110) } }
                  Behavior on scale { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: root.sp(14)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: root.sp(9)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: detail.hasCall ? "󰕧" : "󰏌"  // video / open_in_new
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontIcon
                      renderType: Text.NativeRendering
                    }

                    Text {
                      id: primaryLabel
                      anchors.verticalCenter: parent.verticalCenter
                      text: detail.hasCall
                        ? (detail.event.meetingProvider ? "Join " + detail.event.meetingProvider : "Join call")
                        : "Open in Google Calendar"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontBody
                      font.bold: true
                      renderType: Text.NativeRendering
                    }
                  }

                  Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: root.sp(12)
                    anchors.verticalCenter: parent.verticalCenter
                    width: enterText.implicitWidth + root.sp(10)
                    height: enterText.implicitHeight + root.sp(2)
                    radius: root.sp(3)
                    color: Qt.rgba(0, 0, 0, 0.18)
                    border.width: 1
                    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

                    Text {
                      id: enterText
                      anchors.centerIn: parent
                      text: "↵"
                      color: root.dimForeground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      renderType: Text.NativeRendering
                    }
                  }

                  MouseArea {
                    id: primaryMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.requestAction(detail.hasCall ? "join" : "open")
                  }
                }

                // Another of your accounts, one deliberate step away.
                Button {
                  id: asButton
                  visible: root.hasOtherAccounts
                  height: primary.height
                  text: "as…"
                  tooltipText: detail.hasCall ? "Join as another account" : "Open as another account"
                  bordered: true
                  selected: root.accountPickerOpen
                  foreground: root.dimForeground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontBodySmall
                  onClicked: root.chooseAccountFor(detail.hasCall ? "join" : "open")
                }
              }

              // The account picker, unfolded in place rather than in a popup of
              // its own: a second popup over the panel would take the focus
              // grab away from it and dismiss the event underneath.
              Column {
                width: parent.width
                spacing: root.sp(3)
                visible: root.accountPickerOpen

                Text {
                  text: root.pendingAction === "join" ? "Join as" : "Open as"
                  color: root.faintForeground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                  renderType: Text.NativeRendering
                }

                Repeater {
                  model: root.accountOptions

                  Button {
                    required property var modelData
                    width: parent.width
                    text: modelData.note !== ""
                      ? modelData.label + "   — " + modelData.note
                      : modelData.label
                    leftAlign: true
                    bordered: true
                    foreground: modelData.account === root.defaultAccount
                      ? root.foreground : root.dimForeground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: root.fontCaption
                    verticalPadding: root.sp(4)
                    onClicked: root.performAction(root.pendingAction, modelData.account)
                  }
                }
              }

              Item {
                width: parent.width
                // Either side alone sets the height: an event without a call
                // has no Copy link, and still has Edit and Delete.
                height: Math.max(secondaryRow.implicitHeight, editRow.implicitHeight)

                Row {
                  id: secondaryRow
                  spacing: root.sp(4)

                  Button {
                    visible: detail.hasCall
                    text: "Copy link"
                    iconText: "󰆏"  // nf-md-content_copy
                    tooltipText: detail.hasCall ? Model.displayUrl(detail.event.meetingUrl) + "  (c)" : ""
                    foreground: root.dimForeground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: root.fontCaption
                    iconSize: root.fontBodySmall
                    verticalPadding: root.sp(3)
                    horizontalPadding: root.sp(7)
                    onClicked: {
                      root.copyMeetingFor(detail.event)
                      root.close()
                    }
                  }

                  Button {
                    visible: detail.hasCall
                    text: "Open in Google"
                    iconText: "󰏌"  // nf-md-open_in_new
                    tooltipText: "The event in Google Calendar (o)"
                    foreground: root.dimForeground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: root.fontCaption
                    iconSize: root.fontBodySmall
                    verticalPadding: root.sp(3)
                    horizontalPadding: root.sp(7)
                    onClicked: root.requestAction("open")
                  }

                }

                // Changing it, on the far side from joining it.
                Row {
                  id: editRow
                  anchors.right: parent.right
                  spacing: root.sp(2)

                  Button {
                    visible: Model.canEdit(detail.event)
                    text: "Edit"
                    fontSize: root.fontCaption
                    iconText: "󰏫"  // nf-md-pencil
                    tooltipText: "Change title, time and guests (e)"
                    foreground: root.dimForeground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    iconSize: root.fontBodySmall
                    verticalPadding: root.sp(4)
                    horizontalPadding: root.sp(7)
                    onClicked: root.editEvent(detail.event)
                  }

                  Button {
                    visible: !!detail.event && !detail.event.allDay
                    text: Model.canEdit(detail.event) ? "Delete" : "Remove"
                    fontSize: root.fontCaption
                    iconText: "󰆴"  // nf-md-delete
                    tooltipText: Model.canEdit(detail.event) ? "Delete (Del)" : "Remove from my calendar (Del)"
                    foreground: root.dimForeground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    iconSize: root.fontBodySmall
                    verticalPadding: root.sp(4)
                    horizontalPadding: root.sp(7)
                    onClicked: root.confirmingDelete = true
                  }
                }
              }
            }

            // ---- deleting, asked the way Google asks
            Column {
              id: deleteConfirm
              visible: root.confirmingDelete
              width: parent.width
              spacing: root.sp(10)

              readonly property bool organizer: Model.canEdit(detail.event)
              readonly property int guestCount: detail.event ? Model.editableGuests(detail.event).length : 0
              // Only an organiser's delete reaches the guests at all.
              readonly property bool canEmail: organizer && guestCount > 0
              property string scope: "instance"

              // The confirm buttons land where Delete was; a double click must
              // not go straight through. They arm a moment after appearing.
              property bool armed: false
              onVisibleChanged: {
                armed = false
                if (visible) armTimer.restart()
              }
              Timer {
                id: armTimer
                interval: 400
                onTriggered: deleteConfirm.armed = true
              }

              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: !deleteConfirm.organizer
                  ? "Remove this event from your calendar?"
                  : deleteConfirm.canEmail
                    ? "Email a cancellation to " + deleteConfirm.guestCount +
                      (deleteConfirm.guestCount === 1 ? " guest?" : " guests?")
                    : "Delete this event?"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                font.bold: true
                renderType: Text.NativeRendering
              }

              // Recurring: this one, or the whole series.
              Row {
                visible: !!detail.event && detail.event.recurring === true
                spacing: root.sp(4)

                Repeater {
                  model: [{ id: "instance", label: "This event" }, { id: "series", label: "All events" }]

                  Button {
                    required property var modelData
                    text: modelData.label
                    selected: deleteConfirm.scope === modelData.id
                    bordered: true
                    foreground: root.dimForeground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: root.fontCaption
                    verticalPadding: root.sp(3)
                    horizontalPadding: root.sp(9)
                    onClicked: deleteConfirm.scope = modelData.id
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.detailError.length > 0
                wrapMode: Text.Wrap
                text: root.detailError
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }

              Row {
                anchors.right: parent.right
                spacing: root.sp(6)

                Button {
                  text: "Back"
                  foreground: root.dimForeground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontBodySmall
                  verticalPadding: root.sp(5)
                  horizontalPadding: root.sp(10)
                  onClicked: root.confirmingDelete = false
                }

                Button {
                  visible: deleteConfirm.canEmail
                  enabled: deleteConfirm.armed
                  opacity: deleteConfirm.armed ? 1 : 0.5
                  Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }
                  text: "Don't send"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontBodySmall
                  verticalPadding: root.sp(5)
                  horizontalPadding: root.sp(10)
                  onClicked: root.deleteEvent(detail.event, deleteConfirm.scope, false)
                }

                // The committing choice, in the alarm colour: it cannot be
                // taken back from here.
                Rectangle {
                  readonly property bool hot: confirmMouse.containsMouse && deleteConfirm.armed
                  opacity: deleteConfirm.armed ? 1 : 0.5
                  Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }
                  width: confirmText.implicitWidth + root.sp(24)
                  height: confirmText.implicitHeight + root.sp(12)
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(5)
                  color: Qt.tint(Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1),
                                 Qt.rgba(root.accent.r, root.accent.g, root.accent.b, hot ? 0.75 : 0.6))
                  border.width: 1
                  border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.9)
                  Behavior on color { ColorAnimation { duration: Style.duration(110) } }

                  Text {
                    id: confirmText
                    anchors.centerIn: parent
                    text: root.composerBusy ? "Deleting…"
                      : deleteConfirm.canEmail ? "Send & delete"
                      : deleteConfirm.organizer ? "Delete" : "Remove"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontBodySmall
                    font.bold: true
                    renderType: Text.NativeRendering
                  }

                  MouseArea {
                    id: confirmMouse
                    anchors.fill: parent
                    enabled: deleteConfirm.armed
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.deleteEvent(detail.event, deleteConfirm.scope, deleteConfirm.canEmail)
                  }
                }
              }
            }

            PanelSeparator {
              width: parent.width
              visible: detail.event && (detail.event.location !== "" ||
                                        (detail.event.attendees && detail.event.attendees.length > 0))
            }

            // ---- where
            Row {
              width: parent.width
              spacing: root.sp(9)
              visible: detail.event && detail.event.location !== ""

              Text {
                text: "󰍎"  // nf-md-map_marker
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontBodySmall
                renderType: Text.NativeRendering
              }

              Text {
                width: parent.width - root.sp(24)
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: detail.event ? detail.event.location : ""
                color: root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontBodySmall
                renderType: Text.NativeRendering
              }
            }

            // ---- guests
            //
            // Direct: hover a guest for ×, and the change waits in a bar under
            // the list until you save it — quietly, or with an email.
            Column {
              id: guestList
              width: parent.width
              spacing: root.sp(3)
              visible: detail.event && ((detail.event.attendees && detail.event.attendees.length > 0) ||
                                        detail.canEdit)

              Text {
                text: detail.event && detail.event.attendees && detail.event.attendees.length > 0
                  ? Model.attendeeSummary(detail.event.attendees) : "No guests"
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                bottomPadding: root.sp(2)
                renderType: Text.NativeRendering
              }

              Repeater {
                // Capped: a 40-person invite would push the description off
                // the card, and the count above already tells the whole story.
                model: detail.event && detail.event.attendees
                  ? detail.event.attendees.slice(0, 8) : []

                Rectangle {
                  id: guestRow
                  required property var modelData
                  readonly property string email: String(modelData.email || "").toLowerCase()
                  readonly property bool removable: detail.canEdit && !modelData.self &&
                    !modelData.organizer && modelData.resource !== true
                  readonly property bool removing: detail.removing.indexOf(email) >= 0
                  width: parent.width
                  height: root.sp(28)
                  radius: root.sp(4)
                  color: guestHover.hovered && removable ? root.wash : "transparent"

                  HoverHandler { id: guestHover }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: root.sp(2)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: root.sp(8)
                    opacity: guestRow.removing ? 0.45 : 1
                    Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

                    // Their face (or initials), with your answer as a small
                    // mark on the corner.
                    Item {
                      anchors.verticalCenter: parent.verticalCenter
                      width: root.sp(22)
                      height: root.sp(22)

                      Avatar {
                        anchors.fill: parent
                        size: root.sp(22)
                        email: guestRow.email
                        label: root.nameFor(guestRow.modelData)
                        photo: root.photoFor(guestRow.email)
                        fill: root.washStrong
                        ink: root.dimForeground
                        family: root.fontFamily
                        ring: guestRow.modelData.self === true
                        ringColor: root.dimForeground
                      }

                      Rectangle {
                        visible: guestRow.modelData.response === "accepted" ||
                                 guestRow.modelData.response === "declined"
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: -root.sp(1)
                        width: root.sp(8)
                        height: width
                        radius: width / 2
                        color: guestRow.modelData.response === "accepted" ? Color.accent : root.accent
                        border.width: root.sp(1.5)
                        border.color: Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1)
                      }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.nameFor(guestRow.modelData)
                      color: guestRow.modelData.self ? root.foreground : root.dimForeground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      font.strikeout: guestRow.removing || guestRow.modelData.response === "declined"
                      renderType: Text.NativeRendering
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: guestRow.removing || guestRow.modelData.organizer === true ||
                               guestRow.modelData.response === "tentative"
                      text: guestRow.removing ? "will be removed"
                        : guestRow.modelData.organizer ? "organizer" : "maybe"
                      color: guestRow.removing ? root.accent : root.faintForeground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      font.italic: true
                      renderType: Text.NativeRendering
                    }
                  }

                  // × to remove; on a row already marked, ↺ to keep them.
                  Rectangle {
                    visible: guestRow.removable && (guestHover.hovered || guestRow.removing)
                    anchors.right: parent.right
                    anchors.rightMargin: root.sp(4)
                    anchors.verticalCenter: parent.verticalCenter
                    width: removeLabel.implicitWidth + root.sp(14)
                    height: root.sp(22)
                    radius: height / 2
                    color: removeArea.containsMouse ? root.washStrong : "transparent"
                    border.width: 1
                    border.color: removeArea.containsMouse ? root.strongHairline : "transparent"

                    Text {
                      id: removeLabel
                      anchors.centerIn: parent
                      text: guestRow.removing ? "󰑓 Keep" : "󰅖 Remove"
                      color: removeArea.containsMouse ? root.foreground : root.dimForeground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      renderType: Text.NativeRendering
                    }

                    MouseArea {
                      id: removeArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: detail.toggleRemoval(guestRow.email)
                    }
                  }
                }
              }

              Text {
                visible: detail.event && detail.event.attendees && detail.event.attendees.length > 8
                leftPadding: root.sp(32)
                text: detail.event ? "+ " + (detail.event.attendees.length - 8) + " more" : ""
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }

              // Adding people opens the full editor on its guest field.
              Rectangle {
                visible: detail.canEdit && detail.removing.length === 0
                width: parent.width
                height: root.sp(28)
                radius: root.sp(4)
                color: addArea.containsMouse ? root.wash : "transparent"

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: root.sp(2)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: root.sp(8)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.sp(22)
                    height: width
                    radius: width / 2
                    color: "transparent"
                    border.width: 1
                    border.color: addArea.containsMouse ? root.dimForeground : root.strongHairline

                    Text {
                      anchors.centerIn: parent
                      text: "󰐕"
                      color: addArea.containsMouse ? root.foreground : root.dimForeground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      renderType: Text.NativeRendering
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add people"
                    color: addArea.containsMouse ? root.foreground : root.dimForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    renderType: Text.NativeRendering
                  }
                }

                MouseArea {
                  id: addArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.editEvent(detail.event, true)
                }
              }

              // The pending change: what it is, and how to send it.
              Rectangle {
                visible: detail.removing.length > 0
                width: parent.width
                height: pendingColumn.implicitHeight + root.sp(20)
                radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(5)
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08)
                border.width: 1
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)

                Column {
                  id: pendingColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: root.sp(10)
                  spacing: root.sp(8)

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "Remove " + detail.removing.length +
                      (detail.removing.length === 1 ? " guest" : " guests") +
                      (detail.event && detail.event.recurring
                        ? (detail.removalScope === "series" ? " from every event in the series" : " from this event only")
                        : "") + " — email them about it?"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    font.bold: true
                    renderType: Text.NativeRendering
                  }

                  Row {
                    visible: !!detail.event && detail.event.recurring === true
                    spacing: root.sp(4)

                    Repeater {
                      model: [{ id: "instance", label: "This event" }, { id: "series", label: "All events" }]

                      Button {
                        required property var modelData
                        text: modelData.label
                        selected: detail.removalScope === modelData.id
                        bordered: true
                        foreground: root.dimForeground
                        accent: root.accent
                        fontFamily: root.fontFamily
                        fontSize: root.fontCaption
                        verticalPadding: root.sp(3)
                        horizontalPadding: root.sp(9)
                        onClicked: detail.removalScope = modelData.id
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    visible: root.detailError.length > 0
                    wrapMode: Text.Wrap
                    text: root.detailError
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    renderType: Text.NativeRendering
                  }

                  Row {
                    anchors.right: parent.right
                    spacing: root.sp(6)

                    Button {
                      text: "Cancel"
                      foreground: root.dimForeground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: root.fontCaption
                      verticalPadding: root.sp(4)
                      horizontalPadding: root.sp(9)
                      onClicked: detail.removing = []
                    }

                    Button {
                      text: root.composerBusy ? "Saving…" : "Save, no email"
                      bordered: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: root.fontCaption
                      verticalPadding: root.sp(4)
                      horizontalPadding: root.sp(9)
                      onClicked: detail.saveRemovals(false)
                    }

                    Button {
                      text: root.composerBusy ? "Saving…" : "Save & email"
                      bordered: true
                      selected: true
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: root.fontCaption
                      verticalPadding: root.sp(4)
                      horizontalPadding: root.sp(9)
                      onClicked: detail.saveRemovals(true)
                    }
                  }
                }
              }
            }

            PanelSeparator {
              width: parent.width
              visible: detail.event && detail.event.description !== ""
            }

            Text {
              width: parent.width
              visible: detail.event && detail.event.description !== ""
              wrapMode: Text.Wrap
              text: detail.event ? Model.truncate(detail.event.description, 900) : ""
              color: root.dimForeground
              linkColor: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fontBodySmall
              lineHeight: 1.3
              renderType: Text.NativeRendering
              onLinkActivated: function(link) { root.openUrl(link) }
            }
          }
        }
      }
    }
  }
}
