import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "Layout.js" as Layout

// One screen of the overview: its monitor's workspaces along the top and the
// active workspace's windows spread out below. Every screen gets one, so a
// second monitor shows its own windows rather than a copy.
PanelWindow {
  id: view

  required property var modelData
  // The plugin root (Omaview.qml): lifecycle, theme and dispatch.
  property var overview

  readonly property var monitor: Hyprland.monitorFor(view.modelData)
  // The workspace on show: the monitor's active one while the overview is
  // open, held as it was while it closes. A click on a workspace switches at
  // once, and following it would bring that workspace's windows up in the
  // middle of the fade, a flash of thumbnails just as everything leaves.
  property var workspace: null
  Binding {
    target: view
    property: "workspace"
    value: view.monitor ? view.monitor.activeWorkspace : null
    when: view.overview.opened
    restoreMode: Binding.RestoreNone
  }
  readonly property bool takesKeyboard: !!view.monitor && view.monitor.name === view.overview.focusMonitor
  // The workspace on show, a turn of the event loop late: while it differs,
  // the windows of the one just come on show are taking their places. Asked
  // as a function: a binding on it can still hold the old answer, as these
  // changes reach the thumbnails first.
  property var settledWorkspace: null
  function switchingWorkspace() { return view.workspace !== view.settledWorkspace }
  onWorkspaceChanged: Qt.callLater(function() { view.settledWorkspace = view.workspace })

  screen: view.modelData
  visible: view.overview.mapped
  color: "transparent"
  anchors { top: true; bottom: true; left: true; right: true }
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omaview"
  WlrLayershell.layer: WlrLayer.Overlay
  // Let go once a window is chosen, so Hyprland will move focus to it.
  WlrLayershell.keyboardFocus: view.takesKeyboard && !view.overview.keyboardReleased ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // Opening and a gliding close move the thumbnails between their windows and
  // their slots; a fading close leaves them where they are.
  readonly property real travel: view.overview.opened || view.overview.exitMode === "glide" ? view.overview.reveal : 1
  readonly property real fade: view.overview.reveal
  // Choosing a workspace: its tile grows to fill the screen (zoomInto)
  // while all else fades; the backdrop stays until the very end, when the
  // grown tile and the real desktop under it line up.
  readonly property bool zooming: !view.overview.opened && view.overview.exitMode === "zoom"
  // The last quarter of the zoom hands over to the real desktop by a quick
  // cross-fade: it covers the bar coming in and the scrolling layout
  // settling on the new workspace.
  readonly property real backdropFade: view.zooming ? Layout.clamp01(view.overview.reveal * 4) : view.fade
  // How much of the thumbnails is left: all of it, except in a fading close,
  // where they go out with everything else rather than vanish at the end.
  readonly property real thumbFade: view.travel === view.fade ? 1 : view.fade

  // The wallpaper as Hyprland's blur leaves it behind a translucent window,
  // for thumbnails to show behind their window: the glass a capture of the
  // window alone leaves out.
  readonly property Item windowGlass: windowGlassItem

  // The part of that wallpaper behind a rect on this screen. The wallpaper
  // ends at the screen's edges, so a rect hanging over one, or off screen,
  // takes the same size of it slid back inside.
  function wallpaperBehind(rect) {
    var r = Layout.clampInto(rect, view.width, view.height)
    return Qt.rect(r.x, r.y, r.w, r.h)
  }

  // ------------------------------------------------------------ windows

  // Where a window really is, in this screen's coordinates. Hyprland reports
  // layout coordinates, which are this surface's once the monitor's origin
  // is taken off.
  function realRect(toplevel) {
    if (view.held) {
      var h = view.held[view.overview.addressOf(toplevel)]
      if (h) return h
    }
    var ipc = (toplevel && toplevel.lastIpcObject) || {}
    var at = ipc.at || [0, 0]
    var size = ipc.size || [0, 0]
    var ox = view.monitor ? view.monitor.x : 0
    var oy = view.monitor ? view.monitor.y : 0
    return { x: at[0] - ox, y: at[1] - oy, w: size[0], h: size[1] }
  }

  // The active workspace's windows. Hidden ones are the back tabs of a
  // group, which Hyprland draws as one window.
  readonly property var windows: {
    var out = []
    var ws = view.workspace
    if (!ws) return out
    var all = Hyprland.toplevels.values
    for (var i = 0; i < all.length; i++) {
      var ipc = all[i].lastIpcObject || {}
      if (all[i].workspace !== ws || ipc.hidden === true) continue
      out.push(all[i])
    }
    return out
  }
  readonly property var realRects: view.windows.map(function(t) { return view.realRect(t) })

  readonly property int outer: Style.space(56)
  readonly property int gap: Style.space(40)
  readonly property int labelGap: Style.space(12)
  readonly property int labelHeight: view.labelGap + Math.ceil(Style.font.subtitle * 1.4)
  readonly property rect spreadArea: Qt.rect(view.outer, strip.height + view.outer,
    view.width - view.outer * 2, view.height - strip.height - view.outer * 2)
  readonly property var slots: Layout.spread(view.realRects,
    { x: view.spreadArea.x, y: view.spreadArea.y, w: view.spreadArea.width, h: view.spreadArea.height },
    { gap: view.gap, labelHeight: view.labelHeight })

  // The keyboard cursor, which hovering also moves: an index into `windows`.
  // -1 until the user moves it: then it follows the focused window, by
  // Hyprland's focus history (Quickshell's active window can lag, as just
  // after a restart), which also lands after opening.
  property int cursor: -1
  readonly property int focusedIndex: {
    var best = -1, rank = Infinity
    for (var i = 0; i < view.windows.length; i++) {
      var n = Number((view.windows[i].lastIpcObject || {}).focusHistoryID)
      if (isFinite(n) && n < rank) { rank = n; best = i }
    }
    return best >= 0 ? best : 0
  }
  readonly property int cursorIndex: view.windows.length === 0 ? -1
    : view.cursor < 0 ? view.focusedIndex
    : Math.max(0, Math.min(view.cursor, view.windows.length - 1))

  // Hover moves the cursor only once the pointer itself has moved since the
  // overview opened. Thumbnails gliding in under a pointer at rest (the
  // overview leaves it on the last window chosen) are not a choice.
  property bool pointerMoved: false
  property point pointerAnchor: Qt.point(-1, -1)
  function hovered(index, scenePoint) {
    if (!view.pointerMoved) {
      if (view.pointerAnchor.x < 0) {
        view.pointerAnchor = scenePoint
        return
      }
      if (Math.abs(scenePoint.x - view.pointerAnchor.x) + Math.abs(scenePoint.y - view.pointerAnchor.y) < Style.space(4)) return
      view.pointerMoved = true
    }
    view.cursor = index
  }

  // The window being dragged, its slot, the workspace it would land on (a
  // workspace id, "emptynm" for the + tile, or "" for none), and the window
  // it would trade places with.
  property var dragged: null
  readonly property var draggedSlot: {
    var i = view.windows.indexOf(view.dragged)
    return i >= 0 ? view.slots[i] : null
  }
  property string dropTarget: ""
  property var swapTarget: null

  function resetCursor() {
    view.cursor = -1
    view.pointerMoved = false
    view.pointerAnchor = Qt.point(-1, -1)
  }

  Connections {
    target: view.overview
    function onOpenedChanged() {
      if (!view.overview.opened) {
        view.endPass(true)
        return
      }
      view.passDone = false
      view.resetCursor()
      view.dragged = null
      view.dropTarget = ""
      view.swapTarget = null
      if (view.takesKeyboard) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
    // Once fully open, the backdrop hides the desktop: photograph the
    // windows that are off screen.
    function onRevealChanged() {
      if (view.overview.opened && view.overview.reveal >= 1 && !view.passDone) view.startPass()
    }
    function onStopPasses(refocus) { view.endPass(refocus) }
    function onTerminalSelectedRequested() {
      if (!view.takesKeyboard) return
      // An empty workspace has nothing selected: the terminal just opens on it.
      var chosen = view.cursorIndex >= 0 ? view.windows[view.cursorIndex] : null
      // The selection follows focus from here: the chosen window, then the
      // new terminal as it opens and takes focus.
      view.cursor = -1
      view.overview.terminalNextTo(chosen)
    }
    function onKeyboardReleasedChanged() {
      if (!view.overview.keyboardReleased && view.takesKeyboard && view.overview.opened)
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
    function onMaximizeSelectedRequested() {
      if (!view.takesKeyboard || view.cursorIndex < 0) return
      view.overview.toggleMaximized(view.windows[view.cursorIndex])
    }
    function onCycleSelectedRequested(step) {
      if (view.takesKeyboard) view.cycleCursor(step)
    }
    function onCloseSelectedRequested() {
      if (!view.takesKeyboard || view.cursorIndex < 0) return
      view.overview.closeWindow(view.windows[view.cursorIndex])
    }
    function onReleaseHolds() { view.releaseHold() }
  }

  // ------------------------------------------------------------ photo pass
  //
  // Hyprland captures a window only while it overlaps its monitor, so in a
  // scrolling layout the windows scrolled away would show only an icon.
  // Once the overview is fully open its opaque backdrop hides the real
  // windows, and behind it the layout is scrolled to each off-screen window
  // in turn, without animation, for one picture; then back to where it was,
  // with the window that had focus focused again. Live captures are held
  // meanwhile, since a window sliding off screen would have its refused.

  property bool passing: false
  property bool passDone: false
  property var passQueue: []
  property var passItem: null
  // The window that had focus, and where it was (Hyprland's layout x): the
  // layout goes back by putting it there again. Undoing each scroll by its
  // own distance drifted, as the scrolling layout nudges its view on the
  // focus changes the scrolls cause.
  property var passFocus: null
  property real passAnchorX: 0
  property int passWaited: 0
  // The workspace the pass scrolls, and its monitor. The user can change
  // workspace while the overview is open (a SUPER+number binding, a swipe);
  // every step checks, in Hyprland, that this one is still on screen, as a
  // scroll would otherwise land on the new one and putting focus back would
  // drag the user to the old one, Omarchy's pointer warp with them.
  property int passWorkspaceId: 0
  property string passMonitorName: ""

  function passHere() {
    var name = view.passMonitorName.replace(/[^A-Za-z0-9_.-]/g, "")
    return "local aw = hl.get_active_workspace('" + name + "') "
      + "local here = aw ~= nil and aw.id == " + view.passWorkspaceId + " "
  }

  // Where the windows were when the pass began, by address, used instead of
  // what Hyprland reports until it is over. Omarchy's notification service
  // re-reads every window on each focus change, and the pass changes focus
  // as it scrolls: the overview would otherwise take up the layout mid-pass,
  // and keep it if nothing read it again after the scroll back. Let go once
  // Hyprland has been asked again after the pass (holdAsk, holdLet), or when
  // a choice moves the windows for real (Omaview.releaseHolds).
  property var held: null

  Timer {
    id: holdAsk
    interval: 120
    onTriggered: {
      Hyprland.refreshToplevels()
      holdLet.restart()
    }
  }

  Timer {
    id: holdLet
    interval: 150
    onTriggered: view.held = null
  }

  function releaseHold() {
    holdAsk.stop()
    holdLet.stop()
    view.held = null
  }

  function thumbnailFor(toplevel) {
    var i = Hyprland.toplevels.values.indexOf(toplevel)
    return i >= 0 ? thumbnails.itemAt(i) : null
  }

  // Where a window sits in the tile of the workspace on show, in this
  // surface's coordinates; one off screen, at the tile's edge.
  function tileRectFor(toplevel) {
    var r = view.realRect(toplevel)
    if (!(r.w > 0)) return null
    var s = view.tileScale
    for (var i = 0; i < tiles.count; i++) {
      var tile = tiles.itemAt(i)
      if (!tile || tile.workspace !== view.workspace) continue
      var c = Layout.clampInto({ x: r.x * s, y: r.y * s, w: r.w * s, h: r.h * s }, tile.width, tile.height)
      var p = tile.windowsLayer.mapToItem(null, c.x, c.y)
      return { x: p.x, y: p.y, w: c.w, h: c.h }
    }
    return null
  }

  // A window's picture from its thumbnail in the spread, once it has one,
  // for its workspace tile. Read again as thumbnails come and go.
  function pictureFor(toplevel) {
    var count = thumbnails.count
    var thumb = count > 0 ? view.thumbnailFor(toplevel) : null
    return thumb && thumb.hasPicture ? thumb.picture : null
  }

  function startPass() {
    view.passDone = true
    if (view.passing || !view.workspace) return
    // Only a scrolling layout has places to scroll to.
    if (String((view.workspace.lastIpcObject || {}).tiledLayout || "") !== "scrolling") return
    var queue = []
    for (var i = 0; i < view.windows.length; i++) {
      var r = view.realRects[i]
      var ipc = view.windows[i].lastIpcObject || {}
      if (ipc.floating || !(r.w > 0)) continue
      if (r.x + r.w <= 0 || r.x >= view.width) queue.push({ toplevel: view.windows[i], rect: r })
    }
    if (queue.length === 0) return
    holdAsk.stop()
    holdLet.stop()
    var held = {}
    for (var j = 0; j < view.windows.length; j++)
      held[view.overview.addressOf(view.windows[j])] = view.realRects[j]
    view.held = held
    // The selection stays where it is, whatever focus does meanwhile.
    if (view.cursor < 0) view.cursor = view.focusedIndex
    view.passQueue = queue
    view.passWorkspaceId = view.workspace.id
    view.passMonitorName = view.monitor ? String(view.monitor.name || "") : ""
    // The focused window by Hyprland's focus history, not Quickshell's active
    // one, which can lag.
    view.passFocus = view.windows[view.focusedIndex]
    var at = ((view.passFocus && view.passFocus.lastIpcObject) || {}).at || [0, 0]
    view.passAnchorX = at[0]
    view.passing = true
    view.overview.passingCount++
    // Every window on the workspace holds still while the layout moves.
    view.overview.stillWorkspace(view.workspace, true)
    view.passNext()
  }

  function passNext() {
    if (!view.passing) return
    if (view.passQueue.length === 0 || !view.overview.opened) {
      view.endPass(true)
      return
    }
    // The user moved to another workspace: stop here.
    var active = view.monitor ? view.monitor.activeWorkspace : null
    if (!active || active.id !== view.passWorkspaceId) {
      view.endPass(true)
      return
    }
    var queue = view.passQueue.slice()
    var item = queue.shift()
    view.passQueue = queue
    view.passItem = item
    // Centre it on screen, from where Hyprland has it now.
    var address = view.overview.addressOf(item.toplevel)
    var ox = view.monitor ? view.monitor.x : 0
    var centre = ox + Math.round((view.width - item.rect.w) / 2)
    if (address) Hyprland.dispatch("function() "
      + view.passHere()
      + "if not here then return end "
      + "local v = hl.get_window('address:" + address + "') "
      + "if not v then return end "
      + "local dx = math.floor(" + centre + " - (v.at.x or v.at[1])) "
      + "if dx ~= 0 then hl.dispatch(hl.dsp.layout('move ' .. (dx > 0 and '+' or '') .. dx)) end "
      + "end")
    passSettle.restart()
  }

  // Two frames for the move to land, then the picture.
  Timer {
    id: passSettle
    interval: 50
    onTriggered: {
      var thumb = view.passItem ? view.thumbnailFor(view.passItem.toplevel) : null
      if (!thumb) {
        view.passNext()
        return
      }
      thumb.grabPicture()
      view.passWaited = 0
      passWatch.restart()
    }
  }

  // Wait for the frame, a little while at most.
  Timer {
    id: passWatch
    interval: 30
    repeat: true
    onTriggered: {
      var thumb = view.passItem ? view.thumbnailFor(view.passItem.toplevel) : null
      view.passWaited++
      if (!thumb || !thumb.grabbing || view.passWaited >= 20) {
        passWatch.stop()
        view.passNext()
      }
    }
  }

  // Back to where it was. Also what closing or choosing does mid-pass:
  // `refocus` puts focus back on the window that had it, unless a switch of
  // workspace is waiting (passThen), which then goes in the same command.
  // If the user has gone to another workspace meanwhile, nothing moves now:
  // the way back is kept in Hyprland (omaview_pending) and taken when they
  // return to this one (restoreOnReturn).
  function endPass(refocus) {
    passSettle.stop()
    passWatch.stop()
    if (!view.passing) return
    view.passing = false
    view.passQueue = []
    view.passItem = null
    view.overview.passingCount--
    var then = view.overview.passThen
    view.overview.passThen = ""
    var anchor = view.overview.addressOf(view.passFocus)
    var focusBack = refocus && !then && !!anchor
    var id = view.passWorkspaceId
    var x = Math.round(view.passAnchorX)
    // One command, so the scroll back and what follows land in order, and
    // the windows only animate again once they are home. Back means the
    // anchor window where it was.
    Hyprland.dispatch("function() "
      + view.passHere()
      + (anchor ? "if here then " + view.anchorBack(anchor, x) + "else "
        + "_G.omaview_pending = _G.omaview_pending or {} "
        + "_G.omaview_pending[" + id + "] = { anchor = '" + anchor + "', x = " + x + ", focus = " + focusBack + " } "
        + "end " : "")
      + (then ? "hl.dispatch(" + then + ") " : "")
      + (focusBack ? "if here then " + view.focusKeepingPointer("hl.get_window('address:" + anchor + "')") + "end " : "")
      + view.animateAgain(id)
      + "end")
    var check = Object.assign({}, view.restoreCheck)
    check[id] = true
    view.restoreCheck = check
    holdAsk.restart()
  }

  // Lua: focus a window without moving the pointer. A focus command moves
  // the pointer to the window's middle (cursor:no_warps is off in Omarchy),
  // which is right when the user picked the window, but not when the
  // overview only puts focus back where it was: the pointer is where the
  // user left it, perhaps over another thumbnail by now.
  function focusKeepingPointer(windowExpr) {
    return "local c = hl.get_cursor_pos() "
      + "hl.dispatch(hl.dsp.focus({ window = " + windowExpr + " })) "
      + "if c then hl.dispatch(hl.dsp.cursor.move({ x = math.floor(c.x), y = math.floor(c.y) })) end "
  }

  // Lua: scroll the layout so the anchor window is at layout x `x` again.
  function anchorBack(anchor, x) {
    return "local a = hl.get_window('address:" + anchor + "') "
      + "if a then "
      + "local dx = math.floor(" + x + " - (a.at.x or a.at[1])) "
      + "if dx ~= 0 then hl.dispatch(hl.dsp.layout('move ' .. (dx > 0 and '+' or '') .. dx)) end "
      + "end "
  }

  // Lua: the workspace's windows animate again, once they are home.
  function animateAgain(id) {
    return "hl.timer(function() "
      + "for _, o in ipairs(hl.get_workspace_windows('" + id + "')) do "
      + "hl.dispatch(hl.dsp.window.set_prop({ prop = 'no_anim', value = 'unset', window = o })) "
      + "end "
      + "end, { timeout = 300, type = \"oneshot\" }) "
  }

  // Workspaces whose pass ended while the user was elsewhere, and may have a
  // way back waiting in Hyprland. On return to one, it is put back as it was
  // before the overview opened: scroll, and focus if a plain close would
  // have restored it. Nothing moves if Hyprland has no way back kept.
  property var restoreCheck: ({})

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || String(event.name) !== "workspacev2") return
      var id = parseInt(String(event.data || "").split(",")[0], 10)
      if (!view.restoreCheck[id]) return
      var check = Object.assign({}, view.restoreCheck)
      delete check[id]
      view.restoreCheck = check
      view.restoreOnReturn(id)
    }
  }

  function restoreOnReturn(id) {
    Hyprland.dispatch("function() "
      + "local p = _G.omaview_pending and _G.omaview_pending[" + id + "] "
      + "if not p then return end "
      + "_G.omaview_pending[" + id + "] = nil "
      + "local aw = hl.get_active_workspace() "
      + "if not aw or aw.id ~= " + id + " then return end "
      + "for _, o in ipairs(hl.get_workspace_windows('" + id + "')) do "
      + "hl.dispatch(hl.dsp.window.set_prop({ prop = 'no_anim', value = '1', window = o })) "
      + "end "
      + "local a = hl.get_window(p.anchor and ('address:' .. p.anchor) or '') "
      + "if a then "
      + "local dx = math.floor(p.x - (a.at.x or a.at[1])) "
      + "if dx ~= 0 then hl.dispatch(hl.dsp.layout('move ' .. (dx > 0 and '+' or '') .. dx)) end "
      + "if p.focus then " + view.focusKeepingPointer("a") + "end "
      + "end "
      + view.animateAgain(id)
      + "end")
  }

  // ------------------------------------------------------------ dropping

  // Called by a dragged thumbnail with the pointer in this surface's
  // coordinates; lights the workspace tile under it.
  function dragOver(x, y) {
    var target = ""
    for (var i = 0; i < tiles.count; i++) {
      var tile = tiles.itemAt(i)
      if (!tile) continue
      var p = tile.mapFromItem(null, x, y)
      if (tile.contains(p)) { target = String(tile.workspace.id); break }
    }
    if (!target) {
      var q = addTile.mapFromItem(null, x, y)
      if (addTile.contains(q)) target = "emptynm"
    }
    view.dropTarget = target
    var over = target ? -1 : Layout.rectAt(view.slots, x, y)
    view.swapTarget = over >= 0 && view.windows[over] !== view.dragged ? view.windows[over] : null
  }

  function workspaceForId(id) {
    for (var i = 0; i < view.workspaces.length; i++)
      if (view.workspaces[i].id === id) return view.workspaces[i]
    return null
  }

  // Returns whether the window was sent somewhere. Trading places is not
  // that: the thumbnail eases home, to its new slot once Hyprland has said.
  function drop(toplevel) {
    var target = view.dropTarget
    var other = view.swapTarget
    view.dropTarget = ""
    view.swapTarget = null
    if (other) {
      view.overview.swapWindows(toplevel, other)
      return false
    }
    if (!target || (view.workspace && target === String(view.workspace.id))) return false
    return view.overview.moveWindow(toplevel, target)
  }

  // ------------------------------------------------------------ keyboard

  // Omarchy gives each monitor a block of ten workspaces (11-20 on the
  // second) and numbers them 1-9 and 0 within it, in the bar and on
  // SUPER+number alike; the overview does the same.
  function slotLabel(id) {
    var slot = (id - 1) % 10 + 1
    return slot === 10 ? "0" : String(slot)
  }

  function workspaceForDigit(digit) {
    var active = view.monitor && view.monitor.activeWorkspace ? view.monitor.activeWorkspace.id : 1
    return Math.floor((Math.max(1, active) - 1) / 10) * 10 + digit
  }

  function cycleCursor(step) {
    var n = view.windows.length
    if (n > 0) view.cursor = (view.cursorIndex + step + n) % n
  }

  function handleKey(event) {
    var key = event.key
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var current = view.cursorIndex >= 0 ? view.windows[view.cursorIndex] : null
    var dir = key === Qt.Key_Left || key === Qt.Key_H ? "left"
      : key === Qt.Key_Right || key === Qt.Key_L ? "right"
      : key === Qt.Key_Up || key === Qt.Key_K ? "up"
      : key === Qt.Key_Down || key === Qt.Key_J ? "down" : ""
    // Number keys switch workspace like SUPER+number; with shift they send
    // the selected window there instead, like a drag. Shift+1 arrives as
    // "!", so the native scan code says which digit it was.
    var digit = -1
    if (key >= Qt.Key_1 && key <= Qt.Key_9) digit = key - Qt.Key_0
    else if (key === Qt.Key_0) digit = 10
    else if (shift && event.nativeScanCode >= 10 && event.nativeScanCode <= 19) digit = event.nativeScanCode - 9

    if (key === Qt.Key_Escape) {
      view.overview.dismiss("glide")
    } else if (dir && shift) {
      // The selection stays on the window as it trades places.
      var next = Layout.neighbor(view.slots, view.cursorIndex, dir)
      if (current && next >= 0 && next !== view.cursorIndex) {
        view.cursor = view.cursorIndex
        view.overview.swapWindows(current, view.windows[next])
      }
    } else if (dir) {
      view.cursor = Layout.neighbor(view.slots, view.cursorIndex, dir)
    } else if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
      view.cycleCursor(key === Qt.Key_Backtab || shift ? -1 : 1)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
      if (current) view.overview.activate(current)
    } else if (key === Qt.Key_Delete) {
      if (current) view.overview.closeWindow(current)
    } else if (key === Qt.Key_N || key === Qt.Key_Plus || key === Qt.Key_Equal) {
      if (shift && current && key === Qt.Key_N) view.overview.moveWindow(current, "emptynm")
      else view.overview.newWorkspace(view.monitor)
    } else if (digit > 0) {
      if (shift) {
        var target = view.workspaceForDigit(digit)
        if (current && !(view.workspace && view.workspace.id === target)) view.overview.moveWindow(current, target)
      } else {
        view.switchToId(view.workspaceForDigit(digit))
      }
    }
    // Swallow everything: a key meant for the overview must not reach the
    // window underneath.
    event.accepted = true
  }

  // ------------------------------------------------------------ drawing

  // The desktop sinks away: the wallpaper, sharp and just as the desktop
  // shows it, fades in over the real screen while the thumbnails
  // lift off it, and fades out as they land. Only the workspace strip is
  // frosted (stripGlass).
  // Faded as one flat layer. Opacity alone reaches each child separately, so
  // the dark layers meant to stay hidden under the sharp wallpaper would show
  // through as it fades, and the whole screen would dip darker on the way.
  //
  // Sized by the screen, never by the surface: each time the surface maps it
  // passes through 0×0 and a pixel ratio of 1. Followed, that dropped the
  // decoded wallpapers (BackgroundMedia unloads at a decode size of 0) and
  // every layer's texture, so each opening decoded the 4K wallpaper again
  // (from Qt's image cache if recent, else from disk) and redid every blur in
  // the middle of the opening motion.
  Item {
    id: backdrop
    readonly property real scale: view.monitor && view.monitor.scale > 0 ? view.monitor.scale : 1
    readonly property size pixels: Qt.size(Math.ceil(width * scale), Math.ceil(height * scale))
    width: view.modelData ? view.modelData.width : 0
    height: view.modelData ? view.modelData.height : 0
    opacity: view.backdropFade
    layer.enabled: true
    layer.textureSize: backdrop.pixels

    // Only with no wallpaper to show. One still decoding on the first opening
    // leaves the desktop in view, rather than a dark screen for a moment.
    Rectangle {
      anchors.fill: parent
      color: view.overview.background
      visible: view.overview.wallpaperPath === ""
    }

    // Blurred once and kept as a texture: nothing blurs per frame. Decoded
    // small; a heavy blur loses nothing. Not seen itself (the sharp
    // wallpaper covers it): the strip shows its own part of it.
    Item {
      id: blurredWallpaperItem
      anchors.fill: parent
      layer.enabled: true
      layer.textureSize: backdrop.pixels
      // Never without the sharp wallpaper over it, or the frost fills the
      // screen.
      visible: wallpaper.ready && sharpWallpaper.ready

      BackgroundMedia {
        id: wallpaper
        anchors.fill: parent
        path: view.overview.wallpaperPath
        cached: true
        constrainDecode: true
        decodeSize: Qt.size(Math.ceil(width / 4), Math.ceil(height / 4))
      }

      MultiEffect {
        anchors.fill: parent
        source: wallpaper
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: 64
        blurMultiplier: 0.6
        saturation: -0.15
      }
    }

    // Hyprland's blur, to match real windows: its radius and brightness from
    // the config (Omaview.qml). Lighter than the strip's frost, so it starts
    // from the sharp wallpaper. Brightness multiplies, as a black veil does;
    // MultiEffect's own adds. Not seen either: thumbnails cut out the piece
    // behind a translucent window (see windowGlass).
    Item {
      id: windowGlassItem
      anchors.fill: parent
      layer.enabled: true
      layer.textureSize: Qt.size(backdrop.width, backdrop.height)
      visible: sharpWallpaper.ready

      MultiEffect {
        anchors.fill: parent
        source: sharpWallpaper
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: Math.round(view.overview.glassBlurRadius)
        blurMultiplier: 0
      }

      Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: 1 - view.overview.glassBrightness
      }
    }

    // The wallpaper as the desktop shows it, decoded at the screen's own
    // pixel size so it is as sharp. Kept once decoded, like the blurred one.
    // By the monitor's scale, not the window's: that passes through other
    // values each time the window maps, unless the scale happens to be 2, and
    // a new size would decode it all over again.
    BackgroundMedia {
      id: sharpWallpaper
      anchors.fill: parent
      path: view.overview.wallpaperPath
      cached: true
      constrainDecode: true
      decodeSize: backdrop.pixels
    }
  }

  // A click on empty space closes, like Esc.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onClicked: view.overview.dismiss("glide")
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: true
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) { view.handleKey(event) }
    Component.onCompleted: if (view.takesKeyboard) keyCatcher.forceActiveFocus()
  }

  // This monitor's workspaces, in order. Special workspaces have negative
  // ids and are not places you switch to.
  readonly property var workspaces: {
    var out = []
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      if (all[i].monitor !== view.monitor || all[i].id <= 0) continue
      out.push(all[i])
    }
    out.sort(function(a, b) { return a.id - b.id })
    return out
  }

  readonly property int tileGap: Style.space(20)
  readonly property int addWidth: Style.space(56)
  readonly property var tileSize: Layout.stripTiles(view.workspaces.length, view.width - view.outer * 2,
    view.width / Math.max(1, view.height),
    { gap: view.tileGap, maxH: Math.round(view.height * 0.115), addW: view.addWidth })
  readonly property real tileScale: view.tileSize.w / Math.max(1, view.width)
  readonly property real stripBottom: strip.height

  Rectangle {
    id: strip
    width: parent.width
    height: Style.space(28) + view.tileSize.h + Style.space(10) + Math.ceil(Style.font.body * 1.4) + Style.space(30)
    // Drops in from just above as the overview opens.
    y: -Style.space(24) * (1 - view.fade)
    opacity: view.fade
    color: "transparent"

    // Frosted glass: the blurred wallpaper behind the strip, under its tint;
    // the rest of the background stays sharp.
    ShaderEffectSource {
      id: stripGlass
      anchors.fill: parent
      sourceItem: blurredWallpaperItem
      sourceRect: Qt.rect(strip.x, strip.y, strip.width, strip.height)
    }

    Rectangle {
      anchors.fill: parent
      color: view.overview.glassFill
    }

    // The glass's lit edge.
    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: 1
      color: view.overview.glassEdge
    }

    Row {
      id: stripRow
      anchors.horizontalCenter: parent.horizontalCenter
      y: Style.space(28)
      spacing: view.tileGap

      Repeater {
        id: tiles
        // Keyed by workspace, so a tile and its pictures live as long as its
        // workspace does. A plain array made a new tile for every one each
        // time the list was read again, as on every opening, and each came
        // back blank until its windows were captured anew.
        model: ScriptModel { values: view.workspaces }

        delegate: Item {
          id: tileItem
          required property var modelData
          readonly property var workspace: tileItem.modelData
          readonly property bool current: tileItem.workspace === view.workspace
          readonly property bool target: view.dropTarget !== "" && view.dropTarget === String(tileItem.workspace.id)
          readonly property bool hot: tileMouse.containsMouse && !view.dragged
          readonly property Item windowsLayer: tileWindows

          width: view.tileSize.w
          height: view.tileSize.h

          // The ring sits outside the tile with a gap, so the thumbnail
          // inside is never covered.
          Rectangle {
            anchors.fill: parent
            anchors.margins: -(Style.space(3) + border.width)
            radius: view.overview.tileRadius > 0 ? view.overview.tileRadius + Style.space(3) + border.width : 0
            color: "transparent"
            border.width: tileItem.target ? Style.space(3) : Style.space(2)
            border.color: view.overview.accent
            visible: tileItem.current || tileItem.target
            scale: tileItem.target ? 1.06 : 1
          }

          ClippingRectangle {
            id: tileBody
            anchors.fill: parent
            radius: view.overview.tileRadius
            color: tileItem.target || tileItem.hot ? view.overview.tileFillHot : view.overview.tileFill
            border.width: 1
            border.color: view.overview.glassEdge
            scale: tileItem.target ? 1.06 : 1
            Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

            // The workspace's screen as it looks: its windows where they
            // really are, scaled down, those off screen clipped away.
            // Just the windows, no fill: what grows to fill the screen when
            // this workspace is chosen (zoomInto).
            Item {
              id: tileWindows
              anchors.fill: parent
              Repeater {
                model: tileItem.workspace.toplevels

                delegate: Rectangle {
                  id: mini
                  required property var modelData
                  readonly property var real: view.realRect(mini.modelData)
                  readonly property bool shown: !((mini.modelData.lastIpcObject || {}).hidden === true)
                  // The workspace on show mirrors the spread's pictures
                  // (WindowCapture.mirrorOf).
                  readonly property bool mirrored: tileItem.current
                  visible: mini.shown && mini.real.w > 0
                  x: mini.real.x * view.tileScale
                  y: mini.real.y * view.tileScale
                  width: mini.real.w * view.tileScale
                  height: mini.real.h * view.tileScale
                  radius: view.overview.rounded ? Style.space(3) : 0
                  color: view.overview.windowFill
                  border.width: 1
                  border.color: view.overview.hairline
                  clip: true

                  // Other workspaces: one frame each is enough to recognise
                  // them, and nothing on them moves meanwhile.
                  WindowCapture {
                    anchors.fill: parent
                    anchors.margins: 1
                    mirrorOf: mini.mirrored ? view.pictureFor(mini.modelData) : null
                    source: !mini.mirrored && mini.visible ? mini.modelData.wayland : null
                    active: view.overview.mapped
                    paused: view.passing || !view.overview.opened
                    stayLive: false
                    glass: view.overview.isTerminal(mini.modelData)
                    // Glass over the strip, from what is right behind the
                    // tile, at its own scale. A tile growing to the whole
                    // screen (zoomInto) lands on the real windows' glass.
                    backdrop: view.zooming ? view.windowGlass : blurredWallpaperItem
                    backdropRect: view.wallpaperBehind(view.zooming ? mini.real
                      : { x: stripRow.x + tileItem.x + mini.x, y: strip.y + stripRow.y + tileItem.y + mini.y, w: mini.width, h: mini.height })
                    glassBackground: view.overview.background
                    glassAlpha: view.overview.terminalAlpha
                    windowAlpha: view.overview.windowAlpha(mini.modelData)
                    // Hyprland captures a window on any workspace, as long as
                    // where it sits overlaps the monitor.
                    snapshotTick: view.overview.snapshotTick
                    onScreen: mini.real.x + mini.real.w > 0 && mini.real.x < view.width
                      && mini.real.y + mini.real.h > 0 && mini.real.y < view.height
                    windowSize: Qt.size(mini.real.w, mini.real.h)
                  }
                }
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height + Style.space(10)
            textFormat: Text.PlainText
            text: {
              var ws = tileItem.workspace
              var slot = view.slotLabel(ws.id)
              var name = String(ws.name || "")
              return name && name !== String(ws.id) ? slot + " · " + name : slot
            }
            color: tileItem.current || tileItem.target ? view.overview.foreground : view.overview.softText
            font.family: view.overview.fontFamily
            font.pixelSize: Style.font.body
            font.bold: tileItem.current || tileItem.target
            visible: !tileItem.target
          }

          DropBadge {
            visible: tileItem.target
            text: "Move to " + view.slotLabel(tileItem.workspace.id)
          }

          MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onClicked: function(mouse) {
              if (mouse.button === Qt.MiddleButton) view.overview.removeWorkspace(tileItem.workspace, view.monitor)
              else view.zoomInto(tileItem)
            }
          }
        }
      }

      Item {
        id: addTile
        readonly property bool target: view.dropTarget === "emptynm"
        width: view.addWidth
        height: view.tileSize.h

        Shape {
          anchors.fill: parent
          preferredRendererType: Shape.CurveRenderer
          scale: addTile.target ? 1.06 : 1

          ShapePath {
            strokeColor: addTile.target ? view.overview.accent : view.overview.dashed
            strokeWidth: addTile.target ? Style.space(2) : 1.5
            strokeStyle: addTile.target ? ShapePath.SolidLine : ShapePath.DashLine
            dashPattern: [4, 3]
            fillColor: addTile.target || addMouse.containsMouse ? view.overview.tileFill : "transparent"

            PathRectangle {
              x: 1
              y: 1
              width: addTile.width - 2
              height: addTile.height - 2
              radius: view.overview.tileRadius
            }
          }
        }

        // A plus, drawn rather than typed so no font has to carry it.
        Shape {
          anchors.centerIn: parent
          width: Style.space(20)
          height: Style.space(20)
          preferredRendererType: Shape.CurveRenderer

          ShapePath {
            strokeColor: addTile.target ? view.overview.accent : view.overview.softText
            strokeWidth: Style.space(2)
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: Style.space(10); startY: Style.space(3)
            PathLine { x: Style.space(10); y: Style.space(17) }
            PathMove { x: Style.space(3); y: Style.space(10) }
            PathLine { x: Style.space(17); y: Style.space(10) }
          }
        }

        DropBadge {
          visible: addTile.target
          text: "New workspace"
        }

        MouseArea {
          id: addMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: view.overview.newWorkspace(view.monitor)
        }
      }
    }
  }

  // Under a tile while a window is dragged over it: where the window goes.
  component DropBadge: Rectangle {
    id: badge
    property string text: ""
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height + Style.space(10)
    width: badgeText.implicitWidth + Style.space(16)
    height: badgeText.implicitHeight + Style.space(4)
    radius: view.overview.rounded ? Style.space(4) : 0
    color: view.overview.accent

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: badge.text
      color: view.overview.background
      font.family: view.overview.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  // Where the dragged window came from, held open until it lands.
  Shape {
    visible: !!view.draggedSlot
    x: view.draggedSlot ? view.draggedSlot.x : 0
    y: view.draggedSlot ? view.draggedSlot.y : 0
    width: view.draggedSlot ? view.draggedSlot.w : 0
    height: view.draggedSlot ? view.draggedSlot.h : 0
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeColor: view.overview.hairline
      strokeWidth: 1.5
      strokeStyle: ShapePath.DashLine
      dashPattern: [4, 3]
      fillColor: "transparent"

      PathRectangle {
        x: 1
        y: 1
        width: Math.max(0, (view.draggedSlot ? view.draggedSlot.w : 0) - 2)
        height: Math.max(0, (view.draggedSlot ? view.draggedSlot.h : 0) - 2)
        radius: view.overview.windowRadius
      }
    }
  }

  Text {
    anchors.centerIn: parent
    visible: view.windows.length === 0
    opacity: view.fade
    textFormat: Text.PlainText
    text: "No windows on this workspace"
    color: view.overview.softText
    font.family: view.overview.fontFamily
    font.pixelSize: Style.font.subtitle
  }

  // Every toplevel gets a delegate that stays alive while it exists; the ones
  // not on this workspace hide. A filtered array model would rebuild every
  // thumbnail, and restart every capture, each time a window opened or closed.
  Repeater {
    id: thumbnails
    model: Hyprland.toplevels

    delegate: Thumbnail {
      host: view
      overview: view.overview
    }
  }

  // ------------------------------------------------------------ zoom

  // The chosen workspace's tile, copied at the screen's size so it stays
  // sharp as it grows, from where the tile sits to the whole screen. Its
  // windows are the real ones' pictures at their real places, so the last
  // frame matches the desktop Hyprland has already switched to underneath.
  property rect zoomFrom: Qt.rect(0, 0, 0, 0)
  property Item zoomSource: null
  readonly property real zoomT: view.zooming ? 1 - view.overview.reveal : 0

  ShaderEffectSource {
    id: zoomLayer
    z: 2000
    visible: view.zooming && !!view.zoomSource
    sourceItem: view.zooming ? view.zoomSource : null
    // Live: the windows' places are asked for again once the workspace is
    // on screen (zoomRefresh), and the tile follows as it grows.
    live: view.zooming
    opacity: view.backdropFade
    textureSize: Qt.size(Math.ceil(view.width * view.devicePixelRatio), Math.ceil(view.height * view.devicePixelRatio))
    x: Layout.lerp(view.zoomFrom.x, 0, view.zoomT)
    y: Layout.lerp(view.zoomFrom.y, 0, view.zoomT)
    width: Layout.lerp(view.zoomFrom.width, view.width, view.zoomT)
    height: Layout.lerp(view.zoomFrom.height, view.height, view.zoomT)
  }

  // A number key: zoom into that workspace's tile when it has one, as a
  // click does; otherwise (an empty workspace not yet made) just go.
  function switchToId(id) {
    for (var i = 0; i < tiles.count; i++) {
      var tile = tiles.itemAt(i)
      if (tile && tile.workspace && tile.workspace.id === id) {
        view.zoomInto(tile)
        return
      }
    }
    view.overview.switchWorkspaceId(id, view.monitor)
  }

  function zoomInto(tile) {
    var ws = tile.workspace
    if (!ws || (view.monitor && view.monitor.activeWorkspace === ws) || !tile.windowsLayer) {
      view.overview.switchWorkspace(ws, view.monitor)
      return
    }
    var p = tile.windowsLayer.mapToItem(null, 0, 0)
    view.zoomFrom = Qt.rect(p.x, p.y, tile.windowsLayer.width, tile.windowsLayer.height)
    view.zoomSource = tile.windowsLayer
    zoomLayer.scheduleUpdate()
    view.overview.switchWorkspace(ws, view.monitor, "zoom")
    zoomRefresh.restart()
  }

  // Once Hyprland has the workspace on screen, where its windows now are.
  Timer {
    id: zoomRefresh
    interval: 40
    onTriggered: Hyprland.refreshToplevels()
  }
}
