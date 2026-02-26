#!/usr/bin/env bash
set -euo pipefail

# Install (or update) the RightMic HAL driver and restart coreaudiod.
# Requires admin privileges.
#
# Usage:
#   sudo ./scripts/install-driver.sh          # build + install
#   sudo ./scripts/install-driver.sh --remove # uninstall

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DRIVER_BUNDLE="$BUILD_DIR/RightMic.driver"
INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/RightMic.driver"

if [[ "${1:-}" == "--remove" ]]; then
    echo "==> Removing RightMic driver..."
    rm -rf "$INSTALL_PATH"
    echo "==> Restarting coreaudiod..."
    launchctl kickstart -kp system/com.apple.audio.coreaudiod
    echo "==> Done. RightMic driver removed."
    exit 0
fi

# Build the driver first
"$SCRIPT_DIR/build-driver.sh"

if [[ ! -d "$DRIVER_BUNDLE" ]]; then
    echo "Error: Driver bundle not found at $DRIVER_BUNDLE"
    exit 1
fi

echo "==> Installing RightMic driver..."
rm -rf "$INSTALL_PATH"
cp -R "$DRIVER_BUNDLE" "$INSTALL_PATH"

echo "==> Restarting coreaudiod..."
launchctl kickstart -kp system/com.apple.audio.coreaudiod

echo "==> Done. RightMic should now appear as an input device."
