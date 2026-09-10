#!/bin/zsh
# Runs inside the container: scans everything, checks each manager reports the expected status and at
# least one outdated package where one was pinned, then dry-runs upgrade/remove for every manager.
set -u
cd "$HOME"
out=$(MACUP_USER_PATH="$PATH" ./scripts/macup-scan.sh 2>&1); rc=$?
echo "$out"
echo "===== scan exit $rc"
fail=0
expect() {  # manager expected-status min-packages
  local m=$1 st=$2 min=$3
  local got; got=$(printf '%s\n' "$out" | awk -F'\t' -v m="$m" '$1=="M" && $2==m {print $3}')
  local n; n=$(printf '%s\n' "$out" | awk -F'\t' -v m="$m" '$1=="P" && $2==m' | wc -l | tr -d ' ')
  if [[ "$got" != "$st" ]]; then echo "FAIL $m: status '$got' (expected $st)"; fail=1
  elif (( n < min )); then echo "FAIL $m: $n packages (expected >= $min)"; fail=1
  else echo "ok   $m: $got, $n packages"; fi
}
expect brew missing 0
expect macos missing 0
expect port missing 0
expect mas missing 0
expect npm ok 1
expect pnpm ok 1
expect bun ok 1
expect pip skipped 0   # the pip on PATH belongs to conda; Conda covers its packages
expect pipx ok 1
expect uv ok 1
expect cargo ok 1
expect rustup ok 0   # a pinned toolchain never reports an update; parser is covered on macOS
expect go ok 1
expect gem ok 1
expect composer ok 1
expect conda ok 1
expect mise ok 1
expect tools ok 3
expect nix missing 0

echo "===== dry-run upgrades"
for m in npm bun pnpm pip pipx uv cargo rustup go gem composer conda mise tools nix; do
  names=$(printf '%s\n' "$out" | awk -F'\t' -v m="$m" '$1=="P" && $2==m {print $3}' | head -n2 | tr '\n' ' ')
  [[ "$m" == go ]] && names=$(printf '%s\n' "$out" | awk -F'\t' -v m="$m" '$1=="P" && $2==m {split($7,a,"|"); print a[2]}' | head -n1)
  res=$(MACUP_DRY_RUN=1 MACUP_USER_PATH="$PATH" ./scripts/macup-upgrade.sh $m ${=names} 2>&1); r=$?
  if (( r == 0 )); then echo "ok   $m: $res" | head -n2; else echo "FAIL $m upgrade dry-run exit $r: $res"; fail=1; fi
done
echo "===== dry-run removals"
for m in npm bun pnpm pip pipx uv cargo go gem composer nix; do
  name=$(printf '%s\n' "$out" | awk -F'\t' -v m="$m" '$1=="P" && $2==m {print $3; exit}')
  [[ -z "$name" ]] && name=example
  res=$(MACUP_DRY_RUN=1 MACUP_USER_PATH="$PATH" ./scripts/macup-remove.sh $m "$name" 2>&1); r=$?
  if (( r == 0 )); then echo "ok   $m: $res"; else echo "FAIL $m remove dry-run exit $r: $res"; fail=1; fi
done
echo "===== result: $([[ $fail == 0 ]] && echo PASS || echo FAIL)"
exit $fail
