#!/usr/bin/env bash
# Store builds for Play and the App Store
#   ./release.sh android https://api.example.com/api/v1
#   ./release.sh ios     https://api.example.com/api/v1
# Every upload needs a higher build number than the last, the +N in
# pubspec.yaml's version line

set -euo pipefail
cd "$(dirname "$0")"

PLATFORM="${1:-}"
API="${2:-}"

if [ "$PLATFORM" != "android" ] && [ "$PLATFORM" != "ios" ]; then
    echo "Usage: ./release.sh android|ios https://<server>/api/v1"
    exit 1
fi

if [[ ! "$API" =~ ^https://[^/]+/api/v1$ ]]; then
    echo "The server address must look like https://<server>/api/v1, got: $API"
    exit 1
fi

HEALTH="${API%/api/v1}/health"
if ! curl -fsS -m 10 -o /dev/null "$HEALTH"; then
    echo "The server did not answer at $HEALTH, check the address and that it is running"
    exit 1
fi

# A store build never gets the debug key or a plain http server
unset MIUCHIO_DEV_BUILD

VERSION=$(grep -E '^version:' pubspec.yaml | awk '{print $2}')
echo "Building Miuchio $VERSION for $PLATFORM against $API"

if [ "$PLATFORM" = "android" ]; then
    if [ ! -f android/key.properties ]; then
        echo "android/key.properties is missing, it points at the Play upload key"
        exit 1
    fi
    flutter build appbundle --release --dart-define=API_BASE_URL="$API"
    echo "Upload this file to Play: build/app/outputs/bundle/release/app-release.aab"
else
    flutter build ipa --release --dart-define=API_BASE_URL="$API"
    echo "Upload the .ipa in build/ios/ipa with Transporter or Xcode Organizer"
fi
