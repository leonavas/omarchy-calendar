import QtQuick
import Quickshell
import Quickshell.Io
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
  readonly property int leadMinutes: Math.max(0, Number(setting("leadMinutes", 15)))
  readonly property int warnMinutes: Math.max(0, Number(setting("warnMinutes", 5)))
  readonly property bool hideWhenEmpty: Model.truthy(setting("hideWhenEmpty", false), false)
  readonly property bool joinOnMiddleClick: Model.truthy(setting("joinOnMiddleClick", true), true)
  readonly property string rightClickAction: String(setting("rightClickAction", "New meeting"))

  // ---------------------------------------------------------------- state
  readonly property var panel: panelLoader.item
  readonly property var events: panel ? panel.events : []
  readonly property double nowMs: panel ? panel.nowMs : Date.now()
  readonly property bool needsAuth: panel ? panel.needsAuth === true : false
  readonly property bool vacation: panel ? panel.vacationActive === true : false

  // The one event the bar speaks for: shown from leadMinutes before it starts
  // until warnMinutes after. Outside that window the bar is just the glyph.
  readonly property var subject: Model.barSubject(root.events, root.nowMs,
    root.leadMinutes * 60000, root.warnMinutes * 60000)
  readonly property bool hasSubject: root.subject !== null && root.subject !== undefined
  // Yellow from warnMinutes before the start to warnMinutes after; the subject
  // is already gone past the latter, so only the lower edge needs checking.
  readonly property bool imminent: root.hasSubject &&
    root.subject.start - root.nowMs <= root.warnMinutes * 60000
  readonly property bool running: root.hasSubject &&
    root.subject.start <= root.nowMs && root.subject.end > root.nowMs

  // The text of the event itself, without the glyph.
  readonly property string eventLabel: {
    if (root.needsAuth) return "calendar"
    if (!root.hasSubject) return ""
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

  readonly property string palmGlyph: "󱁕"  // nf-md-palm_tree

  readonly property string label: {
    // Away: the palm tree stands in for the meeting, and says nothing else.
    if (root.vacation) return root.palmGlyph
    if (root.iconOnly || root.eventLabel === "") return root.glyph
    return root.glyph + "  " + root.eventLabel
  }

  readonly property string tooltip: {
    if (root.vacation)
      return "On vacation — " + Model.vacationUntilLabel(
        panel.vacationUntil, root.nowMs, panel.use24Hour) + "\nclick for the beach"
    if (root.needsAuth) return "Google Calendar — not connected yet"
    if (!root.hasSubject) {
      var next = Model.nextEvent(root.events, root.nowMs)
      if (!next) return "Google Calendar — nothing scheduled\n" + root.rightClickHint
      return "Next: " + next.summary + "\n" +
        Model.formatRange(next, panel ? panel.use24Hour : true) + "\n" +
        Model.relativeLabel(next.start, root.nowMs, true) + "\n" + root.rightClickHint
    }
    var parts = [root.subject.summary]
    parts.push(Model.formatRange(root.subject, panel ? panel.use24Hour : true))
    if (root.running) parts.push("on now")
    else parts.push(Model.relativeLabel(root.subject.start, root.nowMs, true))
    if (root.subject.location) parts.push(root.subject.location)
    if (root.subject.meetingUrl)
      parts.push("middle click to join " + (root.subject.meetingProvider || "the call"))
    parts.push(root.rightClickHint)
    return parts.join("\n")
  }

  // ------------------------------------------------------------ hover card
  //
  // Hovering the widget shows what it speaks for as a card you can act on:
  // the event, where it stands against the clock, a Join button, and what
  // follows today. Plain tooltip only when there is nothing to act on.
  readonly property var cardEvent: root.hasSubject ? root.subject
    : Model.nextEvent(root.events, root.nowMs)
  readonly property var cardLater: root.cardEvent
    ? Model.laterToday(root.events, root.cardEvent, root.nowMs, 2) : []
  // The meeting the card's button joins: the card's own event when it has a
  // call, else the next one today that does. A lunch has no call to open.
  readonly property var cardCall: {
    var event = root.cardEvent
    if (!event) return null
    if (event.meetingUrl) return event
    var later = Model.laterToday(root.events, event, root.nowMs, 50)
    for (var i = 0; i < later.length; i++) if (later[i].meetingUrl) return later[i]
    return null
  }
  readonly property bool cardAvailable: !!root.panel && !root.vacation && !root.needsAuth &&
    !!root.cardEvent && !root.opened
  readonly property bool cardHovered: button.tooltipHovered || hoverCard.containsMouse
  property bool cardOpen: false

  onCardAvailableChanged: if (!cardAvailable) root.cardOpen = false
  onCardHoveredChanged: {
    if (root.cardHovered && root.cardAvailable) {
      cardCloseTimer.stop()
      if (!root.cardOpen) cardOpenTimer.restart()
    } else {
      cardOpenTimer.stop()
      if (root.cardOpen) cardCloseTimer.restart()
    }
  }

  Timer {
    id: cardOpenTimer
    interval: 300
    onTriggered: if (root.cardHovered && root.cardAvailable) root.cardOpen = true
  }

  Timer {
    id: cardCloseTimer
    // Long enough to cross the gap between the bar and the card.
    interval: 280
    onTriggered: if (!root.cardHovered) root.cardOpen = false
  }

  QtObject {
    id: cardKey
    function close() { root.cardOpen = false }
  }

  function joinFromCard(event) {
    root.cardOpen = false
    if (panelLoader.item) panelLoader.item.joinMeeting(event)
  }

  function openEventFromCard(event) {
    root.cardOpen = false
    if (panelLoader.item) panelLoader.item.openOnEvent(event)
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

  // Start a call now, as the account the calendar belongs to.
  function startMeeting() {
    if (panelLoader.item) panelLoader.item.startMeeting()
  }

  function openCalendar() {
    if (panelLoader.item) panelLoader.item.openCalendarHome()
  }

  function rightClick() {
    if (root.rightClickAction === "Sync now") root.refresh()
    else if (root.rightClickAction === "Open Google Calendar") root.openCalendar()
    else root.startMeeting()
  }

  readonly property string rightClickHint: {
    if (root.rightClickAction === "Sync now") return "right click to sync"
    if (root.rightClickAction === "Open Google Calendar") return "right click for Google Calendar"
    return "right click to start a meeting"
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

  // The theme's yellow; the shell only exposes red (urgent), so it is read
  // straight from colors.toml.
  property color yellow: "#e0af68"

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var match = String(text()).match(/^\s*(?:yellow|color3)\s*=\s*["']?(#[0-9A-Fa-f]{6})/m)
      if (match) root.yellow = match[1]
    }
  }

  // ---------------------------------------------------------------- layout
  visible: root.vacation || !(root.hideWhenEmpty && !root.hasSubject && !root.needsAuth)
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
    tooltipText: root.cardAvailable ? "" : root.tooltip
    // Yellow around a meeting's start — the one moment the widget has
    // something to say that is worth interrupting the bar's colour for. Red is
    // kept for a calendar that still needs connecting.
    active: (root.imminent && !root.vacation) || root.needsAuth
    activeColor: root.needsAuth ? (root.bar ? root.bar.urgent : Color.urgent) : root.yellow
    useActiveColor: true
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.joinOnMiddleClick && root.hasSubject && root.subject.meetingUrl)
          root.joinNext()
        else root.refresh()
      } else if (mouseButton === Qt.RightButton) {
        root.rightClick()
      } else {
        root.togglePanel()
      }
    }

    onWheelMoved: function(delta) {
      if (panelLoader.item && panelLoader.item.opened)
        panelLoader.item.step(delta > 0 ? -1 : 1)
    }
  }

  PopupCard {
    id: hoverCard
    anchorItem: button
    bar: root.bar
    // Its own popout identity: the widget itself is the panel's, and the
    // card closing must not release the panel's claim on the bar.
    owner: cardKey
    open: root.cardOpen
    triggerMode: "hover"
    contentWidth: hoverCard.fittedContentWidth(hoverCard.sp(360))
    contentHeight: hoverCard.fittedContentHeight(cardColumn.implicitHeight)

    readonly property var host: root.panel
    readonly property var event: root.cardEvent
    readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
    readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.62)
    readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.38)
    readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
    readonly property color wash: Qt.rgba(fg.r, fg.g, fg.b, 0.06)
    readonly property string family: root.bar ? root.bar.fontFamily : Style.font.family
    readonly property bool use24: host ? host.use24Hour : true
    readonly property var status: Model.eventStatus(event, root.nowMs, use24)
    readonly property bool urgent: status.kind === "soon" || status.kind === "running"
    readonly property var call: root.cardCall
    readonly property bool hasCall: !!call
    // The button joins something other than the event on the card.
    readonly property bool callIsLater: hasCall && call !== event

    // The popup's own scale, so the card and the grid read as one family.
    function sp(px) { return host ? host.sp(px) : Style.space(px) }
    function fs(px) { return host ? host.fs(px) : px }
    function tone(hex, amount) { return host ? host.tone(hex, amount) : hex }

    Column {
      id: cardColumn
      width: parent.width
      spacing: hoverCard.sp(10)

      // When, against the clock — yellow once it is close.
      Row {
        width: parent.width
        spacing: hoverCard.sp(7)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: hoverCard.sp(8)
          height: width
          radius: width / 2
          color: hoverCard.event ? hoverCard.event.color : hoverCard.fg
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (!hoverCard.event) return ""
            var label = hoverCard.status.label
            if (hoverCard.status.kind === "later")
              return label !== "" ? "Next · " + label
                : "Next · " + Model.relativeLabel(hoverCard.event.start, root.nowMs, hoverCard.use24)
            return label
          }
          color: hoverCard.urgent ? root.yellow : hoverCard.dim
          font.family: hoverCard.family
          font.pixelSize: hoverCard.fs(Style.font.caption)
          font.bold: hoverCard.urgent
          renderType: Text.NativeRendering
        }
      }

      Column {
        width: parent.width
        spacing: hoverCard.sp(3)

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          text: hoverCard.event ? hoverCard.event.summary : ""
          color: hoverCard.fg
          font.family: hoverCard.family
          font.pixelSize: hoverCard.fs(Style.font.heading)
          font.bold: true
          renderType: Text.NativeRendering
        }

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: hoverCard.event
            ? Model.formatRange(hoverCard.event, hoverCard.use24) + "  ·  " +
              Model.formatDuration(hoverCard.event.end - hoverCard.event.start) +
              (hoverCard.event.location ? "  ·  " + hoverCard.event.location : "")
            : ""
          color: hoverCard.dim
          font.family: hoverCard.family
          font.pixelSize: hoverCard.fs(Style.font.bodySmall)
          renderType: Text.NativeRendering
        }
      }

      // Join, right here — the reason to hover at all. When the event on the
      // card has no call, the button names the meeting it does join.
      Rectangle {
        id: joinButton
        visible: hoverCard.hasCall
        readonly property bool hot: joinMouse.containsMouse
        readonly property bool urgentCall: hoverCard.hasCall &&
          Model.eventStatus(hoverCard.call, root.nowMs, hoverCard.use24).kind !== "later"
        readonly property color base: hoverCard.hasCall
          ? hoverCard.tone(hoverCard.call.color, urgentCall ? 0.95 : 0.7) : hoverCard.wash
        width: parent.width
        height: joinRow.implicitHeight + hoverCard.sp(14)
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : hoverCard.sp(5)
        color: joinMouse.pressed ? Qt.darker(base, 1.1) : hot ? Qt.lighter(base, 1.12) : base
        border.width: 1
        border.color: Qt.rgba(hoverCard.fg.r, hoverCard.fg.g, hoverCard.fg.b, hot ? 0.35 : 0.16)
        scale: joinMouse.pressed ? 0.985 : 1
        Behavior on color { ColorAnimation { duration: Style.duration(110) } }
        Behavior on scale { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }

        Row {
          id: joinRow
          anchors.centerIn: parent
          width: Math.min(implicitWidth, parent.width - hoverCard.sp(24))
          spacing: hoverCard.sp(8)

          Text {
            id: joinIcon
            anchors.verticalCenter: parent.verticalCenter
            text: "󰕧"  // nf-md-video
            color: hoverCard.fg
            font.family: hoverCard.family
            font.pixelSize: hoverCard.fs(Style.font.icon)
            renderType: Text.NativeRendering
          }

          Text {
            id: joinLabel
            anchors.verticalCenter: parent.verticalCenter
            text: !hoverCard.hasCall ? ""
              : hoverCard.call.meetingProvider ? "Join " + hoverCard.call.meetingProvider : "Join call"
            color: hoverCard.fg
            font.family: hoverCard.family
            font.pixelSize: hoverCard.fs(Style.font.body)
            font.bold: true
            renderType: Text.NativeRendering
          }

          Text {
            visible: hoverCard.callIsLater
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, joinButton.width - hoverCard.sp(24) -
              joinIcon.implicitWidth - joinLabel.implicitWidth - hoverCard.sp(16))
            elide: Text.ElideRight
            text: hoverCard.callIsLater
              ? "· " + Model.formatTime(hoverCard.call.start, hoverCard.use24) + " " + hoverCard.call.summary
              : ""
            color: Qt.rgba(hoverCard.fg.r, hoverCard.fg.g, hoverCard.fg.b, 0.75)
            font.family: hoverCard.family
            font.pixelSize: hoverCard.fs(Style.font.bodySmall)
            renderType: Text.NativeRendering
          }
        }

        MouseArea {
          id: joinMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (hoverCard.hasCall) root.joinFromCard(hoverCard.call)
        }
      }

      // What follows today, one click from its card in the popup.
      Column {
        width: parent.width
        spacing: hoverCard.sp(2)
        visible: root.cardLater.length > 0

        Rectangle { width: parent.width; height: 1; color: hoverCard.hairline }
        Item { width: 1; height: hoverCard.sp(4) }

        Text {
          text: "Then"
          color: hoverCard.faint
          font.family: hoverCard.family
          font.pixelSize: hoverCard.fs(Style.font.caption)
          renderType: Text.NativeRendering
        }

        Repeater {
          model: root.cardLater

          Rectangle {
            id: laterRow
            required property var modelData
            width: parent.width
            height: laterTitle.implicitHeight + hoverCard.sp(8)
            radius: hoverCard.sp(4)
            color: laterMouse.containsMouse ? hoverCard.wash : "transparent"

            Row {
              anchors.left: parent.left
              anchors.leftMargin: hoverCard.sp(2)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: hoverCard.sp(8)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: hoverCard.sp(6)
                height: width
                radius: width / 2
                color: laterRow.modelData.color
              }

              Text {
                id: laterTime
                anchors.verticalCenter: parent.verticalCenter
                text: Model.formatTime(laterRow.modelData.start, hoverCard.use24)
                color: hoverCard.faint
                font.family: hoverCard.family
                font.pixelSize: hoverCard.fs(Style.font.caption)
                renderType: Text.NativeRendering
              }

              Text {
                id: laterTitle
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - laterTime.implicitWidth - hoverCard.sp(30) -
                  (laterJoin.visible ? laterJoin.width + hoverCard.sp(8) : 0)
                elide: Text.ElideRight
                text: laterRow.modelData.summary
                color: hoverCard.dim
                font.family: hoverCard.family
                font.pixelSize: hoverCard.fs(Style.font.caption)
                renderType: Text.NativeRendering
              }
            }

            MouseArea {
              id: laterMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openEventFromCard(laterRow.modelData)
            }

            // Its own way into the call, so a later meeting is one click too.
            Rectangle {
              id: laterJoin
              visible: !!laterRow.modelData.meetingUrl
              anchors.right: parent.right
              anchors.rightMargin: hoverCard.sp(2)
              anchors.verticalCenter: parent.verticalCenter
              width: laterJoinText.implicitWidth + hoverCard.sp(14)
              height: laterJoinText.implicitHeight + hoverCard.sp(4)
              radius: height / 2
              color: laterJoinMouse.containsMouse
                ? hoverCard.tone(laterRow.modelData.color, 0.7) : hoverCard.wash
              border.width: 1
              border.color: hoverCard.hairline
              Behavior on color { ColorAnimation { duration: Style.duration(110) } }

              Text {
                id: laterJoinText
                anchors.centerIn: parent
                text: "󰕧 Join"
                color: laterJoinMouse.containsMouse ? hoverCard.fg : hoverCard.dim
                font.family: hoverCard.family
                font.pixelSize: hoverCard.fs(Style.font.caption)
                renderType: Text.NativeRendering
              }

              MouseArea {
                id: laterJoinMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.joinFromCard(laterRow.modelData)
              }
            }
          }
        }
      }

      // The bar's own gestures, said once and quietly.
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: (root.joinOnMiddleClick && root.hasSubject && root.subject.meetingUrl
                ? "middle click joins  ·  " : "") +
              root.rightClickHint.replace("right click to ", "right click: ")
        color: hoverCard.faint
        font.family: hoverCard.family
        font.pixelSize: hoverCard.fs(Style.font.caption)
        renderType: Text.NativeRendering
      }
    }
  }
}
