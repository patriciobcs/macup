# Linux test bench for the MacUp scripts. Installs every package manager that runs on Linux, pins some
# packages to old versions so `outdated` has something to report, and runs the scan + dry-run upgrades.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      zsh curl ca-certificates git build-essential unzip xz-utils bzip2 \
      python3 python3-pip python3-venv pipx ruby-full php-cli php-mbstring php-xml php-curl php-zip \
      golang-go sudo procps && rm -rf /var/lib/apt/lists/*

# Non-root user: mirrors a real Mac, where package dirs belong to the user.
RUN useradd -m -s /bin/zsh dev && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER dev
WORKDIR /home/dev
ENV HOME=/home/dev PATH=/home/dev/.local/bin:/home/dev/.bun/bin:/home/dev/.cargo/bin:/home/dev/go/bin:/home/dev/.config/composer/vendor/bin:/home/dev/.local/share/mise/shims:/home/dev/miniconda3/bin:/usr/local/bin:/usr/bin:/bin

# Node via mise (also gives us the mise scanner), pinned one minor behind so `mise outdated` reports it.
RUN curl -fsSL https://mise.run | sh && ~/.local/bin/mise use -g node@22.0.0 && ~/.local/bin/mise use -g go@1.22.0 \
 && sed -i 's/node = "22.0.0"/node = "22"/' ~/.config/mise/config.toml   # request a range so `mise outdated` has something to say
ENV PATH=/home/dev/.local/share/mise/shims:$PATH

# npm / pnpm / bun with old global packages.
RUN mise exec -- npm install -g typescript@5.0.4 prettier@3.0.0
RUN curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=9.0.0 SHELL=/bin/zsh ENV=/home/dev/.zshrc sh - 2>&1 | tail -3 || true
ENV PNPM_HOME=/home/dev/.local/share/pnpm PATH=/home/dev/.local/share/pnpm:$PATH
RUN pnpm add -g prettier@3.0.0 2>&1 | tail -3 || true
RUN curl -fsSL https://bun.sh/install | bash -s "bun-v1.2.20" && ~/.bun/bin/bun add -g cowsay@1.5.0

# Python: pipx + uv (self-installed) + old tools.
RUN pipx install black==23.1.0
RUN curl -LsSf https://astral.sh/uv/0.4.0/install.sh | sh && (test -x ~/.local/bin/uv || ln -s ~/.cargo/bin/uv ~/.local/bin/uv) && ~/.local/bin/uv tool install ruff==0.1.0
RUN python3 -m pip install --user --break-system-packages "requests==2.28.0"

# Rust: rustup + a tiny old crate.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.80.0 --profile minimal
RUN ~/.cargo/bin/cargo install --locked --version 4.0.0 shellharden 2>&1 | tail -2

# Go binary at an old version (uses the apt Go so the go scanner sees GOPATH/bin).
RUN /usr/bin/go install golang.org/x/tools/cmd/goimports@v0.20.0 2>&1 | tail -3 || true

# Ruby gems (user install) and Composer global package at old versions.
RUN gem install --user-install rake:13.0.0 --no-document
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=$HOME/.local/bin --filename=composer \
 && composer global require --no-interaction "psr/log:1.1.0"

# Miniconda (base env is always somewhat outdated).
RUN curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-py311_24.1.2-0-Linux-$(uname -m | sed 's/arm64/aarch64/').sh -o mc.sh \
 && bash mc.sh -b -p $HOME/miniconda3 && rm mc.sh

# Deno self-installed.
RUN curl -fsSL https://deno.land/install.sh | sh -s v1.40.0 2>&1 | tail -3 || true
ENV PATH=/home/dev/.deno/bin:$PATH

COPY --chown=dev Macup/Resources/Scripts /home/dev/scripts
COPY --chown=dev tests/docker/run-tests.sh /home/dev/run-tests.sh
RUN chmod +x /home/dev/scripts/*.sh /home/dev/run-tests.sh
CMD ["/bin/zsh", "/home/dev/run-tests.sh"]
