#!/bin/zsh
# Native updater contracts plus a real SDK upgrade, entirely inside the disposable Linux container.
# The Tailscale macOS GUI hand-off is covered with stub tools; no VPN is installed or started.
set -euo pipefail
cd /workspace
MACUP_MANAGER_TIMEOUT=5 zsh tests/scan/test.sh
zsh tests/upgrade/test.sh
zsh tests/gem/test.sh
zsh tests/mas/test.sh
zsh tests/docker/gem-plugin.sh

S=/workspace/Macup/Resources/Scripts
cd "$HOME"
echo "===== real gcloud SDK upgrade in OrbStack"
before=$(MACUP_USER_PATH="$PATH" "$S/macup-scan.sh" gcloud)
print -r -- "$before"
[[ "$before" == *$'P\tgcloud\tgcloud\t'* ]] || { echo "FAIL no outdated SDK to test"; exit 1; }

if refused=$(MACUP_USER_PATH="$PATH" "$S/macup-upgrade.sh" gcloud gcloud </dev/null 2>&1); then
  echo "FAIL gcloud accepted an unattended update"; exit 1
fi
[[ "$refused" == *"may install system Python"* ]] || { print -r -- "$refused"; exit 1; }
echo "ok   gcloud refuses an unattended real SDK update"

# A pseudo-terminal exercises the manual path. Disable prompts only in this disposable Linux SDK:
# the macOS Python installer is not available here, and no host directories are writable in the VM.
if ! CLOUDSDK_CORE_DISABLE_PROMPTS=true MACUP_USER_PATH="$PATH" \
  script --quiet --return --command "/bin/zsh $S/macup-upgrade.sh gcloud gcloud" "$HOME/gcloud-update.log" >/dev/null; then
  tail -n 50 "$HOME/gcloud-update.log"; exit 1
fi
after=$(MACUP_USER_PATH="$PATH" "$S/macup-scan.sh" gcloud)
print -r -- "$after"
[[ "$after" == *$'M\tgcloud\tok'* && "$after" != *$'P\tgcloud\t'* ]] \
  || { echo "FAIL SDK still outdated after a successful update"; exit 1; }
echo "ok   real SDK update completed and the update disappeared on rescan"
echo "===== native updater tests: PASS"
