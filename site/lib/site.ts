/// Prefixes a public asset with the Pages base path ("/macup" on github.io, empty on a custom domain).
export function asset(path: string) {
  return `${process.env.NEXT_PUBLIC_BASE_PATH ?? ""}${path}`;
}

export const site = {
  name: "MacUp",
  tagline: "Keep your command-line tools up to date, from the menu bar.",
  repo: "patriciobcs/macup",
  get github() {
    return `https://github.com/${this.repo}`;
  },
  // GitHub resolves this to the asset of the newest release, so the link never goes stale.
  get download() {
    return `https://github.com/${this.repo}/releases/latest/download/MacUp.dmg`;
  },
  get releases() {
    return `https://github.com/${this.repo}/releases`;
  },
  get issues() {
    return `https://github.com/${this.repo}/issues`;
  },
  get license() {
    return `https://github.com/${this.repo}/blob/main/LICENSE`;
  },
  managers: [
    "Homebrew",
    "npm",
    "Bun",
    "pnpm",
    "pip",
    "pipx",
    "uv",
    "Conda",
    "rustup",
    "Cargo",
    "Go",
    "RubyGems",
    "Composer",
    "Nix",
    "mise",
    "MacPorts",
    "Mac App Store",
    "macOS updates",
    "Self-installed tools",
  ],
};
