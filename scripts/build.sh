#!/usr/bin/env bash
#
# Build Capture + (Release, signed with the Developer ID certificate, hardened
# runtime on) and install it to /Applications. This is the normal way to
# (re)build the app.
#
# First time on a new Mac: Xcode → Settings → Accounts → Manage Certificates
# must show "Developer ID Application" (import it from the Mac that created it),
# then run this.
set -euo pipefail
cd "$(dirname "$0")/.."

CN="Developer ID Application"
APP_NAME="Capture +"

command -v xcodegen >/dev/null || { echo "✗ xcodegen not found — run: brew install xcodegen"; exit 1; }
security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN" \
  || { echo "✗ No '$CN' certificate in the keychain — add it in Xcode → Settings → Accounts → Manage Certificates"; exit 1; }

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
