#!/bin/zsh
# Reproduce Homebrew's writable GEM_HOME with read-only Cellar-owned gemspecs and plugin links.
set -uo pipefail
cd "$(dirname "$0")/../.."
S="$PWD/Macup/Resources/Scripts"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/macup-gem.XXXXXX")
trap 'chmod u+w "$fixture/home" 2>/dev/null; rm -rf "$fixture"' EXIT INT TERM
export GEM_FIXTURE="$fixture"
mkdir -p "$fixture/bin" "$fixture/home/specifications" "$fixture/home/plugins" \
  "$fixture/user/specifications" "$fixture/user/plugins" "$fixture/Cellar/ruby/4.0.9/specifications" \
  "$fixture/Cellar/ruby/4.0.9/plugins"
touch "$fixture/Cellar/ruby/4.0.9/specifications/rdoc-7.0.4.gemspec" \
  "$fixture/Cellar/ruby/4.0.9/plugins/rdoc_plugin.rb" "$fixture/home/specifications/rake-13.0.0.gemspec"
chmod 444 "$fixture/Cellar/ruby/4.0.9/plugins/rdoc_plugin.rb"
ln -s "$fixture/Cellar/ruby/4.0.9/specifications/rdoc-7.0.4.gemspec" "$fixture/home/specifications/rdoc-7.0.4.gemspec"
ln -s "$fixture/Cellar/ruby/4.0.9/plugins/rdoc_plugin.rb" "$fixture/home/plugins/rdoc_plugin.rb"
cat > "$fixture/bin/gem" <<'GEM'
#!/bin/zsh
case "$1" in
  --version) print 4.0.3 ;;
  environment)
    case "$2" in
      gemdir) print "$GEM_FIXTURE/home" ;;
      user_gemhome) print "$GEM_FIXTURE/user" ;;
      gempath) print "$GEM_FIXTURE/user:$GEM_FIXTURE/home" ;;
    esac ;;
  specification)
    base="$GEM_FIXTURE/home"
    [[ "${GEM_USER_COPY:-0}" == 1 && "$2" == rdoc ]] && base="$GEM_FIXTURE/user"
    [[ "$2" == rdoc ]] && version=7.0.4 || version=13.0.0
    print -r -- "--- \"$base/specifications/$2-$version.gemspec\"" ;;
  outdated) print 'rdoc (7.0.4 < 8.1.0)'; print 'rake (13.0.0 < 13.4.0)' ;;
  update|uninstall) print -r -- "$*" >> "$GEM_FIXTURE/calls" ;;
esac
GEM
cat > "$fixture/bin/osascript" <<'ADMIN'
#!/bin/zsh
print called > "$GEM_FIXTURE/admin-called"
exit 99
ADMIN
chmod +x "$fixture/bin/gem" "$fixture/bin/osascript"
export MACUP_USER_PATH="$fixture/bin:$PATH"
pass=0; fail=0
ok() { print "ok   $1"; (( pass++ )); return 0 }
bad() { print -r -- "FAIL $1: $2"; (( fail++ )); return 0 }

out=$(zsh "$S/macup-scan.sh" gem)
[[ "$out" == *$'P\tgem\trake\t'* && "$out" != *$'P\tgem\trdoc\t'* ]] \
  && ok "scanner leaves bundled rdoc with Homebrew and still offers independently installed gems" \
  || bad scan "$out"
out=$(zsh "$S/macup-upgrade.sh" gem rdoc 2>&1); rc=$?
[[ $rc == 1 && "$out" == *"Homebrew manages rdoc"* && ! -e "$fixture/calls" ]] \
  && ok "a direct update refuses bundled rdoc before calling RubyGems" || bad update "$out"
out=$(zsh "$S/macup-remove.sh" gem rdoc 2>&1); rc=$?
[[ $rc == 1 && "$out" == *"Homebrew manages rdoc"* && ! -e "$fixture/calls" ]] \
  && ok "bundled rdoc cannot be uninstalled through RubyGems" || bad removal "$out"
out=$(zsh "$S/macup-upgrade.sh" gem 2>&1); rc=$?
calls=$(cat "$fixture/calls" 2>/dev/null)
[[ "$out" == *"Homebrew manages rdoc"* && "$calls" == 'update rake' ]] \
  && ok "update all skips the owned gem and continues with independent gems" || bad batch "$out; calls: $calls"

# A separate user-installed copy with the same name and version must remain independently updatable.
touch "$fixture/user/specifications/rdoc-7.0.4.gemspec"
out=$(GEM_USER_COPY=1 zsh "$S/macup-scan.sh" gem)
[[ "$out" == *$'P\tgem\trdoc\t7.0.4\t8.1.0'* ]] \
  && ok "a user-installed copy of rdoc is still offered" || bad user-scan "$out"
out=$(GEM_USER_COPY=1 zsh "$S/macup-upgrade.sh" gem rdoc 2>&1); rc=$?
[[ $rc == 0 && "$out" == *'gem update --user-install rdoc'* ]] \
  && ok "user-installed rdoc stays in the user gem home" || bad user-update "$out"
out=$(GEM_USER_COPY=1 zsh "$S/macup-remove.sh" gem rdoc 2>&1); rc=$?
[[ $rc == 0 && "$out" == *'--install-dir'*"$fixture/user"* ]] \
  && ok "removing the user copy leaves the bundled gem alone" || bad user-remove "$out"

# The writable spec may be independent, but its destination plugin still belongs to Homebrew.
rm "$fixture/home/specifications/rdoc-7.0.4.gemspec"
touch "$fixture/home/specifications/rdoc-7.0.4.gemspec"
out=$(zsh "$S/macup-upgrade.sh" gem rdoc 2>&1); rc=$?
[[ $rc == 1 && "$out" == *"Homebrew manages rdoc"* ]] \
  && ok "the plugin link itself is protected even with an independent gemspec" || bad plugin "$out"
chmod 555 "$fixture/home"
out=$(zsh "$S/macup-upgrade.sh" gem rake 2>&1); rc=$?
[[ $rc == 1 && "$out" == *"is not writable"* && ! -e "$fixture/admin-called" ]] \
  && ok "an unwritable non-system Ruby never switches to Apple's Ruby or elevates" || bad permissions "$out"
chmod 755 "$fixture/home"
[[ ! -e "$fixture/admin-called" && -L "$fixture/home/plugins/rdoc_plugin.rb" ]] \
  && ok "no administrator command or plugin replacement was attempted" || bad side-effects "$out"
print "gem ownership: $pass passed, $fail failed"
(( fail == 0 ))
