#!/bin/bash
# One-time per machine: creates a self-signed code-signing identity ("Snappy
# Dev") in the login keychain and trusts it.
#
# Why: ad-hoc signing (codesign -s -) pins TCC permissions (Screen Recording)
# to the exact binary hash, so EVERY rebuild silently invalidates the grant —
# System Settings still shows the toggle ON, but capture is denied. Signing
# with a stable certificate makes the app's designated requirement
# certificate-based, so rebuilds keep their TCC grants. scripts/bundle.sh
# automatically uses this identity when it exists.
#
# Prompts: expect a password dialog when trusting the certificate, and on the
# first build a keychain dialog for codesign — choose "Always Allow".
set -euo pipefail

IDENTITY="${SNAPPY_SIGN_IDENTITY:-Snappy Dev}"
# Always the system LibreSSL — Homebrew's OpenSSL 3 produces formats that
# `security import` rejects (e.g. PKCS#12 "MAC verification failed").
OPENSSL=/usr/bin/openssl
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY\""; then
    echo "Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf"

# Import key and certificate as PEM directly — no PKCS#12 round-trip.
security import "$TMP/key.pem" -k "$LOGIN_KEYCHAIN" -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$LOGIN_KEYCHAIN"

# Trust the certificate for code signing (user trust domain — this pops a
# password dialog).
security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" \
    || { echo "FAIL: identity '$IDENTITY' not found after import" >&2; exit 1; }
echo "Created and trusted signing identity '$IDENTITY'."
echo "Next: ./scripts/bundle.sh (it now signs with this identity)."
