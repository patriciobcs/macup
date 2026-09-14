#!/bin/zsh
# The commands MacUp runs, in one place: what each manager is asked to list, to update and to remove.
#
# Sourced by macup-scan.sh, macup-upgrade.sh and macup-remove.sh, and printed by `--commands`, so the
# app can show a manager's commands and offer to change them without a second copy going stale.
#
# A replacement arrives in the environment as MACUP_CMD_<phase>_<manager>, e.g. MACUP_CMD_check_npm.
# The default below is used whenever there is none. The command is run by the shell, so a replacement
# may use pipes and flags like any other command line.
#
# Placeholders, all substituted already shell-quoted:
#   {names}   every package asked for          {name}    one package
#   {python}  the python the scan settled on   {greedy}  --greedy, when that preference is on
#   {kind}    --cask or --formula              {gobin}   where `go install` puts binaries
#   {user}    --user, for a package pip installed into the user site
#
# What a manager updates or lists is not always one command: Go reads every binary in GOBIN, and
# self-installed tools ask GitHub for each tool's latest release. Those phases have no entry here, and
# the app shows them as built in rather than pretending they can be edited.

typeset -gA MACUP_CHECK MACUP_UPDATE MACUP_UPDATE_ALL MACUP_REMOVE

# --- checking for updates --------------------------------------------------------------------------
MACUP_CHECK[macos]='softwareupdate -l --no-scan'
MACUP_CHECK[brew]='brew outdated --json=v2 {greedy}'
MACUP_CHECK[port]='port outdated'
MACUP_CHECK[npm]='npm outdated -g --json'
MACUP_CHECK[bun]='bun outdated -g --no-progress'
MACUP_CHECK[pnpm]='pnpm outdated -g --format json'
MACUP_CHECK[pip]='{python} list --outdated --format=json --disable-pip-version-check'
MACUP_CHECK[pipx]='pipx list --json'
MACUP_CHECK[uv]='uv tool list'
MACUP_CHECK[conda]='conda update --all --dry-run --json'
MACUP_CHECK[rustup]='rustup check'
MACUP_CHECK[cargo]='cargo install --list'
MACUP_CHECK[gem]='gem outdated'
MACUP_CHECK[composer]='composer global outdated --direct --format=json'
MACUP_CHECK[nix]='nix-env -u --dry-run'
MACUP_CHECK[mise]='mise outdated --json'
MACUP_CHECK[mas]='mas outdated'

# --- updating named packages -----------------------------------------------------------------------
# npm, bun, pnpm and uv are given names that already carry @latest: without it they stay inside the
# range that was installed, which is the version reported as outdated in the first place.
MACUP_UPDATE[brew]='brew upgrade {greedy} {kind} -- {name}'
MACUP_UPDATE[port]='port -N upgrade {names}'
MACUP_UPDATE[npm]='npm install -g {names}'
MACUP_UPDATE[bun]='bun add -g {names}'
MACUP_UPDATE[pnpm]='pnpm add -g {names}'
MACUP_UPDATE[pip]='{python} install --upgrade --disable-pip-version-check {user} {name}'
MACUP_UPDATE[pipx]='pipx upgrade {name}'
MACUP_UPDATE[uv]='uv tool install --force {names}'
MACUP_UPDATE[conda]='conda update -y {names}'
MACUP_UPDATE[rustup]='rustup update {names}'
MACUP_UPDATE[cargo]='cargo install --locked {names}'
MACUP_UPDATE[go]='go install {name}@latest'
MACUP_UPDATE[gem]='gem update {names}'
MACUP_UPDATE[composer]='composer global require --no-interaction --update-with-dependencies {names}'
MACUP_UPDATE[nix]='nix-env -u {names}'
MACUP_UPDATE[mise]='mise upgrade {names}'
MACUP_UPDATE[mas]='mas upgrade {names}'
MACUP_UPDATE[macos]='open x-apple.systempreferences:com.apple.Software-Update-Settings.extension'

# rustup is the one manager whose own update is a different command from its packages'.
MACUP_UPDATE[rustup_self]='rustup self update'

# --- updating everything a manager has ---------------------------------------------------------------
MACUP_UPDATE_ALL[brew]='brew upgrade {greedy}'
MACUP_UPDATE_ALL[port]='port -N upgrade outdated'
MACUP_UPDATE_ALL[npm]='npm update -g'
MACUP_UPDATE_ALL[bun]='bun update -g --latest'
MACUP_UPDATE_ALL[pnpm]='pnpm update -g --latest'
MACUP_UPDATE_ALL[pipx]='pipx upgrade-all'
MACUP_UPDATE_ALL[uv]='uv tool upgrade --all'
MACUP_UPDATE_ALL[conda]='conda update -y --all'
MACUP_UPDATE_ALL[rustup]='rustup update'
MACUP_UPDATE_ALL[gem]='gem update'
MACUP_UPDATE_ALL[composer]='composer global update --no-interaction'
MACUP_UPDATE_ALL[nix]='nix-env -u'
MACUP_UPDATE_ALL[mise]='mise upgrade'
MACUP_UPDATE_ALL[mas]='mas upgrade'

# --- removing a package ------------------------------------------------------------------------------
MACUP_REMOVE[brew]='brew uninstall {kind} --force -- {name}'
MACUP_REMOVE[port]='port -N uninstall {name}'
MACUP_REMOVE[npm]='npm uninstall -g {name}'
MACUP_REMOVE[bun]='bun remove -g {name}'
MACUP_REMOVE[pnpm]='pnpm remove -g {name}'
MACUP_REMOVE[pip]='{python} uninstall -y {name}'
MACUP_REMOVE[pipx]='pipx uninstall {name}'
MACUP_REMOVE[uv]='uv tool uninstall {name}'
MACUP_REMOVE[cargo]='cargo uninstall {name}'
MACUP_REMOVE[gem]='gem uninstall -x -a {name}'
MACUP_REMOVE[go]='rm -f {gobin}/{name}'
MACUP_REMOVE[composer]='composer global remove --no-interaction {name}'
MACUP_REMOVE[nix]='nix-env -e {name}'

# macup_cmd <phase> <manager> — the command to run: the user's replacement, or the default.
# Prints nothing when the manager has no single command for that phase.
macup_cmd() {
  local phase=$1 manager=$2 var="MACUP_CMD_${1}_${2}"
  # Checked against the parameter table first: these scripts run under `set -u`, where reading a name
  # that happens not to be set is an error rather than an empty string.
  if (( ${+parameters[$var]} )) && [[ -n "${(P)var}" ]]; then print -r -- "${(P)var}"; return; fi
  case "$phase" in
    check)      print -r -- "${MACUP_CHECK[$manager]:-}" ;;
    update)     print -r -- "${MACUP_UPDATE[$manager]:-}" ;;
    update_all) print -r -- "${MACUP_UPDATE_ALL[$manager]:-}" ;;
    remove)     print -r -- "${MACUP_REMOVE[$manager]:-}" ;;
  esac
}

# macup_fill <command> [key=value ...] — substitutes {placeholders}. Values are quoted by the caller
# when they are package names, so that a name can never turn into a second command.
macup_fill() {
  # The cleanup below uses ## and #, which only mean "one or more" and "optional" under extended_glob.
  setopt local_options extended_glob
  local out=$1; shift
  local pair key value
  for pair in "$@"; do
    key=${pair%%=*}; value=${pair#*=}
    # Split and rejoin rather than ${out//{key}/$value}: zsh reads backslashes in a replacement, which
    # would undo the quoting on a package name and let "evil; rm -rf ~" become a second command.
    while [[ "$out" == *"{$key}"* ]]; do
      out="${out%%\{$key\}*}${value}${out#*\{$key\}}"
    done
  done
  # Anything left unfilled is dropped rather than passed through as a literal brace, and the double
  # spaces an omitted flag leaves behind are collapsed so the printed command reads normally.
  out=${out//\{[a-z]##\}/}
  # An omitted flag leaves a run of spaces behind; collapse them so the command reads as it would be
  # typed, which is also what the app shows.
  print -r -- "${${out// ##/ }%% #}"
}

# macup_print_commands — every command, one per line, for the app to show: phase<TAB>manager<TAB>command
macup_print_commands() {
  local m
  for m in ${(k)MACUP_CHECK};      do printf 'check\t%s\t%s\n' "$m" "${MACUP_CHECK[$m]}"; done
  for m in ${(k)MACUP_UPDATE};     do printf 'update\t%s\t%s\n' "$m" "${MACUP_UPDATE[$m]}"; done
  for m in ${(k)MACUP_UPDATE_ALL}; do printf 'update_all\t%s\t%s\n' "$m" "${MACUP_UPDATE_ALL[$m]}"; done
  for m in ${(k)MACUP_REMOVE};     do printf 'remove\t%s\t%s\n' "$m" "${MACUP_REMOVE[$m]}"; done
}
