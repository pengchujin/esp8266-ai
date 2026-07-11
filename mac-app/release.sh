#!/bin/zsh
set -e

# Release helper for AIClockBridge + Sparkle.
#
# This version is designed for local filesystem updates:
#   - appcast.xml and .app.zip live in
#     ~/Library/Application Support/AIClockBridge/updates/
#   - No HTTP server or GitHub is required.
#   - Updates are signed with a locally-generated Ed25519 key pair.
#
# Usage:
#   1. Bump AppVersion.short in Sources/AIClockBridge/AppVersion.swift.
#   2. Make sure you have a local signing key:
#        ./generate-update-keys.sh
#   3. Run: ./release.sh
#   4. The built app is NOT re-installed to /Applications; only the update
#      artifacts are published locally. The currently-running app will see the
#      new version the next time it checks for updates.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION=$(grep 'static let short' "Sources/AIClockBridge/AppVersion.swift" | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep 'static let build' "Sources/AIClockBridge/AppVersion.swift" | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "Could not extract version from AppVersion.swift" >&2
    exit 1
fi

# Local updates directory and feed URL. Sparkle requires http/https, so we
# serve the local files through the app's own loopback HTTP server.
LOCAL_UPDATES_DIR="${HOME}/Library/Application Support/AIClockBridge/updates"
FEED_URL="http://localhost:8765/updates/appcast.xml"

# Local signing key. Sparkle's sign_update needs the raw 32-byte Ed25519 seed
# in base64 (private.seed.b64), not the PEM file.
PRIVATE_SEED_B64="$SCRIPT_DIR/update-keys/private.seed.b64"
PUBLIC_KEY_FILE="$SCRIPT_DIR/update-keys/public.b64"
SIGN_UPDATE="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ ! -f "$PRIVATE_SEED_B64" ]]; then
    echo "Missing local update signing private seed." >&2
    echo "Run: ./generate-update-keys.sh" >&2
    exit 1
fi

if [[ ! -x "$SIGN_UPDATE" ]]; then
    echo "Missing Sparkle sign_update tool at $SIGN_UPDATE" >&2
    echo "Run: ./build-app.sh first, or check that Sparkle is vendored." >&2
    exit 1
fi

echo "Releasing AIClockBridge $VERSION ($BUILD)"
echo "Update feed: $FEED_URL"

# Build the release .app bundle (does not install to /Applications).
./build-app.sh

DIST_DIR="$SCRIPT_DIR/dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Package the .app into a zip (required by Sparkle).
ZIP_NAME="AIClockBridge-$VERSION.app.zip"
ditto -c -k --keepParent ".build/AIClockBridge.app" "$DIST_DIR/$ZIP_NAME"

# Sign the zip with Sparkle's official sign_update tool so the signature is
# guaranteed to be in the format Sparkle expects.
SIG_B64="$("$SIGN_UPDATE" -f "$PRIVATE_SEED_B64" -p "$DIST_DIR/$ZIP_NAME")"

# Build the enclosure URL. It must be a file:// URL pointing at the local
# updates directory so Sparkle can fetch the zip without a network request.
ZIP_URL="${FEED_URL%/*}/$ZIP_NAME"
LENGTH=$(stat -f%z "$DIST_DIR/$ZIP_NAME")

APPCAST="$DIST_DIR/appcast.xml"
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>AIClockBridge 更新</title>
    <link>$FEED_URL</link>
    <description>ESP8266 AI 状态时钟桥接端更新</description>
    <language>zh</language>
    <item>
      <title>版本 $VERSION</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure url="$ZIP_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIG_B64" />
    </item>
  </channel>
</rss>
EOF

# Publish to the local updates directory.
mkdir -p "$LOCAL_UPDATES_DIR"
cp "$APPCAST" "$LOCAL_UPDATES_DIR/appcast.xml"
cp "$DIST_DIR/$ZIP_NAME" "$LOCAL_UPDATES_DIR/$ZIP_NAME"

echo ""
echo "Published local update:"
echo "  $LOCAL_UPDATES_DIR/appcast.xml"
echo "  $LOCAL_UPDATES_DIR/$ZIP_NAME"
echo ""
echo "The currently-installed app will detect this version on its next update check."
