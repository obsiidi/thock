#!/bin/zsh
# Creates a self-signed code-signing identity "thock-dev" in the login
# keychain — the CLI equivalent of Keychain Access > Certificate Assistant >
# Create a Certificate (type "Code Signing"). Free, local, no Apple account.
# macOS may ask for the login password (trust settings) and, on first use by
# codesign, for keychain access — answer "Always Allow".
set -euo pipefail
NAME="${1:-thock-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "identity \"$NAME\" already exists"
    exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null

# Old-style PKCS#12 encryption: what `security import` reads reliably.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/$NAME.p12" -name "$NAME" -passout pass:thock \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/$NAME.p12" -k "$KEYCHAIN" -P thock \
    -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "created identity \"$NAME\":"
security find-identity -v -p codesigning | grep "\"$NAME\"" || echo "  (not listed yet — check Keychain Access)"
