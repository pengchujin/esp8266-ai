#!/bin/zsh
set -e

# Generate a local Ed25519 key pair for Sparkle update signing.
# The private key stays on this Mac only; the public key is compiled into the
# app so Sparkle can verify locally-published updates.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYS_DIR="$SCRIPT_DIR/update-keys"
mkdir -p "$KEYS_DIR"

PRIVATE_KEY="$KEYS_DIR/private.pem"
PRIVATE_SEED_B64="$KEYS_DIR/private.seed.b64"
PUBLIC_DER="$KEYS_DIR/public.der"
PUBLIC_RAW="$KEYS_DIR/public.raw"
PUBLIC_B64="$KEYS_DIR/public.b64"

if [[ -f "$PRIVATE_KEY" ]]; then
    echo "A private key already exists at $PRIVATE_KEY"
    echo "If you regenerate it, existing updates signed with the old key will stop working."
    echo "Delete it first if you really want a new key."
    exit 1
fi

echo "Generating local Ed25519 key pair for AIClockBridge updates..."

# 1. Generate private key in PEM format.
openssl genpkey -algorithm ed25519 -out "$PRIVATE_KEY"

# 1a. Sparkle's sign_update tool needs the raw 32-byte Ed25519 seed, not the
#     PEM file. Extract it from the DER form and base64-encode it.
openssl pkey -in "$PRIVATE_KEY" -outform DER | tail -c 32 | openssl base64 -A -out "$PRIVATE_SEED_B64"

# 2. Export public key as DER (SubjectPublicKeyInfo).
openssl pkey -in "$PRIVATE_KEY" -pubout -outform DER -out "$PUBLIC_DER"

# 3. Strip the DER header; the last 32 bytes are the raw Ed25519 public key
#    that Sparkle expects in SUPublicEDKey.
tail -c 32 "$PUBLIC_DER" > "$PUBLIC_RAW"

# 4. Base64-encode the raw public key for Info.plist injection.
openssl base64 -in "$PUBLIC_RAW" -out "$PUBLIC_B64" -A

# Clean up DER intermediate.
rm -f "$PUBLIC_DER" "$PUBLIC_RAW"

chmod 600 "$PRIVATE_KEY"

echo ""
echo "Done. Key files:"
echo "  Private PEM  (keep secret, never commit): $PRIVATE_KEY"
echo "  Private seed (Sparkle sign_update input):  $PRIVATE_SEED_B64"
echo "  Public       (compiled into the app):      $PUBLIC_B64"
echo ""
echo "Next: run ./build-app.sh --install to embed the public key."
