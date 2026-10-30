-- Omaview's shortcuts. bin/install-shortcuts.sh copies this file to
-- ~/.config/hypr/omaview.lua each time the shell starts and loads it from
-- bindings.lua with require("hypr.omaview"), so an edit to the copy does not
-- last: change hypr/omaview.lua in the plugin.

local function overview_open()
  for _, layer in ipairs(hl.get_layers()) do
    if layer.namespace == "omaview" then return true end
  end
  return false
end

-- Through the shell's own shortcut: no process starts on the way. Sent
-- from a timer, outside the binding: sent from a release binding, Hyprland
-- passes it on as released, and the shell acts on pressed.
local function toggle()
  hl.timer(function() hl.dispatch(hl.dsp.global("omaview:toggle")) end, { timeout = 1, type = "oneshot" })
end
o.bind_expressions[toggle] = 'hl.dsp.global("omaview:toggle")'

-- Open: tap Super on its own. The release bind is skipped by Hyprland when
-- another key or mouse button went down during the hold, so every other
-- Super shortcut acts as before; a hold longer than tap_ms is no tap.
do
  local tap_ms = 250
  local generation, pressed = 0, 0
  local function later(ms, fn) hl.timer(fn, { timeout = ms, type = "oneshot" }) end
  local function press()
    generation = generation + 1
    local mine = generation
    pressed = mine
    later(tap_ms, function() if pressed == mine then pressed = 0 end end)
  end
  local function release()
    if pressed == 0 then return end
    pressed = 0
    toggle()
  end
  o.bind_expressions[release] = 'hl.dsp.global("omaview:toggle")'
  for _, key in ipairs({ "Super_L", "Super_R" }) do
    o.bind(key, nil, press, { non_consuming = true, transparent = true })
    o.bind("SUPER + " .. key, "Omaview (tap Super)", release, { release = true, non_consuming = true })
  end
end

-- 4 fingers up opens it.
hl.gesture({ fingers = 4, direction = "up", action = toggle })

-- While the overview is open these act on the window selected there, and
-- on the focused window as usual otherwise.
do
  local function act()
    if overview_open() then hl.dispatch(hl.dsp.global("omaview:close-selected")) return end
    hl.dispatch(hl.dsp.window.close())
  end
  o.bind_expressions[act] = "hl.dsp.window.close()"
  o.rebind("SUPER + W", "Close window", act)
end
do
  local function act()
    if overview_open() then hl.dispatch(hl.dsp.global("omaview:close-selected")) return end
    hl.dispatch(hl.dsp.window.close())
  end
  o.bind_expressions[act] = "hl.dsp.window.close()"
  o.rebind("SUPER + Q", "Close window", act)
end
do
  local function act()
    if overview_open() then hl.dispatch(hl.dsp.global("omaview:maximize-selected")) return end
    hl.dispatch(hl.dsp.window.fullscreen({ mode = "maximized" }))
  end
  o.bind_expressions[act] = "hl.dsp.window.fullscreen({ mode = \"maximized\" })"
  o.rebind("SUPER + ALT + F", "Full width", act)
end
do
  local launch = o.launch_terminal()
  local function act()
    if overview_open() then hl.dispatch(hl.dsp.global("omaview:terminal-selected")) return end
    launch()
  end
  o.bind_commands[act] = "omarchy-launch-terminal"
  o.rebind("SUPER + RETURN", "Terminal", act)
end

-- Alt+Tab moves that selection: Hyprland takes the key before the overview
-- sees it. Otherwise Omarchy's two bindings on each key, as one.
do
  local function bind(keys, description, shortcut, next)
    local function act()
      if overview_open() then hl.dispatch(hl.dsp.global("omaview:" .. shortcut)) return end
      hl.dispatch(hl.dsp.window.cycle_next({ next = next }))
      hl.dispatch(hl.dsp.window.bring_to_top())
    end
    o.bind_expressions[act] = "hl.dsp.window.cycle_next({ next = " .. tostring(next) .. " })"
    o.rebind(keys, description, act)
  end
  bind("ALT + TAB", "Focus on next window", "next-selected", true)
  bind("ALT + SHIFT + TAB", "Focus on previous window", "previous-selected", false)
end
