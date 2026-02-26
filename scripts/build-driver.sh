#!/usr/bin/env bash
set -euo pipefail

# Build the RightMic HAL audio driver as a universal .driver bundle.
#
# Usage:
#   ./scripts/build-driver.sh                    # auto-sign with Developer ID
#   ./scripts/build-driver.sh --sign IDENTITY    # sign with specific identity
#   ./scripts/build-driver.sh --no-sign          # skip signing

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DRIVER_SRC="$PROJECT_DIR/Driver"
BUILD_DIR="$PROJECT_DIR/build"
DRIVER_BUNDLE="$BUILD_DIR/RightMic.driver"

SIGNING_IDENTITY=""
NO_SIGN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGNING_IDENTITY="$2"; shift 2 ;;
        --no-sign) NO_SIGN=true; shift ;;
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

# Code signing
if [[ "$NO_SIGN" == true ]]; then
    echo "==> Skipping code signing (--no-sign)"
elif [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "==> Signing driver with: $SIGNING_IDENTITY"
    codesign --force --sign "$SIGNING_IDENTITY" "$DRIVER_BUNDLE"
else
    # Auto-detect: try each Developer ID Application cert until one works
    SIGNED=false
    while IFS= read -r line; do
        HASH=$(echo "$line" | awk '{print $2}')
        [[ -z "$HASH" ]] && continue
        echo "==> Trying to sign with: $HASH"
        if codesign --force --sign "$HASH" "$DRIVER_BUNDLE" 2>/dev/null; then
            echo "==> Signed successfully"
            SIGNED=true
            break
        else
            echo "    Failed, trying next..."
        fi
    done < <(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application")

    if [[ "$SIGNED" == false ]]; then
        echo "WARNING: No working Developer ID found. macOS will likely refuse to load an unsigned HAL driver."
        echo "         Install a Developer ID Application certificate or use --sign IDENTITY."
    fi
fi

echo "==> Driver built: $DRIVER_BUNDLE"
