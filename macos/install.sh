#!/bin/bash
# Installs Working Memory on this Mac:
#   - builds and signs build/dist/Working Memory.app (macos/bundle) and
#     copies it into /Applications, quitting the running copy first
#   - registers the browser capture extension's native messaging host with
#     each Chromium-family browser that has a profile dir (Chrome, Chromium,
#     Brave, Edge, Arc, Vivaldi). Load extension/ unpacked by hand once:
#     chrome://extensions, Developer mode on, Load unpacked.
# Idempotent: rerun after a `git pull` to update.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Applications/Working Memory.app"
BUNDLE_ID="io.github.dogacid.omarchy-working-memory"

APP="$("$ROOT/macos/bundle" | tail -1)"

# A normal quit (not a signal), so the app saves and pushes on the way out.
if pgrep -xq omarchy-working-memory; then
  echo "Quitting the running Working Memory..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" || true
  for _ in $(seq 1 60); do pgrep -xq omarchy-working-memory || break; sleep 0.25; done
fi

rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"

# Same host name and extension ID as the Linux install.sh: the ID is fixed
# by the "key" in extension/manifest.json. The binary itself is the host —
# it recognizes the chrome-extension:// origin argument (see main.cpp).
EXTENSION_ID="mdmpmonhmledmdbohocaafjmjaanpjbn"
SUPPORT="$HOME/Library/Application Support"
for browser_dir in "$SUPPORT/Google/Chrome" "$SUPPORT/Google/Chrome for Testing" "$SUPPORT/Chromium" \
    "$SUPPORT/BraveSoftware/Brave-Browser" "$SUPPORT/Microsoft Edge" "$SUPPORT/Arc/User Data" "$SUPPORT/Vivaldi"; do
  [[ -d "$browser_dir" ]] || continue
  mkdir -p "$browser_dir/NativeMessagingHosts"
  cat >"$browser_dir/NativeMessagingHosts/com.omarchy.working_memory.json" <<JSON
{
  "name": "com.omarchy.working_memory",
  "description": "omarchy-working-memory browser capture",
  "path": "$DEST/Contents/MacOS/omarchy-working-memory",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
  echo "Registered the capture host with ${browser_dir#"$SUPPORT/"}"
done

open "$DEST"
echo "Done. Press Ctrl+Option+N (or use the menu-bar icon) to open Working Memory."
echo "Browser capture: load $ROOT/extension unpacked in chrome://extensions — once."
