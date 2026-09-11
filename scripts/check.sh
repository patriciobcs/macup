#!/bin/zsh
# Everything CI used to run on macOS, locally: format, lint, unit tests, a render of every view, the
# site checks, and script syntax. Add --bench to also run the Linux package-manager bench in Docker.
set -euo pipefail
cd "$(dirname "$0")/.."
step() { print -P "%F{blue}==>%f $1"; }

step "swift-format"; swift format lint --strict --recursive Macup/Sources MacupTests
step "swiftlint";    swiftlint --strict --quiet
step "script syntax"; find Macup/Resources/Scripts tests scripts -name '*.sh' -exec zsh -n {} \;
step "xcodegen";     xcodegen generate >/dev/null
step "build + unit tests"
xcodebuild -project Macup.xcodeproj -scheme Macup -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= test 2>&1 \
  | tee build/check.log | grep -E "error:|Test Case .* failed|Executed .* tests|TEST" || true
grep -q "TEST SUCCEEDED" build/check.log
step "render every view from fixtures"
shots=$(mktemp -d "${TMPDIR:-/tmp}/macup-shots.XXXXXX")
MACUP_SCREENSHOTS="$shots" build/Build/Products/Debug/MacUp.app/Contents/MacOS/MacUp
[[ "$(ls "$shots"/*.png | wc -l | tr -d ' ')" == 6 ]] || { echo "expected 6 renders" >&2; exit 1; }
rm -rf "$shots"
if [[ -d site/node_modules ]]; then step "site: lint, typecheck, prettier"; (cd site && npm run --silent check); fi
if [[ "${1:-}" == "--bench" ]]; then step "linux bench (docker)"; tests/docker/test.sh; fi
print -P "%F{green}all checks passed%f"
