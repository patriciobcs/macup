#!/bin/zsh
# An old duplicate or stale Spotlight version must not keep an already-updated App Store app ready.
set -uo pipefail
cd "$(dirname "$0")/../.."
S="$PWD/Macup/Resources/Scripts"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/macup-mas.XXXXXX")
trap 'rm -rf "$fixture"' EXIT INT TERM
export MAS_FIXTURE="$fixture"
mkdir -p "$fixture/bin" "$fixture/WhatsApp.app/Contents" "$fixture/WhatsApp.localized/WhatsApp.app/Contents"
print 26.44.74 > "$fixture/WhatsApp.app/Contents/Info.plist"
print 26.40.77 > "$fixture/WhatsApp.localized/WhatsApp.app/Contents/Info.plist"
cat > "$fixture/bin/mas" <<'MAS'
#!/bin/zsh
[[ "$1" == version || "$1" == --version ]] && { print 7.0.0; exit 0 }
print "310633997 WhatsApp (26.40.77 -> ${MAS_LATEST:-26.44.74})"
[[ "${MAS_DUPLICATE_ROWS:-0}" == 1 ]] && print "310633997 WhatsApp (26.40.77 -> ${MAS_LATEST:-26.44.74})"
exit 0
MAS
cat > "$fixture/bin/mdfind" <<'FIND'
#!/bin/zsh
[[ "${MAS_NO_PATHS:-0}" == 1 ]] && exit 0
print -r -- "$MAS_FIXTURE/WhatsApp.localized/WhatsApp.app"
print -r -- "$MAS_FIXTURE/WhatsApp.app"
FIND
cat > "$fixture/bin/plutil" <<'PLIST'
#!/bin/zsh
cat "${@: -1}"
PLIST
chmod +x "$fixture/bin/mas" "$fixture/bin/mdfind" "$fixture/bin/plutil"
export MACUP_USER_PATH="$fixture/bin:$PATH"
pass=0; fail=0
ok() { print "ok   $1"; (( pass++ )); return 0 }
bad() { print -r -- "FAIL $1: $2"; (( fail++ )); return 0 }
out=$(zsh "$S/macup-scan.sh" mas 2>/dev/null)
[[ "$out" == *$'M\tmas\tok'* && "$out" != *$'P\tmas\t'* ]] \
  && ok "an old duplicate does not reoffer the version already installed in the current copy" \
  || bad duplicate "$out"
out=$(MAS_LATEST=26.45.0 MAS_DUPLICATE_ROWS=1 zsh "$S/macup-scan.sh" mas 2>/dev/null)
rows=$(print -r -- "$out" | awk -F'\t' '$1=="P" && $2=="mas" {n++} END {print n+0}')
[[ "$rows" == 1 && "$out" == *$'P\tmas\tWhatsApp\t26.44.74\t26.45.0\tapp\t310633997'* ]] \
  && ok "a genuine newer release is offered once, using the actual installed version" || bad newer "$out"
rm -rf "$fixture/WhatsApp.localized"
out=$(zsh "$S/macup-scan.sh" mas 2>/dev/null)
[[ "$out" != *$'P\tmas\t'* ]] \
  && ok "stale Spotlight metadata alone cannot reoffer the installed version" || bad stale "$out"
print 26.46.0 > "$fixture/WhatsApp.app/Contents/Info.plist"
out=$(zsh "$S/macup-scan.sh" mas 2>/dev/null)
[[ "$out" != *$'P\tmas\t'* ]] && ok "a newer installed build is never offered a downgrade" || bad downgrade "$out"
out=$(MAS_NO_PATHS=1 zsh "$S/macup-scan.sh" mas 2>/dev/null)
[[ "$out" == *$'P\tmas\tWhatsApp\t26.40.77\t26.44.74'* ]] \
  && ok "unavailable bundle paths preserve the manager's update report" || bad fallback "$out"
print "App Store reconciliation: $pass passed, $fail failed"
(( fail == 0 ))
