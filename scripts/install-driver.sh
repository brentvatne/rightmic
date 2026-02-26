#!/usr/bin/env bash
set -euo pipefail

# Install (or update) the RightMic HAL driver and restart coreaudiod.
# Requires admin privileges.
#
# Usage:
#   sudo ./scripts/install-driver.sh          # build, sign, install
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
    killall coreaudiod 2>/dev/null || true
    echo "==> Done. RightMic driver removed."
    exit 0
fi

# Build as the real user (not root) so build artifacts have correct ownership
# and the keychain is accessible for code signing.
if [[ -n "${SUDO_USER:-}" ]]; then
    echo "==> Building as $SUDO_USER (dropping privileges for build + sign)..."
    sudo -u "$SUDO_USER" "$SCRIPT_DIR/build-driver.sh"
else
    "$SCRIPT_DIR/build-driver.sh"
fi

if [[ ! -d "$DRIVER_BUNDLE" ]]; then
    echo "Error: Driver bundle not found at $DRIVER_BUNDLE"
    exit 1
fi

echo "==> Installing RightMic driver..."
rm -rf "$INSTALL_PATH"
cp -R "$DRIVER_BUNDLE" "$INSTALL_PATH"

echo "==> Restarting coreaudiod..."
killall coreaudiod 2>/dev/null || true

echo "==> Done. RightMic should now appear as an input device."
