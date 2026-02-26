#!/usr/bin/env bash
set -euo pipefail

# Build RightMic and assemble a proper .app bundle.
#
# Usage:
#   ./scripts/bundle-app.sh                          # unsigned build
#   ./scripts/bundle-app.sh --sign "Developer ID Application: Name (TEAMID)"
#
# Output: build/RightMic.app

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/RightMic.app"
CONTENTS="$APP_BUNDLE/Contents"

SIGNING_IDENTITY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --sign) SIGNING_IDENTITY="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "==> Running tests..."
cd "$PROJECT_DIR"
swift test

echo "==> Building release binary..."
swift build -c release --arch arm64 --arch x86_64

BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/RightMic"

if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY"
    exit 1
fi

echo "==> Building HAL driver..."
"$SCRIPT_DIR/build-driver.sh" ${SIGNING_IDENTITY:+--sign "$SIGNING_IDENTITY"}

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

cp "$BINARY" "$CONTENTS/MacOS/RightMic"
cp "$PROJECT_DIR/Sources/RightMic/Info.plist" "$CONTENTS/Info.plist"

# Copy any processed resources from the SPM build
RESOURCE_BUNDLE="$(dirname "$BINARY")/RightMic_RightMic.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
fi

# Bundle the HAL driver inside the app for installation
DRIVER_BUNDLE="$BUILD_DIR/RightMic.driver"
if [[ -d "$DRIVER_BUNDLE" ]]; then
    cp -R "$DRIVER_BUNDLE" "$CONTENTS/Resources/RightMic.driver"
    echo "==> HAL driver bundled in Resources/"
fi

echo "==> Bundle created at $APP_BUNDLE"

# Code sign if identity provided
if [[ -n "$SIGNING_IDENTITY" ]]; then
    # If identity is a name (not a hash), resolve to a specific hash to avoid
    # ambiguity when multiple certs with the same name exist in the keychain.
    if [[ ! "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        HASH=$(security find-identity -v -p codesigning | grep "$SIGNING_IDENTITY" | head -1 | awk '{print $2}')
        if [[ -n "$HASH" ]]; then
            SIGNING_IDENTITY="$HASH"
        fi
    fi
    echo "==> Signing with: $SIGNING_IDENTITY"
    codesign --deep --force --options runtime \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$PROJECT_DIR/Sources/RightMic/RightMic.entitlements" \
        "$APP_BUNDLE"
    echo "==> Verifying signature..."
    codesign --verify --verbose=2 "$APP_BUNDLE"
else
    echo "==> Skipping code signing (no --sign provided)"
fi

echo "==> Done: $APP_BUNDLE"
