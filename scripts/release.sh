#!/bin/zsh
# Build, sign, notarize and publish MacUp: GitHub release (dmg, zip, Sparkle appcast) and the Homebrew tap.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain (Xcode > Settings > Accounts > Manage Certificates).
#   2. xcrun notarytool store-credentials macup-notary --apple-id <you@example.com> --team-id <TEAMID>
#      (use an app-specific password from appleid.apple.com)
#   3. Sparkle's generate_keys run once (the private key stays in the keychain; the public key is in project.yml).
#   4. gh authenticated with push access to patriciobcs/macup and patriciobcs/homebrew-tap.
# Usage: TEAM_ID=XXXXXXXXXX scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TEAM_ID:?set TEAM_ID to your 10-character Apple Developer Team ID}"
PROFILE="${NOTARY_PROFILE:-macup-notary}"
REPO=patriciobcs/macup
TAP=patriciobcs/homebrew-tap
OUT=dist; ARCHIVE="$OUT/MacUp.xcarchive"; EXPORT="$OUT/export"
rm -rf "$OUT"; mkdir -p "$OUT"

# Fail early on missing prerequisites rather than after a long build.
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "No notarytool profile '$PROFILE'. See the setup notes at the top of this script." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated" >&2; exit 1; }

# Sparkle command-line tools (generate_appcast) matching the Sparkle release line the app links against.
# Sparkle's signing tools, pinned to the same version the app links (project.yml) and checksum-verified,
# because generate_appcast runs with access to the private signing key.
SPARKLE_VERSION=$(sed -nE 's/^ *exactVersion: "([^"]+)"/\1/p' project.yml | head -n1)
SPARKLE_SHA256=01e0f0ebf6614061ea816d414de50f937d64ffa6822ad572243031ca3676fe19   # Sparkle-2.9.0.tar.xz
TOOLS="$PWD/build/sparkle-tools-$SPARKLE_VERSION"
if [[ ! -x "$TOOLS/bin/generate_appcast" ]]; then
  mkdir -p "$TOOLS"
  gh release download "$SPARKLE_VERSION" -R sparkle-project/Sparkle --pattern "Sparkle-$SPARKLE_VERSION.tar.xz" -D "$TOOLS" --clobber
  echo "$SPARKLE_SHA256  $TOOLS/Sparkle-$SPARKLE_VERSION.tar.xz" | shasum -a 256 -c - || { echo "Sparkle tools checksum mismatch" >&2; exit 1; }
  tar -xJf "$TOOLS/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$TOOLS"
fi

# Version: MARKETING_VERSION from project.yml unless VERSION=x.y.z is given. The build number must grow
# with every release because Sparkle compares CFBundleVersion, so it is the commit count on this branch.
VERSION="${VERSION:-$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)"/\1/p' project.yml | head -n1)}"
BUILD=$(git rev-list --count HEAD)
[[ -n "$VERSION" ]] || { echo "could not determine the version" >&2; exit 1; }
git diff --quiet || { echo "working tree has uncommitted changes; commit them so the release matches the repository" >&2; exit 1; }
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && { echo "release v$VERSION already exists; bump MARKETING_VERSION in project.yml" >&2; exit 1; }
echo "Releasing MacUp $VERSION (build $BUILD)"

xcodegen generate
xcodebuild -project Macup.xcodeproj -scheme Macup -configuration Release \
  -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive | tail -2

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" | tail -2

APP="$EXPORT/MacUp.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || { echo "exported app version mismatch" >&2; exit 1; }

# Notarize the app, staple it, then package. Stable asset names keep releases/latest/download links working.
ZIP="$OUT/MacUp.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarizing…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

# The installer window: the app on the left, Applications on the right, an arrow between them.
DMG="$OUT/MacUp.dmg"
rm -rf "$OUT/dmg"; mkdir -p "$OUT/dmg"; cp -R "$APP" "$OUT/dmg/"
command -v create-dmg >/dev/null || { echo "create-dmg is missing (brew install create-dmg)" >&2; exit 1; }
# Signed as well as notarized: a stapled ticket alone leaves the image itself without a signature.
create-dmg --volname MacUp --window-pos 200 120 --window-size 600 400 --icon-size 128 \
  --background scripts/dmg-background.png --codesign "Developer ID Application" \
  --icon MacUp.app 150 190 --hide-extension MacUp.app --app-drop-link 450 190 \
  "$DMG" "$OUT/dmg" >/dev/null
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vv --type exec "$APP" 2>&1 | tail -2

# Sparkle appcast: signs the zip with the EdDSA key in the login keychain.
mkdir -p "$OUT/sparkle"; cp "$ZIP" "$OUT/sparkle/"
"$TOOLS/bin/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  -o "$OUT/appcast.xml" "$OUT/sparkle"

# GitHub release: dmg for people, zip for Sparkle, appcast for the feed URL.
gh release create "v$VERSION" "$DMG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --title "MacUp $VERSION" --generate-notes

# Homebrew tap: point the cask at this release.
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
rm -rf "$OUT/tap"; gh repo clone "$TAP" "$OUT/tap" -- -q
mkdir -p "$OUT/tap/Casks"
cat > "$OUT/tap/Casks/macup.rb" <<CASK
cask "macup" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/MacUp.dmg"
  name "MacUp"
  desc "Keep your command-line tools up to date, from the menu bar"
  homepage "https://github.com/$REPO"

  depends_on macos: :sonoma

  app "MacUp.app"

  zap trash: [
    "~/Library/Application Support/Macup",
    "~/Library/Preferences/io.github.patriciobcs.macup.plist",
  ]
end
CASK
git -C "$OUT/tap" add Casks/macup.rb
git -C "$OUT/tap" commit -q -m "macup $VERSION" || true
git -C "$OUT/tap" push -q

# Tag the source that produced this release.
git tag -f "v$VERSION" >/dev/null && git push -q origin "v$VERSION" || true
echo "Released MacUp $VERSION (build $BUILD): GitHub release v$VERSION (dmg, zip, appcast) and Homebrew tap updated."
