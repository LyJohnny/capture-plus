#!/usr/bin/env bash
#
# Build Capture + (Release, signed with the local self-signed cert) and install it
# to /Applications. This is the normal way to (re)build the app.
#
# First time on a new Mac: run `scripts/setup-signing.sh` once, then this.
set -euo pipefail
cd "$(dirname "$0")/.."

# Signing cert is still named "Capture Plus Self-Signed" (renaming it would reset the granted
# Screen Recording / Mic permissions, which are keyed to it + the bundle id).
CN="Capture Plus Self-Signed"
KC="$HOME/Library/Keychains/capture-plus-signing.keychain-db"
KCPASS="capture-plus-local"
APP_NAME="Capture +"

command -v xcodegen >/dev/null || { echo "✗ xcodegen not found — run: brew install xcodegen"; exit 1; }
security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CN" \
  || { echo "✗ No signing identity — run scripts/setup-signing.sh first"; exit 1; }

security unlock-keychain -p "$KCPASS" "$KC"
xcodegen generate

echo "▶ Building (Release, signed)…"
xcodebuild -project CapturePlus.xcodeproj -scheme CapturePlus -configuration Release \
  -destination 'platform=macOS' build | tail -3

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData/CapturePlus-"*/Build/Products/Release \
  -maxdepth 1 -name "$APP_NAME.app" 2>/dev/null | head -1)
[ -n "${APP:-}" ] || { echo "✗ Build product not found"; exit 1; }

codesign --verify --deep "$APP" && echo "✓ signature valid"

DEST="/Applications/$APP_NAME.app"
[ -w /Applications ] || { mkdir -p "$HOME/Applications"; DEST="$HOME/Applications/$APP_NAME.app"; }

osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "✓ Installed: $DEST"

open "$DEST" && echo "✓ Launched"
