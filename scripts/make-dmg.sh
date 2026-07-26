#!/usr/bin/env bash
#
# Package the built "Capture +.app" into a distributable disk image:
#   dist/Capture-Plus.dmg  (volume name "Capture +", drag-to-Applications layout)
#
# Prereq: build the app first with scripts/build.sh (this script does not build).
#
# NOTE ON GATEKEEPER: the app is self-signed, NOT notarized. On another person's
# Mac, first launch is blocked. On macOS 15 (Sequoia)/26 (Tahoe) the old
# right-click → Open shortcut no longer works — the recipient must approve it via
# System Settings → Privacy & Security → "Open Anyway" (steps are bundled into the
# DMG as "How to Open Capture +.txt"). Clean double-click for everyone would
# require an Apple Developer ID + notarization ($99/yr).
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

# Bundle first-launch instructions in the DMG so a recipient isn't stuck at the
# Gatekeeper block. Steps are correct for macOS 15 (Sequoia) / 26 (Tahoe).
cat > "$STAGING/How to Open Capture +.txt" <<'TXT'
How to open Capture + (first time only)
=======================================

Capture + is a personal app that isn't in the App Store, so macOS asks you to
approve it ONCE. This is normal and only happens the first time.

1. Drag "Capture +" onto the Applications folder in this window.

2. Open your Applications folder and double-click Capture +.
   macOS says it "could not verify" the app  ->  click  Done.
   (Do NOT click "Move to Trash".)

3. Open  System Settings  ->  Privacy & Security.
   Scroll down to the "Security" section. You'll see:
      "Capture +.app" was blocked to protect your Mac.
   Click  Open Anyway.

4. Confirm with Touch ID or your password, then click  Open.

Done — Capture + now opens normally every time.

The first time you take a screenshot or recording, macOS asks for Screen
Recording permission. Allow it — that's what lets Capture + capture your screen.
(Microphone is only requested if you record your voice.)
TXT

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
echo "  Share this file. First launch on another Mac: approve it via System Settings"
echo "  → Privacy & Security → \"Open Anyway\" (see \"How to Open Capture +.txt\" in the DMG)."
