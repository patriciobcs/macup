#!/bin/zsh
# macup-setup.sh — install optional helper tools MacUp can use.
# Usage: macup-setup.sh <tool>      tools: mas
# Env:   MACUP_USER_PATH, MACUP_DRY_RUN=1 (see macup-upgrade.sh)
set -u
setopt NULL_GLOB 2>/dev/null
[[ -n "${MACUP_USER_PATH:-}" ]] && export PATH="$MACUP_USER_PATH:$PATH"
for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin; do
  [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$PATH:$d"
done
export PATH HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_COLOR=0 NO_COLOR=1 CI=1

run() {
  if [[ "${MACUP_DRY_RUN:-0}" == 1 ]]; then printf '$'; printf ' %q' "$@"; printf '\n'; return 0; fi
  printf '$ %s\n' "$*"
  "$@"
}

(( $# >= 1 )) || { echo "usage: $0 <tool>" >&2; exit 64; }
case "$1" in
  mas)
    command -v brew >/dev/null 2>&1 || { echo "Homebrew is required to install mas. Get it from https://brew.sh" >&2; exit 66; }
    run brew install mas ;;
  *) echo "unknown tool: $1" >&2; exit 64 ;;
esac
