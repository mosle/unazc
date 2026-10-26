#!/bin/sh
# Creates a self-signed code-signing identity "Unazc Dev" in the login keychain.
# A fixed identity keeps macOS privacy permissions (mic, accessibility) across rebuilds.
set -eu
NAME="Unazc Dev"
HASH=$(sh "$(dirname "$0")/identity.sh" 2>/dev/null) && { echo "already exists: $NAME ($HASH)"; exit 0; }
# Exit 2 = an identity exists but is unusable or duplicated; do not add another one on top.
[ $? -eq 1 ] || { sh "$(dirname "$0")/identity.sh"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:unazc -out "$TMP/id.p12" 2>/dev/null
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P unazc -T /usr/bin/codesign
echo "created: $NAME"
