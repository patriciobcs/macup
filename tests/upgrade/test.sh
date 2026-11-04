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

# --- a cask whose upgrade needs sudo: the app hands the dry-run command to Terminal ----------------
is "a cask's command is the one Terminal is given" 'brew upgrade --cask -- docker-desktop' -- brew cask:docker-desktop
# Run for real, sudo refuses for want of a terminal, and the log says how to finish the job.
stubs=$(mktemp -d "${TMPDIR:-/tmp}/macup-up.XXXXXX")
printf '#!/bin/zsh\n%s\n' 'echo "sudo: a terminal is required to read the password; either use the -S option" >&2
echo "Error: docker-desktop: Failure while executing; /usr/bin/sudo -E -- /bin/rm exited with 1." >&2; exit 1' \
  > "$stubs/brew"; chmod +x "$stubs/brew"
got=$(MACUP_USER_PATH="$stubs" "$UP" brew cask:docker-desktop 2>&1); rc=$?
(( rc == 1 )) && ok "a cask refused sudo still fails" || bad "a cask refused sudo still fails" "exit $rc"
[[ "$got" == *"Run it in Terminal: brew upgrade --cask -- docker-desktop"* ]] \
  && ok "and says how to finish it in Terminal" || bad "and says how to finish it in Terminal" "got: ${got//$'\n'/ | }"

# --- pip: Homebrew's bundled distributions are writable, but pip does not own them ----------------
mkdir -p "$stubs/site-packages/pip-26.2.2.dist-info" "$stubs/site-packages/requests-2.28.0.dist-info"
print brew > "$stubs/site-packages/pip-26.2.2.dist-info/INSTALLER"
print pip > "$stubs/site-packages/requests-2.28.0.dist-info/INSTALLER"
touch "$stubs/site-packages/requests-2.28.0.dist-info/RECORD"
cat > "$stubs/pip3" <<'PIP'
#!/bin/zsh
case "$1" in
  show)
    print "Location: $PIP_SITE"
    [[ "$2" == pip ]] && print 'Version: 26.2.2' || print 'Version: 2.28.0'
    ;;
  list) print '[{"name":"pip","version":"26.2.2","latest_version":"26.3"},{"name":"requests","version":"2.28.0","latest_version":"2.32.0"}]' ;;
  install|uninstall)
    print -r -- "$*" >> "$PIP_CALLS"
    [[ "$*" == *--break-system-packages* ]] && exit 0
    print 'error: externally-managed-environment' >&2
    exit 1
    ;;
esac
PIP
chmod +x "$stubs/pip3"
export PIP_SITE="$stubs/site-packages" PIP_CALLS="$stubs/pip-calls"
got=$(MACUP_USER_PATH="$stubs" "$UP" pip pip 2>&1); rc=$?
[[ $rc == 1 && "$got" == *"Homebrew manages pip"* && ! -e "$PIP_CALLS" ]] \
  && ok "brew-owned pip is refused before any install or retry" \
  || bad "brew-owned pip is refused before any install or retry" "exit $rc; got: $got"
got=$(MACUP_USER_PATH="$stubs" Macup/Resources/Scripts/macup-remove.sh pip pip 2>&1); rc=$?
[[ $rc == 1 && "$got" == *"Homebrew manages pip"* && ! -e "$PIP_CALLS" ]] \
  && ok "brew-owned pip cannot be removed through pip" \
  || bad "brew-owned pip cannot be removed through pip" "exit $rc; got: $got"
got=$(MACUP_USER_PATH="$stubs" "$UP" pip 2>&1); rc=$?
calls=$(cat "$PIP_CALLS" 2>/dev/null)
[[ "$got" == *"Homebrew manages pip"* && "$calls" == *'requests --break-system-packages'* && "$calls" != *'check pip'* ]] \
  && ok "update all skips bundled pip and still updates pip-owned packages" \
  || bad "update all skips bundled pip and still updates pip-owned packages" "exit $rc; calls: $calls; got: $got"
# A pip-installed copy of pip is updatable, even though the package name is identical.
print pip > "$PIP_SITE/pip-26.2.2.dist-info/INSTALLER"
got=$(MACUP_USER_PATH="$stubs" "$UP" pip pip 2>&1); rc=$?
[[ $rc == 0 && "$got" == *'pip --break-system-packages'* ]] \
  && ok "pip-owned pip keeps its normal update path" \
  || bad "pip-owned pip keeps its normal update path" "exit $rc; got: $got"
got=$(MACUP_USER_PATH="$stubs" Macup/Resources/Scripts/macup-remove.sh pip requests 2>&1); rc=$?
[[ $rc == 0 && "$got" == *'uninstall -y requests --break-system-packages'* ]] \
  && ok "pip-owned packages keep their removal path" \
  || bad "pip-owned packages keep their removal path" "exit $rc; got: $got"
got=$(HOME="$stubs/home" PIP_SITE="$stubs/home/.local/lib/python3.15/site-packages" \
  MACUP_USER_PATH="$stubs" "$UP" pip requests 2>&1); rc=$?
[[ $rc == 0 && "$got" == *'--user requests --break-system-packages'* ]] \
  && ok "user-site packages are still updated in the user site" \
  || bad "user-site packages are still updated in the user site" "exit $rc; got: $got"
unset PIP_SITE PIP_CALLS
rm -rf "$stubs"

print -P "\n%F{blue}upgrade script:%f $pass passed, $fail failed"
(( fail == 0 ))
