import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar half of the calendar plugin: a label for what is on now or next,
// and the button that opens the grid.
//
// Panel.qml owns the data and the popup; this widget reads the event it should
// speak for back off it, so there is one cache, one sync, and one source of
// truth for what "next" means.
BarWidget {
  id: root
  moduleName: "leonavas.calendar"

  // ------------------------------------------------------------- settings
  readonly property string labelMode: String(setting("labelMode", "Next event"))
  readonly property string glyph: String(setting("glyph", "󰃭"))
  readonly property int maxLabelChars: Math.max(6, Number(setting("maxLabelChars", 22)))
  readonly property int warnMinutes: Math.max(0, Number(setting("warnMinutes", 5)))
  readonly property bool hideWhenEmpty: Model.truthy(setting("hideWhenEmpty", false), false)
  readonly property bool joinOnMiddleClick: Model.truthy(setting("joinOnMiddleClick", true), true)

  // ---------------------------------------------------------------- state
  readonly property var panel: panelLoader.item
  readonly property var events: panel ? panel.events : []
  readonly property double nowMs: panel ? panel.nowMs : Date.now()
  readonly property bool needsAuth: panel ? panel.needsAuth === true : false

  // The one event the bar speaks for: whatever is running, handing over to
  // the next one once it is close enough to need leaving for.
  readonly property var subject: Model.barEvent(root.events, root.nowMs)
  readonly property bool hasSubject: root.subject !== null && root.subject !== undefined
  readonly property bool imminent: root.hasSubject &&
    root.subject.start > root.nowMs &&
    root.subject.start - root.nowMs <= root.warnMinutes * 60000
  readonly property bool running: root.hasSubject &&
    root.subject.start <= root.nowMs && root.subject.end > root.nowMs

  // The text of the event itself, without the glyph.
  readonly property string eventLabel: {
    if (root.needsAuth) return "calendar"
    if (!root.hasSubject) return "no events"
    var title = Model.truncate(root.subject.summary, root.maxLabelChars)
    if (root.labelMode === "Countdown")
      return title + " " + Model.relativeLabel(root.subject.start, root.nowMs,
                                               panel ? panel.use24Hour : true)
    if (root.running) return title
    return Model.formatTime(root.subject.start, panel ? panel.use24Hour : true) + " " + title
  }

  // The glyph rides inside the label rather than being anchored over it:
  // WidgetButton centres its Text and measures the slot from that Text, so an
  // overlaid icon would sit on top of the words and contribute no width. A
  // vertical bar has no room for the words at all, so it keeps only the glyph.
  readonly property bool iconOnly: root.vertical || root.labelMode === "Icon only"

  readonly property string label: {
    if (root.iconOnly) return root.glyph
    return root.glyph + "  " + root.eventLabel
  }

  readonly property string tooltip: {
    if (root.needsAuth) return "Google Calendar — not connected yet"
    if (!root.hasSubject) return "Google Calendar — nothing scheduled"
    var parts = [root.subject.summary]
    parts.push(Model.formatRange(root.subject, panel ? panel.use24Hour : true))
    if (root.running) parts.push("on now")
    else parts.push(Model.relativeLabel(root.subject.start, root.nowMs, true))
    if (root.subject.location) parts.push(root.subject.location)
    if (root.subject.meetingUrl)
      parts.push("middle click to join " + (root.subject.meetingProvider || "the call"))
    return parts.join("\n")
  }

  // -------------------------------------------------------- panel contract
  //
  // Shape the bar's summon/hide/toggle routing expects on the widget root:
  // Bar.findPanelWidget looks for open/close/opened here, not on the panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function refresh() {
    if (panelLoader.item) panelLoader.item.sync(true)
  }

  function joinNext() {
    if (!root.hasSubject || !root.subject.meetingUrl) return
    if (panelLoader.item) panelLoader.item.joinMeeting(root.subject)
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close.
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // ---------------------------------------------------------------- layout
  visible: !(root.hideWhenEmpty && !root.hasSubject && !root.needsAuth)
  implicitWidth: root.visible ? button.implicitWidth : 0
  implicitHeight: root.visible ? button.implicitHeight : 0

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    labelVisible: true
    hasVisualContent: root.label !== ""
    tooltipText: root.tooltip
    // Urgent while a meeting is about to start — the one moment the widget
    // has something to say that is worth interrupting the bar's colour for.
    active: root.imminent || root.needsAuth
    useActiveColor: true
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.joinOnMiddleClick && root.hasSubject && root.subject.meetingUrl)
          root.joinNext()
        else root.refresh()
      } else if (mouseButton === Qt.RightButton) {
        root.refresh()
      } else {
        root.togglePanel()
      }
    }

    onWheelMoved: function(delta) {
      if (panelLoader.item && panelLoader.item.opened)
        panelLoader.item.step(delta > 0 ? -1 : 1)
    }
  }
}
