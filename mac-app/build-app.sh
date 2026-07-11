#!/bin/zsh
set -e

# Build the release .app bundle for AIClockBridge and inject version info into
# Info.plist. Run with --install to copy the result to /Applications.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="AIClockBridge"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INFO_PLIST_TEMPLATE="$PROJECT_DIR/Info.plist"

# Read version constants from AppVersion.swift.
VERSION=$(grep 'static let short' "$PROJECT_DIR/Sources/AIClockBridge/AppVersion.swift" | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep 'static let build' "$PROJECT_DIR/Sources/AIClockBridge/AppVersion.swift" | sed -E 's/.*"([^"]+)".*/\1/')

# Local updates directory: appcast.xml + .app.zip live here.
LOCAL_UPDATES_DIR="${HOME}/Library/Application Support/AIClockBridge/updates"

# Appcast feed URL. Defaults to the local HTTP server that the app itself runs
# on 127.0.0.1:8765. Override to use a remote server.
DEFAULT_FEED_URL="http://localhost:8765/updates/appcast.xml"
FEED_URL="${AICLOCK_APPCAST_URL:-$DEFAULT_FEED_URL}"

# Public EdDSA key for Sparkle to verify the downloaded update zip.
PUBLIC_KEY_FILE="$SCRIPT_DIR/update-keys/public.b64"
PUBLIC_KEY=""
if [[ -f "$PUBLIC_KEY_FILE" ]]; then
    PUBLIC_KEY="$(cat "$PUBLIC_KEY_FILE" | tr -d '[:space:]')"
fi

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "Could not extract version from AppVersion.swift" >&2
    exit 1
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "Missing local update signing public key." >&2
    echo "Run: ./generate-update-keys.sh" >&2
    exit 1
fi

echo "Building $APP_NAME $VERSION ($BUILD) ..."
cd "$PROJECT_DIR"
swift build -c release

# Ensure the .app bundle structure exists (SPM creates it automatically).
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy the release binary into the bundle.
cp "$BUILD_DIR/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Make the executable look for embedded frameworks relative to itself.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Copy vendored frameworks that SPM built alongside the executable.
SPARKLE_FRAMEWORK="$BUILD_DIR/arm64-apple-macosx/release/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

# Generate Info.plist from template, injecting version, feed URL and public key.
sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD|g" \
    -e "s|__FEED_URL__|$FEED_URL|g" \
    -e "s|__PUBLIC_KEY__|$PUBLIC_KEY|g" \
    "$INFO_PLIST_TEMPLATE" > "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc code-sign the bundle so Sparkle can verify the update archive.
# A Developer ID is not required for local development/testing.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"
echo "Version: $VERSION ($BUILD)"
echo "Feed URL: $FEED_URL"

if [[ "$1" == "--install" ]]; then
    echo "Installing to /Applications ..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/"
    echo "Installed: /Applications/$APP_NAME.app"
fi
