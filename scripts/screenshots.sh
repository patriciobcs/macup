#!/bin/zsh
# Renders the app's screenshots (light and dark) from fixture data into site/public/screenshots.
# The app draws its own views offscreen, so no screen recording permission is involved.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Macup.xcodeproj -scheme Macup -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= build 2>&1 | grep -E "error:|BUILD"
out="$PWD/site/public/screenshots"; mkdir -p "$out"
MACUP_SCREENSHOTS="$out" build/Build/Products/Debug/MacUp.app/Contents/MacOS/MacUp
ls -1 "$out"
