#!/bin/zsh
# Contract tests for macup-scan.sh, driven by stub tools on PATH so they run in seconds and do not
# depend on what happens to be installed. The Linux bench covers the real managers; this covers the
# behaviour around them: streaming, per-manager isolation, timeouts, and the version in failures.
set -uo pipefail
cd "$(dirname "$0")/../.."
SCAN=Macup/Resources/Scripts/macup-scan.sh
pass=0; fail=0
ok()   { print -P "%F{green}ok%f   $1"; (( pass++ )); return 0 }
bad()  { print -P "%F{red}FAIL%f $1"; print "     $2"; (( fail++ )); return 0 }
check(){ [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "expected to contain: $3
     got: ${2//$'\n'/ | }" }

stubs=$(mktemp -d "${TMPDIR:-/tmp}/macup-stubs.XXXXXX")
trap 'rm -rf "$stubs"' EXIT INT TERM
# printf, not print -r: the shebang needs a real newline or the kernel rejects the interpreter and
# zsh quietly falls through to the real tool further down PATH.
stub() { mkdir -p "$stubs/$1"; printf '#!/bin/zsh\n%s\n' "$2" > "$stubs/$1/$3"; chmod +x "$stubs/$1/$3" }
# run <stub dir> [VAR=value ...] zsh $SCAN <managers...>
run()  { local dir=$1; shift; env PATH="$stubs/$dir:$PATH" MACUP_USER_PATH="$stubs/$dir:$PATH" "$@" }

# --- bun: an older bun rejects `outdated -g` and wants a package.json in the working directory ------
old_bun='[[ "$1" == "--version" ]] && { echo 1.0.2; exit 0 }
for a in "$@"; do [[ "$a" == "-g" ]] && { echo "error: missing package.json, nothing outdated" >&2; exit 1 } done
echo "bun outdated v1.0.2"
echo "|---|"
echo "| Package | Current | Update | Latest |"
echo "|---------|---------|--------|--------|"
echo "| cowsay | 1.5.0 | 1.6.0 | 1.6.0 |"'
stub oldbun "$old_bun" bun
home=$(mktemp -d); mkdir -p "$home/install/global"; print '{}' > "$home/install/global/package.json"
out=$(run oldbun BUN_INSTALL="$home" zsh "$SCAN" bun 2>/dev/null)
check "bun: old version falls back to its global directory" "$out" "P	bun	cowsay	1.5.0	1.6.0"

# Same old bun, but nothing installed globally: there is no package.json, and nothing is outdated.
empty=$(mktemp -d); mkdir -p "$empty/install/global"
out=$(run oldbun BUN_INSTALL="$empty" zsh "$SCAN" bun 2>/dev/null)
check "bun: no global packages reports ok, not an error" "$out" "M	bun	ok"
[[ "$out" != *"P	bun"* ]] && ok "bun: no packages reported when none are installed" \
  || bad "bun: no packages reported when none are installed" "got: $out"

# --- a failure names the version, so a bug report shows whether the tool is simply too old ---------
stub brokenbun '[[ "$1" == "--version" ]] && { echo 1.0.2; exit 0 }
echo "error: missing package.json, nothing outdated" >&2; exit 1' bun
with=$(mktemp -d); mkdir -p "$with/install/global"; print '{}' > "$with/install/global/package.json"
out=$(run brokenbun BUN_INSTALL="$with" zsh "$SCAN" bun 2>/dev/null)
check "failure message carries the tool version" "$out" "(bun 1.0.2)"

# --- the version travels with every installed manager, so a report never has to ask for it ----------
stub versioned '[[ "$1" == "--version" ]] && { echo "bun 9.9.9"; exit 0 }
echo "not a table"' bun
out=$(run versioned zsh "$SCAN" bun 2>/dev/null)
check "an installed manager reports its version" "$out" "M	bun	ok		9.9.9"
# A manager that is not installed has no binary to ask. Which managers are absent depends on the
# machine, so this checks the contract rather than naming one.
out=$(run versioned zsh "$SCAN" pnpm conda nix mise port mas 2>/dev/null)
offenders=$(print -r -- "$out" | awk -F'\t' '$3 == "missing" && $5 != ""')
[[ -z "$offenders" ]] && ok "a missing manager reports no version" \
  || bad "a missing manager reports no version" "$offenders"

# --- a tool that falls over silently must not read as "nothing outdated" ---------------------------
# npm and pnpm exit non-zero both when packages are outdated and when they break, so the tell is that
# they printed nothing while complaining on stderr.
stub brokenpnpm '[[ "$1" == "--version" ]] && { echo "ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING" >&2; exit 1 }
echo "TypeError: a dynamic import callback was not specified" >&2; exit 1' pnpm
out=$(run brokenpnpm zsh "$SCAN" pnpm 2>/dev/null)
check "a broken manager is an error, not an empty result" "$out" "M	pnpm	error"
# It cannot say what version it is, so the next most useful fact is where it actually lives: a
# corepack shim or a stale copy on the PATH shows up immediately.
# The path is fully resolved, so match its tail rather than the temporary directory's spelling.
check "a tool with no version reports its path instead" "$out" "(pnpm at /" \
  && check "and the path points at the tool itself" "$out" "brokenpnpm/pnpm)"
check "and the error says what the tool said" "$out" "dynamic import callback"

# Nothing outdated is the normal case: npm prints nothing and exits cleanly.
stub quiet 'exit 0' npm
out=$(run quiet zsh "$SCAN" npm 2>/dev/null)
check "no output and a clean exit is up to date" "$out" "M	npm	ok"

# Outdated packages make npm exit non-zero while still printing JSON, which must stay a success.
# npm pretty-prints its JSON, and the scanner reads it line by line, so the stub has to as well.
stub outdated '[[ "$1" == "--version" ]] && { echo 10.0.0; exit 0 }
[[ "$1" == "root" ]] && { echo /tmp/npm-root; exit 0 }
cat <<JSON
{
  "cowsay": {
    "current": "1.5.0",
    "wanted": "1.6.0",
    "latest": "1.6.0",
    "dependent": "global",
    "location": "/tmp/npm-root/cowsay"
  }
}
JSON
exit 1' npm
out=$(run outdated zsh "$SCAN" npm 2>/dev/null)
check "a non-zero exit with JSON is still a success" "$out" "M	npm	ok"
check "and its packages are reported" "$out" "P	npm	cowsay	1.5.0	1.6.0"

# A non-zero exit with nothing on stderr stays ambiguous, so it is left alone rather than guessed at.
stub silent 'exit 1' npm
out=$(run silent zsh "$SCAN" npm 2>/dev/null)
check "a silent non-zero exit is not called an error" "$out" "M	npm	ok"

# --- streaming: a fast manager is reported before a slow one finishes ------------------------------
stub slow 'sleep 3; echo "{}"' npm
stub slow '[[ "$1" == "--version" ]] && { echo 9.9.9; exit 0 }
echo "cowsay v1.0.0:"' bun   # not a real bun table, so it yields no packages, just a header
# Stamp each line as it arrives: what matters is when bun appears, not when the scan ends.
stamped=$(run slow zsh "$SCAN" npm bun 2>/dev/null | while IFS= read -r line; do print "$(date +%s) $line"; done)
bun_at=$(print -r -- "$stamped" | awk '/M\tbun\t/ {print $1; exit}')
npm_at=$(print -r -- "$stamped" | awk '/M\tnpm\t/ {print $1; exit}')
if [[ -n "$bun_at" && -n "$npm_at" ]] && (( npm_at - bun_at >= 2 )); then
  ok "streaming: bun is emitted $(( npm_at - bun_at ))s before the slow npm, not held until the end"
else
  bad "streaming: bun is emitted before the slow npm" "bun at ${bun_at:-?}, npm at ${npm_at:-?}"
fi

# --- isolation: one manager blowing up leaves the others intact -----------------------------------
stub mixed 'echo "npm ERR! cannot read package tree" >&2; echo "not json"; exit 3' npm
stub mixed '[[ "$1" == "--version" ]] && { echo 9.9.9; exit 0 }
echo "no table here"' bun
out=$(run mixed zsh "$SCAN" npm bun 2>/dev/null)
check "isolation: a failing manager still reports" "$out" "M	npm	error"
check "isolation: the other manager is unaffected" "$out" "M	bun	ok"

# --- a hung manager is stopped and reported rather than holding the whole scan ---------------------
stub hang 'sleep 30' npm
out=$(run hang MACUP_MANAGER_TIMEOUT=1 zsh "$SCAN" npm 2>/dev/null)
check "a hung manager times out" "$out" "took longer than 1s and was stopped"

print ""
print -P "%F{blue}scan script:%f $pass passed, $fail failed"
(( fail == 0 ))
