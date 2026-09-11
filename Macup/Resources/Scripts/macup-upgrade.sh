#!/bin/zsh
# macup-upgrade.sh — upgrade packages for one manager.
# Usage: macup-upgrade.sh <manager> [name ...]      (no names = upgrade everything for that manager)
# Env:   MACUP_USER_PATH  PATH resolved from the user's login shell (prepended)
#        MACUP_DRY_RUN=1  print the command instead of running it
# Exit code is the package manager's exit code. Output is streamed as-is.
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

(( $# >= 1 )) || { echo "usage: $0 <manager> [name ...]" >&2; exit 64; }
manager=$1; shift
names=("$@")

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
  brew)
    if (( ${#names} )); then
      # Casks and formulae are upgraded with the same command; brew resolves the kind.
      # If a cask's app was deleted by hand, brew cannot uninstall the old version; reinstalling fixes that state.
      rc=0; capture=$(mktemp "${TMPDIR:-/tmp}/macup-brew.XXXXXX"); trap 'rm -f "$capture"' EXIT
      for n in "${names[@]}"; do
        # Names may carry their kind ("cask:ghostty", "formula:jq") so a formula and a cask sharing a name stay apart.
        kindflag=(); case "$n" in cask:*) kindflag=(--cask); n=${n#cask:} ;; formula:*) kindflag=(--formula); n=${n#formula:} ;; esac
        run brew upgrade ${MACUP_BREW_GREEDY:+--greedy} "${kindflag[@]}" -- "$n" 2>&1 | tee "$capture"; bstatus=$pipestatus[1]
        if (( bstatus != 0 )) && grep -q "is not there" "$capture"; then
          echo "→ app is missing from disk, reinstalling the cask instead"
          run brew reinstall --cask -- "$n" || rc=1
        elif (( bstatus != 0 )); then rc=1; fi
      done
      exit $rc
    else
      run brew upgrade ${MACUP_BREW_GREEDY:+--greedy}
    fi ;;
  npm)
    # npm cannot safely replace itself while running (it lazily loads modules from the tree it is
    # overwriting and dies with MODULE_NOT_FOUND). Let the *new* npm, fetched by npx, do the install.
    if (( ${#names} )); then
      others=(${names:#npm}); rc=0
      (( ${#others} )) && { run npm install -g "${others[@]/%/@latest}" || rc=1; }
      (( ${names[(Ie)npm]} )) && { run npx -y npm@latest install -g npm@latest || rc=1; }
      exit $rc
    else
      run npm update -g
    fi ;;
  bun)
    if (( ${#names} )); then run bun add -g "${names[@]/%/@latest}"; else run bun update -g --latest; fi ;;
  pnpm)
    if (( ${#names} )); then run pnpm add -g "${names[@]/%/@latest}"; else run pnpm update -g --latest; fi ;;
  pip)
    py=pip3; command -v pip3 >/dev/null 2>&1 || py=pip
    flags=(--disable-pip-version-check)
    if (( ${#names} == 0 )); then
      names=($($py list --outdated --format=json --disable-pip-version-check 2>/dev/null | \
        awk '{ gsub(/\},[[:space:]]*\{/, "}\n{"); print }' | sed -nE 's/.*"name": *"([^"]*)".*/\1/p'))
    fi
    rc=0
    for n in "${names[@]}"; do
      # Packages living in the user site (pip install --user) must be upgraded there too.
      loc=$($py show "$n" 2>/dev/null | sed -n 's/^Location: //p')
      userflag=(); [[ "$loc" == "$HOME/Library/Python/"* || "$loc" == "$HOME/.local/lib/"* ]] && userflag=(--user)
      pip_run $py install --upgrade "${flags[@]}" "${userflag[@]}" "$n" || rc=1
    done
    exit $rc ;;
  uv)
    # `uv tool upgrade` honours the version pin used at install time; the user asked for the latest.
    if (( ${#names} )); then run uv tool install --force "${names[@]/%/@latest}"; else run uv tool upgrade --all; fi ;;
  cargo)
    if (( ${#names} )); then run cargo install --locked "${names[@]}"
    else
      crates=($(cargo install --list 2>/dev/null | sed -nE 's/^([A-Za-z0-9_-]+) v[0-9][^ :]*:$/\1/p'))
      (( ${#crates} )) && run cargo install --locked "${crates[@]}"
    fi ;;
  rustup)
    run rustup update ;;
  gem)
    if (( ${#names} )); then gem_run update "${names[@]}"; else gem_run update; fi ;;
  mas)
    # names carry the App Store ids for mas.
    if (( ${#names} )); then run mas upgrade "${names[@]}"; else run mas upgrade; fi ;;
  macos)
    # System updates need a restart and an administrator; hand off to System Settings.
    run open "x-apple.systempreferences:com.apple.Software-Update-Settings.extension" ;;
  tools)
    rc=0
    # Each tool's own updater first; if it fails (GitHub API rate limits are common), the official installer.
    for n in "${names[@]}"; do
      case "$n" in
        uv)   run uv self update || { echo "→ falling back to the uv installer"; run sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' || rc=1; } ;;
        bun)  run bun upgrade || { echo "→ falling back to the Bun installer"; run sh -c 'curl -fsSL https://bun.sh/install | bash' || rc=1; } ;;
        deno) run deno upgrade || { echo "→ falling back to the Deno installer"; run sh -c 'curl -fsSL https://deno.land/install.sh | sh' || rc=1; } ;;
        # `pnpm self-update` in 9.x can leave a broken binary yet exit 0; the standalone installer is the documented way.
        pnpm) run sh -c 'curl -fsSL https://get.pnpm.io/install.sh | sh -' || rc=1 ;;
        mise) run mise self-update -y || { echo "→ falling back to the mise installer"; run sh -c 'curl -fsSL https://mise.run | sh' || rc=1; } ;;
        *) echo "no self-update known for $n" >&2; rc=1 ;;
      esac
    done
    exit $rc ;;
  mise)
    if (( ${#names} )); then run mise upgrade "${names[@]}"; else run mise upgrade; fi ;;
  pipx)
    if (( ${#names} )); then rc=0; for n in "${names[@]}"; do run pipx upgrade "$n" || rc=1; done; exit $rc
    else run pipx upgrade-all; fi ;;
  go)
    # names are import paths of the main packages (from `go version -m`).
    rc=0; for n in "${names[@]}"; do run go install "$n@latest" || rc=1; done; exit $rc ;;
  port)
    if (( ${#names} )); then as_admin /opt/local/bin/port -N upgrade "${names[@]}"; else as_admin /opt/local/bin/port -N upgrade outdated; fi ;;
  nix)
    if (( ${#names} )); then run nix-env -u "${names[@]}"; else run nix-env -u; fi ;;
  composer)
    # `composer global update` stays inside the constraint in composer.json; `require` without a version
    # moves the constraint to the latest stable release, which is what "outdated" reported.
    if (( ${#names} )); then run composer global require --no-interaction --update-with-dependencies "${names[@]}"
    else run composer global update --no-interaction; fi ;;
  conda)
    if (( ${#names} )); then run conda update -y "${names[@]}"; else run conda update -y --all; fi ;;
  *) echo "unknown manager: $manager" >&2; exit 64 ;;
esac
