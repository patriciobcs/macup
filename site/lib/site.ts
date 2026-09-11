/// Prefixes a public asset with the Pages base path ("/macup" on github.io, empty on a custom domain).
export function asset(path: string) {
  return `${process.env.NEXT_PUBLIC_BASE_PATH ?? ""}${path}`;
}

export const site = {
  name: "MacUp",
  tagline: "Keep your command-line tools up to date, from the menu bar.",
  /// The <title>, which is the strongest on-page ranking signal. Short enough not to be truncated in
  /// a result (~60 characters with the name), and worded the way someone searches for the problem
  /// rather than for the app, which nobody knows to look for yet.
  headline: "Update Every Package Manager on Your Mac",
  /// The search result's second line. Google truncates around 155 characters, so this stays under it
  /// and leads with the words someone would type: macOS, the manager names, outdated.
  description:
    "Free macOS menu bar app that finds every package manager on your Mac — Homebrew, npm, pip, Cargo and 15 more — and updates what is outdated in one click.",
  repo: "patriciobcs/macup",
  author: { handle: "@patriciobcs", url: "https://patriciobcs.com" },
  /// Canonical origin. Search engines and Open Graph need absolute URLs, and the CNAME in public/
  /// points GitHub Pages at this domain.
  url: "https://macup.patriciobcs.com",
  /// Shown when the page is shared; a real screenshot of the app rather than a logo.
  ogImage: "/screenshots/readme.png",
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
