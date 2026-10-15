#!/bin/sh
# Creates a self-signed code signing identity in the login keychain, once per Mac.
#
# Why: macOS ties Input Monitoring permission and the login-item launch constraint to the app's code signature.
# An ad-hoc signature changes with every build, so each rebuild would lose the permission. A signature from a
# fixed local certificate keeps the same identity across builds. (A Developer ID certificate does the same for
# distributed builds.) The private key never leaves this Mac.
set -e
# macOS LibreSSL: its PKCS#12 output is what `security import` reads reliably (OpenSSL 3 needs -legacy).
NAME="${1:-Local Code Signing}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Signing identity \"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout "pass:$PASS" 2>/dev/null
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created signing identity \"$NAME\" (valid for 10 years) in your login keychain."
echo "The first build may ask to allow codesign to use it: choose Always Allow."
