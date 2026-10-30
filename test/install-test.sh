#!/usr/bin/env bash

# Tests bin/install-shortcuts.sh against a throwaway HOME, with a hyprctl that
# only counts reloads, and syntax-checks the Lua it installs.
#
#   bash test/install-test.sh

set -euo pipefail
cd "$(dirname "$0")/.."
plugin=$PWD

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home"
unset XDG_STATE_HOME
hypr="$HOME/.config/hypr"
mkdir -p "$hypr" "$work/bin"
printf '#!/bin/sh\n[ ! -e "%s/hyprctl-down" ] || exit 4\necho "$@" >> "%s/reloads"\n' "$work" "$work" > "$work/bin/hyprctl"
printf '#!/bin/sh\necho "$@" >> "%s/omarchy-calls"\n' "$work" > "$work/bin/omarchy"
chmod +x "$work/bin/hyprctl" "$work/bin/omarchy"
export PATH="$work/bin:$PATH"

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: wanted '$2', got '$3'"; fails=$((fails + 1)); fi
}
reloads() { if [ -f "$work/reloads" ]; then wc -l < "$work/reloads"; else echo 0; fi; }
requires() { grep -cxF 'require("hypr.omaview")' "$hypr/bindings.lua"; }
run() { bash "$plugin/bin/install-shortcuts.sh"; }

luac -p "$plugin/hypr/omaview.lua"
check "Lua parses" 0 $?
check "Super is bound" 1 "$(grep -c 'Omaview (tap Super)' "$plugin/hypr/omaview.lua")"

run
check "no bindings.lua: no omaview.lua" no "$([ -e "$hypr/omaview.lua" ] && echo yes || echo no)"
check "no bindings.lua: no reload" 0 "$(reloads)"

printf -- '-- mine\nhl.unbind("SUPER + X")' > "$hypr/bindings.lua"
run
check "first run copies the file" same "$(cmp -s "$plugin/hypr/omaview.lua" "$hypr/omaview.lua" && echo same)"
check "first run adds the require" 1 "$(requires)"
check "first run keeps the user's lines" 1 "$(grep -cxF 'hl.unbind("SUPER + X")' "$hypr/bindings.lua")"
check "first run reloads" 1 "$(reloads)"

run
check "second run adds nothing" 1 "$(requires)"
check "second run does not reload" 1 "$(reloads)"

echo "-- edited" >> "$hypr/omaview.lua"
run
check "a changed copy is replaced" same "$(cmp -s "$plugin/hypr/omaview.lua" "$hypr/omaview.lua" && echo same)"
check "replacing it reloads" 2 "$(reloads)"

echo "-- edited" >> "$hypr/omaview.lua"
touch "$work/hyprctl-down"
check "a failed reload fails the run" failed "$(run >/dev/null 2>&1 && echo ran || echo failed)"
rm "$work/hyprctl-down"
run
check "the next start reloads after all" 3 "$(reloads)"
run
check "and only once" 3 "$(reloads)"

# The removal steps as the README gives them, so the two cannot drift apart.
awk '/^## Remove/ { on = 1 } on && /^```/ { if (code) exit; code = 1; next } code' "$plugin/README.md" > "$work/remove.sh"
mkdir -p "$HOME/.local/state/omaview"
touch "$HOME/.local/state/omaview/reload-owed"
bash -euo pipefail "$work/remove.sh"
check "removal removes the plugin" "plugin remove shilai_li.omaview" "$(cat "$work/omarchy-calls")"
check "removal takes out the require" 0 "$(requires || true)"
check "removal takes out the comment" 0 "$(grep -c 'Omaview' "$hypr/bindings.lua" || true)"
check "removal keeps the user's lines" 1 "$(grep -cxF 'hl.unbind("SUPER + X")' "$hypr/bindings.lua")"
check "removal deletes the copy" no "$([ -e "$hypr/omaview.lua" ] && echo yes || echo no)"
check "removal deletes the state" no "$([ -e "$HOME/.local/state/omaview" ] && echo yes || echo no)"
check "removal reloads" 4 "$(reloads)"

[ "$fails" -eq 0 ]
