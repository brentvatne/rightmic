#!/usr/bin/env bash
set -euo pipefail

# Local release: build, sign, notarize, and create .pkg installer.
#
# Requires .env with:
#   SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)"
#   APPLE_ID=user@example.com
#   APPLE_ID_PASSWORD=xxxx-xxxx-xxxx-xxxx
#   APPLE_TEAM_ID=XXXXXXXXXX
# Optional:
#   INSTALLER_IDENTITY="Developer ID Installer: Name (TEAMID)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

cd "$PROJECT_DIR"

# Determine version from git tag or default
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "1.0.0")}"
VERSION="${VERSION#v}"

echo "==> Building and signing (v${VERSION})..."
./scripts/bundle-app.sh --sign "$SIGNING_IDENTITY"

# Sign the standalone driver (bundle-app.sh signs it inside the .app via --deep,
# but the .pkg installs the driver as a separate component)
echo "==> Signing standalone driver..."
codesign --force --options runtime --sign "$SIGNING_IDENTITY" build/RightMic.driver
codesign --verify --verbose=2 build/RightMic.driver

echo "==> Creating .pkg installer..."
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    ./scripts/create-pkg.sh --version "$VERSION" --sign "$INSTALLER_IDENTITY"
else
    ./scripts/create-pkg.sh --version "$VERSION"
fi

echo "==> Notarizing..."
SUBMIT_OUT=$(xcrun notarytool submit build/RightMic.pkg \
    --apple-id "$APPLE_ID" --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --output-format json)
SUBMISSION_ID=$(echo "$SUBMIT_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "    Submission ID: $SUBMISSION_ID"

for i in $(seq 1 80); do
    sleep 15
    INFO=$(xcrun notarytool info "$SUBMISSION_ID" \
        --apple-id "$APPLE_ID" --password "$APPLE_ID_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" --output-format json)
    STATUS=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
    echo "    [$i/80] Status: $STATUS"
    if [[ "$STATUS" == "Accepted" ]]; then break; fi
    if [[ "$STATUS" == "Invalid" ]]; then echo "Notarization failed"; exit 1; fi
done
if [[ "$STATUS" != "Accepted" ]]; then echo "Notarization timed out"; exit 1; fi

echo "==> Stapling..."
xcrun stapler staple build/RightMic.pkg

echo "==> Done: build/RightMic.pkg"
