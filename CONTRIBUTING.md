# Contributing to MacUp

Issues and pull requests are welcome. Keep the app simple: default Apple components, no configuration required to get value, and every manager backed by its own outdated command rather than guesswork. Commits follow [Conventional Commits](https://www.conventionalcommits.org). For security matters see [SECURITY.md](SECURITY.md).

## Getting set up

Requirements: Xcode 16 or later and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Macup.xcodeproj -scheme Macup -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

`project.yml` is the source of truth; the generated Xcode project and Info.plist are not committed.

Run `git config core.hooksPath .githooks` once and the pre-commit hook runs the relevant checks on what you stage.

## How it fits together

The app is a SwiftUI shell around three zsh scripts in `Macup/Resources/Scripts`: `macup-scan.sh` runs every manager's own outdated command concurrently and prints one tab-separated line per package, and `macup-upgrade.sh` and `macup-remove.sh` map a manager and package to the right command. The scripts inherit your login shell's environment, so they see the same tools you do in Terminal. The app parses the output, resolves dates and advisories from public registries with an on-disk cache, and decides what is eligible to show.

## Checks

`scripts/check.sh` runs everything locally: format and lint checks, the unit tests, a coverage report, a render of every view from fixtures, the site checks and script syntax. `scripts/check.sh --bench` adds the Linux bench. CI enforces the same checks.

Individually: `swift format --in-place --recursive Macup/Sources MacupTests` and `swiftlint` for the app (`brew install swiftlint`), `npm run check` inside `site/` for the website (ESLint, TypeScript, Prettier).

## Tests

- **Unit tests** cover the parsers, version comparison, eligibility rules, process handling and the store.
- **Linux bench.** `tests/docker/test.sh` builds an Ubuntu image with 14 managers and packages pinned to old versions, then runs the scan and dry-run upgrades and removals. Needs Docker or a compatible runtime. This is the one job CI runs, and only when scripts change.
- **macOS integration.** `tests/macos/` installs every manager on a disposable Mac or VM, pins old packages, performs real upgrades and removals, and verifies each by rescanning. It is not run in CI, since macOS runner minutes bill at ten times the rate. Do not run `tests/macos/setup.sh` on a Mac you care about.

## Coverage

`scripts/check.sh` writes `build/coverage.lcov` and prints the total. It is measured twice and uploaded under two flags:

- **unit** — the XCTest suite, which covers the parsers, versions, eligibility, the registry lookups, the store and the shell environment.
- **render** — the offscreen render of every view from fixtures. SwiftUI view bodies only run when something draws them, so this is what covers `Macup/Sources/Views`. It proves a view builds and draws with the given state, nothing more; behaviour worth asserting belongs in a test.

Code that runs the package managers themselves (`ScriptRunner.scan`, the upgrade and removal paths) is deliberately not covered here — that is what the Linux bench and the macOS integration tests are for.

Coverage is tracked on [Codecov](https://codecov.io/gh/patriciobcs/macup), but the tests need macOS and CI runs no macOS runners, so the report is uploaded from a maintainer's machine instead of from a pull request:

```sh
brew install codecov-cli
CODECOV_TOKEN=<repository upload token> scripts/check.sh
```

Without the token the report is still written locally, just not uploaded. Codecov statuses are informational and never block a pull request, since not every commit has a report attached; see `codecov.yml`.

## Adding a package manager

1. Add a `scan_<name>` function to `macup-scan.sh` that prints a header line and one `P` line per outdated package, and add the name to `ALL`.
2. Add the upgrade and remove commands to the other two scripts.
3. Add a case to `Manager` in `Macup/Sources/Models/Models.swift`, and a registry lookup in `Registry.swift` if release dates are available.
4. Add it to the Linux bench and the macOS test with a package pinned to an old version.

## App icon

`Macup/Resources/MacUp.icon` is the source, and it carries light and dark renditions. macOS only draws the dark one when the user picks a dark "Icon & widget style", so the app swaps its own Dock icon to follow the system appearance (`DockIcon.swift`) using the two exports in `Macup/Resources/AppIcons`. Regenerate them after changing the icon:

```sh
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for r in Default Dark; do
  "$ictool" Macup/Resources/MacUp.icon --export-image --output-file "Macup/Resources/AppIcons/AppIcon$r.png" \
    --platform macOS --rendition $r --width 256 --height 256 --scale 2
done
```

## Screenshots

The only screenshot the project keeps is `site/public/screenshots/readme.png`, the image at the top of the README. It is made by hand; replace it when the interface changes enough to make it wrong.

The app can still draw all of its views offscreen from sample data (`Screenshots.swift`, triggered by `MACUP_SCREENSHOTS=<directory>`). Nothing ships those images: `scripts/check.sh` renders them to a temporary directory and fails if any view cannot be drawn, which is what covers the SwiftUI code.

## Website

`site/` is a static Next.js page deployed to GitHub Pages by the Website workflow. `npm run dev` inside `site/` serves it on localhost:3000; review website changes there before pushing. Pages deploys on every push that touches `site/`.

## Release

Maintainers only. One-time setup on the releasing Mac: a Developer ID Application certificate, `xcrun notarytool store-credentials macup-notary`, Sparkle's `generate_keys`, `brew install create-dmg`, and `gh` authenticated with push access to this repository and the tap. Then:

```sh
TEAM_ID=XXXXXXXXXX scripts/release.sh
```

The script archives, signs, notarizes and staples, generates the signed Sparkle appcast, publishes the GitHub release with the dmg, zip and appcast, updates the cask in [patriciobcs/homebrew-tap](https://github.com/patriciobcs/homebrew-tap), and tags the source. Bump `MARKETING_VERSION` in `project.yml` first.
