# AGENTS.md — omaview

Notes for anyone (agent or human) working on this repo. User-facing docs live
in `README.md`; don't duplicate them here.

## What it is

**Omaview** (`shilai_li.omaview`) — a window overview for Hyprland, as an
Omarchy shell plugin of kind `overlay` with `keepLoaded: true`.

Non-negotiables:

- **No Hyprland plugin, no second Quickshell.** QML inside `omarchy-shell`.
- **Themed, never styled.** Only `Commons.Color.*` and `Style.*`, so
  `omarchy theme set` repaints it.
- **Smooth or nothing.** Every transition is animated at the display's refresh
  rate; opening must feel instant (no process start on the hot path).
- **Keyboard-driven too.** Everything the mouse does has a key.

## Ground truth — read it, don't guess

| What | Path |
|---|---|
| Shell source / UI kit / theme singletons | `/usr/share/omarchy/shell/{,Ui/,Commons/}` |
| Plugin contract + IPC table | `~/omarchy/docs/omarchy-shell.md` |
| Overlay reference | `~/Projects/omarchy-eye-break/Break.qml` |
| Quickshell version | `quickshell --version` (0.3.2 at time of writing) |

## Layout of the code

- `Omaview.qml` — lifecycle (one `reveal` clock, 0 = over the real windows,
  1 = spread), theme tokens, every `Hyprland.dispatch`. The clock moves on
  the frames the focused monitor's surface shows (`frameShown`), at most a
  refresh and a quarter per frame, not on Qt's animation clock: each opening
  maps a new surface, Hyprland misses a refresh on its first frames, and a
  clock that caught up jumped a third of the way in one frame. Measure with a
  `frameSwapped` log or a `gpu-screen-recorder` capture at the display's rate.
- `Overview.qml` — one `PanelWindow` per screen: blurred-wallpaper backdrop
  (decoded at quarter size, blurred once into a layer, only its opacity
  animates), glass strip, drop targets, keys, and the photo pass: once fully
  open, behind its opaque backdrop, it scrolls a scrolling layout to each
  off-screen window for one picture (live captures held), then back, putting
  the focused window where it was. Window positions are held (`held`) for
  the pass: Omarchy's notification service re-reads all windows on every
  focus change, which the pass causes. Every pass step checks in Lua
  (`hl.get_active_workspace`) that its workspace is still on screen: if the
  user switched away (SUPER+number, a swipe), nothing scrolls or refocuses
  then — the way back waits in `_G.omaview_pending` and is taken when they
  return. The follow-up focus after a choice is likewise skipped once the
  user has moved on, or has the overview open again. A focus command moves
  the pointer to the window's middle (`cursor:no_warps` is off): focuses the
  overview issues on its own (putting focus back) save and restore the
  pointer (`focusKeepingPointer`); only a window the user picked keeps it. Workspace tiles are keyed by
  workspace (`ScriptModel`) so they survive re-reads; a tile shows its
  workspace's screen as it looks, and the current workspace's tile mirrors
  the spread's pictures instead of capturing again.
- `Thumbnail.qml` — one per toplevel, hidden when not on this workspace.
- `WindowCapture.qml` — `ScreencopyView` that grabs a still first, then goes
  live, and keeps its last frame between openings. A refused capture ends the
  recording and drops the view's picture (`ScreencopyView.stopped` is never
  emitted; `hasContent` falling is the sign), so a copy of the last frame sits
  under the view until a new one is up. Hyprland renders a window
  into a capture only while it overlaps its monitor, so a window scrolled
  fully off screen (scrolling layout) gives no picture; it shows its last
  frame, or its app icon.
- `shaders/terminal-glass.frag` — captures arrive opaque, losing two kinds
  of see-through, which this puts back over `windowGlass` (Overview.qml), the
  wallpaper as Hyprland's blur leaves it: radius from `blur:size` and
  `blur:passes`, fitted to screenshots of real windows, and `blur:brightness`.
  The strip has its own, heavier frost. The two kinds: a
  terminal's own background opacity (theme background × opacity over black,
  redrawn; opacity from the theme's `foot.ini` `alpha`, only for windows
  Hyprland tags `terminal`), and Hyprland's opacity on the whole window
  (window rules, e.g. Files at 0.75), read at each opening with
  `hyprctl getprop` (Omaview.qml `askOpacities`). The compiled `.qsb` is
  committed; rebuild after editing:
  `/usr/lib/qt6/bin/qsb --qt6 -o shaders/terminal-glass.frag.qsb shaders/terminal-glass.frag`
- `hypr/omaview.lua` — the shortcuts. `bin/install-shortcuts.sh`
  (`test/install-test.sh`) copies it to `~/.config/hypr/omaview.lua` and adds
  `require("hypr.omaview")` to `bindings.lua`; Omaview.qml runs it as the
  shell starts, and Hyprland reloads only if something changed. Keys open the
  overview through the `omaview:toggle` global shortcut (no process).
- `Layout.js` — pure geometry, tested by `test/layout-test.sh`.

Hyprland here runs the Lua config: dispatches are `hl.dsp.*` expressions,
not classic dispatcher names. `keepLoaded` instances survive
`rescanPlugins`, so restart the shell to load edits.
