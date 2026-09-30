#!/usr/bin/env bash
#
# One-time per Mac. Creates a local self-signed code-signing certificate for
# Capture + in a dedicated keychain, so the app has a STABLE signature and macOS
# permissions (Screen Recording, Microphone) persist across rebuilds instead of
# resetting every time (which is what an unsigned / "adhoc" build causes).
#
# ALL your Macs must share ONE certificate. macOS ties the permissions to the
# exact certificate, so a Mac with its own certificate can't install a DMG built
# on another Mac (or vice versa) without re-granting every permission. To keep
# them in sync, the certificate is backed up to iCloud Drive
# ("Capture Plus/capture-plus-signing.p12"):
#   - already set up here  → make sure the iCloud backup exists
#   - backup in iCloud     → import it (same certificate as your other Macs)
#   - neither              → create a new one and back it up
# Never commit the .p12: anyone holding it could sign an app that inherits
# Capture +'s Screen Recording permission on your Macs.
#
# Idempotent: safe to re-run. To undo: `security delete-keychain "$KC"`.
set -euo pipefail

CN="Capture Plus Self-Signed"
KC="${CAPTUREPLUS_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/capture-plus-signing.keychain-db}"
KCPASS="capture-plus-local"   # local-only; no security value beyond this Mac
BACKUP="${CAPTUREPLUS_SIGNING_P12:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Capture Plus/capture-plus-signing.p12}"

# Creates the keychain, imports a .p12 into it, and adds it to the search list.
import_p12() {
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p "$KCPASS" "$KC"
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$KCPASS" "$KC"
  security import "$1" -k "$KC" -P "$KCPASS" -A -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1 || true
  # Add to the user keychain search list (preserving what's already there).
  security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
}

backup_identity() {
  [ -f "$BACKUP" ] && return 0
  mkdir -p "$(dirname "$BACKUP")"
  security unlock-keychain -p "$KCPASS" "$KC"
  security export -k "$KC" -t identities -f pkcs12 -P "$KCPASS" -o "$BACKUP"
  echo "✓ Backed up the certificate to $BACKUP"
}

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "✓ Signing identity '$CN' already present in $KC"
  backup_identity
  exit 0
fi

if [ -f "$BACKUP" ]; then
  import_p12 "$BACKUP"
  echo "✓ Imported the shared signing identity '$CN' from $BACKUP"
  security find-identity -p codesigning "$KC" | grep "$CN"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Capture Plus Self-Signed
O = Capture + Personal Use
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/capplus.key" -out "$WORK/capplus.crt" \
  -days 3650 -nodes -config "$WORK/cert.conf"
openssl pkcs12 -export -inkey "$WORK/capplus.key" -in "$WORK/capplus.crt" -out "$WORK/capplus.p12" \
  -passout "pass:$KCPASS" -name "$CN" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

import_p12 "$WORK/capplus.p12"

echo "✓ Created signing identity '$CN' in $KC"
security find-identity -p codesigning "$KC" | grep "$CN"
backup_identity
