#!/bin/zsh
# One-time setup: creates a self-signed code-signing certificate ("Agora Local Signing") in your login
# keychain. build-app.sh then signs every build with it, so macOS sees the same app each time and stops
# asking for your keychain password after each rebuild. Remove it with:
#   security delete-identity -c "Agora Local Signing"
set -euo pipefail
NAME="Agora Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
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
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="agora-$RANDOM$RANDOM"
# macOS only reads the older PKCS#12 encryption; OpenSSL 3 needs -legacy for it, LibreSSL doesn't know the flag.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". Rebuild with scripts/build-app.sh, then click \"Always Allow\" once at the next keychain prompt."
