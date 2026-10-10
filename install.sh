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
#   - registers the browser capture extension's native messaging host with
#     each Chromium-family browser that has a config dir (Chromium, Chrome,
#     Brave), and adds the extension to Chromium's --load-extension list in
#     ~/.config/chromium-flags.conf, the way Omarchy loads its own
#     extensions (other browsers: load extension/ unpacked by hand)
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
ln -sfn "$REPO_DIR/bin/omarchy-working-memory-native-host" "$LOCAL_BIN/omarchy-working-memory-native-host"

# The extension's ID is fixed by the "key" in extension/manifest.json, so
# the host can be restricted to exactly that extension.
EXTENSION_ID="mdmpmonhmledmdbohocaafjmjaanpjbn"
for browser_dir in "$HOME/.config/chromium" "$HOME/.config/google-chrome" "$HOME/.config/BraveSoftware/Brave-Browser"; do
  [[ -d "$browser_dir" ]] || continue
  mkdir -p "$browser_dir/NativeMessagingHosts"
  cat >"$browser_dir/NativeMessagingHosts/com.omarchy.working_memory.json" <<JSON
{
  "name": "com.omarchy.working_memory",
  "description": "omarchy-working-memory browser capture",
  "path": "$LOCAL_BIN/omarchy-working-memory-native-host",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
  echo "Registered the capture host with ${browser_dir#"$HOME/"}"
done

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

# Chromium reads extra command-line flags from this file; Omarchy ships it
# with a --load-extension list of its own extensions. Add ours to that list
# (only one --load-extension flag takes effect, so append, don't add a
# second line). Takes effect the next time Chromium starts.
CHROMIUM_FLAGS="$HOME/.config/chromium-flags.conf"
EXTENSION_DIR="$REPO_DIR/extension"
if [[ -f "$CHROMIUM_FLAGS" ]] && ! grep -qF "$EXTENSION_DIR" "$CHROMIUM_FLAGS"; then
  cp "$CHROMIUM_FLAGS" "$CHROMIUM_FLAGS.bak.$(date +%s)"
  if grep -q '^--load-extension=' "$CHROMIUM_FLAGS"; then
    sed -i "s|^--load-extension=.*|&,$EXTENSION_DIR|" "$CHROMIUM_FLAGS"
  else
    printf '%s\n' "--load-extension=$EXTENSION_DIR" >>"$CHROMIUM_FLAGS"
  fi
  echo "Added the capture extension to $CHROMIUM_FLAGS (restart Chromium to load it)"
elif [[ ! -f "$CHROMIUM_FLAGS" ]]; then
  echo "Browser capture: load $EXTENSION_DIR as an unpacked extension"
  echo "(chrome://extensions, Developer mode on, Load unpacked) — once."
fi
echo "Done. Press Super+N (or click the bar icon on Omarchy) to open the working-memory scratchpad."
