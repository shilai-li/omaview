import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Layout.js" as Layout

// The overview: a fullscreen layer-shell surface on every output, each showing
// its own monitor's windows spread out and its workspaces along the top. kind
// "overlay" with keepLoaded, so the surfaces stay alive in omarchy-shell
// between summons and open without a cold start.
//
// This file owns the lifecycle (one `reveal` clock every surface follows) and
// everything sent to Hyprland. Overview.qml draws one screen, Thumbnail.qml
// one window, Layout.js holds the geometry.
Item {
  id: root

  // Injected by the host on load.
  property var shell
  property var manifest
  property string omarchyPath

  readonly property string pluginId: (root.manifest && root.manifest.id) || "shilai_li.omaview"

  // `opened` is where we are going, `mapped` whether the surfaces are up.
  // They differ while the closing motion plays: the surfaces stay mapped
  // until the thumbnails are back over their windows.
  property bool opened: false
  property bool mapped: false

  // 0 = every thumbnail sits exactly over its real window, 1 = spread out.
  // One clock for every screen, so all of them open and close together.
  property real reveal: 0

  // How the next close looks. "glide" flies the thumbnails back onto their
  // windows; "fade" is for a close that switched workspace, where the
  // windows they would fly back to are no longer on screen.
  property string exitMode: "glide"

  // The monitor that had focus on open: its surface takes the keyboard.
  property string focusMonitor: ""

  readonly property int openMs: Style.duration(220)
  readonly property int closeMs: Style.duration(150)

  // ------------------------------------------------------------- theme
  // Everything is derived from the theme palette, so `omarchy theme set`
  // repaints the overview without a reload.
  readonly property string fontFamily: Style.font.family
  readonly property color foreground: Commons.Color.foreground
  readonly property color muted: Commons.Color.muted
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color background: Commons.Color.background
  // Glass: a little of the foreground over the blur, edged by a brighter line.
  readonly property color glassFill: Util.alpha(foreground, 0.07)
  readonly property color glassEdge: Util.alpha(foreground, 0.18)
  readonly property color hairline: Util.alpha(foreground, 0.12)
  readonly property color tileFill: Util.alpha(foreground, 0.08)
  readonly property color tileFillHot: Util.alpha(foreground, 0.16)
  readonly property color windowFill: Util.alpha(foreground, 0.08)
  readonly property color dashed: Util.alpha(foreground, 0.35)
  // Secondary text. Muted is too faint over a busy blurred wallpaper;
  // softened foreground stays readable on any of them.
  readonly property color softText: Util.alpha(foreground, 0.72)
  // Shadows are the theme's background pushed toward black, so they read on
  // light themes too.
  readonly property color shadow: Util.alpha(Qt.darker(background, 4), 0.6)

  // How see-through the theme makes terminals (Omarchy's Glassy windows set
  // the same opacity for every terminal it ships). Captures come out opaque,
  // so Thumbnail.qml puts the glass back with this. 1 = opaque, no glass.
  readonly property string terminalThemePath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/foot.ini"
  property real terminalAlpha: 1

  FileView {
    path: root.terminalThemePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var match = String(text() || "").match(/^\s*alpha\s*=\s*([0-9.]+)/m)
      var value = match ? Number(match[1]) : 1
      root.terminalAlpha = isFinite(value) && value > 0 && value <= 1 ? value : 1
    }
    onLoadFailed: root.terminalAlpha = 1
  }

  // Hyprland's opacity per window (window rules, such as the one Omarchy
  // gives the file manager), by address: [active, inactive, opaque]. Captures
  // leave it out, so WindowCapture blends it back. Neither Quickshell nor
  // `hyprctl clients` reports it, so it is asked for with `hyprctl getprop`,
  // all windows in one batch, at each opening (Omarchy's transparency toggle
  // changes it with no event to go by) and in the background after a window
  // opens. Until then a window has no entry and shows opaque: asked only at
  // the opening, with a process per value, the answer came some 50 ms into
  // the motion, and a terminal it did not know yet glided in flat and dark
  // until it did. Each answer replaces the last, so closed windows drop out.
  property var opacities: ({})

  function windowAlpha(toplevel) {
    var o = root.opacities[root.addressOf(toplevel)]
    if (!o || o[2]) return 1
    var focused = Number(((toplevel && toplevel.lastIpcObject) || {}).focusHistoryID) === 0
    var v = focused ? o[0] : o[1]
    return isFinite(v) && v > 0 && v <= 1 ? v : 1
  }

  readonly property var opacityProps: ["opacity", "opacity_inactive", "opaque"]
  property var opacityAsked: []

  function askOpacities() {
    if (opacityProc.running) return
    var all = Hyprland.toplevels.values, list = [], requests = []
    for (var i = 0; i < all.length; i++) {
      var a = root.addressOf(all[i])
      if (!a) continue
      list.push(a)
      for (var p = 0; p < root.opacityProps.length; p++) requests.push("getprop address:" + a + " " + root.opacityProps[p])
    }
    if (list.length === 0) return
    root.opacityAsked = list
    // One answer per request, blank lines between, "window not found" for a
    // window that closed meanwhile.
    opacityProc.command = ["hyprctl", "--batch", requests.join("; ")]
    opacityProc.running = true
  }

  Process {
    id: opacityProc
    stdout: StdioCollector {
      onStreamFinished: {
        var answers = String(this.text || "").split(/\n\s*\n/).map(function(a) { return a.trim() })
          .filter(function(a) { return a !== "" })
        var list = root.opacityAsked, n = root.opacityProps.length
        // Out of step with the requests: keep what was known.
        if (answers.length !== list.length * n) return
        var next = ({})
        for (var i = 0; i < list.length; i++) {
          var f = answers.slice(i * n, i * n + n)
          if (f[2] !== "true" && f[2] !== "false") continue
          next[list[i]] = [Number(f[0]), Number(f[1]), f[2] === "true"]
        }
        root.opacities = next
      }
    }
  }

  // Hyprland's window blur, so the glass in a thumbnail matches a real
  // window's. The radius follows size and passes, fitted to screenshots.
  property real blurSize: 4
  property real blurPasses: 2
  property real glassBrightness: 0.75
  readonly property real glassBlurRadius: root.blurSize * Math.pow(2, root.blurPasses) * 0.75

  function askBlur() {
    if (!blurProc.running) blurProc.running = true
  }

  Process {
    id: blurProc
    command: ["sh", "-c", "for o in size passes brightness; do hyprctl getoption decoration:blur:$o; done"]
    stdout: StdioCollector {
      onStreamFinished: {
        var found = String(this.text || "").match(/^(?:int|float): [0-9.]+/gm) || []
        var values = found.map(function(line) { return Number(line.split(": ")[1]) })
        if (values.length !== 3 || !values.every(isFinite)) return
        root.blurSize = values[0]
        root.blurPasses = values[1]
        root.glassBrightness = Math.max(0, Math.min(1, values[2]))
      }
    }
  }

  // Terminals are what the theme makes see-through; Hyprland tags them.
  // Only they get the glass, so a dark page in a browser is left alone.
  function isTerminal(toplevel) {
    var tags = ((toplevel && toplevel.lastIpcObject) || {}).tags || []
    for (var i = 0; i < tags.length; i++)
      if (String(tags[i]).indexOf("terminal") === 0) return true
    return false
  }

  // The desktop the overview sits on: the wallpaper, blurred. Omarchy keeps a link to the current one; the link's target is
  // what the image caches by, so a new wallpaper is decoded once and an
  // unchanged one never again.
  readonly property string wallpaperLink: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property string wallpaperPath: ""

  Process {
    id: wallpaperResolve
    command: ["readlink", "-f", root.wallpaperLink]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(this.text || "").trim()
        if (path) root.wallpaperPath = path
      }
    }
  }
  Component.onCompleted: {
    wallpaperResolve.running = true
    root.claimLayerRule()
    root.askOpacities()
    root.askBlur()
    installShortcuts.running = true
  }

  // The theme decides whether anything is round, as Hyprland's rounding does.
  readonly property bool rounded: Style.cornerRadius > 0
  readonly property int windowRadius: rounded ? Style.space(10) : 0
  readonly property int tileRadius: rounded ? Style.space(8) : 0

  // ------------------------------------------------------- shortcuts
  //
  // Hyprland's side of these is hypr/omaview.lua, in place from the start.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    if (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.slice(0, -1)
    // A URL's path is percent-encoded; the script wants the real one.
    return decodeURIComponent(url)
  }

  Process {
    id: installShortcuts
    command: ["/usr/bin/bash", root.pluginDir + "/bin/install-shortcuts.sh"]
    onExited: function(code) { if (code !== 0) console.warn("Omaview: installing shortcuts failed:", code) }
  }

  // The keys open the overview through this, so no process starts on the
  // way: the shell's own toggle, as `omarchy-shell shell toggle` would do.
  GlobalShortcut {
    appid: "omaview"
    name: "toggle"
    description: "Open or close the overview"
    onPressed: {
      if (root.shell && typeof root.shell.toggle === "function") root.shell.toggle(root.pluginId, "{}")
      else if (root.opened) root.dismiss("glide")
      else root.open("{}")
    }
  }

  // ---------------------------------------------------------- lifecycle

  function open(payloadJson) {
    if (root.opened) return
    // Geometry and stacking come from hyprctl's JSON, which Quickshell only
    // refreshes when asked. Bindings pick up the answer when it lands.
    Hyprland.refreshToplevels()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshMonitors()
    var monitor = Hyprland.focusedMonitor
    root.focusMonitor = monitor ? String(monitor.name || "") : ""
    root.keyboardReleased = false
    // Opened again before the last choice's follow-up focus went out (the
    // close takes 150 ms): that choice is history now.
    refocusTimer.stop()
    root.pendingFocus = null
    root.exitMode = "glide"
    root.opened = true
    // A fresh still of every window on screen, asked for while the captures
    // are still idle (WindowCapture `snapshotTick`): the picture kept from
    // before can be well out of date (a terminal that has scrolled since),
    // and laid half see-through over its window it showed as doubled text.
    // It lands within a frame or two, as the surfaces come up.
    root.snapshotTick++
    // The clock first, then the surfaces: their first frame starts it.
    root.animateTo(1, root.openMs)
    root.mapped = true
    // Off the hot path: the wallpaper already decoded shows at once, and a
    // changed one swaps in when this answers. Opacities likewise.
    wallpaperResolve.running = true
    root.askOpacities()
  }

  // Called by the shell on hide, including the hide dismiss() asks for.
  // A workspace growing to fill the screen moves further than a close
  // fades, so it takes a little longer; still under 300 ms.
  readonly property int zoomMs: Style.duration(280)

  function close() {
    if (!root.opened) return
    root.opened = false
    root.animateTo(0, root.exitMode === "zoom" ? root.zoomMs : root.closeMs)
  }

  // Closing from inside the overlay goes through the shell, so its
  // summon/toggle bookkeeping stays in step.
  function dismiss(mode) {
    if (!root.opened) return
    root.exitMode = mode || "glide"
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    root.close()
  }

  function animateTo(value, ms) {
    root.revealRunning = false
    revealFallback.stop()
    if (ms <= 0) {
      root.reveal = value
      root.settle()
      return
    }
    root.revealFrom = root.reveal
    root.revealTo = value
    root.revealMs = ms
    root.revealElapsed = 0
    root.revealLast = 0
    root.revealRunning = true
    revealFallback.start()
    // Already up (a close, or reopening mid-close): one step now, so the
    // surface has something new to draw and the frames start coming.
    if (root.mapped) root.frameShown()
  }

  function settle() {
    if (root.opened || root.reveal > 0) return
    root.mapped = false
    if (root.pendingFocus) refocusTimer.restart()
  }

  // The window a click chose. Focus is sent at once, and again once the
  // surfaces are gone, followed by the pointer: with follow_mouse on, the
  // pointer left where the thumbnail was would hand focus to whatever window
  // is under it, as when a scrolling layout slides the chosen window in from
  // off screen and a neighbour ends up under the pointer.
  property var pendingFocus: null

  Timer {
    id: refocusTimer
    interval: 60
    onTriggered: {
      var toplevel = root.pendingFocus
      root.pendingFocus = null
      if (!toplevel || root.opened) return
      var address = root.addressOf(toplevel)
      if (!address) return
      // One Lua function in Hyprland: focus, then once the layout has placed
      // the window, put the pointer in its middle. Each step only while the
      // window's workspace is still the one on screen: the user may have
      // gone on to another workspace by now, and focusing this window would
      // drag them back (and Omarchy's pointer warp with them).
      // And not if the overview is showing again: the user reopened it and
      // has the pointer on some thumbnail.
      var stillThere = "local aw = hl.get_active_workspace() "
        + "if not aw or not v.workspace or aw.id ~= v.workspace.id then return end "
        + "for _, l in ipairs(hl.get_layers()) do if l.namespace == 'omaview' then return end end "
      Hyprland.dispatch("function() "
        + "local v = hl.get_window('address:" + address + "') "
        + "if not v then return end "
        + stillThere
        + "hl.dispatch(hl.dsp.focus({ window = v })) "
        + "hl.timer(function() "
        + "local v = hl.get_window('address:" + address + "') "
        + "if not v then return end "
        + stillThere
        + "local at, size = v.at, v.size "
        + "local x = (at.x or at[1]) + (size.x or size[1]) / 2 "
        + "local y = (at.y or at[2]) + (size.y or size[2]) / 2 "
        + "hl.dispatch(hl.dsp.cursor.move({ x = math.floor(x), y = math.floor(y) })) "
        + "hl.dispatch(hl.dsp.focus({ window = v })) "
        + "end, { timeout = 40, type = \"oneshot\" }) "
        + "end")
    }
  }

  // Quickshell learns of a new workspace without its monitor (the event does
  // not say), so a workspace a window was just sent to would miss the strip,
  // which lists each monitor's own. Window geometry likewise only comes from
  // asking. While the overview is up, ask again after anything that changes
  // either; one request covers a burst of events.
  Connections {
    target: Hyprland
    enabled: root.mapped
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (/^(createworkspace|destroyworkspace|moveworkspace|renameworkspace|changeworkspaceid|openwindow|closewindow|movewindow|changefloatingmode|fullscreen)/.test(name))
        hyprRefresh.restart()
    }
  }

  // Background stills. Hyprland will not capture a window wholly off its
  // monitor, so a window scrolled away shows only what was kept of it. While
  // the overview is closed, a little after each change of window or
  // workspace, every window then on screen takes one still frame
  // (WindowCapture, `snapshotTick`), so opening finds recent pictures of
  // whatever was last seen.
  property int snapshotTick: 0

  Connections {
    target: Hyprland
    enabled: !root.mapped
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (/^(activewindowv2|workspacev2|openwindow|movewindowv2|fullscreen)$/.test(name)) stillDelay.restart()
      if (name === "openwindow") root.newWindows = true
    }
  }

  // A window opened since the opacities were last asked for (askOpacities).
  property bool newWindows: false

  // Past the window animations, then ask where everything is, then shoot.
  Timer {
    id: stillDelay
    interval: 500
    onTriggered: {
      Hyprland.refreshToplevels()
      stillShoot.restart()
    }
  }

  Timer {
    id: stillShoot
    interval: 80
    onTriggered: {
      if (root.mapped) return
      root.snapshotTick++
      if (root.newWindows) {
        root.newWindows = false
        root.askOpacities()
      }
    }
  }

  // Hyprland animates layer surfaces in and out on its own, which would play
  // a second fade, frozen on our last frame, after the overview's own
  // motion. A runtime rule for our namespace turns that off; it is set again
  // after a config reload, which drops runtime rules.
  function claimLayerRule() {
    Hyprland.dispatch("function() hl.layer_rule({ name = 'omaview', match = { namespace = '^omaview$' }, no_anim = true }) end")
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || String(event.name) !== "configreloaded") return
      root.claimLayerRule()
      root.askBlur()
    }
  }

  Timer {
    id: hyprRefresh
    interval: 40
    onTriggered: {
      Hyprland.refreshWorkspaces()
      Hyprland.refreshToplevels()
    }
  }

  // The reveal clock, moved on by the frames the overview shows rather than
  // by time alone. Each opening maps a new surface, and Hyprland misses a
  // refresh or two on its first frames; a clock that catches up then jumped
  // a third of the way in one frame, the stutter at the start. Here each
  // frame shown (`frameShown`, from the surface on the focused monitor)
  // moves the motion on by the time since the last one, but by at most a
  // refresh and a quarter: a late frame holds a moment, and the motion ends
  // that much later. Qt's own animation clock cannot do this: other surfaces of
  // the shell keep it ticking while ours waits.
  property real revealFrom: 0
  property real revealTo: 0
  property real revealMs: 1
  property real revealElapsed: 0
  property bool revealRunning: false
  property real revealLast: 0
  readonly property real refreshMs: {
    var monitor = Hyprland.focusedMonitor
    var rate = monitor && monitor.lastIpcObject ? Number(monitor.lastIpcObject.refreshRate) : 0
    return isFinite(rate) && rate >= 24 ? 1000 / rate : 1000 / 60
  }

  function frameShown() {
    if (!root.revealRunning) return
    var now = Date.now()
    // The first frame moves on by one refresh: it has nothing to measure
    // from, and a frame that changes nothing would ask for no next one.
    var step = root.revealLast > 0 ? now - root.revealLast : root.refreshMs
    root.revealLast = now
    root.advanceReveal(Math.min(Math.max(0, step), root.refreshMs * 1.25))
  }

  function advanceReveal(ms) {
    root.revealElapsed = Math.min(root.revealMs, root.revealElapsed + ms)
    var t = root.revealElapsed / root.revealMs
    if (t < 1) {
      root.reveal = Layout.lerp(root.revealFrom, root.revealTo, Layout.ease(Style.easeOut, t))
      return
    }
    // Exactly the end: `reveal >= 1` is what "fully open" means elsewhere.
    root.revealRunning = false
    revealFallback.stop()
    root.reveal = root.revealTo
    root.settle()
  }

  // No frames coming at all (no surface on the focused monitor): the wall
  // clock alone, so the motion still ends.
  Timer {
    id: revealFallback
    interval: 100
    repeat: true
    onTriggered: {
      var now = Date.now()
      if (now - root.revealLast < revealFallback.interval) return
      var step = root.revealLast > 0 ? now - root.revealLast : revealFallback.interval
      root.revealLast = now
      root.advanceReveal(step)
    }
  }

  // ----------------------------------------------------------- Hyprland
  // Windows are named by address, because a class is not an identity.

  function addressOf(toplevel) {
    var address = String((toplevel && toplevel.address) || "")
    if (!address) return ""
    if (address.indexOf("0x") !== 0) address = "0x" + address
    return /^0x[0-9a-f]+$/i.test(address) ? address : ""
  }

  function windowSelector(toplevel) {
    var address = root.addressOf(toplevel)
    return address ? "window = \"address:" + address + "\"" : ""
  }

  // Workspace selectors are Hyprland's own strings: an id, or "emptynm" for
  // the next empty workspace on the focused monitor.
  function workspaceSelector(workspace) {
    return String(workspace).replace(/[^A-Za-z0-9:+_-]/g, "")
  }

  // How long the chosen window's workspace moves without animation: past the
  // close and the refocus after it.
  readonly property int stillMs: 500

  // Windows the overview took out of maximized (1) or fullscreen (2) to show
  // another, by address, so choosing them again restores it. Forgotten when
  // the window gets focus some other way: then it stays as the user left it.
  property var steppedBack: ({})

  Connections {
    target: Hyprland
    enabled: !root.mapped
    function onRawEvent(event) {
      if (!event || String(event.name) !== "activewindowv2") return
      var address = String(event.data || "").split(",")[0]
      if (address && address.indexOf("0x") !== 0) address = "0x" + address
      // The overview's own focus lands after it has closed; that one is the
      // choice just made, not the user going back some other way.
      if (address && root.pendingFocus && root.addressOf(root.pendingFocus) === address) return
      if (address) delete root.steppedBack[address]
    }
  }

  // One Lua function in Hyprland, so it all lands in one go:
  //  - Every window on the workspace stops animating for a moment. Focusing
  //    a window in a scrolling layout scrolls it into view, and the overview
  //    already showed the way there; the windows should simply be there.
  //  - Hyprland ignores a focus request for a window under a maximized or
  //    fullscreen one, so that one has to step back for the chosen window to
  //    come forward as it is. On a scrolling workspace
  //    a maximized window keeps its size: it becomes a full-width column, and
  //    the layout scrolls past it to the choice. Otherwise it goes back to its
  //    own size, and that is remembered (`steppedBack`): choosing it again in
  //    the overview brings it back maximized or fullscreen.
  //  - Focus, and a floating window comes out on top.
  function focusWindow(toplevel) {
    var address = root.addressOf(toplevel)
    if (!address) return

    var ws = toplevel.workspace
    var scrolling = !!ws && String((ws.lastIpcObject || {}).tiledLayout || "") === "scrolling"
    var all = Hyprland.toplevels.values
    for (var i = 0; i < all.length; i++) {
      var other = all[i]
      if (other === toplevel || other.workspace !== toplevel.workspace) continue
      var ipc = other.lastIpcObject || {}
      var mode = Number(ipc.fullscreen || 0)
      var otherAddress = root.addressOf(other)
      // A full-width column keeps its size; nothing to restore.
      if (scrolling && mode === 1 && !ipc.floating) continue
      if (otherAddress && (mode === 1 || mode === 2)) root.steppedBack[otherAddress] = mode
    }
    var restore = root.steppedBack[address] || 0
    delete root.steppedBack[address]
    var restoreName = restore === 1 ? "maximized" : restore === 2 ? "fullscreen" : ""

    Hyprland.dispatch("function() "
      + "local w = hl.get_window('address:" + address + "') "
      + "if not w or not w.workspace then return end "
      + "local others = hl.get_workspace_windows(tostring(w.workspace.id)) "
      + "for _, o in ipairs(others) do "
      + "hl.dispatch(hl.dsp.window.set_prop({ prop = 'no_anim', value = '1', window = o })) "
      + "end "
      + "for _, o in ipairs(others) do "
      + "if o.address ~= w.address and ((o.fullscreen or 0) == 1 or (o.fullscreen or 0) == 2) then "
      + "local full = o.fullscreen == 1 and not o.floating "
      + "hl.dispatch(hl.dsp.window.fullscreen({ mode = (o.fullscreen == 1) and 'maximized' or 'fullscreen', action = 'unset', window = o })) "
      // Column width applies to the focused column, and not while it is
      // maximized: so after the unset, focus it and widen it.
      + (scrolling ? "if full then "
        + "hl.dispatch(hl.dsp.focus({ window = o })) "
        + "hl.dispatch(hl.dsp.layout('colresize 1.0')) "
        + "end " : "")
      + "end "
      + "end "
      + "hl.dispatch(hl.dsp.focus({ window = w })) "
      + "hl.dispatch(hl.dsp.window.alter_zorder({ mode = 'top', window = w })) "
      + (restoreName ? "hl.dispatch(hl.dsp.window.fullscreen({ mode = '" + restoreName + "', action = 'set', window = w })) " : "")
      + "hl.timer(function() "
      + "for _, o in ipairs(hl.get_workspace_windows(tostring(w.workspace.id))) do "
      + "hl.dispatch(hl.dsp.window.set_prop({ prop = 'no_anim', value = 'unset', window = o })) "
      + "end "
      + "end, { timeout = " + root.stillMs + ", type = \"oneshot\" }) "
      + "end")
  }

  // Click a window: go to it. The windows may move for it (scrolled into
  // view, a maximized one stepping back), so the overview holds still until
  // Hyprland says where they are now, then glides straight there. Gliding
  // at once would head for the old places, off screen for a window scrolled
  // away, and turn back when the answer landed.
  //
  // Hyprland does not move focus to a window while a layer holds the
  // keyboard exclusively, so the overview lets go of it first. Focusing while
  // still holding it did nothing until the overview had closed, and a window
  // off screen then scrolled in only after the overview was gone.
  property var activating: null
  property bool focusSent: false
  property bool keyboardReleased: false

  function activate(toplevel) {
    if (root.activating) return
    root.pendingFocus = toplevel
    root.activating = toplevel
    root.focusSent = false
    root.keyboardReleased = true
    // A photo pass mid-way has the layout scrolled: put it back first, and
    // give that a few frames more to land.
    var midPass = root.passingCount > 0
    if (midPass) root.stopPasses(false)
    focusAfterRelease.interval = midPass ? 90 : 34
    activateTimeout.interval = midPass ? 260 : 200
    focusAfterRelease.restart()
    activateTimeout.restart()
  }

  // Overview.qml's photo passes: how many are running, and how to stop
  // them all; `refocus` puts focus back where it was, which is only right
  // when nothing else is about to take it.
  property int passingCount: 0
  signal stopPasses(bool refocus)
  // The windows have moved for real (a choice landed): positions held
  // through a photo pass give way to what Hyprland now reports.
  signal releaseHolds()

  // Window animation off (or back on) for every window on a workspace, so
  // the layout can move behind the overview without anything sliding.
  function stillWorkspace(workspace, still) {
    if (!workspace) return
    Hyprland.dispatch("function() "
      + "for _, o in ipairs(hl.get_workspace_windows('" + workspace.id + "')) do "
      + "hl.dispatch(hl.dsp.window.set_prop({ prop = 'no_anim', value = '" + (still ? "1" : "unset") + "', window = o })) "
      + "end "
      + "end")
  }

  // Two frames for the layer's new keyboard mode to reach Hyprland.
  Timer {
    id: focusAfterRelease
    interval: 34
    onTriggered: {
      if (!root.activating) return
      root.focusWindow(root.activating)
      root.focusSent = true
      Hyprland.refreshToplevels()
    }
  }

  function finishActivate() {
    if (!root.activating) return
    root.activating = null
    activateTimeout.stop()
    focusAfterRelease.stop()
    root.releaseHolds()
    root.dismiss("glide")
  }

  // The answer arrives as a fresh IPC object on the chosen window; one that
  // lands before the focus went out describes the old layout.
  Connections {
    target: root.activating
    function onLastIpcObjectChanged() { if (root.focusSent) root.finishActivate() }
  }

  // Should the answer not come, go anyway.
  Timer {
    id: activateTimeout
    interval: 200
    onTriggered: root.finishActivate()
  }

  function closeWindow(toplevel) {
    var target = root.windowSelector(toplevel)
    if (target) Hyprland.dispatch("hl.dsp.window.close({ " + target + " })")
  }

  function moveWindow(toplevel, workspace) {
    var target = root.windowSelector(toplevel)
    var selector = root.workspaceSelector(workspace)
    if (!target || !selector) return false
    Hyprland.dispatch("hl.dsp.window.move({ workspace = \"" + selector + "\", follow = false, " + target + " })")
    return true
  }

  // Reorder: two windows trade places in the layout. The spread follows on
  // its own, as it lays windows out by where they really are. Named by
  // address, so neither takes focus and the layout stays where it is.
  function swapWindows(first, second) {
    var a = root.addressOf(first), b = root.addressOf(second)
    if (!a || !b || a === b) return
    Hyprland.dispatch("hl.dsp.window.swap({ window = \"address:" + a + "\", target = \"address:" + b + "\" })")
    hyprRefresh.restart()
  }

  function focusMonitorNamed(name) {
    var safe = String(name || "").replace(/[^A-Za-z0-9_.-]/g, "")
    if (safe) Hyprland.dispatch("hl.dsp.focus({ monitor = \"" + safe + "\" })")
  }

  // Click a workspace: switch to it. The current one just closes the overview.
  function switchWorkspace(workspace, monitor, mode) {
    if (!workspace) return
    if (monitor && monitor.activeWorkspace === workspace) {
      root.dismiss("glide")
      return
    }
    root.dispatchAfterPasses("hl.dsp.focus({ workspace = \"" + workspace.id + "\" })")
    root.dismiss(mode || "fade")
  }

  // By number, from the keyboard, as SUPER+number does.
  function switchWorkspaceId(id, monitor) {
    if (monitor && monitor.activeWorkspace && monitor.activeWorkspace.id === id) {
      root.dismiss("glide")
      return
    }
    root.dispatchAfterPasses("hl.dsp.focus({ workspace = \"" + id + "\" })")
    root.dismiss("fade")
  }

  // The + tile: a fresh empty workspace on the monitor it was clicked on.
  // It is added to the strip and the overview stays:
  // the next free number in the monitor's block of ten (Omarchy's), made
  // persistent so Hyprland keeps it while empty and off screen. Runtime
  // rules last until the config is reloaded.
  function newWorkspace(monitor) {
    if (!monitor) return
    var active = monitor.activeWorkspace ? monitor.activeWorkspace.id : 1
    var base = Math.floor((Math.max(1, active) - 1) / 10) * 10
    var taken = {}
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) taken[all[i].id] = true
    var id = -1
    for (var n = base + 1; n <= base + 10; n++) {
      if (!taken[n]) { id = n; break }
    }
    if (id < 0) return
    var name = String(monitor.name || "").replace(/[^A-Za-z0-9_.-]/g, "")
    Hyprland.dispatch("function() hl.workspace_rule({ workspace = '" + id + "', monitor = '" + name + "', persistent = true }) end")
    hyprRefresh.restart()
  }

  // Middle-click on a tile: remove that workspace. Its windows come to the workspace on screen, and it
  // stops being persistent (if the + tile made it), so Hyprland drops it
  // once empty. The workspace on screen itself cannot be removed so.
  function removeWorkspace(workspace, monitor) {
    if (!workspace || !monitor || monitor.activeWorkspace === workspace || workspace.id <= 0) return
    var here = monitor.activeWorkspace ? monitor.activeWorkspace.id : 0
    if (here <= 0) return
    Hyprland.dispatch("function() "
      + "for _, o in ipairs(hl.get_workspace_windows('" + workspace.id + "')) do "
      + "hl.dispatch(hl.dsp.window.move({ workspace = '" + here + "', follow = false, window = o })) "
      + "end "
      + "hl.workspace_rule({ workspace = '" + workspace.id + "', persistent = false }) "
      + "end")
    hyprRefresh.restart()
  }

  // SUPER+Q / SUPER+W while the overview is open: Hyprland's bindings take
  // those keys before the overview sees them, so the user's bindings send
  // this global instead of closing the focused window, and the screen that
  // has the keyboard closes the window selected there (Overview.qml).
  signal closeSelectedRequested()
  // SUPER+ALT+F likewise: full width for the selected window.
  signal maximizeSelectedRequested()

  GlobalShortcut {
    appid: "omaview"
    name: "maximize-selected"
    description: "Toggle full width for the window selected in the overview"
    onPressed: if (root.opened) root.maximizeSelectedRequested()
  }

  // SUPER+Enter likewise: a new terminal next to the selected window, and
  // the overview stays up while a window opens. A scrolling layout puts a new window right of the focused one,
  // and Hyprland moves no focus while a layer holds the keyboard: so the
  // overview lets go of it, focuses the selected window (keeping the
  // pointer), opens the terminal from it, in its folder, as Omarchy's own
  // binding does, and takes the keyboard back once the window is there. With
  // no window selected (an empty workspace) there is nothing to open it from:
  // it goes on the workspace on show, on the monitor that has the keyboard.
  signal terminalSelectedRequested()

  GlobalShortcut {
    appid: "omaview"
    name: "terminal-selected"
    description: "Open a terminal next to the window selected in the overview"
    onPressed: if (root.opened) root.terminalSelectedRequested()
  }

  function terminalNextTo(toplevel) {
    if (!root.opened || root.activating) return
    var pid = Number(((toplevel && toplevel.lastIpcObject) || {}).pid)
    root.terminalCommand = isFinite(pid) && pid > 0
      ? ["omarchy-launch-terminal", "--pid=" + pid] : ["omarchy-launch-terminal"]
    root.terminalFor = toplevel
    root.keyboardReleased = true
    terminalFocus.restart()
    terminalGiveUp.restart()
  }

  property var terminalFor: null
  property var terminalCommand: null

  // Two frames for the layer's keyboard mode to reach Hyprland.
  Timer {
    id: terminalFocus
    interval: 34
    onTriggered: {
      if (!root.opened) return root.takeKeyboardBack()
      var address = root.addressOf(root.terminalFor)
      if (address) {
        Hyprland.dispatch("function() local c = hl.get_cursor_pos() "
          + "hl.dispatch(hl.dsp.focus({ window = 'address:" + address + "' })) "
          + "if c then hl.dispatch(hl.dsp.cursor.move({ x = math.floor(c.x), y = math.floor(c.y) })) end end")
      } else {
        root.focusMonitorNamed(root.focusMonitor)
      }
      if (root.terminalCommand) Util.execArgv(root.terminalCommand)
      root.terminalCommand = null
    }
  }

  // The new window is up: the keyboard back to the overview.
  Connections {
    target: Hyprland
    enabled: terminalGiveUp.running
    function onRawEvent(event) {
      if (event && String(event.name) === "openwindow") Qt.callLater(root.takeKeyboardBack)
    }
  }

  // Should no window come, take the keyboard back anyway.
  Timer {
    id: terminalGiveUp
    interval: 3000
    onTriggered: root.takeKeyboardBack()
  }

  function takeKeyboardBack() {
    terminalFocus.stop()
    terminalGiveUp.stop()
    root.terminalFor = null
    root.terminalCommand = null
    if (root.opened && !root.activating) root.keyboardReleased = false
    hyprRefresh.restart()
  }

  function toggleMaximized(toplevel) {
    var target = root.windowSelector(toplevel)
    if (target) Hyprland.dispatch("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"toggle\", " + target + " })")
    hyprRefresh.restart()
  }

  // ALT+Tab and ALT+SHIFT+Tab move the selection, as Tab does: Hyprland
  // binds them, so the overview's own keys never see them.
  signal cycleSelectedRequested(int step)

  GlobalShortcut {
    appid: "omaview"
    name: "next-selected"
    description: "Select the next window in the overview"
    onPressed: if (root.opened) root.cycleSelectedRequested(1)
  }

  GlobalShortcut {
    appid: "omaview"
    name: "previous-selected"
    description: "Select the previous window in the overview"
    onPressed: if (root.opened) root.cycleSelectedRequested(-1)
  }

  GlobalShortcut {
    appid: "omaview"
    name: "close-selected"
    description: "Close the window selected in the overview"
    onPressed: if (root.opened) root.closeSelectedRequested()
  }

  // A dispatcher that must not land while a photo pass has the layout
  // scrolled: `layout move` acts on the active workspace, so a switch first
  // would leave the old one scrolled, and the pass putting focus back would
  // switch straight back to it. Mid-pass, it goes in the same command as the
  // scroll back (passThen, read by Overview.endPass), in place of that focus.
  property string passThen: ""
  function dispatchAfterPasses(dispatcher) {
    if (root.passingCount > 0) {
      root.passThen = dispatcher
      root.stopPasses(false)
    } else {
      Hyprland.dispatch(dispatcher)
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      Overview {
        overview: root
      }
    }
  }
}
