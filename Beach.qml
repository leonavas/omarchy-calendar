import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The beach: what the popup shows while vacation mode is on.
//
// A palm tree on the sand, the sea breathing in and out, a low sun. Drawn on
// a Canvas rather than shipped as a GIF so it scales with the panel, takes the
// panel's corner radius, and weighs nothing in the repository. Only the
// shoreline, the fronds and the birds move, slowly, and only while the panel
// is open.
Item {
  id: scene

  // The panel that owns this scene: metrics, fonts, and the way out.
  required property var host

  readonly property double untilMs: host ? host.vacationUntil : 0
  readonly property double nowMs: host ? host.nowMs : Date.now()
  readonly property real radius: Style.cornerRadius > 0 ? Style.cornerRadius : 0

  // Seconds since the scene appeared. Everything periodic reads off this one
  // clock, so the tide, the sway and the birds cannot drift apart.
  property real time: 0

  Timer {
    // 25 fps is plenty for water that moves this slowly, and gentle on a
    // laptop that is supposed to be resting too.
    interval: 40
    repeat: true
    running: scene.visible
    onTriggered: {
      scene.time += 0.04
      canvas.requestPaint()
    }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    function roundedClip(ctx, w, h, r) {
      ctx.beginPath()
      if (r <= 0) { ctx.rect(0, 0, w, h); return }
      ctx.moveTo(r, 0)
      ctx.lineTo(w - r, 0); ctx.arcTo(w, 0, w, r, r)
      ctx.lineTo(w, h - r); ctx.arcTo(w, h, w - r, h, r)
      ctx.lineTo(r, h); ctx.arcTo(0, h, 0, h - r, r)
      ctx.lineTo(0, r); ctx.arcTo(0, 0, r, 0, r)
      ctx.closePath()
    }

    // The water's edge at x, for the current tide. Two sines of different
    // wavelengths so the line never quite repeats.
    function shoreY(x, shore, t) {
      return shore + 5 * Math.sin(x / 55 + t * 0.9) + 3 * Math.sin(x / 23 - t * 0.6)
    }

    function shorePath(ctx, w, shore, t, bottomY) {
      ctx.beginPath()
      ctx.moveTo(0, bottomY)
      for (var x = 0; x <= w + 8; x += 8) ctx.lineTo(x, shoreY(x, shore, t))
      ctx.lineTo(w, bottomY)
      ctx.closePath()
    }

    function frond(ctx, x0, y0, angle, length, droop, width, fill) {
      var dx = Math.cos(angle), dy = Math.sin(angle)
      var tipX = x0 + dx * length
      var tipY = y0 + dy * length + droop
      var midX = x0 + dx * length * 0.55
      var midY = y0 + dy * length * 0.55 + droop * 0.25
      // Perpendicular to the frond's own direction, for the two edges.
      var nx = -dy, ny = dx
      ctx.beginPath()
      ctx.moveTo(x0, y0)
      ctx.quadraticCurveTo(midX + nx * width, midY + ny * width, tipX, tipY)
      ctx.quadraticCurveTo(midX - nx * width * 0.6, midY - ny * width * 0.6, x0, y0)
      ctx.closePath()
      ctx.fillStyle = fill
      ctx.fill()
      // The rib, so the leaf reads as a leaf and not a blob.
      ctx.beginPath()
      ctx.moveTo(x0, y0)
      ctx.quadraticCurveTo(midX, midY, tipX, tipY)
      ctx.strokeStyle = "rgba(20, 60, 35, 0.45)"
      ctx.lineWidth = 1
      ctx.stroke()
    }

    function bird(ctx, x, y, size, flap) {
      ctx.beginPath()
      ctx.moveTo(x - size, y + flap)
      ctx.quadraticCurveTo(x - size / 2, y - size * 0.3, x, y)
      ctx.quadraticCurveTo(x + size / 2, y - size * 0.3, x + size, y + flap)
      ctx.strokeStyle = "rgba(60, 40, 50, 0.55)"
      ctx.lineWidth = 1.2
      ctx.stroke()
    }

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height, t = scene.time
      ctx.reset()
      ctx.clearRect(0, 0, w, h)
      roundedClip(ctx, w, h, scene.radius)
      ctx.clip()

      // ---- sky, low sun
      var horizon = h * 0.52
      var sky = ctx.createLinearGradient(0, 0, 0, horizon)
      sky.addColorStop(0, "#22405f")
      sky.addColorStop(0.5, "#b8666a")
      sky.addColorStop(0.85, "#e8a06b")
      sky.addColorStop(1, "#f6cf95")
      ctx.fillStyle = sky
      ctx.fillRect(0, 0, w, horizon)

      var sunX = w * 0.70, sunY = h * 0.43, sunR = h * 0.085
      var glow = ctx.createRadialGradient(sunX, sunY, sunR * 0.5, sunX, sunY, sunR * 3.2)
      glow.addColorStop(0, "rgba(255, 225, 170, 0.55)")
      glow.addColorStop(1, "rgba(255, 225, 170, 0)")
      ctx.fillStyle = glow
      ctx.beginPath(); ctx.arc(sunX, sunY, sunR * 3.2, 0, Math.PI * 2); ctx.fill()
      ctx.fillStyle = "#ffe6ae"
      ctx.beginPath(); ctx.arc(sunX, sunY, sunR, 0, Math.PI * 2); ctx.fill()

      // Two gulls, far off, crossing slowly.
      for (var b = 0; b < 2; b++) {
        var span = w * 1.3
        var bx = ((w * 0.15 + b * w * 0.3 + t * 7) % span) - w * 0.15
        var by = h * (0.16 + b * 0.06) + Math.sin(t * 0.5 + b) * 4
        bird(ctx, bx, by, 5 + b * 1.5, Math.sin(t * 3 + b * 2) * 2.5)
      }

      // ---- a far island, to give the sea a scale
      ctx.fillStyle = "rgba(60, 70, 90, 0.55)"
      ctx.beginPath()
      ctx.moveTo(w * 0.80, horizon)
      ctx.quadraticCurveTo(w * 0.86, horizon - h * 0.035, w * 0.92, horizon)
      ctx.closePath()
      ctx.fill()

      // ---- sand
      var sand = ctx.createLinearGradient(0, horizon, 0, h)
      sand.addColorStop(0, "#ead3a8")
      sand.addColorStop(1, "#d3b283")
      ctx.fillStyle = sand
      ctx.fillRect(0, horizon, w, h - horizon)

      // ---- tide: an eleven-second breath in and out
      var shoreBase = h * 0.735, tideAmp = h * 0.045
      var shore = shoreBase + tideAmp * Math.sin(t * 2 * Math.PI / 11)

      // Wet sand where the water has been, fading as it dries.
      var reach = shoreBase + tideAmp + 8
      var wet = ctx.createLinearGradient(0, shore, 0, reach + 6)
      wet.addColorStop(0, "rgba(110, 80, 50, 0.30)")
      wet.addColorStop(1, "rgba(110, 80, 50, 0)")
      shorePath(ctx, w, shore, t, reach + 6)
      ctx.fillStyle = wet
      ctx.fill()

      // ---- the sea
      var sea = ctx.createLinearGradient(0, horizon, 0, shore)
      sea.addColorStop(0, "#2a6a8a")
      sea.addColorStop(0.6, "#3f9fae")
      sea.addColorStop(1, "#8fd3cf")
      ctx.beginPath()
      ctx.moveTo(0, horizon)
      ctx.lineTo(w, horizon)
      for (var x = w; x >= -8; x -= 8) ctx.lineTo(x, shoreY(x, shore, t))
      ctx.closePath()
      ctx.fillStyle = sea
      ctx.fill()

      // Sun on the water.
      var shimmer = ctx.createLinearGradient(0, horizon, 0, shore)
      shimmer.addColorStop(0, "rgba(255, 230, 180, 0.45)")
      shimmer.addColorStop(1, "rgba(255, 230, 180, 0)")
      ctx.fillStyle = shimmer
      ctx.beginPath()
      ctx.moveTo(sunX - sunR * 0.8, horizon)
      ctx.lineTo(sunX + sunR * 0.8, horizon)
      ctx.lineTo(sunX + sunR * 2.2, shore)
      ctx.lineTo(sunX - sunR * 2.2, shore)
      ctx.closePath()
      ctx.fill()

      // Swells: faint lighter lines drifting shoreward.
      ctx.lineWidth = 1.5
      for (var s = 0; s < 4; s++) {
        var frac = ((s / 4) + (t * 0.03)) % 1
        var y = horizon + (shore - horizon) * (0.25 + frac * 0.7)
        var alpha = 0.10 + 0.12 * frac
        ctx.strokeStyle = "rgba(230, 250, 250, " + alpha.toFixed(3) + ")"
        ctx.beginPath()
        for (var sx = 0; sx <= w; sx += 8) {
          var sy = y + 2.5 * Math.sin(sx / (40 + s * 10) + t * 0.7 + s)
          if (sx === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy)
        }
        ctx.stroke()
      }

      // Foam along the edge, and a fainter line just behind it.
      ctx.lineWidth = 3
      ctx.strokeStyle = "rgba(255, 255, 255, 0.85)"
      ctx.beginPath()
      for (var fx = 0; fx <= w + 8; fx += 8) {
        var fy = shoreY(fx, shore, t)
        if (fx === 0) ctx.moveTo(fx, fy); else ctx.lineTo(fx, fy)
      }
      ctx.stroke()
      ctx.lineWidth = 2
      ctx.strokeStyle = "rgba(255, 255, 255, 0.30)"
      ctx.beginPath()
      for (var gx = 0; gx <= w + 8; gx += 8) {
        var gy = shoreY(gx, shore - 9, t + 1.4)
        if (gx === 0) ctx.moveTo(gx, gy); else ctx.lineTo(gx, gy)
      }
      ctx.stroke()

      // ---- the palm
      var baseX = w * 0.23, baseY = h * 0.87
      var topX = w * 0.31, topY = h * 0.27
      var ctrlX = w * 0.19, ctrlY = h * 0.56
      var scale = h / 400
      // Shade under the tree, on the sand.
      ctx.fillStyle = "rgba(90, 65, 40, 0.18)"
      ctx.beginPath()
      ctx.ellipse(baseX + 20 * scale - 46 * scale, baseY + 2 - 7 * scale, 92 * scale, 14 * scale)
      ctx.fill()

      var segments = 16
      var prev = null
      for (var i = 0; i <= segments; i++) {
        var u = i / segments
        var px = (1 - u) * (1 - u) * baseX + 2 * (1 - u) * u * ctrlX + u * u * topX
        var py = (1 - u) * (1 - u) * baseY + 2 * (1 - u) * u * ctrlY + u * u * topY
        if (prev) {
          ctx.lineWidth = (17 - 9 * u) * scale
          ctx.lineCap = "round"
          ctx.strokeStyle = i % 2 === 0 ? "#7c563a" : "#8d6547"
          ctx.beginPath(); ctx.moveTo(prev.x, prev.y); ctx.lineTo(px, py); ctx.stroke()
          // Ring at each joint, on the lit side.
          ctx.lineWidth = 1
          ctx.strokeStyle = "rgba(60, 38, 22, 0.35)"
          ctx.beginPath(); ctx.arc(px, py, (8.5 - 4.5 * u) * scale, Math.PI * 0.9, Math.PI * 1.9); ctx.stroke()
        }
        prev = { x: px, y: py }
      }

      // Fronds, back ones first, each swaying on its own phase.
      var angles = [-160, -128, -96, -64, -32, 0, 28, 200, 170]
      var length = h * 0.20
      for (var f = 0; f < angles.length; f++) {
        var sway = 3.2 * Math.sin(t * 0.55 + f * 0.9)
        var angle = (angles[f] + sway) * Math.PI / 180
        var back = f >= 7
        var fill = back ? "rgba(36, 92, 62, 0.85)"
          : (f % 2 === 0 ? "#2f8a55" : "#3aa065")
        var droop = length * (0.35 + 0.1 * Math.sin(t * 0.4 + f))
        frond(ctx, topX, topY, angle, length * (back ? 0.75 : 1), droop, length * 0.15, fill)
      }

      // Coconuts, tucked where the fronds meet.
      ctx.fillStyle = "#5c3b22"
      var nuts = [[-6, 4], [4, 6], [-1, 10]]
      for (var n = 0; n < nuts.length; n++) {
        ctx.beginPath()
        ctx.arc(topX + nuts[n][0] * scale, topY + nuts[n][1] * scale, 4.2 * scale, 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }

  // ---------------------------------------------------------------- words
  //
  // Bottom left: that you are away, and until when. Bottom right: the ways
  // out. Fixed ink colours because they sit on sand, not on the theme.
  readonly property color ink: "#4a3826"
  readonly property color dimInk: "#7b6449"

  Column {
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.leftMargin: scene.host.sp(18)
    anchors.bottomMargin: scene.host.sp(16)
    spacing: scene.host.sp(2)

    Text {
      text: "󱁕  On vacation"
      color: scene.ink
      font.family: scene.host.fontFamily
      font.pixelSize: scene.host.fontHeading
      font.bold: true
      renderType: Text.NativeRendering
    }

    Text {
      text: {
        var until = Model.vacationUntilLabel(scene.untilMs, scene.nowMs, scene.host.use24Hour)
        var left = Model.vacationRemainingLabel(scene.untilMs, scene.nowMs)
        return left.length > 0 ? until + "  ·  " + left : until
      }
      color: scene.dimInk
      font.family: scene.host.fontFamily
      font.pixelSize: scene.host.fontBodySmall
      renderType: Text.NativeRendering
    }
  }

  Row {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: scene.host.sp(16)
    anchors.bottomMargin: scene.host.sp(14)
    spacing: scene.host.sp(6)

    Button {
      text: "Change end"
      iconText: "󰃰"  // nf-md-calendar_clock
      foreground: scene.dimInk
      accent: scene.host.accent
      fontFamily: scene.host.fontFamily
      fontSize: scene.host.fontBodySmall
      onClicked: scene.host.openVacationDialog()
    }

    Button {
      text: "End vacation"
      iconText: "󰃭"  // nf-md-calendar
      bordered: true
      foreground: scene.ink
      accent: scene.host.accent
      fontFamily: scene.host.fontFamily
      fontSize: scene.host.fontBodySmall
      onClicked: scene.host.endVacation()
    }
  }
}
