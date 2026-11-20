#!/bin/zsh
# Exercise the real RubyGems installer against the same read-only plugin symlink layout as Homebrew.
# Everything, including the two locally built test gems, stays in the disposable container.
set -euo pipefail
S=/workspace/Macup/Resources/Scripts
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cellar="$work/Cellar/ruby/test/gems"
home="$work/home"
mkdir -p "$work/package/lib" "$home/specifications" "$home/plugins" "$work/user"
cd "$work/package"
print '# fixture plugin' > lib/rubygems_plugin.rb
for version in 1.0.0 2.0.0; do
  cat > fixture.gemspec <<GEMSPEC
Gem::Specification.new do |s|
  s.name = 'macup-plugin-check'
  s.version = '$version'
  s.summary = 'Local MacUp permission regression fixture'
  s.authors = ['MacUp tests']
  s.files = ['lib/rubygems_plugin.rb']
end
GEMSPEC
  gem build fixture.gemspec >/dev/null 2>&1
done
gem install --local --no-document --install-dir "$cellar" macup-plugin-check-1.0.0.gem >/dev/null
ln -s "$cellar/specifications/macup-plugin-check-1.0.0.gemspec" "$home/specifications/macup-plugin-check-1.0.0.gemspec"
ln -s "$cellar/plugins/macup-plugin-check_plugin.rb" "$home/plugins/macup-plugin-check_plugin.rb"
chmod 444 "$cellar/plugins/macup-plugin-check_plugin.rb"
export GEM_HOME="$home" GEM_PATH="$home:$cellar" MACUP_USER_PATH="$PATH"

if gem install --local --no-document macup-plugin-check-2.0.0.gem > "$work/installer.log" 2>&1; then
  echo "FAIL real RubyGems did not reproduce the plugin permission error"; exit 1
fi
grep -q 'FilePermissionError\|Permission denied' "$work/installer.log"
echo "ok   real RubyGems reproduces the read-only Homebrew-style plugin failure"

out=$(MACUP_CMD_check_gem="printf 'macup-plugin-check (1.0.0 < 2.0.0)\\n'" "$S/macup-scan.sh" gem)
[[ "$out" == *$'M\tgem\tok'* && "$out" != *$'P\tgem\tmacup-plugin-check\t'* ]]
echo "ok   MacUp filters the real bundled gem from the update list"
if "$S/macup-upgrade.sh" gem macup-plugin-check > "$work/guard.log" 2>&1; then
  echo "FAIL direct upgrade bypassed the ownership guard"; exit 1
fi
grep -q 'Homebrew manages' "$work/guard.log"
if "$S/macup-remove.sh" gem macup-plugin-check >> "$work/guard.log" 2>&1; then
  echo "FAIL removal bypassed the ownership guard"; exit 1
fi
[[ -L "$home/plugins/macup-plugin-check_plugin.rb" && ! -w "$cellar/plugins/macup-plugin-check_plugin.rb" ]]
echo "ok   direct update and removal leave the original plugin link and permissions intact"
