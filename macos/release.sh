#!/bin/bash
# Builds a notarized build/dist/Working-Memory-<version>.dmg that opens
# without a Gatekeeper warning on any Mac (running macOS 26+, see the .pro).
#
# One-time setup:
#   1. A "Developer ID Application" certificate in the keychain: Xcode ›
#      Settings › Accounts › your team › Manage Certificates › + .
#   2. Notary credentials saved under the profile name below:
#        xcrun notarytool store-credentials working-memory-notary \
#          --apple-id <you@example.com> --team-id <TEAMID>
#      (it prompts for an app-specific password from account.apple.com).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${NOTARY_PROFILE:-working-memory-notary}"

# Reuse the bundle macos/install.sh just built if nothing's changed since
# (macdeployqt makes a fresh one take several minutes).
APP="$ROOT/build/dist/Working Memory.app"
if [[ ! -d "$APP" ]] || [[ -n "$(find "$ROOT/src" "$ROOT/macos/Info.plist" "$ROOT/macos/entitlements.plist" "$ROOT/macos/AppIcon.icns" "$ROOT/omarchy-working-memory.pro" -newer "$APP/Contents/_CodeSignature/CodeResources" -print -quit 2>/dev/null)" ]]; then
  APP="$("$ROOT/macos/bundle" | tail -1)"
fi
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)"
if [[ -z "$IDENTITY" ]]; then
  echo "No Developer ID Application certificate found; see the setup at the top of $0." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/dist/Working-Memory-$VERSION.dmg"
STAGE="$ROOT/build/dist/dmg"

# The usual drag-to-Applications layout.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Working Memory" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "Submitting for notarization (usually a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Notarized: $DMG"
