#!/usr/bin/env bash
set -euo pipefail

# Create a DMG from RightMic.app with an Applications symlink.
#
# Usage:
#   ./scripts/create-dmg.sh                        # uses build/RightMic.app
#   ./scripts/create-dmg.sh path/to/RightMic.app   # custom path
#
# Output: build/RightMic.dmg

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

APP_PATH="${1:-$BUILD_DIR/RightMic.app}"
DMG_PATH="$BUILD_DIR/RightMic.dmg"
STAGING="$BUILD_DIR/dmg-staging"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: $APP_PATH not found. Run bundle-app.sh first."
    exit 1
fi

echo "==> Creating DMG..."

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "RightMic" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"

echo "==> DMG created at $DMG_PATH"
