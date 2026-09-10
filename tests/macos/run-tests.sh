#!/bin/zsh
# macOS integration test: scan, check every manager, then really upgrade and remove one package per
# manager and verify by rescanning. Runs on a disposable GitHub Actions runner.
set -u
cd "$(dirname "$0")/../.."
S=Macup/Resources/Scripts
# Conda goes last so the pip on PATH is Homebrew Python's, not conda's (which the scanner skips on purpose).
export MACUP_USER_PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/Library/pnpm:$HOME/Library/pnpm/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/.deno/bin:$HOME/.composer/vendor/bin:$HOME/.local/share/mise/shims:/opt/local/bin:$PATH:/opt/homebrew/opt/miniconda/bin:/usr/local/Caskroom/miniconda/base/bin:/opt/homebrew/Caskroom/miniconda/base/bin"
export PNPM_HOME="$HOME/Library/pnpm"
# Homebrew's Ruby first, so gems are user-writable on the runner.
for d in "$(brew --prefix)"/lib/ruby/gems/*/bin(N) "$(brew --prefix)/opt/ruby/bin"; do MACUP_USER_PATH="$d:$MACUP_USER_PATH"; done
export PATH="$MACUP_USER_PATH"
fail=0
scan() { "$S/macup-scan.sh" "$@" 2>/dev/null; }
status_of() { printf '%s\n' "$1" | awk -F'\t' -v m="$2" '$1=="M" && $2==m {print $3}'; }
count_of()  { printf '%s\n' "$1" | awk -F'\t' -v m="$2" '$1=="P" && $2==m' | wc -l | tr -d ' '; }
first_of()  { printf '%s\n' "$1" | awk -F'\t' -v m="$2" '$1=="P" && $2==m {print $3; exit}'; }
has()       { printf '%s\n' "$1" | awk -F'\t' -v m="$2" -v n="$3" '$1=="P" && $2==m && $3==n' | grep -q .; }
installed_of() { printf '%s\n' "$1" | awk -F'\t' -v m="$2" -v n="$3" '$1=="P" && $2==m && $3==n {print $4; exit}'; }

echo "===== full scan"
out=$(scan); echo "$out" | grep '^M'
echo "$out" | grep '^P' | awk -F'\t' '{printf "  %-9s %-28s %-10s -> %-10s %s\n", $2, $3, $4, $5, $6}'

expect() {  # manager expected-status min-packages
  local got; got=$(status_of "$out" "$1"); local n; n=$(count_of "$out" "$1")
  if [[ "$got" != "$2" ]]; then echo "FAIL $1: status '$got' (expected $2)"; fail=1
  elif (( n < $3 )); then echo "FAIL $1: $n packages (expected >= $3)"; fail=1
  else echo "ok   $1: $got, $n packages"; fi
}
# Managers whose installation on the runner is best-effort: "ok" when present, "missing" otherwise.
expect_if_present() {  # manager command min-packages
  if command -v "$2" >/dev/null 2>&1; then expect "$1" ok "$3"; else expect "$1" missing 0; fi
}
echo "===== expectations"
expect macos ok 0
expect brew ok 1
expect_if_present port port 0
expect npm ok 1
expect bun ok 1
expect pnpm ok 1
expect pip ok 1
expect pipx ok 1
expect uv ok 1
expect_if_present conda conda 0
expect rustup ok 0
expect cargo ok 1
expect go ok 1
expect gem ok 1
expect_if_present composer composer 1
expect nix missing 0
expect mise ok 1
expect tools ok 3
# mas cannot sign in on CI; it must at least run and be parsed (ok) or fail cleanly (error).
mas_status=$(status_of "$out" mas); [[ "$mas_status" == ok || "$mas_status" == error ]] && echo "ok   mas: $mas_status" || { echo "FAIL mas: $mas_status"; fail=1; }
has "$out" brew jq || { echo "FAIL brew: jq not reported outdated"; fail=1; }
has "$out" tools uv || { echo "FAIL tools: self-installed uv not reported"; fail=1; }
has "$out" go goimports || { echo "FAIL go: goimports not reported"; fail=1; }
has "$out" mise node || { echo "FAIL mise: node not reported"; fail=1; }

# Real upgrades: run the script and rescan. The package must either leave the outdated list or, for
# managers whose scanner lists every installed package (latest resolved by the app), report a new version.
upgrade_check() {  # manager name [upgrade-arg]
  local m=$1 n=$2 arg=${3:-$2}
  local before; before=$(installed_of "$out" "$m" "$n")
  echo "--- upgrade $m $n ($before)"
  local log="/tmp/up-$m-${n//\//_}.log"
  "$S/macup-upgrade.sh" "$m" "$arg" > "$log" 2>&1; local rc=$?
  if (( rc != 0 )); then echo "FAIL $m upgrade exited $rc :"; tail -n 5 "$log"; fail=1; return; fi
  local after; after=$(scan "$m")
  local now; now=$(installed_of "$after" "$m" "$n")
  if [[ -z "$now" ]]; then echo "ok   $m: $n upgraded (no longer outdated)"
  elif [[ "$now" != "$before" ]]; then echo "ok   $m: $n upgraded ($before -> $now)"
  else echo "FAIL $m: $n still at $before after upgrade"; tail -n 5 "$log"; fail=1; fi
}
echo "===== real upgrades"
upgrade_check brew jq
upgrade_check npm typescript
upgrade_check bun cowsay
upgrade_check pnpm is-odd
upgrade_check pip requests
upgrade_check pipx black
upgrade_check uv ruff
upgrade_check cargo shellharden
upgrade_check go goimports "$(printf '%s\n' "$out" | awk -F'\t' '$1=="P" && $2=="go" && $3=="goimports" {split($7,a,"|"); print a[2]}')"
upgrade_check gem colorize
command -v composer >/dev/null && upgrade_check composer psr/log
upgrade_check mise node
if [[ -n "$(first_of "$out" conda)" ]]; then upgrade_check conda "$(first_of "$out" conda)"; fi
echo "--- rustup update (runs, nothing pinned)"; "$S/macup-upgrade.sh" rustup > /tmp/up-rustup.log 2>&1 && echo "ok   rustup: update ran" || { echo "FAIL rustup update"; tail -n 5 /tmp/up-rustup.log; fail=1; }
echo "--- macos: dry-run hand-off"; MACUP_DRY_RUN=1 "$S/macup-upgrade.sh" macos && echo "ok   macos"
echo "--- port: dry-run (needs an admin prompt for real)"; MACUP_DRY_RUN=1 "$S/macup-upgrade.sh" port nano && echo "ok   port"
echo "--- nix: dry-run"; MACUP_DRY_RUN=1 "$S/macup-upgrade.sh" nix && echo "ok   nix"

# Real removals: the package must disappear from the manager's own listing.
remove_check() {  # manager name check-command...
  local m=$1 n=$2; shift 2
  echo "--- remove $m $n"
  local log="/tmp/rm-$m-${n//\//_}.log"
  "$S/macup-remove.sh" "$m" "$n" > "$log" 2>&1; local rc=$?
  if (( rc != 0 )); then echo "FAIL $m remove exited $rc"; tail -n 5 "$log"; fail=1; return; fi
  if "$@" >/dev/null 2>&1; then echo "FAIL $m: $n still present after remove"; fail=1; else echo "ok   $m: $n removed"; fi
}
echo "===== real removals"
remove_check brew jq brew list --formula jq
remove_check npm prettier test -d "$(npm root -g)/prettier"
remove_check bun cowsay test -d "$HOME/.bun/install/global/node_modules/cowsay"
remove_check pnpm is-odd sh -c 'pnpm ls -g --depth 0 | grep -q is-odd'
remove_check pip requests python3 -c 'import requests'
remove_check pipx black sh -c 'pipx list | grep -q black'
remove_check uv ruff sh -c 'uv tool list | grep -q ruff'
remove_check cargo shellharden test -x "$HOME/.cargo/bin/shellharden"
remove_check go goimports test -x "$HOME/go/bin/goimports"
remove_check gem colorize sh -c 'gem list colorize | grep -q colorize'
command -v composer >/dev/null && remove_check composer psr/log sh -c 'composer global show psr/log'
# Self-updates last: a new pnpm major keeps its own global directory, so packages installed by the
# old one must be removed before pnpm itself is replaced.
echo "===== self-installed tool upgrades"
upgrade_check tools uv
upgrade_check tools pnpm
upgrade_check tools deno
upgrade_check tools bun

echo "===== result: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit $fail
