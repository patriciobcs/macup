#!/bin/zsh
# macup-scan.sh — discover package managers and list outdated packages.
#
# Output: tab-separated lines, one record per line.
#   M <manager> <status> <message>             manager header (status: ok|missing|error|skipped)
#   P <manager> <name> <installed> <latest> <kind> <extra> <updated>
#       outdated package. latest may be "?" when the app must resolve it from a registry.
#       updated = epoch seconds when the installed version landed on this Mac (Homebrew's install
#       receipt; the install folder/binary modification time for the others), or empty if unknown.
#   kind is prefixed with "system-" when the package lives in a location owned by macOS
#   (system Ruby gems, the Xcode Python, a root-owned npm prefix): those should not be changed.
# Usage: macup-scan.sh [manager ...]   (no args = all managers)
set -u
setopt NULL_GLOB EXTENDED_GLOB 2>/dev/null

# Zero-config PATH: GUI apps inherit a tiny PATH. Prefer the PATH the app resolved from the user's login
# shell (MACUP_USER_PATH), then append well-known tool dirs that are not already present.
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
# Homebrew refreshes its API cache on `outdated` at most once a day; without that refresh results go stale.
export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_COLOR=0 NO_COLOR=1
export npm_config_update_notifier=false

header() { printf 'M\t%s\t%s\t%s\n' "$1" "$2" "${${3:-}//[$'\t\n']/ }"; }
pkg()    { printf 'P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${1//[$'\t\n']/ }" "${2//[$'\t\n']/ }" "${3//[$'\t\n']/ }" "${4//[$'\t\n']/ }" "${5//[$'\t\n']/ }" "${${6:-}//[$'\t\n']/ }" "${${7:-}//[$'\t\n']/ }"; }
if stat -f %m / >/dev/null 2>&1; then mtime() { [[ -e "$1" ]] && stat -f %m "$1" 2>/dev/null; }
else mtime() { [[ -e "$1" ]] && stat -c %Y "$1" 2>/dev/null; }; fi
# First dotted version number in a tool's --version output.
self_version() { "$1" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1; }
have()   { command -v "$1" >/dev/null 2>&1; }
# Last line of a command's stderr, cleaned up for display in the app.
errline() {
  # Prefer a line that names the problem; otherwise the last non-empty line. One line, no control chars.
  local lines; lines=$(tr -d "\r" < "$1" 2>/dev/null | sed -E "s/\x1b\[[0-9;]*m//g" | grep -vE '^[[:space:]]*$')
  local pick; pick=$(printf '%s\n' "$lines" | grep -iE 'offline|could not|unable|cannot|error|failed|denied|not found|timed out|unreachable' | head -n1)
  [[ -z "$pick" ]] && pick=$(printf '%s\n' "$lines" | tail -n1)
  printf '%s' "$pick" | tr -d "\t" | sed -E 's/^[[:space:]]+//' | cut -c1-200
}

# Extract "key": "value" (string) or first element of an array of strings from one JSON object line.
# Only used on JSON we know is pretty-printed one key per line (brew, npm, pip).
jstr() { sed -nE "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -n1; }

scan_brew() {
  have brew || { header brew missing; return; }
  local greedy=""; [[ "${MACUP_BREW_GREEDY:-0}" == 1 ]] && greedy="--greedy"
  local out; local err="$tmp/brew.err"
  out=$(brew outdated --json=v2 $greedy 2>"$err") || { header brew error "brew outdated failed: $(errline "$err")"; return; }
  header brew ok
  local prefix; prefix=$(brew --prefix 2>/dev/null)
  brew_time() {  # $1 kind, $2 name, $3 installed version
    local n=${2##*/}
    if [[ "$1" == cask ]]; then mtime "$prefix/Caskroom/$n/$3"
    else sed -nE 's/.*"time": *([0-9]+).*/\1/p' "$prefix/Cellar/$n/$3/INSTALL_RECEIPT.json" 2>/dev/null | head -n1; fi
  }
  # Minimal streaming parse: section (formulae/casks), then name / installed_versions[0] / current_version.
  local section="" name="" installed="" latest="" in_inst=0 v=""
  while IFS= read -r line; do
    case "$line" in
      *'"formulae"'*) section=formula ;;
      *'"casks"'*)    section=cask ;;
      *'"name"'*)     name=$(printf '%s\n' "$line" | jstr name) ;;
      *'"installed_versions"'*) in_inst=1; installed="" ;;
      *'"current_version"'*)
        latest=$(printf '%s\n' "$line" | jstr current_version)
        [[ -n "$name" && -n "$latest" ]] && pkg brew "$name" "${installed:-?}" "$latest" "$section" "" "$(brew_time "$section" "$name" "$installed")"
        name="" installed="" latest="" ;;
      *)
        if (( in_inst )); then
          v=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*"([^"]*)".*/\1/p')
          [[ -n "$v" ]] && installed="$v"
          [[ "$line" == *']'* ]] && in_inst=0
        fi ;;
    esac
  done <<< "$out"
}

scan_npm() {
  have npm || { header npm missing; return; }
  local out; local err="$tmp/npm.err"
  out=$(npm outdated -g --json 2>"$err"); local rc=$?
  # npm exits 1 when outdated packages exist; only treat non-JSON output as error.
  [[ -z "$out" ]] && out="{}"
  [[ "$out" != \{* ]] && { header npm error "npm outdated failed: $(errline "$err")"; return; }
  header npm ok
  local root kind=global; root=$(npm root -g 2>/dev/null)
  [[ -n "$root" && -d "$root" && ! -w "$root" ]] && kind=system-global
  local name="" current="" latest=""
  while IFS= read -r line; do
    case "$line" in
      *'"current"'*) current=$(printf '%s\n' "$line" | jstr current) ;;
      *'"latest"'*)  latest=$(printf '%s\n' "$line" | jstr latest) ;;
      *'"location"'*|*'"dependent"'*) ;;
      *'"'*'": {'*)  name=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*"([^"]*)"[[:space:]]*:.*/\1/p') ;;
      *'}'*) [[ -n "$name" && -n "$latest" && "$current" != "$latest" ]] && pkg npm "$name" "${current:-?}" "$latest" "$kind" "" "$(mtime "$root/$name")"
             name="" current="" latest="" ;;
    esac
  done <<< "$out"
}

scan_bun() {
  have bun || { header bun missing; return; }
  local out; local err="$tmp/bun.err"
  out=$(bun outdated -g --no-progress 2>"$err") || { header bun error "bun outdated failed: $(errline "$err")"; return; }
  header bun ok
  local root="${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules" name cur latest
  # Table rows: | name | current | update | latest |
  printf '%s\n' "$out" | awk -F'|' '
    /^\|[^-]/ && $2 !~ /Package/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); gsub(/^[ \t]+|[ \t]+$/, "", $5);
      if ($2 != "" && $3 != $5) printf "%s\t%s\t%s\n", $2, $3, $5 }' | \
  while IFS=$'\t' read -r name cur latest; do pkg bun "$name" "$cur" "$latest" global "" "$(mtime "$root/$name")"; done
}

scan_pnpm() {
  have pnpm || { header pnpm missing; return; }
  local out; local err="$tmp/pnpm.err"
  out=$(pnpm outdated -g --format json 2>"$err"); local rc=$?
  [[ -z "$out" ]] && out="{}"
  [[ "$out" != \{* ]] && { header pnpm error "pnpm outdated failed: $(errline "$err")"; return; }
  header pnpm ok
  local root; root=$(pnpm root -g 2>/dev/null)
  # pnpm JSON is compact or pretty; normalise to one key per line.
  local name="" current="" latest=""
  while IFS= read -r line; do
    case "$line" in
      *'"current"'*) current=$(printf '%s\n' "$line" | jstr current) ;;
      *'"latest"'*)  latest=$(printf '%s\n' "$line" | jstr latest) ;;
      *'"'*'":'*'{'*)  name=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*"([^"]*)"[[:space:]]*:.*/\1/p') ;;
      *'}'*) [[ -n "$name" && -n "$latest" && "$current" != "$latest" ]] && pkg pnpm "$name" "${current:-?}" "$latest" global "" "$(mtime "$root/$name")"
             name="" current="" latest="" ;;
    esac
  done <<< "$(printf '%s\n' "$out" | awk '{ gsub(/[{,]/, "&\n"); print }')"
}

scan_pip() {
  local py=""
  for c in pip3 pip; do have "$c" && { py="$c"; break; }; done
  [[ -z "$py" ]] && { header pip missing; return; }
  # "pip 24.0 from /path/site-packages/pip (python 3.12)" → site-packages; unwritable means macOS/Xcode owns it.
  local site kind=package; site=$($py --version 2>/dev/null | sed -nE 's/^pip [^ ]+ from (.*)\/pip \(python.*/\1/p')
  # A pip inside a conda environment lists conda's own packages; Conda handles those.
  case "$site" in *conda*/*|*mamba*/*) header pip skipped "pip belongs to the conda environment; see Conda"; return ;; esac
  local out; local err="$tmp/pip.err"
  out=$($py list --outdated --format=json --disable-pip-version-check 2>"$err") || { header pip error "pip list failed: $(errline "$err")"; return; }
  header pip ok
  [[ -n "$site" && -d "$site" && ! -w "$site" ]] && kind=system-package
  # Compact JSON: [{"name": "...", "version": "...", "latest_version": "...", ...}, ...]
  local name cur latest info
  printf '%s\n' "$out" | awk '{ gsub(/\},[[:space:]]*\{/, "}\n{"); print }' | \
    sed -nE 's/.*"name": *"([^"]*)".*"version": *"([^"]*)".*"latest_version": *"([^"]*)".*/\1\t\2\t\3/p' | \
  while IFS=$'\t' read -r name cur latest; do
    # dist-info (or older egg-info) folder: name is normalised (dashes/dots → underscores, any case).
    local norm=${name//[-.]/_}
    info=("$site"/(#i)${norm}-$cur.dist-info(N) "$site"/(#i)${name}-$cur.dist-info(N) "$site"/(#i)${norm}-$cur*.egg-info(N) "$site"/(#i)${name}-$cur*.egg-info(N))
    pkg pip "$name" "$cur" "$latest" "$kind" "" "$(mtime "${info[1]:-}")"
  done
}

scan_uv() {
  have uv || { header uv missing; return; }
  local out; local err="$tmp/uv.err"
  out=$(uv tool list 2>"$err") || { header uv error "uv tool list failed: $(errline "$err")"; return; }
  header uv ok
  local dir name cur; dir=$(uv tool dir 2>/dev/null)
  # "name vX.Y.Z" lines; latest resolved by the app via PyPI.
  printf '%s\n' "$out" | sed -nE 's/^([A-Za-z0-9_.-]+) v([0-9][^ ]*).*/\1\t\2/p' | \
  while IFS=$'\t' read -r name cur; do pkg uv "$name" "$cur" "?" tool "" "$(mtime "$dir/$name")"; done
}

scan_cargo() {
  have cargo || { header cargo missing; return; }
  local out; local err="$tmp/cargo.err"
  out=$(cargo install --list 2>"$err") || { header cargo error "cargo install --list failed: $(errline "$err")"; return; }
  header cargo ok
  local bin="${CARGO_HOME:-$HOME/.cargo}/bin" name cur exe
  # "name vX.Y.Z:" lines (skip local path/git installs which carry a "(...)" suffix) followed by indented
  # binary names; latest via crates.io.
  printf '%s\n' "$out" | awk '
    /^[A-Za-z0-9_-]+ v[0-9][^ :]*:$/ { sub(/:$/, ""); split($0, a, " v"); name=a[1]; ver=a[2]; next }
    /^    / && name != "" { print name "\t" ver "\t" $1; name="" }' | \
  while IFS=$'\t' read -r name cur exe; do pkg cargo "$name" "$cur" "?" crate "" "$(mtime "$bin/$exe")"; done
}

scan_rustup() {
  have rustup || { header rustup missing; return; }
  local out; local err="$tmp/rustup.err"
  # rustup >= 1.29 exits 100 when updates are available; older versions exit 0.
  out=$(rustup check 2>"$err"); local rc=$?
  (( rc == 0 || rc == 100 )) || { header rustup error "rustup check failed: $(errline "$err")"; return; }
  header rustup ok
  # "stable-aarch64-apple-darwin - Update available : 1.93.0 (hash 2026-01-19) -> 1.98.1 (hash 2026-09-01)"  (rustup 1.28)
  # "stable-aarch64-apple-darwin - update available: 1.93.0 (hash 2026-01-19) -> 1.98.1 (hash 2026-09-01)"   (rustup 1.29)
  local home="${RUSTUP_HOME:-$HOME/.rustup}" name cur latest date loc
  printf '%s\n' "$out" | sed -nE \
    -e 's/^([^ ]+) - [Uu]pdate available ?: ([0-9][^ ]*)( \([^)]*\))? -> ([0-9][^ ]*)( \([^ ]* ([0-9-]+)\))?.*/\1\t\2\t\4\t\6/p' | \
  while IFS=$'\t' read -r name cur latest date; do
    if [[ "$name" == rustup ]]; then loc=$(command -v rustup); else loc="$home/toolchains/$name"; fi
    pkg rustup "$name" "$cur" "$latest" toolchain "$date" "$(mtime "$loc")"
  done
}

scan_gem() {
  have gem || { header gem missing; return; }
  local dir; dir=$(gem environment gemdir 2>/dev/null)
  local out; local err="$tmp/gem.err"
  out=$(gem outdated 2>"$err") || { header gem error "gem outdated failed: $(errline "$err")"; return; }
  # System Ruby installs into /Library, which needs an administrator password to change.
  local system=0
  if [[ -n "$dir" && ! -w "$dir" ]]; then header gem ok admin; system=1; else header gem ok; fi
  local name cur latest kind loc p
  local -a gempaths; gempaths=(${(s/:/)$(gem environment gempath 2>/dev/null)})
  printf '%s\n' "$out" | sed -nE 's/^([A-Za-z0-9_.-]+) \(([^ ]+) < ([^)]+)\)$/\1\t\2\t\3/p' | \
  while IFS=$'\t' read -r name cur latest; do
    kind=gem
    local userdirs=("$HOME"/.gem/ruby/*/gems/"$name"-"$cur"); loc=""
    if (( ${#userdirs} )); then loc=${userdirs[1]}
    else
      (( system )) && kind=system-gem
      # Installed gems can live in any GEM_PATH entry (system Ruby keeps its own under /System).
      for p in "${gempaths[@]}"; do [[ -d "$p/gems/$name-$cur" ]] && { loc="$p/gems/$name-$cur"; break; }; done
    fi
    pkg gem "$name" "$cur" "$latest" "$kind" "" "$(mtime "$loc")"
  done
}

scan_mas() {
  have mas || { header mas missing; return; }
  local out; local err="$tmp/mas.err"
  out=$(mas outdated 2>"$err") || { header mas error "mas outdated failed: $(errline "$err")"; return; }
  header mas ok
  local id name cur latest app when
  # "497799835 Xcode (15.0 -> 15.1)"
  printf '%s\n' "$out" | sed -nE 's/^([0-9]+) +(.*) \(([^ ]+) -> ([^)]+)\)$/\1\t\2\t\3\t\4/p' | \
  while IFS=$'\t' read -r id name cur latest; do
    app=$(mdfind "kMDItemAppStoreAdamID == $id" 2>/dev/null | head -n1)
    when=""; [[ -n "$app" ]] && when=$(mtime "$app/Contents/Info.plist")
    pkg mas "$name" "$cur" "$latest" app "$id" "$when"
  done
}


scan_macos() {
  have softwareupdate || { header macos missing; return; }
  # --no-scan reads the list macOS refreshes in the background, so this stays fast.
  local out; out=$(softwareupdate -l --no-scan 2>/dev/null) || { header macos ok; return; }
  header macos ok
  local current; current=$(sw_vers -productVersion 2>/dev/null)
  # "	Title: macOS Sequoia 15.6, Version: 15.6, Size: ..., Recommended: YES, Action: restart,"
  printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*Title: ([^,]+), Version: ([^,]+),.*/\1\t\2/p' | \
  while IFS=$'\t' read -r title version; do
    local installed="?"; [[ "$title" == macOS* ]] && installed=$current
    pkg macos "$title" "$installed" "$version" os "" ""
  done
}

scan_tools() {
  # Tools installed by their own curl | sh installers. Nothing else updates them, so MacUp checks
  # GitHub's latest release for each one that is not managed by Homebrew, npm, Nix, mise or MacPorts.
  local brewp=""; have brew && brewp=$(brew --prefix 2>/dev/null)
  local spec name repo prefix bin real cur latest
  local -a lookups=()   # PIDs of our own lookups: a bare `wait` would also wait on jobs inherited from the runner
  local -a specs=("uv|astral-sh/uv|" "bun|oven-sh/bun|bun-v" "deno|denoland/deno|v" "pnpm|pnpm/pnpm|v" "mise|jdx/mise|v")
  local found=0
  for spec in "${specs[@]}"; do
    IFS='|' read -r name repo prefix <<< "$spec"
    have "$name" || continue
    bin=$(command -v "$name"); real=$(realpath "$bin" 2>/dev/null || print -r -- "$bin")
    [[ -n "$brewp" && "$real" == "$brewp"/* ]] && continue
    case "$real" in
      */node_modules/*|*/corepack/*|/nix/store/*|*/.rustup/*|*/.cargo/bin/*|*/mise/*|*/.asdf/*|/opt/local/*|/usr/local/Cellar/*) continue ;;
      */pipx/venvs/*|*/site-packages/*|*/Python.framework/*|*/.local/share/uv/tools/*|*/.volta/*) continue ;;
    esac
    cur=$(self_version "$name"); [[ -z "$cur" ]] && continue
    found=1
    # Latest tag from the releases/latest redirect: no API rate limit involved.
    ( tag=$(curl -sI -m 10 "https://github.com/$repo/releases/latest" | sed -nE 's#^[Ll]ocation: .*/tag/([^[:space:]]+).*#\1#p' | tr -d '\r')
      latest=${tag#$prefix}
      [[ -n "$latest" && "$latest" == "$cur" ]] && exit 0   # already current
      pkg tools "$name" "$cur" "${latest:-?}" tool "$repo:$tag" "$(mtime "$real")" > "$tmp/lookup-tools.$name" ) &
    lookups+=($!)
  done
  (( ${#lookups} )) && wait "${lookups[@]}"
  (( found )) || { header tools missing; return; }
  header tools ok
  cat "$tmp"/lookup-tools.* 2>/dev/null   # distinct prefix: "$tmp/tools.part" is this scanner's own output
}

scan_mise() {
  have mise || { header mise missing; return; }
  local out; local err="$tmp/mise.err"
  out=$(mise outdated --json 2>"$err") || { header mise error "mise outdated failed: $(errline "$err")"; return; }
  header mise ok
  # { "node": { "current": "20.11.0", "latest": "20.12.2", ... }, ... }
  local name="" current="" latest="" where
  while IFS= read -r line; do
    case "$line" in
      *'"current"'*) current=$(printf '%s\n' "$line" | jstr current) ;;
      *'"latest"'*)  latest=$(printf '%s\n' "$line" | jstr latest) ;;
      *'"'*'":'*'{'*)  [[ -z "$name" ]] && name=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*"([^"]*)"[[:space:]]*:.*/\1/p') ;;
      *'}'*)
        if [[ -n "$name" && -n "$latest" && "$current" != "$latest" ]]; then
          where=$(mise where "$name" 2>/dev/null)
          pkg mise "$name" "${current:-?}" "$latest" runtime "" "$(mtime "$where")"
        fi
        [[ "$line" == *'}'* && -n "$name" && -n "$latest" ]] && { name=""; current=""; latest=""; } ;;
    esac
  done <<< "$(printf '%s\n' "$out" | awk '{ gsub(/[{,]/, "&\n"); print }')"
}

scan_pipx() {
  have pipx || { header pipx missing; return; }
  local out; local err="$tmp/pipx.err"
  out=$(pipx list --json 2>"$err") || { header pipx error "pipx list failed: $(errline "$err")"; return; }
  header pipx ok
  # pipx needs Python, so Python is there to read its JSON. Latest resolved by the app via PyPI.
  printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for name, v in d.get("venvs", {}).items():
    mp = v.get("metadata", {}).get("main_package", {})
    print(name, mp.get("package_version", "?"), v.get("metadata", {}).get("venv_path", "") or "", sep="\t")
' 2>/dev/null | while IFS=$'\t' read -r name cur venv; do
    [[ -z "$venv" ]] && venv="$(pipx environment --value PIPX_LOCAL_VENVS 2>/dev/null)/$name"
    pkg pipx "$name" "$cur" "?" tool "" "$(mtime "$venv")"
  done
}

scan_go() {
  have go || { header go missing; return; }
  # Binaries land in GOBIN, else GOPATH/bin. Version managers (mise, asdf) point GOPATH elsewhere, so the
  # default ~/go/bin is scanned as well.
  local bin; bin=$(go env GOBIN 2>/dev/null); [[ -z "$bin" ]] && bin="$(go env GOPATH 2>/dev/null)/bin"
  local -a dirs=("$bin"); [[ "$bin" != "$HOME/go/bin" && -d "$HOME/go/bin" ]] && dirs+=("$HOME/go/bin")
  header go ok
  local f info mod ver pth
  for f in "${^dirs[@]}"/*(N.x); do
    info=$(go version -m "$f" 2>/dev/null) || continue
    pth=$(printf '%s\n' "$info" | awk '$1=="path"{print $2; exit}')
    mod=$(printf '%s\n' "$info" | awk '$1=="mod"{print $2; exit}')
    ver=$(printf '%s\n' "$info" | awk '$1=="mod"{print $3; exit}')
    # Binaries built from a local checkout report "(devel)" and cannot be compared.
    [[ -z "$mod" || -z "$pth" || "$ver" != v[0-9]* ]] && continue
    pkg go "${f:t}" "$ver" "?" binary "$mod|$pth" "$(mtime "$f")"
  done
}

scan_port() {
  have port || { header port missing; return; }
  local out; local err="$tmp/port.err"
  out=$(port outdated 2>"$err") || { header port error "port outdated failed: $(errline "$err")"; return; }
  # MacPorts installs into /opt/local as root, so changes need an administrator password.
  header port ok admin
  # "git                            2.44.0_0 < 2.45.0_0"
  printf '%s\n' "$out" | sed -nE 's/^([A-Za-z0-9_.+-]+) +([^ ]+) < ([^ ]+).*/\1\t\2\t\3/p' | \
  while IFS=$'\t' read -r name cur latest; do
    pkg port "$name" "$cur" "$latest" port "" "$(mtime "/opt/local/var/macports/software/$name")"
  done
}

scan_nix() {
  if ! have nix-env; then
    have nix && { header nix skipped "nix profile has no outdated listing; run: nix profile upgrade --all"; return; }
    header nix missing; return
  fi
  local out; local err="$tmp/nix.err"
  out=$(nix-env -u --dry-run 2>&1) || { header nix error "nix-env failed: $(printf '%s\n' "$out" | tail -n1 | cut -c1-160)"; return; }
  header nix ok
  # "upgrading 'hello-2.10' to 'hello-2.12'"  → split name/version at the first "-<digit>".
  printf '%s\n' "$out" | sed -nE "s/^upgrading '([^']+)' to '([^']+)'.*/\1\t\2/p" | \
  while IFS=$'\t' read -r from to; do
    local name=${from%%-[0-9]*} cur=${from#*-[0-9]} latest=${to#*-[0-9]}
    cur=${from:${#name}+1}; latest=${to:${#name}+1}
    pkg nix "$name" "$cur" "$latest" package "" ""
  done
}

scan_composer() {
  have composer || { header composer missing; return; }
  local out; local err="$tmp/composer.err"
  out=$(composer global outdated --direct --format=json 2>"$err") || { header composer error "composer outdated failed: $(errline "$err")"; return; }
  header composer ok
  local home; home=$(composer global config home 2>/dev/null)
  # Composer needs PHP, so PHP is there to read its JSON.
  printf '%s\n' "$out" | php -r '$d = json_decode(stream_get_contents(STDIN), true); foreach (($d["installed"] ?? []) as $p) printf("%s\t%s\t%s\n", $p["name"], $p["version"], $p["latest"]);' 2>/dev/null | \
  while IFS=$'\t' read -r name cur latest; do
    pkg composer "$name" "$cur" "$latest" package "" "$(mtime "$home/vendor/$name")"
  done
}

scan_conda() {
  have conda || { header conda missing; return; }
  local base; base=$(conda info --base 2>/dev/null)
  local out; local err="$tmp/conda.err"
  # The solver can take a while; the app allows the scan several minutes.
  out=$(conda update --all --dry-run --json 2>"$err") || { header conda error "conda dry run failed: $(errline "$err")"; return; }
  header conda ok
  printf '%s\n' "$out" | "$base/bin/python" -c '
import json, sys
d = json.load(sys.stdin)
acts = d.get("actions") or {}
old = {p["name"]: p["version"] for p in acts.get("UNLINK", [])}
for p in acts.get("LINK", []):
    if p["name"] in old and old[p["name"]] != p["version"]:
        print(p["name"], old[p["name"]], p["version"], p.get("build_string", ""), sep="\t")
' 2>/dev/null | while IFS=$'\t' read -r name cur latest build; do
    local meta=("$base"/conda-meta/"$name"-"$cur"-*.json(N))
    pkg conda "$name" "$cur" "$latest" package "" "$(mtime "${meta[1]:-}")"
  done
}

ALL=(macos brew port npm bun pnpm pip pipx uv conda rustup cargo go gem composer nix mise tools mas)
managers=("$@"); (( $# == 0 )) && managers=("${ALL[@]}")

# Run managers concurrently, each into its own temp file, then emit in stable order.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/macup.XXXXXX"); trap 'rm -rf "$tmp"' EXIT TERM INT HUP
# Each manager gets its own deadline so one slow or hung tool cannot take the whole scan with it.
deadline=${MACUP_MANAGER_TIMEOUT:-180}
for m in "${managers[@]}"; do
  (
    trap - EXIT TERM INT HUP   # subshells inherit the cleanup trap; only the main shell may remove $tmp
    ( trap - EXIT TERM INT HUP; "scan_$m" > "$tmp/$m.part" 2>/dev/null ) &
    worker=$!
    # The watchdog kills the manager process itself, not only the worker shell, and never holds our stdout.
    ( trap - EXIT TERM INT HUP; sleep "$deadline"; pkill -TERM -P $worker 2>/dev/null; kill -TERM $worker 2>/dev/null && : > "$tmp/$m.timeout" ) >/dev/null 2>&1 &
    watchdog=$!
    wait $worker 2>/dev/null
    pkill -P $watchdog 2>/dev/null; kill $watchdog 2>/dev/null; wait $watchdog 2>/dev/null
    mv -f "$tmp/$m.part" "$tmp/$m" 2>/dev/null
  ) &
done
wait
for m in "${managers[@]}"; do
  if [[ -e "$tmp/$m.timeout" ]]; then header "$m" error "took longer than ${deadline}s and was stopped"
  elif [[ -s "$tmp/$m" ]]; then cat "$tmp/$m"
  else header "$m" error "scanner crashed"; fi
done
