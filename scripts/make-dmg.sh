#!/usr/bin/env bash
#
# Package the built "Capture +.app" into a distributable disk image:
#   dist/Capture-Plus.dmg  (volume name "Capture +", drag-to-Applications layout)
#
# Prereq: build the app first with scripts/build.sh (this script does not build).
#
# NOTE ON GATEKEEPER: the app is self-signed, NOT notarized. On another person's
# Mac, first launch is blocked by Gatekeeper — they must right-click the app in
# /Applications and choose "Open" once (or System Settings > Privacy & Security >
# "Open Anyway"). After that it launches normally. Clean double-click for everyone
# would require an Apple Developer ID + notarization ($99/yr).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Capture +"
VOL_NAME="Capture +"
OUT="dist/Capture-Plus.dmg"

# Locate the freshly built app: prefer the Release build product, else the
# installed copy in /Applications (or ~/Applications).
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData/CapturePlus-"*/Build/Products/Release \
  -maxdepth 1 -name "$APP_NAME.app" 2>/dev/null | head -1)
[ -n "${APP:-}" ] || APP="/Applications/$APP_NAME.app"
[ -d "$APP" ] || APP="$HOME/Applications/$APP_NAME.app"
[ -d "$APP" ] || { echo "✗ '$APP_NAME.app' not found — run scripts/build.sh first"; exit 1; }
echo "▶ Packaging: $APP"

# Confirm it is signed (a broken signature would fail on the recipient's Mac).
codesign --verify --deep "$APP" 2>/dev/null && echo "✓ signature valid" \
  || { echo "✗ app signature invalid — rebuild with scripts/build.sh"; exit 1; }

# Stage the app + an Applications symlink so the recipient can drag to install.
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p dist
rm -f "$OUT"
echo "▶ Building disk image…"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT" >/dev/null

hdiutil verify "$OUT" >/dev/null && echo "✓ image verifies"
SIZE=$(du -h "$OUT" | cut -f1 | tr -d ' ')
echo "✓ Created: $OUT ($SIZE)"
echo ""
echo "  Share this file. First launch on another Mac: right-click the app in"
echo "  /Applications → Open (once) to get past Gatekeeper. See scripts/make-dmg.sh header."
