#!/bin/zsh
# Contract tests for macup-upgrade.sh: which command each request turns into. Driven by MACUP_DRY_RUN,
# so nothing is installed and they run in milliseconds.
#
# This is the failure these cover: a command that succeeds without doing what was asked. The package
# stays outdated, MacUp offers it again after the next scan, and the log looks perfectly healthy.
set -uo pipefail
cd "$(dirname "$0")/../.."
UP=Macup/Resources/Scripts/macup-upgrade.sh
pass=0; fail=0
ok()  { print -P "%F{green}ok%f   $1"; (( pass++ )); return 0 }
bad() { print -P "%F{red}FAIL%f $1"; print "     $2"; (( fail++ )); return 0 }
# is <name> <expected command line> -- <arguments to macup-upgrade.sh>
is() {
  local name=$1 want=$2; shift 3
  local got; got=$(MACUP_DRY_RUN=1 "$UP" "$@" 2>&1)
  [[ "$got" == *"$want"* ]] && ok "$name" || bad "$name" "expected to contain: $want
     got: ${got//$'\n'/ | }"
}

# --- rustup: two different commands behind one manager ---------------------------------------------
# `rustup update` syncs the toolchains and leaves rustup itself at the version it was. Asking for
# rustup and getting the toolchain command is silent, and the update is offered again for ever.
is "rustup itself takes the self-update command" 'rustup self update' -- rustup rustup
is "a toolchain takes the ordinary update" 'rustup update stable-aarch64-apple-darwin' \
  -- rustup stable-aarch64-apple-darwin
got=$(MACUP_DRY_RUN=1 "$UP" rustup stable-aarch64-apple-darwin 2>&1)
[[ "$got" != *"self update"* ]] && ok "a toolchain does not drag rustup along" \
  || bad "a toolchain does not drag rustup along" "got: $got"
is "asking for both runs both" 'rustup self update' -- rustup stable-aarch64-apple-darwin rustup
is "nothing named still updates the toolchains" 'rustup update' -- rustup

# --- the names reach the command for the managers that take them -----------------------------------
is "npm names are passed through" 'npm install -g' -- npm lodash
is "an unknown manager is refused" 'unknown manager' -- definitely-not-a-manager

# --- the command table: what the app shows, and what a replacement does -----------------------------
CMDS=Macup/Resources/Scripts/macup-commands.sh
got=$(MACUP_DRY_RUN=1 MACUP_CMD_remove_npm='npm uninstall -g --silent {name}' \
  Macup/Resources/Scripts/macup-remove.sh npm example 2>&1)
[[ "$got" == *"npm uninstall -g --silent example"* ]] && ok "a replacement is used instead of the default" \
  || bad "a replacement is used instead of the default" "got: $got"

# What runs as root is never taken from a setting, so these two ignore a replacement entirely.
got=$(MACUP_DRY_RUN=1 MACUP_CMD_remove_port='echo pwned' \
  Macup/Resources/Scripts/macup-remove.sh port example 2>&1)
[[ "$got" == *"/opt/local/bin/port -N uninstall example"* ]] \
  && ok "an elevated command ignores a replacement" \
  || bad "an elevated command ignores a replacement" "got: $got"
got=$(MACUP_DRY_RUN=1 MACUP_CMD_update_gem='echo pwned' \
  Macup/Resources/Scripts/macup-upgrade.sh gem example 2>&1)
[[ "$got" != *pwned* ]] && ok "and so does the elevated update" \
  || bad "and so does the elevated update" "got: $got"

# A package name is quoted before it reaches the shell, so it cannot become a second command.
# The command line is handed to the shell, so a name carrying a ";" or a "$(...)" has to reach it
# quoted. Checked by what is absent: the separator standing on its own, ready to be run.
got=$(MACUP_DRY_RUN=1 Macup/Resources/Scripts/macup-remove.sh npm 'evil; touch /tmp/macup-pwned' 2>&1)
[[ "$got" != *"-g evil; touch"* && "$got" == *"evil"* ]] \
  && ok "a package name cannot become a second command" \
  || bad "a package name cannot become a second command" "got: $got"
got=$(MACUP_DRY_RUN=1 Macup/Resources/Scripts/macup-upgrade.sh npm 'evil$(whoami)' 2>&1)
[[ "$got" != *'-g evil$(whoami)'* ]] && ok "nor can it substitute a command" \
  || bad "nor can it substitute a command" "got: $got"

# The app reads the commands from the scripts, so what it shows is what runs.
listed=$(Macup/Resources/Scripts/macup-scan.sh --commands 2>&1)
[[ $(printf '%s\n' "$listed" | wc -l) -gt 50 ]] && ok "the commands can be listed for the app" \
  || bad "the commands can be listed for the app" "got ${#listed} bytes"
[[ "$listed" == *$'check\tnpm\tnpm outdated -g --json'* ]] && ok "and each line is phase, manager, command" \
  || bad "and each line is phase, manager, command" "got: ${listed//$'\n'/ | }"

print -P "\n%F{blue}upgrade script:%f $pass passed, $fail failed"
(( fail == 0 ))
