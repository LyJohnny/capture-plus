#!/usr/bin/env bash
#
# One-time per Mac. Creates a local self-signed code-signing certificate for
# Capture + in a dedicated keychain, so the app has a STABLE signature and macOS
# permissions (Screen Recording, Microphone) persist across rebuilds instead of
# resetting every time (which is what an unsigned / "adhoc" build causes).
#
# This certificate is only meaningful on this machine — it can't sign anything
# anyone else would trust. That's fine: it exists purely so this Mac recognizes
# each rebuild of Capture + as "the same app."
#
# Idempotent: safe to re-run. To undo: `security delete-keychain "$KC"`.
set -euo pipefail

CN="Capture Plus Self-Signed"
KC="$HOME/Library/Keychains/capture-plus-signing.keychain-db"
KCPASS="capture-plus-local"   # local-only; no security value beyond this Mac

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "✓ Signing identity '$CN' already present in $KC"
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

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$WORK/capplus.p12" -k "$KC" -P "$KCPASS" -A -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1 || true
# Add to the user keychain search list (preserving what's already there).
security list-keychains -d user -s "$KC" $(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')

echo "✓ Created signing identity '$CN' in $KC"
security find-identity -p codesigning "$KC" | grep "$CN"
