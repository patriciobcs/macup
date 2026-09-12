#!/bin/zsh
# Everything CI used to run on macOS, locally: format, lint, unit tests, a render of every view, the
# site checks, and script syntax. Add --bench to also run the Linux package-manager bench in Docker.
set -euo pipefail
cd "$(dirname "$0")/.."
step() { print -P "%F{blue}==>%f $1"; }

step "swift-format"; swift format lint --strict --recursive Macup/Sources MacupTests
step "swiftlint";    swiftlint --strict --quiet
step "script syntax"; find Macup/Resources/Scripts tests scripts -name '*.sh' -exec zsh -n {} \;
step "scan script"; tests/scan/test.sh
step "xcodegen";     xcodegen generate >/dev/null
step "build + unit tests"
xcodebuild -project Macup.xcodeproj -scheme Macup -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= test 2>&1 \
  | tee build/check.log | grep -E "error:|Test Case .* failed|Executed .* tests|TEST" || true
grep -q "TEST SUCCEEDED" build/check.log
step "render every view from fixtures"
shots=$(mktemp -d "${TMPDIR:-/tmp}/macup-shots.XXXXXX")
# The render draws every view offscreen, so its profile is what covers the SwiftUI code.
LLVM_PROFILE_FILE="$PWD/build/render.profraw" MACUP_SCREENSHOTS="$shots" \
  build/Build/Products/Debug/MacUp.app/Contents/MacOS/MacUp
[[ "$(ls "$shots"/*.png | wc -l | tr -d ' ')" == 6 ]] || { echo "expected 6 renders" >&2; exit 1; }
rm -rf "$shots"
step "coverage"
# Xcode links the app's own code into a debug dylib; the executable beside it is only a stub.
dylib=build/Build/Products/Debug/MacUp.app/Contents/MacOS/MacUp.debug.dylib
tests=$(find build/Build/ProfileData -name Coverage.profdata -print -quit)
cov() {  # cov <profile> <output>: repo-relative lcov for the app's own sources
  xcrun llvm-cov export -format=lcov -instr-profile "$1" "$dylib" -ignore-filename-regex='MacupTests' \
    | sed "s|^SF:$PWD/|SF:|" > "$2"
}
xcrun llvm-profdata merge -sparse build/render.profraw -o build/render.profdata
xcrun llvm-profdata merge -sparse "$tests" build/render.profdata -o build/coverage.profdata
cov "$tests" build/coverage-unit.lcov
cov build/render.profdata build/coverage-render.lcov
cov build/coverage.profdata build/coverage.lcov
xcrun llvm-cov report -instr-profile build/coverage.profdata "$dylib" -ignore-filename-regex='MacupTests' | tail -1
# Uploaded only when a token is present, since the tests run here rather than in CI.
if [[ -n "${CODECOV_TOKEN:-}" ]]; then
  if command -v codecovcli >/dev/null; then
    step "codecov upload"
    # One upload per flag: -F flags the whole upload, not an individual file.
    codecovcli upload-process --disable-search -n unit -f build/coverage-unit.lcov -F unit
    codecovcli upload-process --disable-search -n render -f build/coverage-render.lcov -F render
  else
    echo "CODECOV_TOKEN is set but codecovcli is missing (brew install codecov-cli)" >&2
  fi
fi
if [[ -d site/node_modules ]]; then step "site: lint, typecheck, prettier"; (cd site && npm run --silent check); fi
if [[ "${1:-}" == "--bench" ]]; then step "linux bench (docker)"; tests/docker/test.sh; fi
print -P "%F{green}all checks passed%f"
