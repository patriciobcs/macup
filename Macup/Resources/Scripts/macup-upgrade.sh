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
         /Library/Frameworks/Python.framework/Versions/Current/bin "$HOME"/.pyenv/shims "$HOME"/.rbenv/shims \
         "$HOME/google-cloud-sdk/bin" /usr/local/google-cloud-sdk/bin /opt/google-cloud-sdk/bin \
         /opt/homebrew/share/google-cloud-sdk/bin /usr/local/share/google-cloud-sdk/bin \
         /Applications/Tailscale.app/Contents/MacOS "$HOME/Applications/Tailscale.app/Contents/MacOS"; do
  [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$PATH:$d"
done
export PATH
# Standalone pnpm needs PNPM_HOME for global operations; derive it when the login shell did not provide it.
if [[ -z "${PNPM_HOME:-}" ]]; then
  for d in "$HOME/Library/pnpm" "$HOME/.local/share/pnpm"; do [[ -d "$d" ]] && { export PNPM_HOME="$d"; break; }; done
  # Nothing installed globally yet: fall back to pnpm's own default location.
  if [[ -z "${PNPM_HOME:-}" ]]; then
    if [[ "$OSTYPE" == darwin* ]]; then export PNPM_HOME="$HOME/Library/pnpm"; else export PNPM_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/pnpm"; fi
  fi
fi
# pnpm refuses global commands unless its global bin directory is on PATH, even before that directory
# exists (issue #17): $PNPM_HOME itself up to pnpm 10, $PNPM_HOME/bin from 11. Both go on PATH whether
# or not they are there yet.
for d in "$PNPM_HOME" "$PNPM_HOME/bin"; do [[ ":$PATH:" != *":$d:"* ]] && PATH="$PATH:$d"; done
export PATH
export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_COLOR=0 NO_COLOR=1 npm_config_update_notifier=false CI=1

source "${0:A:h}/macup-commands.sh"
source "${0:A:h}/macup-pip.sh"
source "${0:A:h}/macup-gem.sh"
source "${0:A:h}/macup-native-tools.sh"

(( $# >= 1 )) || { echo "usage: $0 <manager> [name ...]" >&2; exit 64; }
manager=$1; shift
names=("$@")

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

# fill <phase> <manager> [key=value ...] — the resolved command for this manager, placeholders filled.
fill() { macup_fill "$(macup_cmd $1 $2)" "${@:3}" }
# q <word ...> — the words as one shell-quoted list, so a package name can never become a command.
q() { print -r -- "${(j: :)${(q)@}}" }

# pip-owned packages can live in a PEP 668 Python. Brew-owned distributions are checked before
# reaching this function, so the retry never tries to replace Homebrew's bundled pip.
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

# Elevate only Apple's actual system Ruby, never a different Ruby or a Homebrew-owned gem.
gem_run() {
  local name=$1; macup_gem_context "$name"
  macup_gem_is_brew_owned "$name" && { macup_gem_brew_message "$name"; return 1; }
  local dir=$MACUP_GEM_TARGET
  if [[ -n "$dir" && ! -w "$dir" ]]; then
    if [[ -z "$MACUP_GEM_USER_FLAG" ]] && macup_gem_is_system_ruby; then as_admin /usr/bin/gem update "$name"
    else print -r -- "→ $dir is not writable; update $name using the Ruby installation that owns it."; return 1; fi
  else
    run gem update ${MACUP_GEM_USER_FLAG:+$MACUP_GEM_USER_FLAG} "$name"
  fi
}

case "$manager" in
  brew)
    if (( ${#names} )); then
      # Casks and formulae are upgraded with the same command; brew resolves the kind.
      # If a cask's app was deleted by hand, brew cannot uninstall the old version; reinstalling fixes that state.
      rc=0; capture=$(mktemp "${TMPDIR:-/tmp}/macup-brew.XXXXXX"); trap 'rm -f "$capture"' EXIT
      for n in "${names[@]}"; do
        # Names may carry their kind ("cask:ghostty", "formula:jq") so a formula and a cask sharing a name stay apart.
        kind=""; case "$n" in cask:*) kind=--cask; n=${n#cask:} ;; formula:*) kind=--formula; n=${n#formula:} ;; esac
        cmd=$(fill update brew "greedy=${MACUP_BREW_GREEDY:+--greedy}" "kind=$kind" "name=$(q $n)")
        run_cmd "$cmd" 2>&1 | tee "$capture"; bstatus=$pipestatus[1]
        if (( bstatus != 0 )) && grep -q "is not there" "$capture"; then
          echo "→ app is missing from disk, reinstalling the cask instead"
          run brew reinstall --cask -- "$n" || rc=1
        elif (( bstatus != 0 )); then
          rc=1
          # Some casks run part of their upgrade through sudo, and sudo will only ask for a password in
          # a terminal. Homebrew has already put the old version back; say how to finish the job.
          grep -q "a terminal is required to read the password" "$capture" \
            && echo "→ $n needs your administrator password, which sudo only asks for in a terminal. Run it in Terminal: $cmd"
        fi
      done
      exit $rc
    else
      run_cmd "$(fill update_all brew "greedy=${MACUP_BREW_GREEDY:+--greedy}")"
    fi ;;
  npm)
    # npm cannot safely replace itself while running (it lazily loads modules from the tree it is
    # overwriting and dies with MODULE_NOT_FOUND). Let the *new* npm, fetched by npx, do the install.
    if (( ${#names} )); then
      others=(${names:#npm}); rc=0
      (( ${#others} )) && { run_cmd "$(fill update npm "names=$(q ${others[@]/%/@latest})")" || rc=1; }
      (( ${names[(Ie)npm]} )) && { run npx -y npm@latest install -g npm@latest || rc=1; }
      exit $rc
    else
      run_cmd "$(fill update_all npm)"
    fi ;;
  bun)
    if (( ${#names} )); then run_cmd "$(fill update bun "names=$(q ${names[@]/%/@latest})")"
    else run_cmd "$(fill update_all bun)"; fi ;;
  pnpm)
    if (( ${#names} )); then run_cmd "$(fill update pnpm "names=$(q ${names[@]/%/@latest})")"
    else run_cmd "$(fill update_all pnpm)"; fi ;;
  pip)
    py=pip3; command -v pip3 >/dev/null 2>&1 || py=pip
    if (( ${#names} == 0 )); then
      names=($($py list --outdated --format=json --disable-pip-version-check 2>/dev/null | \
        awk '{ gsub(/\},[[:space:]]*\{/, "}\n{"); print }' | sed -nE 's/.*"name": *"([^"]*)".*/\1/p'))
    fi
    rc=0
    for n in "${names[@]}"; do
      # Packages living in the user site (pip install --user) must be upgraded there too.
      metadata=$($py show "$n" 2>/dev/null)
      loc=$(print -r -- "$metadata" | sed -n 's/^Location: //p')
      version=$(print -r -- "$metadata" | sed -n 's/^Version: //p')
      if macup_pip_is_brew_owned "$loc" "$n" "$version"; then
        macup_pip_brew_message "$n"; rc=1; continue
      fi
      user=""; [[ "$loc" == "$HOME/Library/Python/"* || "$loc" == "$HOME/.local/lib/"* ]] && user=--user
      pip_run_cmd "$(fill update pip "python=$py" "user=$user" "name=$(q $n)")" || rc=1
    done
    exit $rc ;;
  uv)
    # `uv tool upgrade` honours the version pin used at install time; the user asked for the latest.
    if (( ${#names} )); then run_cmd "$(fill update uv "names=$(q ${names[@]/%/@latest})")"
    else run_cmd "$(fill update_all uv)"; fi ;;
  cargo)
    if (( ${#names} )); then run_cmd "$(fill update cargo "names=$(q $names)")"
    else
      crates=($(cargo install --list 2>/dev/null | sed -nE 's/^([A-Za-z0-9_-]+) v[0-9][^ :]*:$/\1/p'))
      (( ${#crates} )) && run_cmd "$(fill update cargo "names=$(q $crates)")"
    fi ;;
  rustup)
    # `rustup update` syncs the toolchains and leaves rustup itself alone, so asking for "rustup" by
    # name has to mean `rustup self update`. Running the wrong one of the two is silent: the command
    # succeeds, the version it reported never moves, and the same update is offered after every scan.
    toolchains=(${names:#rustup})
    rc=0
    if (( ${#names} == 0 )); then run_cmd "$(fill update_all rustup)" || rc=$?
    else
      (( ${#toolchains} )) && { run_cmd "$(fill update rustup "names=$(q $toolchains)")" || rc=$? }
      (( ${#names} != ${#toolchains} )) && { run_cmd "$(fill update rustup_self)" || rc=$? }
    fi
    exit $rc ;;
  mas)
    # names carry the App Store ids for mas.
    if (( ${#names} )); then run_cmd "$(fill update mas "names=$(q $names)")"
    else run_cmd "$(fill update_all mas)"; fi ;;
  macos)
    # System updates need a restart and an administrator; hand off to System Settings.
    run_cmd "$(fill update macos)" ;;
  tailscale|gcloud)
    if [[ "${MACUP_DRY_RUN:-0}" != 1 ]]; then
      owner=$(native_tool_owner "$manager") && { print -r -- "→ $owner manages $manager; update it there."; exit 1; }
      if [[ "$manager" == gcloud ]]; then
        # Google's component updater can run a system Python installer. Keep its prompts visible and
        # never run it unattended, even when called directly rather than through the app.
        if [[ ! -t 0 || ! -t 1 ]]; then
          print -r -- "→ Google Cloud CLI updates may install system Python; run this update in Terminal."
          exit 1
        fi
        print -r -- "→ Google Cloud CLI may install or update system Python as part of this SDK update."
        root=$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)
        gcloud_updater_disabled "$root" && { print -r -- "→ Component updates are disabled; use the installer that manages this SDK."; exit 1; }
        # Google requires the working directory to be outside the SDK while it replaces components.
        cd "${TMPDIR:-/tmp}" || exit 1
      else
        variant=$(tailscale version --json 2>/dev/null | tr '{,' '\n\n' | sed -nE 's/^[[:space:]]*"osVariant"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
        [[ "$variant" == macsys ]] || { print -r -- "→ This Tailscale installation must be updated by its original installer or the App Store."; exit 1; }
      fi
    fi
    run_cmd "$(fill update "$manager")" ;;
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
    if (( ${#names} )); then run_cmd "$(fill update mise "names=$(q $names)")"
    else run_cmd "$(fill update_all mise)"; fi ;;
  pipx)
    if (( ${#names} )); then rc=0; for n in "${names[@]}"; do run_cmd "$(fill update pipx "name=$(q $n)")" || rc=1; done; exit $rc
    else run_cmd "$(fill update_all pipx)"; fi ;;
  go)
    # names are import paths of the main packages (from `go version -m`).
    rc=0; for n in "${names[@]}"; do run_cmd "$(fill update go "name=$(q $n)")" || rc=1; done; exit $rc ;;
  nix)
    if (( ${#names} )); then run_cmd "$(fill update nix "names=$(q $names)")"
    else run_cmd "$(fill update_all nix)"; fi ;;
  composer)
    # `composer global update` stays inside the constraint in composer.json; `require` without a version
    # moves the constraint to the latest stable release, which is what "outdated" reported.
    if (( ${#names} )); then run_cmd "$(fill update composer "names=$(q $names)")"
    else run_cmd "$(fill update_all composer)"; fi ;;
  conda)
    if (( ${#names} )); then run_cmd "$(fill update conda "names=$(q $names)")"
    else run_cmd "$(fill update_all conda)"; fi ;;
  # These two can end up running with administrator privileges, and what runs as root is never taken
  # from a setting: only a root-owned executable this script names itself is elevated.
  gem)
    macup_gem_setup
    if (( ${#names} == 0 )); then
      outdated=$(gem outdated) || exit $?
      names=($(print -r -- "$outdated" | sed -nE 's/^([A-Za-z0-9_.-]+) \(.*/\1/p'))
    fi
    rc=0; for n in "${names[@]}"; do gem_run "$n" || rc=1; done
    exit $rc ;;
  port)
    if (( ${#names} )); then as_admin /opt/local/bin/port -N upgrade "${names[@]}"; else as_admin /opt/local/bin/port -N upgrade outdated; fi ;;
  *) echo "unknown manager: $manager" >&2; exit 64 ;;
esac
