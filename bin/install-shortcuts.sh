#!/usr/bin/env bash

# Puts Omaview's shortcuts in place: hypr/omaview.lua copied into Hyprland's
# config, and bindings.lua loading it. Run by Omaview.qml as the shell starts.
# Hyprland reloads only when something changed, so a start with everything in
# place costs nothing. A reload that failed stays owed: the marker is left for
# the next start, when the files already match and nothing else would ask.

set -euo pipefail

plugin=$(cd "$(dirname "$0")/.." && pwd)
hypr="$HOME/.config/hypr"
require='require("hypr.omaview")'
reload_owed="${XDG_STATE_HOME:-$HOME/.local/state}/omaview/reload-owed"
changed=

# Omaview's bindings are Lua: a classic config has nowhere to load them.
[ -f "$hypr/bindings.lua" ] || exit 0

if ! cmp -s "$plugin/hypr/omaview.lua" "$hypr/omaview.lua"; then
  cp "$plugin/hypr/omaview.lua" "$hypr/omaview.lua"
  changed=1
fi

if ! grep -qxF "$require" "$hypr/bindings.lua"; then
  printf '\n-- Omaview: tap Super to open the overview.\n%s\n' "$require" >> "$hypr/bindings.lua"
  changed=1
fi

if [ -n "$changed" ]; then
  mkdir -p "$(dirname "$reload_owed")"
  touch "$reload_owed"
fi

[ -e "$reload_owed" ] || exit 0
hyprctl reload >/dev/null
rm -f "$reload_owed"
