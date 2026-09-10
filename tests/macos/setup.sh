#!/bin/zsh
# Prepares a macOS GitHub Actions runner so every scanner has something real to find:
# installs the managers the image lacks and pins packages to old versions.
set -eux
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

# Tools the runner image may lack (the arm64 images ship without Go, pipx or Rust on the PATH).
brew install jq mas ruby
command -v go >/dev/null || brew install go
command -v pipx >/dev/null || brew install pipx
command -v cargo >/dev/null || { brew install rustup; "$(brew --prefix)/opt/rustup/bin/rustup-init" -y --profile minimal; }
export PATH="$HOME/.cargo/bin:$(brew --prefix)/opt/rustup/bin:$PATH"
command -v python3 >/dev/null || brew install python

# Homebrew: install current formula/cask, then rename the installed version so brew sees it as outdated.
jq_ver=$(ls "$(brew --cellar)/jq" | head -n1)
mv "$(brew --cellar)/jq/$jq_ver" "$(brew --cellar)/jq/1.6"
brew unlink jq && brew link --overwrite jq
brew install --cask hiddenbar || true
if [[ -d "$(brew --prefix)/Caskroom/hiddenbar" ]]; then
  hb_ver=$(ls "$(brew --prefix)/Caskroom/hiddenbar" | grep -v '^\.' | head -n1)
  mv "$(brew --prefix)/Caskroom/hiddenbar/$hb_ver" "$(brew --prefix)/Caskroom/hiddenbar/1.0"
fi

# Node ecosystem.
npm install -g typescript@5.0.4 prettier@3.0.0
curl -fsSL https://bun.sh/install | bash -s "bun-v1.2.20"
~/.bun/bin/bun add -g cowsay@1.5.0
curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=9.15.0 SHELL=/bin/zsh ENV="$HOME/.zshrc" sh -
export PNPM_HOME="$HOME/Library/pnpm"; export PATH="$PNPM_HOME:$PATH"
pnpm add -g is-odd@3.0.0

# Python ecosystem.
python3 -m pip install --user --break-system-packages "requests==2.28.0" || python3 -m pip install --user "requests==2.28.0"
pipx install black==23.1.0
curl -LsSf https://astral.sh/uv/0.4.0/install.sh | sh
test -x ~/.local/bin/uv || ln -s ~/.cargo/bin/uv ~/.local/bin/uv
~/.local/bin/uv tool install ruff==0.1.0

# Rust and Go.
cargo install --locked --version 4.0.0 shellharden
go install golang.org/x/tools/cmd/goimports@v0.20.0

# Ruby (Homebrew's, so the gem dir is writable and no admin prompt is involved) and PHP.
export PATH="$(brew --prefix)/opt/ruby/bin:$PATH"
gem install colorize:0.8.1 --no-document
command -v composer >/dev/null || brew install composer
composer global require --no-interaction "psr/log:1.1.0"

# Conda.
command -v conda >/dev/null || brew install --cask miniconda

# mise with a version range so `mise outdated` has something to report.
curl -fsSL https://mise.run | sh
~/.local/bin/mise use -g node@22.0.0
sed -i '' 's/node = "22.0.0"/node = "22"/' ~/.config/mise/config.toml

# Deno (self-installed).
curl -fsSL https://deno.land/install.sh | sh -s v1.40.0

# MacPorts: install the pkg for this macOS version; scanning works, nothing is pinned.
if ! command -v port >/dev/null; then
  major=$(sw_vers -productVersion | cut -d. -f1)
  case "$major" in 15) codename=Sequoia ;; 26) codename=Tahoe ;; 14) codename=Sonoma ;; *) codename="" ;; esac
  if [[ -n "$codename" ]]; then
    # Best effort: shared runners often hit GitHub's anonymous API limit, so authenticate when a token is present.
    auth=(); [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    if url=$(curl -fsSL "${auth[@]}" https://api.github.com/repos/macports/macports-base/releases/latest | \
          python3 -c "import json,sys; print(next(a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if a['name'].endswith('-$major-$codename.pkg')))"); then
      curl -fsSL "$url" -o macports.pkg && sudo installer -pkg macports.pkg -target / && rm macports.pkg
      sudo /opt/local/bin/port -N install nano || true
    else
      echo "MacPorts skipped: could not resolve the installer URL"
    fi
  fi
fi
echo "setup done"
