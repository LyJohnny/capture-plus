#!/usr/bin/env bash
#
# Cut a release end to end:
#   bump the version → build + install → notarized DMG → GitHub release
#   → sign the DMG for Sparkle → update appcast.xml → push.
#
# Usage: scripts/release.sh <version> [title] [notes]
#   e.g. scripts/release.sh 0.7.0 "Double-click install + in-app updates"
#
# Needs, once per Mac:
#   - "Developer ID Application" certificate in the keychain (see build.sh)
#   - notarytool profile "capture-plus-notary" (see make-dmg.sh)
#   - the Sparkle EdDSA private key in the keychain. It was created on the
#     first release Mac with `generate_keys`; move it to another Mac with
#     `generate_keys -x <file>` there and `generate_keys -f <file>` here.
#     Never commit that file.
#   - `gh auth login`
# The Sparkle tools are fetched automatically (pinned version below).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [title] [notes]}"
TITLE="${2:-Capture + v$VERSION}"
NOTES="${3:-}"
REPO="LyJohnny/capture-plus"
DMG="dist/Capture-Plus.dmg"

SPARKLE_VERSION="2.10.0"
SPARKLE_BIN="$HOME/.sparkle/$SPARKLE_VERSION/bin"

# --- Preflight ---------------------------------------------------------------
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ version must look like 1.2.3"; exit 1; }
[ "$(git branch --show-current)" = "main" ] || { echo "✗ release from main"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "✗ commit or stash your changes first"; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "✗ main differs from origin/main — pull/push first"; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "✗ tag v$VERSION already exists"; exit 1; }
command -v gh >/dev/null || { echo "✗ gh not found — brew install gh && gh auth login"; exit 1; }

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "▶ Fetching Sparkle $SPARKLE_VERSION tools…"
  mkdir -p "$SPARKLE_BIN/.."
  curl -sSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$SPARKLE_BIN/.." bin
fi

# --- 1. Version bump -----------------------------------------------------------
BUILD=$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"/\1/p' project.yml) + 1 ))
sed -i '' \
  -e "s/^\( *CFBundleShortVersionString: \)\"[^\"]*\"/\1\"$VERSION\"/" \
  -e "s/^\( *MARKETING_VERSION: \)\"[^\"]*\"/\1\"$VERSION\"/" \
  -e "s/^\( *CFBundleVersion: \)\"[^\"]*\"/\1\"$BUILD\"/" \
  -e "s/^\( *CURRENT_PROJECT_VERSION: \)\"[^\"]*\"/\1\"$BUILD\"/" \
  project.yml
echo "▶ Version $VERSION (build $BUILD)"

# --- 2. Build + notarized DMG --------------------------------------------------
scripts/build.sh
scripts/make-dmg.sh

# --- 3. Publish the release first, so the feed never points at a missing file --
git add project.yml Resources/Info.plist
git commit -q -m "Version $VERSION"
git push -q origin main
if [ -n "$NOTES" ]; then
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "$TITLE" --notes "$NOTES"
else
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "$TITLE" --generate-notes
fi
echo "✓ Released v$VERSION on GitHub"

# --- 4. Sparkle feed -----------------------------------------------------------
# generate_appcast works on a folder of archives and keeps the entries of an
# existing appcast.xml in that folder, so the repo's feed goes in and comes out.
cp appcast.xml dist/appcast.xml 2>/dev/null || true
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO/releases" \
  --maximum-deltas 0 \
  dist
cp dist/appcast.xml appcast.xml
grep -q "v$VERSION/Capture-Plus.dmg" appcast.xml || { echo "✗ appcast.xml has no entry for v$VERSION"; exit 1; }
git add appcast.xml
git commit -q -m "Appcast: v$VERSION"
git push -q origin main
echo "✓ Update feed published — existing installs will see v$VERSION within a day (or via Check for Updates…)"
