import QtQuick
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
  readonly property int panelGridHeight: root.sp(Math.max(160, Number(setting("gridHeight", 540))))

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
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

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
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/calendar"
  property var cache: Model.parseCache("")
  readonly property var allEvents: cache.events || []
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

  readonly property var days: Model.visibleDays(root.anchorDay, root.view, root.weekStart, root.workweek)
  readonly property bool showingToday: {
    for (var i = 0; i < root.days.length; i++) if (root.days[i] === root.todayMs) return true
    return false
  }
  readonly property int todayColumn: {
    for (var i = 0; i < root.days.length; i++) if (root.days[i] === root.todayMs) return i
    return -1
  }

  // Everything the grid draws, recomputed as one pass whenever the visible
  // range or the event list moves.
  readonly property var dayModels: {
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
  readonly property var allDayLayout: Model.layoutAllDay(root.events, root.days)
  readonly property int allDayLanes: Math.min(3, root.allDayLayout.lanes)

  function step(direction) {
    var count = Model.stepFor(root.view, root.workweek)
    root.anchorDay = Model.addDays(root.anchorDay, direction * count)
    root.selectedEvent = null
  }

  function goToday() {
    root.anchorDay = Model.startOfDay(Date.now())
    root.selectedEvent = null
    Qt.callLater(root.scrollToRelevantHour)
  }

  function setView(next) {
    if (root.view === next) return
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
    root.selectedEvent = null
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

  // A left click asks which account to open as, but only when there is more
  // than one to ask about; with a single account there is nothing to choose.
  function requestAction(action) {
    if (root.accountOptions.length <= 1) {
      root.performAction(action, root.defaultAccount)
      return
    }
    root.pendingAction = action
    root.accountPickerOpen = true
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
    if (!root.notifyArmed) { root.armNotifications(); return }

    var now = Date.now()
    for (var i = 0; i < root.events.length; i++) {
      var event = root.events[i]
      if (event.allDay || event.response === "declined") continue
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
      // critical means the toast never auto-dismisses, so it waits to be
      // clicked instead of vanishing while you are still reading it.
      "-u", "critical",
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
    root.controller.show()
    root.sync(false)
    Qt.callLater(root.scrollToRelevantHour)
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
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Open on the working day, not on midnight. Today opens with the now line
  // halfway down the viewport — it is the thing you came to read, and it wants
  // what is behind it as much as what is ahead. Browsing another day has no
  // now line to aim at, so it starts at the hour the day tends to begin.
  function scrollToRelevantHour() {
    if (!gridFlick) return
    // Called from a callLater on open, when the flickable may not have been
    // laid out yet; the configured height is what it is about to become.
    var viewport = gridFlick.height > 0 ? gridFlick.height : root.panelGridHeight
    var target
    if (root.showingToday) {
      // The same measure the now line itself is drawn at, so the two cannot
      // drift apart across a DST boundary.
      var start = Model.startOfDay(root.nowMs)
      var nowY = ((root.nowMs - start) / Model.dayLength(start)) * grid.height
      target = nowY - viewport / 2
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
  readonly property int gutterWidth: root.sp(root.showWeekNumbers && root.view !== "day" ? 54 : 46)
  readonly property int headerHeight: root.sp(30)
  readonly property int dayHeaderHeight: root.sp(40)
  readonly property int allDayRowHeight: root.sp(19)
  readonly property int allDayHeight: root.allDayLanes > 0
    ? root.allDayLanes * root.allDayRowHeight + root.sp(6) : 0
  readonly property int footerHeight: root.sp(20)

  readonly property int desiredWidth: {
    if (root.view === "day") return root.sp(560)
    if (root.view === "3day") return root.sp(840)
    return root.sp(workweek ? 1000 : 1260)
  }
  readonly property int desiredHeight: root.headerHeight + root.dayHeaderHeight +
    root.allDayHeight + root.panelGridHeight + root.footerHeight + root.sp(18)

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
    function week(): void { root.setView("week") }
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

      onCloseRequested: {
        // Escape unwinds one layer at a time — account picker, then the event,
        // then the panel. The grid behind is still where you left it, and
        // dismissing straight to the bar would lose that.
        if (root.accountPickerOpen) root.cancelAccountPicker()
        else if (root.selectedEvent) root.clearSelection()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.step(dx > 0 ? 1 : -1)
        else if (dy !== 0) gridFlick.contentY = Math.max(
          0, Math.min(gridFlick.contentY + dy * grid.hourHeight,
                      Math.max(0, grid.height - gridFlick.height)))
      }
      onTextKey: function(text) {
        var key = String(text).toLowerCase()
        if (key === "t") root.goToday()
        else if (key === "d") root.setView("day")
        else if (key === "w") root.setView("week")
        else if (key === "3") root.setView("3day")
        else if (key === "r") root.sync(true)
      }

      // ------------------------------------------------------------ header
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.headerHeight

        Text {
          id: rangeTitle
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: Model.rangeTitle(root.days)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.fontTitle
          font.bold: true
          renderType: Text.NativeRendering
        }

        Row {
          anchors.left: rangeTitle.right
          anchors.leftMargin: root.sp(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(2)

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅁"  // nf-md-chevron_left
            tooltipText: "Previous"
            foreground: root.dimForeground
            accent: root.accent
            fontFamily: root.fontFamily
            iconSize: root.fontIcon
            verticalPadding: root.sp(2)
            horizontalPadding: root.sp(5)
            onClicked: root.step(-1)
          }
          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅂"  // nf-md-chevron_right
            tooltipText: "Next"
            foreground: root.dimForeground
            accent: root.accent
            fontFamily: root.fontFamily
            iconSize: root.fontIcon
            verticalPadding: root.sp(2)
            horizontalPadding: root.sp(5)
            onClicked: root.step(1)
          }
          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: "Today"
            visible: !root.showingToday
            bordered: true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: root.fontCaption
            verticalPadding: root.sp(2)
            horizontalPadding: root.sp(7)
            onClicked: root.goToday()
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.sp(2)

          Repeater {
            model: [
              { id: "day", label: "D" },
              { id: "3day", label: "3" },
              { id: "week", label: "W" }
            ]

            Button {
              required property var modelData
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.label
              tooltipText: modelData.id === "day" ? "Day view (d)"
                : modelData.id === "3day" ? "3-day view (3)" : "Week view (w)"
              selected: root.view === modelData.id
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: root.fontCaption
              verticalPadding: root.sp(2)
              horizontalPadding: root.sp(6)
              onClicked: root.setView(modelData.id)
            }
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"  // nf-md-refresh
            tooltipText: root.syncing ? "Syncing…" : "Sync now (r)"
            foreground: root.syncing ? root.accent : root.dimForeground
            accent: root.accent
            fontFamily: root.fontFamily
            iconSize: root.fontIcon
            // Button spins its own icon while a fetch is in flight, which is
            // the only feedback a sync gives before the grid repaints.
            iconSpinning: root.syncing
            verticalPadding: root.sp(2)
            horizontalPadding: root.sp(5)
            onClicked: root.sync(true)
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
          visible: root.showWeekNumbers && root.view !== "day"
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.bottomMargin: root.sp(6)
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
            model: root.days

            Item {
              required property var modelData
              required property int index
              readonly property bool isToday: modelData === root.todayMs
              width: (dayHeader.width - root.gutterWidth) / Math.max(1, root.days.length)
              height: parent.height

              Column {
                anchors.centerIn: parent
                spacing: root.sp(1)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: Model.shortWeekday(parent.parent.modelData).toUpperCase()
                  color: parent.parent.isToday ? root.accent : root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: root.fontCaption
                  font.letterSpacing: 0.8
                  renderType: Text.NativeRendering
                }

                // Today's date sits in a filled pip, the way Google marks it.
                Rectangle {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Math.max(dayNumber.implicitWidth + root.sp(9), root.sp(20))
                  height: root.sp(20)
                  radius: height / 2
                  color: parent.parent.isToday ? root.accent : "transparent"

                  Text {
                    id: dayNumber
                    anchors.centerIn: parent
                    text: new Date(parent.parent.parent.modelData).getDate()
                    color: parent.parent.parent.isToday
                      ? Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
                      : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontSubtitle
                    font.bold: parent.parent.parent.isToday
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
          anchors.right: parent.right
          height: 1
          color: root.strongHairline
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
          width: root.gutterWidth
          horizontalAlignment: Text.AlignRight
          rightPadding: root.sp(7)
          text: "all-day"
          color: root.faintForeground
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          renderType: Text.NativeRendering
        }

        Repeater {
          model: root.allDayLayout.bars

          Rectangle {
            required property var modelData
            readonly property var event: modelData.event
            readonly property string style: Model.blockStyle(event)

            visible: modelData.lane < root.allDayLanes
            x: root.gutterWidth + modelData.startCol * allDayBand.columnWidth + 1
            y: root.sp(3) + modelData.lane * root.allDayRowHeight
            width: Math.max(root.sp(10),
              (modelData.endCol - modelData.startCol + 1) * allDayBand.columnWidth - 2)
            height: root.allDayRowHeight - root.sp(3)
            radius: root.sp(3)
            color: style === "filled" ? event.color : Model.withAlpha(event.color, 0.16)
            border.width: style === "filled" ? 0 : 1
            border.color: event.color
            opacity: style === "declined" ? 0.45 : 1

            Text {
              anchors.fill: parent
              anchors.leftMargin: root.sp(6)
              anchors.rightMargin: root.sp(4)
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
              text: (modelData.continuesBefore ? "‹ " : "") + event.summary +
                    (modelData.continuesAfter ? " ›" : "")
              color: parent.style === "filled" ? Model.textOn(event.color) : root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fontCaption
              font.strikeout: parent.style === "declined"
              renderType: Text.NativeRendering
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.selectEvent(parent.event)
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

          // Hour rules and their labels.
          Repeater {
            model: 24

            Item {
              required property int index
              y: index * grid.hourHeight
              width: grid.width
              height: grid.hourHeight

              Text {
                anchors.right: parent.left
                anchors.rightMargin: -root.gutterWidth + root.sp(7)
                anchors.top: parent.top
                anchors.topMargin: -root.sp(5)
                text: index === 0 ? "" : Model.formatHourLabel(index, root.use24Hour)
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
            }
          }

          // Day separators.
          Repeater {
            model: root.days.length

            Rectangle {
              required property int index
              visible: index > 0
              x: root.gutterWidth + index * grid.columnWidth
              width: 1
              height: grid.height
              color: root.hairline
            }
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
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
              z: -1
            }
          }

          // ---- events, one delegate per day column
          Repeater {
            model: root.dayModels

            Item {
              required property var modelData
              required property int index
              x: root.gutterWidth + index * grid.columnWidth
              width: grid.columnWidth
              height: grid.height

              Repeater {
                model: parent.modelData.blocks

                Rectangle {
                  id: block
                  required property var modelData
                  readonly property var event: modelData.event
                  readonly property string style: Model.blockStyle(event)
                  readonly property bool selected: root.selectedEvent && root.selectedEvent.id === event.id
                  readonly property real slot: parent.width / Math.max(1, modelData.columns)

                  x: modelData.column * slot + 1
                  y: modelData.top * grid.height
                  width: Math.max(root.sp(14), slot * modelData.span - root.sp(3))
                  height: Math.max(root.sp(12), modelData.height * grid.height - 1)
                  radius: root.sp(3)
                  clip: true

                  color: style === "filled" ? event.color : Model.withAlpha(event.color, 0.14)
                  border.width: style === "filled" ? (selected ? 2 : 0) : 1
                  border.color: style === "filled"
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.9)
                    : event.color
                  opacity: style === "declined" ? 0.45 : (hover.hovered ? 0.88 : 1)

                  // The left rail is what tells outlined and declined blocks
                  // which calendar they belong to once the fill is gone.
                  Rectangle {
                    visible: block.style !== "filled"
                    width: root.sp(3)
                    height: parent.height
                    color: block.event.color
                  }

                  Column {
                    anchors.fill: parent
                    anchors.margins: root.sp(3)
                    anchors.leftMargin: block.style === "filled" ? root.sp(5) : root.sp(7)
                    spacing: 0

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      maximumLineCount: block.height > root.sp(34) ? 2 : 1
                      wrapMode: Text.Wrap
                      text: block.event.summary
                      color: block.style === "filled"
                        ? Model.textOn(block.event.color) : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: root.fontCaption
                      font.bold: true
                      font.strikeout: block.style === "declined"
                      renderType: Text.NativeRendering
                    }

                    Text {
                      width: parent.width
                      // Only when there is room: a 15-minute block that tries
                      // to show two lines shows neither.
                      visible: block.height > root.sp(28)
                      elide: Text.ElideRight
                      text: Model.formatTime(block.event.start, root.use24Hour) +
                            (block.event.meetingUrl ? "  󰕧" : "")
                      color: block.style === "filled"
                        ? Model.withAlpha(Model.textOn(block.event.color), 0.8)
                        : root.dimForeground
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
          Item {
            visible: root.todayColumn >= 0
            y: {
              var start = Model.startOfDay(root.nowMs)
              return ((root.nowMs - start) / Model.dayLength(start)) * grid.height
            }
            x: root.gutterWidth
            width: grid.width - root.gutterWidth
            height: 1
            z: 5

            Rectangle {
              anchors.fill: parent
              color: root.accent
              opacity: 0.55
            }

            // The dot marks which column is actually today, which is the only
            // thing distinguishing the line in a week view.
            Rectangle {
              visible: root.todayColumn >= 0
              x: root.todayColumn * grid.columnWidth
              y: -root.sp(3)
              width: root.sp(7)
              height: root.sp(7)
              radius: width / 2
              color: root.accent
            }
          }
        }
      }

      // ------------------------------------------------------------ footer
      Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.footerHeight

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - root.sp(90)
          elide: Text.ElideRight
          text: {
            if (root.needsAuth) return "Not connected to Google — click to set up"
            if (root.syncError.length > 0) return "⚠ " + root.syncError
            if (root.syncMessage.length > 0) return "⚠ " + root.syncMessage
            if (!root.everSynced) return "Waiting for the first sync…"
            return Model.syncAgeLabel(root.cache.syncedAt, root.nowMs) + " · " +
                   root.calendars.length +
                   (root.calendars.length === 1 ? " calendar" : " calendars")
          }
          color: (root.needsAuth || root.syncError.length > 0) ? root.accent : root.faintForeground
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

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "d/3/w · t today · r sync"
          color: root.faintForeground
          font.family: root.fontFamily
          font.pixelSize: root.fontCaption
          renderType: Text.NativeRendering
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
    }
  }

  Component {
    id: eventDetail

    Item {
      readonly property var event: root.selectedEvent

      // Catches the click that dismisses, and stops it reaching the grid.
      MouseArea {
        anchors.fill: parent
        onClicked: root.clearSelection()
      }

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                       Color.popups.background.b, 0.88)
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - root.sp(24), root.sp(400))
        height: Math.min(parent.height - root.sp(16),
                         detailColumn.implicitHeight + root.sp(28))
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : root.sp(4)
        color: Color.popups.background
        border.width: 1
        border.color: root.strongHairline

        // Swallows clicks so they do not fall through to the dismiss layer.
        MouseArea {
          anchors.fill: parent
        }

        // The event's colour, as a rail down the side.
        Rectangle {
          width: root.sp(3)
          height: parent.height - root.sp(2)
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: 1
          radius: width / 2
          color: event ? event.color : root.accent
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
          onClicked: root.clearSelection()
        }

        Flickable {
          anchors.fill: parent
          anchors.margins: root.sp(14)
          anchors.leftMargin: root.sp(16)
          contentWidth: width
          contentHeight: detailColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: detailColumn
            width: parent.width
            spacing: root.sp(8)

            Text {
              width: parent.width - root.sp(22)
              wrapMode: Text.Wrap
              text: event ? event.summary : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fontHeading
              font.bold: true
              renderType: Text.NativeRendering
            }

            Column {
              width: parent.width
              spacing: root.sp(2)

              Text {
                text: event ? (Model.longWeekday(event.start) + ", " +
                               Model.monthName(event.start) + " " +
                               new Date(event.start).getDate()) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fontBody
                renderType: Text.NativeRendering
              }

              Text {
                text: event ? (Model.formatRange(event, root.use24Hour) +
                               (event.allDay ? "" : "  ·  " +
                                Model.formatDuration(event.end - event.start)) +
                               (event.recurring ? "  ·  repeats" : "")) : ""
                color: root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontBodySmall
                renderType: Text.NativeRendering
              }
            }

            // ---- join / open, and which account to do it as
            Column {
              width: parent.width
              spacing: root.sp(6)

              Row {
                spacing: root.sp(6)

                Button {
                  visible: event && event.meetingUrl !== ""
                  text: event && event.meetingProvider
                    ? "Join " + event.meetingProvider : "Join"
                  iconText: "󰕧"  // nf-md-video
                  bordered: true
                  selected: root.accountPickerOpen && root.pendingAction === "join"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontBodySmall
                  onClicked: root.requestAction("join")
                }

                Button {
                  visible: event && event.meetingUrl !== ""
                  text: "Copy link"
                  iconText: "󰆏"  // nf-md-content_copy
                  bordered: true
                  foreground: root.dimForeground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontBodySmall
                  onClicked: {
                    root.copyMeetingFor(event)
                    root.close()
                  }
                }

                Button {
                  text: "Open in Google"
                  iconText: "󰏌"  // nf-md-open_in_new
                  bordered: true
                  selected: root.accountPickerOpen && root.pendingAction === "open"
                  foreground: root.dimForeground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: root.fontBodySmall
                  onClicked: root.requestAction("open")
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
                  font.letterSpacing: 0.6
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
            }

            PanelSeparator {
              width: parent.width
              visible: event && (event.location !== "" || event.calendar !== "" ||
                                 (event.attendees && event.attendees.length > 0))
            }

            // ---- where
            Row {
              width: parent.width
              spacing: root.sp(8)
              visible: event && event.location !== ""

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
                text: event ? event.location : ""
                color: root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontBodySmall
                renderType: Text.NativeRendering
              }
            }

            // ---- which calendar, and your own answer to the invitation
            Row {
              width: parent.width
              spacing: root.sp(8)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: root.sp(8)
                height: root.sp(8)
                radius: width / 2
                color: event ? event.color : root.accent
              }

              Text {
                width: parent.width - root.sp(24)
                elide: Text.ElideRight
                text: event
                  ? event.calendar + (event.attendees && event.attendees.length > 0
                      ? "  ·  " + Model.responseLabel(event.response) : "")
                  : ""
                color: root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontBodySmall
                renderType: Text.NativeRendering
              }
            }

            // ---- guests
            Column {
              width: parent.width
              spacing: root.sp(3)
              visible: event && event.attendees && event.attendees.length > 0

              Text {
                text: event ? Model.attendeeSummary(event.attendees) : ""
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }

              Repeater {
                // Capped: a 40-person invite would push the description off
                // the card, and the count above already tells the whole story.
                model: event && event.attendees
                  ? event.attendees.slice(0, 8) : []

                Row {
                  required property var modelData
                  spacing: root.sp(6)

                  Text {
                    text: Model.responseGlyph(modelData.response)
                    color: modelData.response === "accepted" ? "#33b679"
                      : modelData.response === "declined" ? root.accent
                      : root.faintForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    renderType: Text.NativeRendering
                  }

                  Text {
                    text: Model.attendeeName(modelData) +
                          (modelData.organizer ? " (organizer)" : "")
                    color: modelData.self ? root.foreground : root.dimForeground
                    font.family: root.fontFamily
                    font.pixelSize: root.fontCaption
                    renderType: Text.NativeRendering
                  }
                }
              }

              Text {
                visible: event && event.attendees && event.attendees.length > 8
                text: event ? "+ " + (event.attendees.length - 8) + " more" : ""
                color: root.faintForeground
                font.family: root.fontFamily
                font.pixelSize: root.fontCaption
                renderType: Text.NativeRendering
              }
            }

            PanelSeparator {
              width: parent.width
              visible: event && event.description !== ""
            }

            Text {
              width: parent.width
              visible: event && event.description !== ""
              wrapMode: Text.Wrap
              text: event ? Model.truncate(event.description, 900) : ""
              color: root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: root.fontBodySmall
              lineHeight: 1.25
              renderType: Text.NativeRendering
              onLinkActivated: function(link) { root.openUrl(link) }
            }
          }
        }
      }
    }
  }
}
