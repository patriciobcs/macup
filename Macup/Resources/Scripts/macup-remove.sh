#!/bin/zsh
# macup-remove.sh — uninstall one package.
# Usage: macup-remove.sh <manager> <name> [kind]
# Env:   MACUP_USER_PATH  PATH resolved from the user's login shell (prepended)
#        MACUP_DRY_RUN=1  print the command instead of running it
set -u
setopt NULL_GLOB 2>/dev/null
[[ -n "${MACUP_USER_PATH:-}" ]] && export PATH="$MACUP_USER_PATH:$PATH"
for d in "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/.local/bin" /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin \
         "$HOME"/.nvm/versions/node/*/bin "$HOME"/.volta/bin "$HOME"/Library/pnpm "$HOME"/Library/pnpm/bin "$HOME"/.local/share/pnpm "$HOME"/.local/share/pnpm/bin "${PNPM_HOME:-/nonexistent}" "${PNPM_HOME:-/nonexistent}/bin" "$HOME"/.hermes/node/bin \
         "$HOME"/.fnm/aliases/default/bin "$HOME"/Library/Application\ Support/fnm/aliases/default/bin \
         /Library/Frameworks/Python.framework/Versions/Current/bin "$HOME"/.pyenv/shims "$HOME"/.rbenv/shims; do
  [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$PATH:$d"
done
export PATH
# Standalone pnpm needs PNPM_HOME for global operations; derive it when the login shell did not provide it.
if [[ -z "${PNPM_HOME:-}" ]]; then
  for d in "$HOME/Library/pnpm" "$HOME/.local/share/pnpm"; do [[ -d "$d" ]] && { export PNPM_HOME="$d"; break; }; done
fi
export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_COLOR=0 NO_COLOR=1 npm_config_update_notifier=false CI=1

source "${0:A:h}/macup-commands.sh"

(( $# >= 2 )) || { echo "usage: $0 <manager> <name> [kind]" >&2; exit 64; }
manager=$1; name=$2; kind=${3:-}

run() {
  if [[ "${MACUP_DRY_RUN:-0}" == 1 ]]; then printf '$'; printf ' %q' "$@"; printf '\n'; return 0; fi
  printf '$ %s\n' "$*"
  "$@"
}

# run_cmd <command line> — the same, for a command that came from the table rather than from argv.
# The line is run by the shell, so a replacement of the user's may pipe and redirect like any other.
run_cmd() {
  printf '$ %s\n' "$1"
  [[ "${MACUP_DRY_RUN:-0}" == 1 ]] && return 0
  eval "$1"
}

# remove_cmd <manager> [key=value ...] — the resolved, filled-in removal command for this manager.
remove_cmd() { macup_fill "$(macup_cmd remove $1)" "name=${(q)name}" "${@:2}" }

# pip on a PEP 668 "externally managed" Python (Homebrew's) refuses changes until told the user knows.
# The package is already there, so retry with the flag when pip asks for it.
pip_run_cmd() {
  local cap; cap=$(mktemp "${TMPDIR:-/tmp}/macup-pip.XXXXXX")
  run_cmd "$1" 2>&1 | tee "$cap"; local st=$pipestatus[1]
  if (( st != 0 )) && grep -q "externally-managed-environment" "$cap"; then
    echo "→ externally managed Python (PEP 668); retrying with --break-system-packages"
    run_cmd "$1 --break-system-packages"; st=$?
  fi
  rm -f "$cap"; return $st
}

# Run a command with administrator privileges through the standard macOS password prompt.
as_admin() {
  # Only a root-owned, non-writable executable may run with elevated rights: never something a user-level
  # process could have swapped in (rbenv/asdf shims, ~/.local/bin, a writable /usr/local/bin).
  local exe=$1
  if [[ "${MACUP_DRY_RUN:-0}" != 1 ]]; then
    [[ -x "$exe" ]] || { echo "refusing to elevate: $exe is not an executable path" >&2; return 1; }
    local owner mode; owner=$(stat -f %u "$exe" 2>/dev/null); mode=$(stat -f %Lp "$exe" 2>/dev/null)
    if [[ "$owner" != 0 || "${mode: -2}" == *[2367]* ]]; then
      echo "refusing to elevate: $exe is not owned by root, or is group/world writable" >&2; return 1
    fi
  fi
  if [[ "${MACUP_DRY_RUN:-0}" == 1 ]]; then printf '$ (admin)'; printf ' %q' "$@"; printf '\n'; return 0; fi
  printf '$ (admin) %s\n' "$*"
  local cmd; cmd=$(printf '%q ' "$@")
  cmd=${cmd//\\/\\\\}; cmd=${cmd//\"/\\\"}
  # A fixed PATH inside the elevated shell, so nothing the user's PATH points at is consulted as root.
  osascript -e "do shell script \"PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/local/bin $cmd 2>&1\" with administrator privileges"
}

# gem: elevate only when the gem directory is not writable (system Ruby).
gem_run() {
  local dir; dir=$(gem environment gemdir 2>/dev/null)
  # An unwritable gem dir means the system Ruby: elevate Apple's /usr/bin/gem, never a shim from PATH.
  if [[ -n "$dir" && ! -w "$dir" ]]; then as_admin /usr/bin/gem "$@"; else run gem "$@"; fi
}

case "$manager" in
  # --force removes every installed version (brew keeps old kegs after upgrades) and casks whose app
  # was already deleted by hand.
  brew)   run_cmd "$(remove_cmd brew "kind=$([[ "$kind" == cask ]] && print -- --cask)")" ;;
  npm)    run_cmd "$(remove_cmd npm)" ;;
  bun)    run_cmd "$(remove_cmd bun)" ;;
  pnpm)   run_cmd "$(remove_cmd pnpm)" ;;
  pip)    py=pip3; command -v pip3 >/dev/null 2>&1 || py=pip; pip_run_cmd "$(remove_cmd pip "python=$py")" ;;
  uv)     run_cmd "$(remove_cmd uv)" ;;
  cargo)  run_cmd "$(remove_cmd cargo)" ;;
  pipx)     run_cmd "$(remove_cmd pipx)" ;;
  go)       bin=$(go env GOBIN 2>/dev/null); [[ -z "$bin" ]] && bin="$(go env GOPATH 2>/dev/null)/bin"
            [[ -f "$bin/$name" ]] || bin="$HOME/go/bin"
            [[ -f "$bin/$name" ]] || { echo "$name not found in GOBIN or ~/go/bin" >&2; exit 1; }
            run_cmd "$(remove_cmd go "gobin=${(q)bin}")" ;;
  nix)      run_cmd "$(remove_cmd nix)" ;;
  composer) run_cmd "$(remove_cmd composer)" ;;
  # These two can end up running with administrator privileges, and what runs as root is never taken
  # from a setting: only a root-owned executable this script names itself is elevated.
  gem)      gem_run uninstall -x -a "$name" ;;
  port)     as_admin /opt/local/bin/port -N uninstall "$name" ;;
  rustup|mas|macos|tools|mise|conda) echo "Removing is not supported for $manager" >&2; exit 65 ;;
  *) echo "unknown manager: $manager" >&2; exit 64 ;;
esac
