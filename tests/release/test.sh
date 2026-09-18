#!/bin/zsh
# Exercise the actual release tag-fetch command against a disposable local remote. In zsh,
# "$VERSION:refs/..." treats :r as a parameter modifier and silently corrupts the tag name.
set -euo pipefail
cd "$(dirname "$0")/../.."
fetch=$(sed -n '/^git fetch origin /p' scripts/release.sh)
[[ -n "$fetch" ]]
fixture=$(mktemp -d "${TMPDIR:-/tmp}/macup-release-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
git init -q --bare "$fixture/remote.git"
git init -q "$fixture/checkout"
cd "$fixture/checkout"
git -c user.name=Test -c user.email=test@localhost -c commit.gpgsign=false commit -q --allow-empty -m fixture
git remote add origin "$fixture/remote.git"
VERSION=1.0.2
expected=$(git rev-parse HEAD)
git -c tag.gpgsign=false tag "v$VERSION"
git push -q origin "v$VERSION"
git tag -d "v$VERSION" >/dev/null
eval "$fetch"
[[ "$(git rev-parse "v$VERSION^{commit}")" == "$expected" ]]
echo "ok   release tag fetch preserves the full version and exact commit"
