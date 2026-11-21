#!/bin/zsh
# App Store reconciliation must work for any app and distinguish installations from indexed copies.
set -uo pipefail
cd "$(dirname "$0")/../.."
S="$PWD/Macup/Resources/Scripts"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/macup-mas.XXXXXX")
trap 'rm -rf "$fixture"' EXIT INT TERM
export MAS_FIXTURE="$fixture"
mkdir -p "$fixture/bin" "$fixture/home/Applications"
cat > "$fixture/bin/mas" <<'MAS'
#!/bin/zsh
[[ "$1" == version || "$1" == --version ]] && { print 7.0.0; exit 0 }
[[ "${MAS_OUTDATED_FAIL:-0}" == 1 ]] && { print 'Error: App Store is offline' >&2; exit 1 }
cat "$MAS_FIXTURE/outdated"
MAS
cat > "$fixture/bin/mdfind" <<'FIND'
#!/bin/zsh
[[ "${MAS_NO_PATHS:-0}" == 1 ]] && exit 0
query=${@: -1}; id=${query##* }
if [[ -f "$MAS_FIXTURE/paths-$id" ]]; then
  if [[ "$1" == -0 ]]; then cat "$MAS_FIXTURE/paths-$id"
  else tr '\0' '\n' < "$MAS_FIXTURE/paths-$id"; fi
fi
[[ "${MAS_QUERY_FAIL:-0}" == 1 ]] && exit 1
exit 0
FIND
cat > "$fixture/bin/mdls" <<'MDLS'
#!/bin/zsh
cat "${@: -1}/Contents/spotlight-bundle-id" 2>/dev/null
MDLS
cat > "$fixture/bin/plutil" <<'PLIST'
#!/bin/zsh
# Use Apple's real plist reader on macOS; the Linux bench needs only these fixture XML fields.
[[ "$OSTYPE" == darwin* ]] && exec /usr/bin/plutil "$@"
key=${2##*.}; file=${@: -1}
[[ "$file" == - ]] && text=$(cat) || text=$(cat "$file" 2>/dev/null)
value=$(print -r -- "$text" | sed -nE "s|.*<key>$key</key><string>([^<]*)</string>.*|\1|p")
if [[ -z "$value" ]]; then
  value=$(print -r -- "$text" | sed -nE "s#.*<key>$key</key><(true|false)/>.*#\1#p")
fi
[[ -n "$value" ]] || exit 1
print -r -- "$value"
PLIST
cat > "$fixture/bin/diskutil" <<'DISK'
#!/bin/zsh
[[ "${MAS_VOLUME_READONLY:-0}" == 1 ]] && readonly=true || readonly=false
print -r -- "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>ReadOnlyVolume</key><$readonly/></dict></plist>"
DISK
chmod +x "$fixture/bin/"*
export HOME="$fixture/home" PATH="$fixture/bin:$PATH" MACUP_USER_PATH="$fixture/bin:$PATH"
pass=0; fail=0
ok() { print "ok   $1"; (( pass++ )); return 0 }
bad() { print -r -- "FAIL $1: $2"; (( fail++ )); return 0 }
app() {
  local destination=$1 version=$2 identifier=${3:-org.example.reader}
  mkdir -p "$destination/Contents/_MASReceipt"
  cat > "$destination/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>999999</string>
</dict></plist>
PLIST
  print -r -- "$identifier" > "$destination/Contents/spotlight-bundle-id"
  touch "$destination/Contents/_MASReceipt/receipt"
}
paths() { local id=$1; shift; printf '%s\0' "$@" > "$fixture/paths-$id"; }
row() { print -r -- "1001 Example Reader (${1:-1.0} -> ${2:-2.0})" > "$fixture/outdated"; }
scan() { zsh "$S/macup-scan.sh" mas 2>/dev/null; }
absent() { [[ "$out" == *$'M\tmas\tok'* && "$out" != *$'P\tmas\t'* ]] && ok "$1" || bad "$1" "$out"; }
offered() { [[ "$out" == *$'P\tmas\tExample Reader\t'"$2"$'\t'"$3"$'\tapp\t1001'* ]] && ok "$1" || bad "$1" "$out"; }

installed="$HOME/Applications/Example Reader.app"
duplicate="$HOME/Applications/Example Reader.localized/Example Reader.app"
app "$installed" 2.0; app "$duplicate" 1.0
row; paths 1001 "$duplicate" "$installed"
out=$(scan); absent "an old duplicate cannot reoffer the version already installed"
row 1.0 3.0; cat "$fixture/outdated" > "$fixture/extra-row"; cat "$fixture/extra-row" >> "$fixture/outdated"
out=$(scan)
count=$(print -r -- "$out" | awk -F'\t' '$1=="P" && $2=="mas" {n++} END {print n+0}')
[[ "$count" == 1 && "$out" == *$'P\tmas\tExample Reader\t2.0\t3.0\tapp\t1001'* ]] \
  && ok "a genuine newer release is offered once per App Store ID" || bad deduplication "$out"
rm -rf "$duplicate"; row
out=$(scan); absent "stale version metadata alone cannot reoffer the installed version"
app "$installed" 3.0
out=$(scan); absent "a newer installed version is never offered a downgrade"
app "$installed" 2.0
out=$(MAS_NO_PATHS=1 scan); offered "missing Spotlight paths preserve the manager report" 1.0 2.0
out=$(MAS_QUERY_FAIL=1 scan); offered "a failed Spotlight query preserves the manager report" 1.0 2.0
out=$(MAS_OUTDATED_FAIL=1 scan)
[[ "$out" == *$'M\tmas\terror\t'* && "$out" != *$'P\tmas\t'* ]] \
  && ok "an App Store failure is not reported as everything up to date" || bad app-store-failure "$out"

# A newer copy outside Applications must not stand in for the older installed copy, in either order.
download="$HOME/Downloads/Example Reader.app"
app "$installed" 1.0; app "$download" 3.0
paths 1001 "$download" "$installed"
out=$(scan); offered "a newer downloaded copy cannot hide an installed app's update" 1.0 2.0
paths 1001 "$installed" "$download"
out=$(scan); offered "installation selection does not depend on Spotlight result order" 1.0 2.0
app "$duplicate" 3.0; paths 1001 "$duplicate" "$installed"
out=$(scan); offered "a nested archive cannot replace a top-level installation" 1.0 2.0
custom="$HOME/Tools/Example Reader.app"; app "$custom" 2.0
paths 1001 "$custom"
out=$(scan); absent "a real App Store installation in a custom location is still recognised"
app "$custom" 1.0; paths 1001 "$download" "$custom"
out=$(scan); offered "a newer download cannot hide an update for a custom installation" 1.0 2.0
paths 1001 "$download"
out=$(scan); absent "an app installed only in Downloads still uses its actual version"

for relative in .Trash .Trashes/501 Backups.backupdb/Mac .timemachine/Mac 'Snapshots/2026-11-20.backup'; do
  copy="$HOME/$relative/Example Reader.app"; app "$copy" 3.0
  paths 1001 "$copy" "$installed"
  out=$(scan); offered "a copy in $relative cannot hide a real update" 1.0 2.0
done
app "$HOME/.Trash/Example Reader.app" 1.0
paths 1001 "$HOME/.Trash/Example Reader.app"
out=$(scan); absent "an app left only in Trash is not offered as installed"
out=$(MAS_QUERY_FAIL=1 scan); offered "partial failed queries cannot prove an app was removed" 1.0 2.0
app "$HOME/.Trash/Example Reader.app" 3.0
alias="$HOME/Applications/Trashed Alias.app"
ln -s "$HOME/.Trash/Example Reader.app" "$alias"
paths 1001 "$alias" "$installed"
out=$(scan); offered "an Applications symlink into Trash cannot hide a real update" 1.0 2.0

# Verify the on-disk identity and installation source before overriding the manager's version.
app "$installed" ''; paths 1001 "$download" "$installed"
out=$(scan); offered "an unverifiable primary installation does not fall back to a newer download" 1.0 2.0
paths 1001 "$installed"; app "$installed" 2.0
print org.example.replaced > "$installed/Contents/spotlight-bundle-id"
out=$(scan); offered "a replaced bundle with stale indexed identity is not trusted" 1.0 2.0
app "$installed" 2.0; rm "$installed/Contents/_MASReceipt/receipt"
out=$(scan); offered "a direct-download copy cannot impersonate an App Store installation" 1.0 2.0
app "$installed" 2.0; print 'not a plist' > "$installed/Contents/Info.plist"
out=$(scan); offered "unreadable bundle metadata preserves the manager report" 1.0 2.0
app "$installed" beta
out=$(scan); offered "an unrecognised installed version cannot hide an update" 1.0 2.0
app "$installed" ''
out=$(scan); offered "a build number is never substituted for a missing marketing version" 1.0 2.0
app "$installed" 2.0; row 1.0 pending
out=$(scan); offered "an unrecognised latest version preserves the manager report" 2.0 pending
app "$installed" 1.0; row 0.9 1.0.0
out=$(scan); absent "equivalent padded versions do not repeat updates"
app "$installed" 1.9; row 1.0 1.10
out=$(scan); offered "numeric comparison keeps 1.10 newer than 1.9" 1.9 1.10

# App names and paths are data, and two different apps must be reconciled independently.
unusual="$HOME/Applications/"$'Photo\nStudio.app'; app "$unusual" 2.0
row; paths 1001 "$unusual"
out=$(scan); absent "NUL-delimited paths support app names containing a newline"
other="$HOME/Applications/Photo Studio (Lite).app"; app "$other" 1.0 org.example.photos
app "$installed" 2.0; paths 1001 "$installed"; paths 2002 "$other"
print '2002 Photo Studio (Lite) (1.0 -> 2.0)' >> "$fixture/outdated"
out=$(scan)
[[ "$out" != *$'P\tmas\tExample Reader'* && "$out" == *$'P\tmas\tPhoto Studio (Lite)\t1.0\t2.0\tapp\t2002'* ]] \
  && ok "different apps and names containing parentheses reconcile independently" || bad independent "$out"

# Mounted installers must be excluded, while the App Store's preferred volume is an install root.
source "$S/macup-apps.sh"
priority=$(macup_app_install_priority /Applications/Utilities/Example.app)
[[ "$priority" == 2 ]] && ok "nested system Applications folders are install roots" || bad system-root "$priority"
priority=$(macup_app_install_priority '/Volumes/External Apps/Applications/Example.app' 'External Apps')
[[ "$priority" == 3 ]] && ok "the App Store preferred volume is an install root" || bad external-root "$priority"
priority=$(MAS_VOLUME_READONLY=1 macup_app_install_priority '/Volumes/Installer/Example.app')
[[ -z "$priority" ]] && ok "a mounted read-only installer is not an installation" || bad installer "$priority"
priority=$(macup_app_install_priority "$HOME/Applications/Parent.app/Contents/Helpers/Example.app")
[[ -z "$priority" ]] && ok "an embedded helper bundle is not a separate installed app" || bad embedded "$priority"

print "App Store reconciliation: $pass passed, $fail failed"
(( fail == 0 ))
