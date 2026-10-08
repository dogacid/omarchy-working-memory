#!/bin/bash
# Installs the working-memory scratchpad on Omarchy (Hyprland) or archsway
# (sway):
#   - builds the Qt binary (bin/build) and symlinks it plus the toggle
#     script onto ~/.local/bin
#   - Omarchy, if ~/.config/hypr/hyprland.lua exists:
#     - symlinks the Quickshell bar-widget plugin into ~/.config/omarchy/plugins/
#     - symlinks the Hyprland window-rule/keybinding module and wires it into
#       ~/.config/hypr/hyprland.lua (idempotent: skips if already required)
#     - adds the bar-widget to the bar layout via `omarchy bar put`
#   - sway, if ~/.config/sway exists: symlinks sway/working-memory.conf into
#     ~/.config/sway/config.d/ (which archsway's sway config includes)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="$HOME/.local/bin"
PLUGIN_DST="$HOME/.config/omarchy/plugins/omarchy-working-memory"
HYPR_DIR="$HOME/.config/hypr"
HYPRLAND_LUA="$HYPR_DIR/hyprland.lua"
SWAY_DIR="$HOME/.config/sway"

mkdir -p "$LOCAL_BIN"

echo "Building omarchy-working-memory..."
"$REPO_DIR/bin/build"

# Symlinked, not copied, so a rebuild (bin/build) takes effect immediately
# without rerunning this installer, same as the toggle script.
ln -sfn "$REPO_DIR/build/omarchy-working-memory" "$LOCAL_BIN/omarchy-working-memory"
ln -sfn "$REPO_DIR/bin/omarchy-working-memory-toggle" "$LOCAL_BIN/omarchy-working-memory-toggle"

if [[ -f "$HYPRLAND_LUA" ]]; then
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
fi

if [[ -d "$SWAY_DIR" ]]; then
  echo "Linking sway config..."
  mkdir -p "$SWAY_DIR/config.d"
  ln -sfn "$REPO_DIR/sway/working-memory.conf" "$SWAY_DIR/config.d/working-memory.conf"
  if [[ -n ${SWAYSOCK:-} ]]; then
    swaymsg reload >/dev/null || echo "swaymsg reload failed; check the sway config" >&2
  fi
fi

if [[ ! -f "$HYPRLAND_LUA" && ! -d "$SWAY_DIR" ]]; then
  echo "Neither Hyprland (~/.config/hypr/hyprland.lua) nor sway (~/.config/sway) found;" >&2
  echo "only the binary and toggle script were installed." >&2
fi

echo "Done. Press Super+N (or click the bar icon on Omarchy) to open the working-memory scratchpad."
