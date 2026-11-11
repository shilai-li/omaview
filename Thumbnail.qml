import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import "Layout.js" as Layout

// One window in the spread: a live capture that starts exactly over the real
// window, glides into its slot, and can be clicked, closed or dragged onto a
// workspace. One delegate per Hyprland toplevel; it hides while its window
// is somewhere else.
Item {
  id: thumb

  required property var modelData
  property var host
  property var overview

  readonly property var toplevel: thumb.modelData
  // Index, real place and slot read together from the one layout the screen
  // works out (Overview.qml `layout`): read one by one, a thumbnail could
  // see a new list with an old index for a moment, and lose its slot.
  readonly property var entry: {
    var l = thumb.host.layout
    var i = l.windows.indexOf(thumb.toplevel)
    return i < 0 ? null : { index: i, real: l.rects[i], slot: l.slots[i] }
  }
  readonly property int slotIndex: thumb.entry ? thumb.entry.index : -1
  readonly property bool present: !!thumb.entry
  readonly property var real: thumb.entry ? thumb.entry.real : null
  readonly property var slot: thumb.entry ? thumb.entry.slot : null
  readonly property bool selected: thumb.present && thumb.host.cursorIndex === thumb.slotIndex
  readonly property bool settled: thumb.overview.settled
  // The screen's motion, for a thumbnail on show. One whose window is on
  // another workspace reads a constant instead, so the dozens of them do no
  // work on each frame of the opening.
  readonly property real travel: thumb.present ? thumb.host.travel : 1
  readonly property real thumbFade: thumb.present ? thumb.host.thumbFade : 1
  // The dragged window is over this one: let go and they trade places.
  readonly property bool swapping: !!thumb.host.swapTarget && thumb.host.swapTarget === thumb.toplevel

  // Hyprland's focus history: 0 is the focused window. Kept as the stacking
  // order so the glide in and out overlaps the way the windows do.
  readonly property int focusRank: {
    var ipc = thumb.toplevel ? thumb.toplevel.lastIpcObject : null
    var n = ipc && isFinite(Number(ipc.focusHistoryID)) ? Number(ipc.focusHistoryID) : 50
    return Math.max(0, Math.min(100, n))
  }

  visible: thumb.present && !!thumb.slot
  z: thumb.dragging ? 1000 : 200 - thumb.focusRank

  // The slot, animated only when it moves while the overview is open (a
  // window closed or arrived); on open the thumbnail starts from it at once.
  // Set by place() rather than bound: a thumbnail getting a slot has no place
  // of its own to animate from. Brought here by a change of workspace, it
  // starts from its window in that workspace's tile; a new window fades in
  // where it belongs.
  property real slotX: 0
  property real slotY: 0
  property real slotW: 0
  property real slotH: 0
  property real toX: 0
  property real toY: 0
  property real toW: 0
  property real toH: 0
  property int moveMs: Style.duration(200)
  property bool placed: false
  // 0 to 1 as a new window fades in.
  property real entered: 1

  function place() {
    var s = thumb.slot
    if (!s) {
      thumb.placed = false
      return
    }
    var wasPlaced = thumb.placed
    var same = s.x === thumb.toX && s.y === thumb.toY && s.w === thumb.toW && s.h === thumb.toH
    thumb.placed = true
    thumb.toX = s.x
    thumb.toY = s.y
    thumb.toW = s.w
    thumb.toH = s.h
    if (thumb.settled && wasPlaced) {
      if (same) return
      thumb.moveMs = Style.duration(200)
      slotMove.restart()
      return
    }
    slotMove.stop()
    var from = thumb.settled && thumb.host.switchingWorkspace() ? thumb.host.tileRectFor(thumb.toplevel) : null
    thumb.slotX = from ? from.x : s.x
    thumb.slotY = from ? from.y : s.y
    thumb.slotW = from ? from.w : s.w
    thumb.slotH = from ? from.h : s.h
    if (from) {
      thumb.moveMs = Style.duration(280)
      slotMove.restart()
    } else if (thumb.settled) {
      enterFade.restart()
    }
  }
  onSlotChanged: thumb.place()
  Component.onCompleted: thumb.place()

  ParallelAnimation {
    id: slotMove
    NumberAnimation { target: thumb; property: "slotX"; to: thumb.toX; duration: thumb.moveMs; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    NumberAnimation { target: thumb; property: "slotY"; to: thumb.toY; duration: thumb.moveMs; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    NumberAnimation { target: thumb; property: "slotW"; to: thumb.toW; duration: thumb.moveMs; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    NumberAnimation { target: thumb; property: "slotH"; to: thumb.toH; duration: thumb.moveMs; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
  }

  NumberAnimation {
    id: enterFade
    target: thumb
    property: "entered"
    from: 0
    to: 1
    duration: Style.duration(200)
    easing.type: Easing.Bezier
    easing.bezierCurve: Style.easeOut
  }

  // ------------------------------------------------------------ dragging

  property bool pressed: false
  property bool dragging: false
  property real pressX: 0
  property real pressY: 0
  // The pointer, in the surface's coordinates, and where on the thumbnail it
  // took hold, as fractions, so the window stays under the same spot.
  property real pointerX: 0
  property real pointerY: 0
  property real grabX: 0.5
  property real grabY: 0.5
  // 1 while held, eased back to 0 when let go over nothing.
  property real dragBlend: 0
  // Sent to a workspace: fades out until Hyprland takes the window away.
  property bool sent: false

  NumberAnimation {
    id: returnAnim
    target: thumb
    property: "dragBlend"
    to: 0
    duration: Style.duration(180)
    easing.type: Easing.Bezier
    easing.bezierCurve: Style.easeOut
  }

  // A window that Hyprland did not take after all comes back.
  Timer {
    id: sentTimeout
    interval: 600
    onTriggered: {
      thumb.sent = false
      returnAnim.restart()
    }
  }

  onPresentChanged: {
    if (thumb.present) return
    // Gone from this workspace (moved, closed): forget the drag.
    sentTimeout.stop()
    returnAnim.stop()
    thumb.sent = false
    thumb.dragging = false
    thumb.dragBlend = 0
    if (thumb.host.dragged === thumb.toplevel) thumb.host.dragged = null
  }

  // Shrinks toward tile size as the pointer nears the workspace strip.
  readonly property real dragScale: {
    var reach = Style.space(260)
    var t = Layout.clamp01((thumb.pointerY - thumb.host.stripBottom) / reach)
    var small = Math.min(1, (thumb.host.tileSize.w * 1.3) / Math.max(1, thumb.slotW))
    return Layout.lerp(small, 1, t)
  }

  // ------------------------------------------------------------ geometry

  // Where the window really is. A choice made in the overview can move it
  // (scrolled into view, a maximized neighbour stepping back), and Hyprland's
  // answer lands while the thumbnails are already gliding home; easing to it
  // keeps the glide from changing course in one frame.
  readonly property bool hasReal: !!thumb.real && thumb.real.w > 0 && thumb.real.h > 0
  readonly property bool sized: {
    var size = ((thumb.toplevel && thumb.toplevel.lastIpcObject) || {}).size
    return !!size && size[0] > 0 && size[1] > 0
  }
  property real realX: thumb.real ? thumb.real.x : 0
  property real realY: thumb.real ? thumb.real.y : 0
  property real realW: thumb.real ? thumb.real.w : 0
  property real realH: thumb.real ? thumb.real.h : 0
  readonly property bool closing: !thumb.overview.opened && thumb.overview.mapped
  Behavior on realX { enabled: thumb.closing; NumberAnimation { duration: Style.duration(120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
  Behavior on realY { enabled: thumb.closing; NumberAnimation { duration: Style.duration(120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
  Behavior on realW { enabled: thumb.closing; NumberAnimation { duration: Style.duration(120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
  Behavior on realH { enabled: thumb.closing; NumberAnimation { duration: Style.duration(120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

  // A window wholly off the screen (scrolled away in a scrolling layout) has
  // no place on it to glide to or from: flying there crosses the whole
  // screen in a blink. Its thumbnail fades and settles in its slot instead.
  readonly property bool offscreen: thumb.hasReal
    && (thumb.real.x + thumb.real.w <= 0 || thumb.real.x >= thumb.host.width
      || thumb.real.y + thumb.real.h <= 0 || thumb.real.y >= thumb.host.height)
  readonly property bool glides: thumb.hasReal && !thumb.offscreen

  readonly property real baseX: thumb.glides ? Layout.lerp(thumb.realX, thumb.slotX, thumb.travel) : thumb.slotX
  readonly property real baseY: thumb.glides ? Layout.lerp(thumb.realY, thumb.slotY, thumb.travel) : thumb.slotY
  readonly property real baseW: thumb.glides ? Layout.lerp(thumb.realW, thumb.slotW, thumb.travel) : thumb.slotW
  readonly property real baseH: thumb.glides ? Layout.lerp(thumb.realH, thumb.slotH, thumb.travel) : thumb.slotH
  readonly property real heldW: thumb.slotW * thumb.dragScale
  readonly property real heldH: thumb.slotH * thumb.dragScale

  x: Layout.lerp(thumb.baseX, thumb.pointerX - thumb.grabX * thumb.heldW, thumb.dragBlend)
  y: Layout.lerp(thumb.baseY, thumb.pointerY - thumb.grabY * thumb.heldH, thumb.dragBlend)
  width: Layout.lerp(thumb.baseW, thumb.heldW, thumb.dragBlend)
  height: Layout.lerp(thumb.baseH, thumb.heldH, thumb.dragBlend)
  rotation: -2 * thumb.dragBlend
  // Never from 0: a fading thumbnail starts a little small, as entrances do.
  scale: (thumb.glides ? 1 : Layout.lerp(0.94, 1, thumb.travel)) * Layout.lerp(0.94, 1, thumb.entered)
  // A gliding thumbnail hands over to its real window during the last
  // quarter of the way home (and takes over during the first quarter out):
  // a capture never looks quite like the window as Hyprland draws it (its
  // blur, its opacity), and switching in one frame showed as a pop.
  opacity: (thumb.glides ? Layout.clamp01(thumb.travel * 4) : thumb.travel)
    * thumb.thumbFade * thumb.entered
    * (thumb.sent ? 0 : 1) * (thumb.host.dragged && !thumb.dragging && !thumb.swapping ? 0.55 : 1)
  // Eases the dim of a drag and the fade of a window sent away; the open and
  // close already move frame by frame on the reveal clock.
  Behavior on opacity { enabled: thumb.settled; NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

  // ------------------------------------------------------------ drawing

  // Lifted off the desktop: a soft shadow that grows in as the window leaves
  // its real place, where Hyprland already draws one. An analytic shadow,
  // cheap enough for every window at once.
  RectangularShadow {
    anchors.fill: parent
    radius: thumb.overview.windowRadius
    blur: Style.space(36) * (thumb.dragging ? 1.4 : 1)
    offset.y: Style.space(14)
    spread: 0
    color: thumb.overview.shadow
    opacity: thumb.travel
  }

  // The hover / cursor ring, outside the window with a gap.
  Rectangle {
    readonly property int inset: Style.space(3)
    anchors.fill: parent
    anchors.margins: -(inset + border.width)
    radius: thumb.overview.windowRadius > 0 ? thumb.overview.windowRadius + inset + border.width : 0
    color: "transparent"
    border.width: Style.space(3)
    border.color: thumb.overview.accent
    visible: (thumb.selected && thumb.travel > 0.5 && !thumb.host.dragged) || thumb.dragging || thumb.swapping
  }

  readonly property real cornerRadius: thumb.overview.windowRadius * Layout.clamp01(thumb.travel * 2)

  // Under the picture: what shows of a window with none yet.
  Rectangle {
    anchors.fill: parent
    radius: thumb.cornerRadius
    color: thumb.overview.windowFill
  }

  // The picture is drawn at its slot's size and scaled to wherever the
  // thumbnail is on its way. Its layer (rounded corners, glass) then keeps
  // one texture for the whole motion: sized by the moving thumbnail, it was
  // made anew and redrawn for every window on every frame.
  Item {
    id: pane
    width: Math.max(1, thumb.toW)
    height: Math.max(1, thumb.toH)
    transform: Scale {
      xScale: thumb.width / pane.width
      yScale: thumb.height / pane.height
    }

    WindowCapture {
      id: capture
      anchors.fill: parent
      // Never a window without a size: Hyprland reports one squeezed to
      // nothing (a crowded dwindle layout) as 0 or less, and a capture of it
      // is a buffer Wayland rejects, which takes the whole shell down.
      // Kept on a window gone to another workspace, which keeps its last
      // frame (nothing is asked of it there: it is not on screen, and not
      // live): it is back at once on return, and a workspace left mid-pass
      // shows it in its tile (Overview.qml awayHeld).
      source: (thumb.present ? thumb.hasReal : thumb.sized) ? thumb.toplevel.wayland : null
      active: thumb.overview.mapped
      // Held while the overview photographs off-screen windows, and while it
      // closes (a choice may scroll the layout); a window off screen is never
      // captured live, only grabbed while scrolled into view.
      paused: thumb.host.passing || !thumb.overview.opened
      // Stills only while it opens: the motion is too quick to see a window
      // change, and the frames are better spent on the motion.
      holdLive: !thumb.settled
      stayLive: thumb.present && !thumb.offscreen
      // The wallpaper from behind the thumbnail itself, at its own scale, so
      // the thumbnail is a pane of glass where it sits. At either end of the
      // glide it is over its real window, and that glass lines up.
      glass: thumb.overview.isTerminal(thumb.toplevel)
      backdrop: thumb.host.windowGlass
      backdropRect: thumb.host.wallpaperBehind({ x: thumb.x, y: thumb.y, w: thumb.width, h: thumb.height })
      glassBackground: thumb.overview.background
      glassAlpha: thumb.overview.terminalAlpha
      windowAlpha: thumb.overview.windowAlpha(thumb.toplevel)
      snapshotTick: thumb.overview.snapshotTick
      onScreen: thumb.hasReal && !thumb.offscreen
      windowSize: thumb.hasReal ? Qt.size(thumb.real.w, thumb.real.h) : Qt.size(0, 0)
      cornerRadius: thumb.cornerRadius
      shownSize: Qt.size(thumb.width, thumb.height)
      pixelRatio: thumb.host.pixelRatio
      layerSize: Qt.size(Math.ceil(pane.width * thumb.host.pixelRatio), Math.ceil(pane.height * thumb.host.pixelRatio))
    }
  }

  // The hairline edge, where the ring is not.
  Rectangle {
    anchors.fill: parent
    radius: thumb.cornerRadius
    color: "transparent"
    border.width: 1
    border.color: thumb.overview.hairline
    visible: !(thumb.selected || thumb.dragging)
  }

  // No picture yet (a window Hyprland will not capture while it is off
  // screen): the app's icon and name, so it is still recognisable.
  Column {
    anchors.centerIn: parent
    width: parent.width - Style.space(16)
    spacing: Style.space(10)
    visible: !capture.hasPicture

    IconImage {
      anchors.horizontalCenter: parent.horizontalCenter
      readonly property int size: Math.min(Style.space(64), Math.round(thumb.height * 0.3))
      implicitSize: size
      visible: thumb.appIcon !== "" && size >= Style.space(16)
      source: thumb.appIcon
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: thumb.appName
      color: thumb.overview.softText
      font.family: thumb.overview.fontFamily
      font.pixelSize: Style.font.subtitle
    }
  }

  readonly property var appEntry: {
    var ipc = (thumb.toplevel && thumb.toplevel.lastIpcObject) || {}
    var id = String((thumb.toplevel && thumb.toplevel.wayland && thumb.toplevel.wayland.appId) || ipc["class"] || "")
    return id ? thumb.overview.appEntryFor(id) : null
  }
  readonly property string appName: {
    if (thumb.appEntry && thumb.appEntry.name) return String(thumb.appEntry.name)
    var ipc = (thumb.toplevel && thumb.toplevel.lastIpcObject) || {}
    return String((thumb.toplevel && thumb.toplevel.wayland && thumb.toplevel.wayland.appId) || ipc["class"] || "")
  }
  readonly property string appIcon: thumb.appEntry && thumb.appEntry.icon ? Quickshell.iconPath(String(thumb.appEntry.icon), true) : ""

  // Titles mostly name their app already, so the title alone.
  readonly property string caption: String((thumb.toplevel && thumb.toplevel.title) || "") || thumb.appName

  // For the overview's photo pass (Overview.qml): take a picture now that
  // the window has been scrolled on screen, and say when one has landed.
  function grabPicture() { capture.grab() }
  readonly property bool grabbing: capture.grabbing

  // The capture, for the workspace tile to show rather than capturing the
  // window a second time.
  readonly property Item picture: capture
  readonly property bool hasPicture: capture.hasPicture

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height + thumb.host.labelGap
    width: Math.max(parent.width, Style.space(120))
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
    textFormat: Text.PlainText
    text: thumb.caption
    color: thumb.selected ? thumb.overview.foreground : thumb.overview.softText
    font.family: thumb.overview.fontFamily
    font.pixelSize: Style.font.subtitle
    font.bold: thumb.selected
    opacity: Layout.clamp01(thumb.travel * 2 - 1) * (1 - thumb.dragBlend)
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: thumb.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    enabled: thumb.overview.opened

    // Hover selects only once the pointer has really moved (Overview.qml).
    onPositionChanged: function(event) {
      var p = mouse.mapToItem(null, event.x, event.y)
      if (!thumb.host.dragged && !thumb.selected && thumb.present) thumb.host.hovered(thumb.slotIndex, p)
      if (!thumb.pressed) return
      thumb.pointerX = p.x
      thumb.pointerY = p.y
      if (!thumb.dragging && Math.hypot(p.x - thumb.pressX, p.y - thumb.pressY) > Style.space(6)) {
        returnAnim.stop()
        thumb.dragging = true
        thumb.dragBlend = 1
        thumb.host.dragged = thumb.toplevel
      }
      if (thumb.dragging) thumb.host.dragOver(p.x, p.y)
    }
    onPressed: function(event) {
      if (event.button !== Qt.LeftButton) return
      var p = mouse.mapToItem(null, event.x, event.y)
      thumb.pressed = true
      thumb.pressX = p.x
      thumb.pressY = p.y
      thumb.pointerX = p.x
      thumb.pointerY = p.y
      thumb.grabX = Layout.clamp01(event.x / Math.max(1, mouse.width))
      thumb.grabY = Layout.clamp01(event.y / Math.max(1, mouse.height))
    }
    onReleased: function(event) {
      if (event.button !== Qt.LeftButton) return
      thumb.pressed = false
      if (!thumb.dragging) return
      thumb.dragging = false
      thumb.host.dragged = null
      if (thumb.host.drop(thumb.toplevel)) {
        thumb.sent = true
        sentTimeout.restart()
      } else {
        returnAnim.restart()
      }
    }
    onCanceled: {
      thumb.pressed = false
      if (!thumb.dragging) return
      thumb.dragging = false
      thumb.host.dragged = null
      thumb.host.dropTarget = ""
      thumb.host.swapTarget = null
      returnAnim.restart()
    }
    onClicked: function(event) {
      if (thumb.dragBlend > 0) return
      if (event.button === Qt.MiddleButton) thumb.overview.closeWindow(thumb.toplevel)
      else thumb.overview.activate(thumb.toplevel)
    }
  }
}
