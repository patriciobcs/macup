# Security

MacUp runs package managers on your behalf. This document describes what that means, what the app does and does not do, and how to report a problem.

## Reporting a vulnerability

Please do not open a public issue for security problems.

- Email **contact@patriciobcs.com**.
- Or use GitHub's private reporting: **Security → Report a vulnerability** on this repository. Reports reach the maintainer only.

You will get an acknowledgement within 7 days. Confirmed issues are fixed in a new release and credited in the release notes unless you prefer otherwise.

Only the latest release is supported.

## What MacUp does

- **Runs commands with your privileges, never more.** Scans and updates run as your user through the same commands you would type. The two exceptions are RubyGems in the system Ruby's directory and MacPorts, which cannot be changed without administrator rights. For those, MacUp asks through the standard macOS administrator prompt each time. It never stores a password.
- **Passes package names as arguments, never as shell text.** Names come from the managers' own output and reach commands as separate arguments. The one place a command string is built, the administrator prompt, quotes every argument. This is exercised in the automated tests with hostile names.
- **Inherits your login shell's environment.** The scripts run with the variables of your login shell, including its PATH, exactly as Terminal would. This is what lets MacUp find Homebrew, nvm, pnpm or a custom GOPATH. Variables your shell exports are therefore visible to the package managers MacUp runs, as they are when you run them yourself.
- **Talks to a fixed set of hosts over HTTPS, and sends them only what the lookup needs.** For each outdated package: its name to the relevant registry (npm, PyPI, crates.io, RubyGems, Packagist, the Go module proxy) or to GitHub (Homebrew commit dates, self-installed tool releases) for the release date, and its name plus installed version to OSV.dev for advisories. Up-to-date packages are never mentioned to anyone. Downloaded copies fetch the Sparkle appcast from this repository's releases. The package managers themselves contact their own registries.
- **Overrides Homebrew Python's "externally managed" guard only on retry.** When pip refuses a change under PEP 668, MacUp retries the same command with `--break-system-packages`, because the package is already installed there and you asked to change it. The retry is printed in the log.
- **Falls back to vendor installers for self-installed tools.** When `uv self update`, `bun upgrade`, `deno upgrade` or `mise self-update` fail, and always for standalone pnpm, MacUp runs the vendor's documented installer script over HTTPS. That is the same command their websites tell you to run, and it only happens for tools you installed that way. Every command and its output is shown in the log.
- **Signs and notarizes every release.** Releases are signed with an Apple Developer ID and notarized by Apple. Downloaded copies update through Sparkle with EdDSA-signed appcasts; the signing key never leaves the maintainer's machine. Homebrew installs update through the cask, whose checksum is pinned per version.
- **Stores state locally only.** Scan results, an install-date cache, action history and preferences live in `~/Library/Application Support/Macup` and the app's preferences domain. Nothing is sent anywhere.

## What MacUp does not do

- **It is not sandboxed and is not on the Mac App Store.** The App Store sandbox prevents an app from running Homebrew, npm or any other package manager. MacUp uses the hardened runtime and carries no entitlements, but it is a normal, unsandboxed macOS app with the same reach as your Terminal.
- **It does not run anything in the background with elevated rights.** There is no helper daemon, no launchd job as root, and no persistent privilege.
- **It does not install anything without a click.** Scans are automatic; updates, removals and installs only happen when you trigger them. Removals ask for confirmation.
- **It does not verify what package managers download.** MacUp trusts each manager's own integrity checks. It adds no signature verification of its own on top of theirs.
- **It does not detect compromised releases.** The release-age wait lowers the chance of installing a release that is pulled within hours. It is a heuristic, not a scanner. Advisories come from OSV.dev and cover only the ecosystems OSV indexes.
- **It does not collect telemetry** and has no accounts.

## Claims we make and how to check them

| Claim | How to verify |
|---|---|
| No entitlements, hardened runtime | `codesign -d --entitlements :- /Applications/MacUp.app` prints none; `codesign -dv` shows `flags=0x10000(runtime)` |
| Signed and notarized | `spctl -a -vv /Applications/MacUp.app` reports `source=Notarized Developer ID` |
| Only the hosts listed above | Grep `Macup/Sources` and `Macup/Resources/Scripts` for `https://` |
| No shell interpolation of package names | Read `run()`, `as_admin()` and `pip_run()` in `Macup/Resources/Scripts/macup-upgrade.sh` |
| Administrator prompt only for gems and MacPorts | Grep the scripts for `as_admin` |

## Scope

In scope: the app, its scripts, the release process and the website. Out of scope: vulnerabilities in the package managers or registries MacUp calls, and issues that require an attacker to already control your user account.
