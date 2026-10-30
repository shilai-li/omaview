import QtQuick
import Quickshell.Hyprland
import Quickshell.Wayland

// A window's picture. Live capture only delivers a frame when the window
// redraws, and a window on another workspace may sit without redrawing, so
// this grabs one still frame first and goes live once it has one, if
// `stayLive`.
//
// Hyprland only renders a window into a capture while it overlaps its
// monitor; one scrolled fully off screen in a scrolling layout gives nothing.
// So the source stays attached while the overview is closed: the last frame
// is kept, and such a window shows how it last looked.
//
// A capture Hyprland refuses (the window was off screen at that moment, or
// it resized mid-capture, as when a window opens or closes beside it) ends
// Quickshell's recording for good: the view drops its picture at once, and
// every later request fails; detaching and re-attaching the same view does
// not bring it back. So the view is made by a Loader, and a stopped or still
// empty capture is started afresh by making a new one, but only when that can
// work: the overview showing and the window on screen, by a fresh answer. A
// window still resizing can refuse that one too, so with a picture to fall
// back on it is tried again quickly; `lastFrame`, a copy under the view, shows
// how the window last looked meanwhile.
//
// Captures also arrive opaque, so a translucent terminal comes out flat, and
// Hyprland's opacity on a whole window is left out. With `glass` on (a
// terminal) or `windowAlpha` under 1, shaders/terminal-glass.frag puts the
// blurred wallpaper that was behind it back through.
Item {
  id: capture

  // The toplevel's `wayland` handle, or null when there is no window.
  property var source: null
  // Whether the overview is showing; nothing is captured while it is not.
  property bool active: false
  // Keep updating after the first frame. Off for pictures that only need to
  // be recognisable, like the workspace tiles.
  property bool stayLive: true
  // Whether the window overlaps the screen, where Hyprland will capture it.
  property bool onScreen: false
  // The window's real size, so a kept frame shows at the window's scale.
  property size windowSize: Qt.size(0, 0)

  // The glass: on for a translucent terminal, with the blurred wallpaper item
  // and the part of it (in its own coordinates) that was behind the window.
  property bool glass: false
  property Item backdrop: null
  property rect backdropRect: Qt.rect(0, 0, 0, 0)
  property color glassBackground: "black"
  property real glassAlpha: 1
  // Hyprland's opacity for the whole window, which a capture leaves out.
  property real windowAlpha: 1

  // Off for one turn of the event loop: the view is destroyed and made anew.
  property bool restarting: false
  readonly property var screencopy: viewLoader.item
  readonly property bool hasContent: !!capture.screencopy && capture.screencopy.hasContent
  // Something to show: the view's picture, or the copy kept of it.
  readonly property bool hasPicture: capture.mirrorOf ? capture.mirrorOf.hasPicture
    : capture.hasContent || capture.kept
  // Another capture to show the picture of, instead of capturing.
  property Item mirrorOf: null
  readonly property Item picture: rawPicture
  function captureFrame() { if (capture.screencopy) capture.screencopy.captureFrame() }

  // The view's picture, copied now and then, for when the view loses it.
  // Always drawn, under the view: a copy not drawn would not be updated. It
  // stays at the size the window had, from the top left, as a window's content
  // does when it resizes: stretched to the new shape, it reads as broken.
  // Only a frame that has been up a while is copied: a new window's first is
  // from the middle of its open animation, half faded in.
  property bool kept: false
  property size keptSize: Qt.size(0, 0)
  readonly property real windowScale: capture.windowSize.width > 0 ? capture.width / capture.windowSize.width : 0

  Timer {
    interval: 500
    repeat: true
    running: capture.active && capture.hasContent
    onTriggered: {
      capture.keptSize = capture.windowSize
      capture.kept = true
      lastFrame.scheduleUpdate()
    }
  }

  // The picture alone, without the glass, for a tile to mirror (`mirrorOf`).
  Item {
    id: rawPicture
    anchors.fill: parent
    ShaderEffectSource {
      id: lastFrame
      width: capture.windowScale > 0 && capture.keptSize.width > 0 ? capture.keptSize.width * capture.windowScale : capture.width
      height: capture.windowScale > 0 && capture.keptSize.height > 0 ? capture.keptSize.height * capture.windowScale : capture.height
      sourceItem: viewLoader
      live: false
    }

    Loader {
      id: viewLoader
      anchors.fill: parent
      active: !capture.restarting
      sourceComponent: ScreencopyView {
        captureSource: capture.source
        live: capture.active && !capture.paused && !!captureSource && hasContent && capture.stayLive
        onHasContentChanged: capture.contentChanged(hasContent)
      }
    }
  }

  // The current workspace's tile has its windows' pictures in the spread
  // already: it shows those rather than capturing every window twice, and
  // lays its own glass over them.
  ShaderEffectSource {
    anchors.fill: parent
    visible: !!capture.mirrorOf
    sourceItem: capture.mirrorOf ? capture.mirrorOf.picture : null
  }
  // The recording ended (a refused capture); restart it when it can work.
  // Told by the picture going: ScreencopyView never emits its `stopped`.
  property bool ended: false

  function contentChanged(has) {
    if (has) {
      capture.grabbing = false
      capture.restarts = 0
    } else if (!capture.restarting && !!capture.source) {
      capture.ended = true
    }
  }

  // Held while windows may slide off screen under a live capture, which
  // Hyprland would refuse, ending the recording: while the overview scrolls
  // the layout behind itself to photograph windows that are off screen, and
  // while it closes, as a choice can scroll the layout too. grab() still
  // works.
  property bool paused: false

  // One fresh picture now, the window being on screen for it (the overview
  // has just scrolled it there). A recording that ended is started afresh
  // first. `grabbing` is on until the frame is in: for a capture that has no
  // picture yet, until one lands (a few tries at most); for one that has,
  // after a moment, as a replaced frame gives no signal.
  property bool grabbing: false
  property int grabTries: 0
  function grab() {
    if (!capture.source) return
    capture.grabbing = true
    capture.grabTries = 0
    if (capture.ended) {
      capture.ended = false
      capture.restarting = true
      Qt.callLater(function() { capture.restarting = false })
    } else if (capture.hasContent) {
      capture.captureFrame()
      grabSettle.restart()
    } else {
      capture.captureFrame()
    }
  }
  Timer {
    id: grabSettle
    interval: 120
    onTriggered: capture.grabbing = false
  }

  Timer {
    interval: 40
    repeat: true
    running: capture.grabbing && capture.active && !capture.restarting && !capture.hasContent
    onTriggered: {
      if (++capture.grabTries > 14) capture.grabbing = false
      else capture.captureFrame()
    }
  }

  // A limited run of fresh starts, enough to outlast a resize, so a window
  // Hyprland will not capture at all is not asked about constantly.
  property int restarts: 0

  function restart() {
    capture.ended = false
    capture.restarts++
    capture.restarting = true
    Qt.callLater(function() { capture.restarting = false })
  }

  readonly property bool canRestart: capture.active && !capture.paused && capture.onScreen && !!capture.source
    && !capture.restarting && capture.restarts < 8

  onCanRestartChanged: if (capture.canRestart && capture.ended) restartWait.start()
  onEndedChanged: if (capture.ended) restartWait.start()

  // Ask where everything is, then judge.
  Timer {
    id: restartWait
    interval: 30
    onTriggered: {
      Hyprland.refreshToplevels()
      restartCheck.restart()
    }
  }

  Timer {
    id: restartCheck
    interval: 40
    onTriggered: if (capture.canRestart && capture.ended) capture.restart()
  }

  // A background still while the overview is closed: the root bumps the tick
  // after the desktop changes, and a window on screen takes one frame. Off
  // screen, Hyprland would refuse it, so the kept frame is left alone. Only
  // once it has a picture: before the first opening there is no recording
  // yet, and asking only logs a warning.
  property int snapshotTick: 0
  onSnapshotTickChanged: if (!capture.active && !!capture.source && capture.onScreen
    && capture.hasContent && !capture.ended) capture.captureFrame()

  // The recording comes up asynchronously after the source is set, and
  // asking before then does nothing; so ask again until a frame lands. Ten
  // misses in a row on screen mean the recording is gone: start a new one,
  // after three when a kept frame makes that cost nothing.
  property int attempts: 0
  onSourceChanged: {
    capture.attempts = 0
    capture.restarts = 0
  }
  onActiveChanged: {
    capture.attempts = 0
    capture.restarts = 0
    if (!capture.active) {
      capture.grabbing = false
      return
    }
    if (capture.ended && capture.canRestart) restartWait.start()
    // A still kept from an earlier opening refreshes on the next.
    else if (capture.hasContent && !capture.stayLive) capture.captureFrame()
  }

  Timer {
    interval: 50
    repeat: true
    running: capture.active && !capture.paused && capture.onScreen && !!capture.source && !!capture.screencopy && !capture.hasContent && capture.attempts < 40
    onTriggered: {
      if (capture.ended) return
      capture.attempts++
      if (capture.attempts % (capture.kept ? 3 : 10) === 0 && capture.canRestart) capture.restart()
      else capture.captureFrame()
    }
  }

  // Windows resizing around a capture can use up those tries at once, and
  // the view stays empty though the window is plainly there: try again.
  Timer {
    interval: 3000
    repeat: true
    running: capture.active && !capture.paused && capture.onScreen && !!capture.source && !capture.hasContent
    onTriggered: {
      capture.attempts = 0
      capture.restarts = 0
    }
  }

  // A terminal's own see-through background, or Hyprland's opacity on the
  // whole window (`windowAlpha`, from a window rule): either needs the
  // wallpaper behind.
  readonly property bool keyGlassOn: capture.glass && capture.glassAlpha < 1
  readonly property bool glassOn: (capture.keyGlassOn || capture.windowAlpha < 0.999)
    && !!capture.backdrop && capture.backdrop.visible && capture.hasPicture

  // Only a texture for the shader, never drawn itself.
  ShaderEffectSource {
    id: wallpaperPiece
    visible: false
    live: capture.glassOn
    sourceItem: capture.glassOn ? capture.backdrop : null
    sourceRect: capture.backdropRect
  }

  layer.enabled: capture.glassOn
  layer.effect: ShaderEffect {
    property var backdrop: wallpaperPiece
    property color background: capture.glassBackground
    property real alpha: capture.glassAlpha
    property real tolerance: 0.035
    property real keyGlass: capture.keyGlassOn ? 1 : 0
    property real windowAlpha: capture.windowAlpha
    fragmentShader: Qt.resolvedUrl("shaders/terminal-glass.frag.qsb")
  }
}
