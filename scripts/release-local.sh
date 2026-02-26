#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

cd "$PROJECT_DIR"

echo "==> Building and signing..."
./scripts/bundle-app.sh --sign "$SIGNING_IDENTITY"

echo "==> Notarizing..."
cd build
zip -r RightMic-notarize.zip RightMic.app
SUBMIT_OUT=$(xcrun notarytool submit RightMic-notarize.zip \
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
rm RightMic-notarize.zip

echo "==> Stapling..."
xcrun stapler staple RightMic.app
cd "$PROJECT_DIR"

echo "==> Creating DMG..."
./scripts/create-dmg.sh

echo "==> Done: build/RightMic.dmg"
