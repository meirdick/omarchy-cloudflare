import QtQuick
import qs.Commons

// The Cloudflare mark drawn from primitives rather than an SVG. A 16px bar
// slot is small enough that Qt's SVG rasterizer loses the thin parts of the
// cloud outline; a Canvas path stays crisp at any slot size, and recolors with
// the theme without a second asset for light backgrounds.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool crossed: false
  property bool warning: false
  property bool busy: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Canvas {
    id: cloud
    anchors.fill: parent
    antialiasing: true
    opacity: root.busy ? 0.55 : 1.0

    Connections {
      target: root
      function onColorChanged() { cloud.requestPaint() }
      function onIconSizeChanged() { cloud.requestPaint() }
    }

    Behavior on opacity {
      NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }

    // Traced against the official mark: a flat-bottomed cloud whose left lobe
    // sits lower than the right, with a tail extending past the right lobe.
    // Coordinates are a 0..1 unit box so the shape scales with the slot.
    onPaint: {
      var ctx = getContext("2d")
      var s = Math.min(width, height)
      var ox = (width - s) / 2
      var oy = (height - s) / 2
      function px(u) { return ox + u * s }
      function py(v) { return oy + v * s }

      ctx.reset()
      ctx.beginPath()
      // Flat base, left to right.
      ctx.moveTo(px(0.10), py(0.72))
      // Left shoulder rising into the small lobe.
      ctx.bezierCurveTo(px(0.02), py(0.72), px(0.00), py(0.60), px(0.09), py(0.55))
      // Body of the cloud: the large lobe.
      ctx.bezierCurveTo(px(0.10), py(0.36), px(0.30), py(0.26), px(0.44), py(0.35))
      ctx.bezierCurveTo(px(0.52), py(0.20), px(0.74), py(0.22), px(0.78), py(0.40))
      // Tail running out to the right edge and back along the base.
      ctx.bezierCurveTo(px(0.92), py(0.40), px(0.98), py(0.52), px(0.94), py(0.62))
      ctx.lineTo(px(0.90), py(0.72))
      ctx.closePath()

      ctx.fillStyle = root.color
      ctx.fill()
    }
  }

  // "Signed out" state. Drawn over the mark rather than swapping it out, so
  // the icon keeps the same silhouette and slot width in every state.
  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: Math.round(root.iconSize * 1.15)
    height: Math.max(1, Math.round(root.iconSize * 0.10))
    radius: height / 2
    rotation: -45
    color: root.color
  }

  // Corner badge for a failed deployment or a Worker over its error-rate
  // threshold. Small enough not to disturb the mark, urgent-colored so it
  // reads at a glance from across the bar.
  Rectangle {
    visible: root.warning
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -Math.round(root.iconSize * 0.06)
    anchors.topMargin: -Math.round(root.iconSize * 0.06)
    width: Math.max(3, Math.round(root.iconSize * 0.34))
    height: width
    radius: width / 2
    color: root.badgeColor
  }
}
