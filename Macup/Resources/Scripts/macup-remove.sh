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

(( $# >= 2 )) || { echo "usage: $0 <manager> <name> [kind]" >&2; exit 64; }
manager=$1; name=$2; kind=${3:-}

run() {
  if [[ "${MACUP_DRY_RUN:-0}" == 1 ]]; then printf '$'; printf ' %q' "$@"; printf '\n'; return 0; fi
  printf '$ %s\n' "$*"
  "$@"
}

# pip on a PEP 668 "externally managed" Python (Homebrew's) refuses changes until told the user knows.
# The package is already there, so retry with the flag when pip asks for it.
pip_run() {
  local cap; cap=$(mktemp "${TMPDIR:-/tmp}/macup-pip.XXXXXX")
  run "$@" 2>&1 | tee "$cap"; local st=$pipestatus[1]
  if (( st != 0 )) && grep -q "externally-managed-environment" "$cap"; then
    echo "→ externally managed Python (PEP 668); retrying with --break-system-packages"
    run "$@" --break-system-packages; st=$?
  fi
  rm -f "$cap"; return $st
}

# Run a command with administrator privileges through the standard macOS password prompt.
as_admin() {
  if [[ "${MACUP_DRY_RUN:-0}" == 1 ]]; then printf '$ (admin)'; printf ' %q' "$@"; printf '\n'; return 0; fi
  printf '$ (admin) %s\n' "$*"
  local cmd; cmd=$(printf '%q ' "$@")
  cmd=${cmd//\\/\\\\}; cmd=${cmd//\"/\\\"}
  osascript -e "do shell script \"$cmd 2>&1\" with administrator privileges"
}

# gem: elevate only when the gem directory is not writable (system Ruby).
gem_run() {
  local dir; dir=$(gem environment gemdir 2>/dev/null)
  if [[ -n "$dir" && ! -w "$dir" ]]; then as_admin "$(command -v gem)" "$@"; else run gem "$@"; fi
}

case "$manager" in
  # --force removes every installed version (brew keeps old kegs after upgrades) and casks whose app
  # was already deleted by hand.
  brew)   if [[ "$kind" == cask ]]; then run brew uninstall --cask --force -- "$name"; else run brew uninstall --force -- "$name"; fi ;;
  npm)    run npm uninstall -g "$name" ;;
  bun)    run bun remove -g "$name" ;;
  pnpm)   run pnpm remove -g "$name" ;;
  pip)    py=pip3; command -v pip3 >/dev/null 2>&1 || py=pip; pip_run $py uninstall -y "$name" ;;
  uv)     run uv tool uninstall "$name" ;;
  cargo)  run cargo uninstall "$name" ;;
  gem)    gem_run uninstall -x -a "$name" ;;
  pipx)     run pipx uninstall "$name" ;;
  go)       bin=$(go env GOBIN 2>/dev/null); [[ -z "$bin" ]] && bin="$(go env GOPATH 2>/dev/null)/bin"
            [[ -f "$bin/$name" ]] || bin="$HOME/go/bin"
            [[ -f "$bin/$name" ]] || { echo "$name not found in GOBIN or ~/go/bin" >&2; exit 1; }
            run rm -f "$bin/$name" ;;
  port)     as_admin "$(command -v port)" -N uninstall "$name" ;;
  nix)      run nix-env -e "$name" ;;
  composer) run composer global remove --no-interaction "$name" ;;
  rustup|mas|macos|tools|mise|conda) echo "Removing is not supported for $manager" >&2; exit 65 ;;
  *) echo "unknown manager: $manager" >&2; exit 64 ;;
esac
