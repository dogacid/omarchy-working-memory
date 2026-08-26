#!/bin/bash
# Installs the working-memory scratchpad into this Omarchy system:
#   - builds the TUI binary and the toggle script onto ~/.local/bin
#   - symlinks the Quickshell bar-widget plugin into ~/.config/omarchy/plugins/
#   - symlinks the Hyprland window-rule/keybinding module and wires it into
#     ~/.config/hypr/hyprland.lua (idempotent: skips if already required)
#   - adds the bar-widget to the bar layout via `omarchy bar put`
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"
PLUGIN_DST="$HOME/.config/omarchy/plugins/omarchy-working-memory"
HYPR_DIR="$HOME/.config/hypr"
HYPRLAND_LUA="$HYPR_DIR/hyprland.lua"

mkdir -p "$LOCAL_BIN"

echo "Building omarchy-working-memory..."
go -C "$REPO_DIR" build -o "$LOCAL_BIN/omarchy-working-memory" .

install -m755 "$REPO_DIR/bin/omarchy-working-memory-toggle" "$LOCAL_BIN/omarchy-working-memory-toggle"

echo "Linking Quickshell plugin..."
mkdir -p "$(dirname "$PLUGIN_DST")"
ln -sfn "$REPO_DIR/plugin/omarchy-working-memory" "$PLUGIN_DST"

echo "Linking Hyprland module..."
ln -sfn "$REPO_DIR/hypr/working-memory.lua" "$HYPR_DIR/working-memory.lua"

if ! grep -q 'require("hypr.working-memory")' "$HYPRLAND_LUA"; then
  cp "$HYPRLAND_LUA" "$HYPRLAND_LUA.bak.$(date +%s)"
  printf '\nrequire("hypr.working-memory")\n' >>"$HYPRLAND_LUA"
  echo "Added require(\"hypr.working-memory\") to $HYPRLAND_LUA"
else
  echo "hyprland.lua already requires hypr.working-memory, skipping."
fi

if command -v hyprctl >/dev/null && hyprctl clients >/dev/null 2>&1; then
  hyprctl reload >/dev/null
  errors="$(hyprctl configerrors 2>/dev/null || true)"
  if [[ -n "$errors" && "$errors" != "ok" ]]; then
    echo "Hyprland reported config errors:" >&2
    echo "$errors" >&2
  fi
fi

if command -v omarchy-bar >/dev/null; then
  omarchy bar put omarchy-working-memory --section right || true
fi

echo "Done. Press Super+N or click the bar icon to open the working-memory scratchpad."
