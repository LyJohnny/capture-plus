#!/usr/bin/env bash
#
# Package the built "Capture +.app" into a distributable disk image:
#   dist/Capture-Plus.dmg  (volume name "Capture +", drag-to-Applications layout)
#
# Prereq: build the app first with scripts/build.sh (this script does not build).
#
# The app is signed with a Developer ID certificate and the finished DMG is
# sent to Apple for notarization, then the ticket is stapled, so it opens with
# a plain double-click on any Mac. Needs the notarytool keychain profile
# "capture-plus-notary" (one-time: `xcrun notarytool store-credentials
# capture-plus-notary --apple-id <id> --team-id BDU36H5583`).
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
codesign -s "Developer ID Application" --timestamp "$OUT" && echo "✓ image signed"

echo "▶ Notarizing with Apple (usually 1–5 minutes)…"
xcrun notarytool submit "$OUT" --keychain-profile capture-plus-notary --wait --timeout 30m \
  | grep -E "id:|status:" | tail -2
xcrun stapler staple "$OUT" >/dev/null && echo "✓ notarization ticket stapled"
spctl --assess --type open --context context:primary-signature -v "$OUT" 2>&1 | grep -q "accepted" \
  && echo "✓ Gatekeeper accepts the image" \
  || { echo "✗ Gatekeeper rejects the image — check: xcrun notarytool log <id> --keychain-profile capture-plus-notary"; exit 1; }
SIZE=$(du -h "$OUT" | cut -f1 | tr -d ' ')
echo "✓ Created: $OUT ($SIZE) — opens with a double-click on any Mac"
