#!/usr/bin/env bash
set -euo pipefail

# Create a .pkg installer for RightMic (app + HAL driver).
# Expects pre-built build/RightMic.app and build/RightMic.driver.
#
# Usage:
#   ./scripts/create-pkg.sh                                          # unsigned
#   ./scripts/create-pkg.sh --sign "Developer ID Installer: ..."     # signed
#   ./scripts/create-pkg.sh --version 1.2.0                          # set version
#
# Output: build/RightMic.pkg

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/RightMic.app"
DRIVER_BUNDLE="$BUILD_DIR/RightMic.driver"
VERSION="${VERSION:-1.0.0}"

SIGNING_IDENTITY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGNING_IDENTITY="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

for bundle in "$APP_BUNDLE" "$DRIVER_BUNDLE"; do
    if [[ ! -d "$bundle" ]]; then
        echo "Error: $bundle not found. Build first with bundle-app.sh."
        exit 1
    fi
done

echo "==> Creating .pkg installer (v${VERSION})..."

STAGING="$BUILD_DIR/pkg-staging"
rm -rf "$STAGING"

# Stage app → /Applications/RightMic.app
mkdir -p "$STAGING/app-root/Applications"
cp -R "$APP_BUNDLE" "$STAGING/app-root/Applications/"

# Stage driver → /Library/Audio/Plug-Ins/HAL/RightMic.driver
mkdir -p "$STAGING/driver-root/Library/Audio/Plug-Ins/HAL"
cp -R "$DRIVER_BUNDLE" "$STAGING/driver-root/Library/Audio/Plug-Ins/HAL/"

# Postinstall script restarts coreaudiod so the driver loads immediately
mkdir -p "$STAGING/scripts"
cat > "$STAGING/scripts/postinstall" << 'SCRIPT'
#!/bin/bash
killall coreaudiod 2>/dev/null || true
exit 0
SCRIPT
chmod +x "$STAGING/scripts/postinstall"

echo "==> Building component packages..."
pkgbuild \
    --root "$STAGING/app-root" \
    --identifier "com.rightmic.app.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    "$BUILD_DIR/RightMic-app.pkg"

pkgbuild \
    --root "$STAGING/driver-root" \
    --identifier "com.rightmic.driver.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$STAGING/scripts" \
    "$BUILD_DIR/RightMic-driver.pkg"

echo "==> Building product archive..."
productbuild \
    --synthesize \
    --package "$BUILD_DIR/RightMic-app.pkg" \
    --package "$BUILD_DIR/RightMic-driver.pkg" \
    "$BUILD_DIR/distribution.xml"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    productbuild \
        --distribution "$BUILD_DIR/distribution.xml" \
        --package-path "$BUILD_DIR" \
        --sign "$SIGNING_IDENTITY" \
        "$BUILD_DIR/RightMic.pkg"
else
    productbuild \
        --distribution "$BUILD_DIR/distribution.xml" \
        --package-path "$BUILD_DIR" \
        "$BUILD_DIR/RightMic.pkg"
fi

# Clean up intermediates
rm -rf "$STAGING"
rm -f "$BUILD_DIR/RightMic-app.pkg" "$BUILD_DIR/RightMic-driver.pkg" "$BUILD_DIR/distribution.xml"

echo "==> Installer created: $BUILD_DIR/RightMic.pkg"
