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

print -P "\n%F{blue}upgrade script:%f $pass passed, $fail failed"
(( fail == 0 ))
