#!/usr/bin/env bash
set -euo pipefail

# Build the RightMic HAL audio driver as a universal .driver bundle.
#
# Usage:
#   ./scripts/build-driver.sh                    # unsigned
#   ./scripts/build-driver.sh --sign "Developer ID Application: ..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DRIVER_SRC="$PROJECT_DIR/Driver"
BUILD_DIR="$PROJECT_DIR/build"
DRIVER_BUNDLE="$BUILD_DIR/RightMic.driver"

SIGNING_IDENTITY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGNING_IDENTITY="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "==> Building RightMic HAL driver..."

# Clean previous build
rm -rf "$DRIVER_BUNDLE"

# Create bundle structure
mkdir -p "$DRIVER_BUNDLE/Contents/MacOS"

# Compile as universal dylib (arm64 + x86_64)
clang \
    -dynamiclib \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=14.0 \
    -framework CoreAudio \
    -framework CoreFoundation \
    -I "$DRIVER_SRC" \
    -o "$DRIVER_BUNDLE/Contents/MacOS/RightMicDriver" \
    "$DRIVER_SRC/RightMicDriver.c"

# Copy Info.plist
cp "$DRIVER_SRC/Info.plist" "$DRIVER_BUNDLE/Contents/Info.plist"

# Code sign if identity provided
if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "==> Signing driver with: $SIGNING_IDENTITY"
    codesign --force --sign "$SIGNING_IDENTITY" "$DRIVER_BUNDLE"
fi

echo "==> Driver built: $DRIVER_BUNDLE"
echo "    Install with: sudo cp -R $DRIVER_BUNDLE /Library/Audio/Plug-Ins/HAL/"
echo "    Then restart: sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod"
