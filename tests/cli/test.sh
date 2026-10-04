#!/bin/zsh
# End-to-end tests for `macup` in a terminal: the real built executable, linked as `macup` the way the
# Homebrew cask links it, against a real npm whose global packages live in a throwaway home. Nothing
# outside that home is changed. Needs the npm registry.
# Usage: tests/cli/test.sh <MacUp.app/Contents/MacOS/MacUp>
# Set LLVM_PROFILE_FILE to collect coverage from a coverage build (scripts/check.sh does).
set -uo pipefail
cd "$(dirname "$0")/../.."
APP=${1:?usage: tests/cli/test.sh <MacUp.app/Contents/MacOS/MacUp>}
APP=${APP:A}
pass=0; fail=0
ok()   { print -P "%F{green}ok%f   $1"; (( pass++ )); return 0 }
bad()  { print -P "%F{red}FAIL%f $1"; print -r -- "     ${2//$'\n'/$'\n'     }"; (( fail++ )); return 0 }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "expected to contain: $3"$'\n'"got: $2" }
lacks(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "expected not to contain: $3"$'\n'"got: $2" }
code() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "exit $2, expected $3" }

command -v npm >/dev/null && command -v node >/dev/null || { echo "npm and node are needed" >&2; exit 1; }
[[ -x "$APP" ]] || { echo "not an executable: $APP" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "${APP:h:h}/Info.plist")

H=$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/macup-cli.XXXXXX")")
# Settings of its own as well: ignoring a package here must never ignore it in the real app.
SUITE="macup.cli-test.$$"
trap 'rm -rf "$H"; defaults delete "$SUITE" >/dev/null 2>&1' EXIT INT TERM
mkdir -p "$H/bin" "$H/state"
ln -s "$APP" "$H/bin/macup"
# A clean environment, as cron or a fresh terminal would give: the app's default settings, and npm's
# global packages in the throwaway home.
E=(env -i HOME="$H" USER="${USER:-runner}" TMPDIR="${TMPDIR:-/tmp}" SHELL=/bin/zsh NO_COLOR=1
   PATH="$H/bin:$H/npm/bin:${$(command -v node):h}:${$(command -v npm):h}:/usr/bin:/bin:/usr/sbin:/sbin"
   npm_config_prefix="$H/npm" npm_config_update_notifier=false MACUP_STATE_DIR="$H/state" MACUP_DEFAULTS_SUITE="$SUITE"
   ${LLVM_PROFILE_FILE:+LLVM_PROFILE_FILE=$LLVM_PROFILE_FILE})
m() { "${E[@]}" macup "$@" 2>&1 }
installed() { "${E[@]}" npm ls -g --depth=0 is-odd 2>/dev/null | sed -nE 's/.*is-odd@([0-9.]+).*/\1/p' }

print -P "%F{blue}== the tool itself%f"
out=$(m version); code "version exits 0" $? 0
[[ "$out" == "MacUp $version" ]] && ok "linked as macup, it still finds its app: $out" \
  || bad "version through the link" "got: $out, expected MacUp $version"
out=$(m help); has "help shows the usage" "$out" "Usage: macup"
out=$(m upgarde); code "a typo exits 64" $? 64; has "and says what was wrong" "$out" "Unknown command"
out=$(m upgrade left-pad); code "an unknown manager exits 64" $? 64; has "and lists the known ones" "$out" "npm"

print -P "%F{blue}== a real outdated package%f"
"${E[@]}" npm install -g is-odd@2.0.0 --silent >/dev/null 2>&1
[[ "$(installed)" == 2.0.0 ]] && ok "is-odd 2.0.0 installed in the throwaway home" || bad "setup" "npm install failed"
out=$(m check npm); code "check exits 0" $? 0
has "check finds it" "$out" "is-odd  2.0.0 →"
has "and says what to run" "$out" "macup upgrade"
json=$(m status npm --json)
print -r -- "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert [i["name"] for i in d["ready"]] == ["is-odd"], d
assert d["ready"][0]["manager"] == "npm" and d["ready"][0]["installed"] == "2.0.0", d
' && ok "status --json is valid and lists it" || bad "status --json" "$json"

out=$(m upgrade npm --dry-run); code "a dry run exits 0" $? 0
has "a dry run prints the real command" "$out" "\$ npm install -g is-odd@latest"
[[ "$(installed)" == 2.0.0 ]] && ok "and changes nothing" || bad "dry run" "is-odd is now $(installed)"

out=$(m ignore npm:is-odd); has "ignore" "$out" "Ignoring npm:is-odd"
out=$(m status npm); lacks "an ignored package is not offered" "$out" "is-odd"
out=$(m upgrade npm); has "nor updated" "$out" "Nothing to update"
out=$(m unignore is-odd); has "unignore" "$out" "No longer ignoring npm:is-odd"
[[ "$(defaults read io.github.patriciobcs.macup ignoredPackages 2>/dev/null)" != *is-odd* ]] \
  && ok "the real app's settings were never touched" || bad "settings" "npm:is-odd reached the real settings"

print -P "%F{blue}== upgrade, while another MacUp is updating%f"
# Another process holds the update lock for a few seconds, as the menu bar app does mid-update.
python3 -c "
import fcntl, time
f = open('$H/state/update.lock', 'a'); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(3)" &
holder=$!
sleep 0.5
start=$SECONDS
out=$(m upgrade npm); rc=$?
waited=$(( SECONDS - start ))
wait $holder
code "upgrade exits 0" $rc 0
has "it waits for the other one" "$out" "Waiting for MacUp to finish updating"
(( waited >= 2 )) && ok "rather than running alongside it (${waited}s)" || bad "lock" "finished after ${waited}s"
has "it streams npm's own output" "$out" "\$ npm install -g is-odd@latest"
has "and sums up" "$out" "Updated 1 package."
now=$(installed)
[[ -n "$now" && "$now" != 2.0.0 ]] && ok "is-odd really is $now now" || bad "upgrade" "is-odd is still ${now:-missing}"
out=$(m status npm); has "and nothing is left to do" "$out" "Everything is up to date"
python3 -c "
import json
h = json.load(open('$H/state/history.json'))
assert any(r['kind'] == 'upgrade' and r['package'] == 'is-odd' and r['succeeded'] for r in h), h
" && ok "the history the app shows records it" || bad "history" "$(cat "$H/state/history.json")"

print -P "%F{blue}== a failing upgrade%f"
"${E[@]}" npm install -g is-odd@2.0.0 --silent >/dev/null 2>&1
m check npm >/dev/null
# The user's own replacement command, which is how a broken upgrade is made to happen on purpose.
out=$("${E[@]}" MACUP_CMD_update_npm='echo "npm ERR! simulated" >&2; exit 3' macup upgrade npm 2>&1); rc=$?
code "a failed upgrade exits 1" $rc 1
has "and names what failed" "$out" "1 failed: is-odd"

print ""
print -P "%F{blue}command line:%f $pass passed, $fail failed"
(( fail == 0 ))
