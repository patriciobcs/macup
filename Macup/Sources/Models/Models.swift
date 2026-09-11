import Foundation

/// A package manager Macup knows how to scan and upgrade.
enum Manager: String, CaseIterable, Codable, Identifiable, Hashable {
    // Order is display and "Update all" order: rustup runs before cargo so crates needing a newer rustc can build.
    case macos, brew, port, npm, bun, pnpm, pip, pipx, uv, conda, rustup, cargo, go, gem, composer, nix, mise, tools,
        mas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brew: "Homebrew"
        case .npm: "npm"
        case .bun: "Bun"
        case .pnpm: "pnpm"
        case .pip: "pip"
        case .uv: "uv"
        case .cargo: "Cargo"
        case .rustup: "Rust toolchain"
        case .gem: "RubyGems"
        case .mas: "App Store (mas)"
        case .macos: "macOS"
        case .port: "MacPorts"
        case .pipx: "pipx"
        case .conda: "Conda"
        case .go: "Go"
        case .composer: "Composer"
        case .nix: "Nix"
        case .mise: "mise"
        case .tools: "Self-installed tools"
        }
    }

    var symbol: String {
        switch self {
        case .brew: "mug"
        case .npm, .bun, .pnpm: "cube"
        case .pip, .uv: "cube.transparent"
        case .cargo, .rustup: "gearshape.2"
        case .gem: "diamond"
        case .mas: "bag"
        case .macos: "apple.logo"
        case .port: "shippingbox"
        case .pipx: "cube.transparent"
        case .conda: "circle.hexagongrid"
        case .go: "chevron.left.forwardslash.chevron.right"
        case .composer: "shippingbox.circle"
        case .nix: "snowflake"
        case .mise: "square.stack.3d.up"
        case .tools: "wrench.and.screwdriver"
        }
    }

    /// Managers whose "update" is a hand-off (System Settings) rather than a command; excluded from Update All.
    var opensExternally: Bool { self == .macos }

    /// Managers whose packages MacUp can uninstall. Toolchains, OS updates, self-installed tools and the
    /// conda base environment are left alone.
    var supportsRemoval: Bool { ![.rustup, .mas, .macos, .tools, .mise, .conda].contains(self) }

    /// OSV.dev ecosystem name used for vulnerability lookups, when the manager maps to one.
    var osvEcosystem: String? {
        switch self {
        case .npm, .bun, .pnpm: "npm"
        case .pip, .uv, .pipx: "PyPI"
        case .cargo: "crates.io"
        case .gem: "RubyGems"
        case .go: "Go"
        case .composer: "Packagist"
        case .brew, .rustup, .mas, .macos, .port, .conda, .nix, .mise, .tools: nil
        }
    }
}

enum ManagerStatus: String, Codable, Equatable {
    case ok, missing, error, skipped
}

struct ManagerReport: Identifiable, Equatable, Codable {
    let manager: Manager
    var status: ManagerStatus
    var message: String
    var id: Manager { manager }
    /// Changing packages needs an administrator password (system Ruby gems in /Library).
    var needsAdmin: Bool { status == .ok && message == "admin" }
}

/// How the release date of a package version was determined.
enum DateSource: String, Codable, Equatable {
    /// The registry (npm, PyPI, crates.io, RubyGems) or the scanner itself reported the publish date.
    case registry
    /// Homebrew formula/cask bump commit date on GitHub.
    case homebrew
    /// No authoritative date: we count from the moment Macup first saw this version.
    case firstSeen
}

struct OutdatedPackage: Identifiable, Equatable, Codable, Hashable {
    let manager: Manager
    let name: String
    var installed: String
    /// "?" from the scanner means the app must resolve it from a registry.
    var latest: String
    var kind: String
    var extra: String
    var releaseDate: Date?
    var dateSource: DateSource = .firstSeen
    var advisories: [String] = []
    /// When the installed version landed on this Mac. Exact for Homebrew (install receipt); the install
    /// folder or binary modification time for everything else.
    var updatedAt: Date?

    var id: String { "\(manager.rawValue):\(name)" }
    var versionKey: String { "\(id)@\(latest)" }
    /// Lives in a location owned by macOS (system Ruby, Xcode's Python, a root-owned npm prefix).
    var isSystem: Bool { kind.hasPrefix("system-") }
    /// Kind without the "system-" marker, e.g. "cask", "gem".
    var baseKind: String { isSystem ? String(kind.dropFirst("system-".count)) : kind }
    var isSecurity: Bool { !advisories.isEmpty }
    var needsLatest: Bool { latest == "?" }

    /// The identifier passed to the upgrade script: mas uses App Store ids and Go uses the main package's
    /// import path, both carried in `extra`.
    var upgradeArgument: String {
        switch manager {
        case .mas: extra
        case .go: extra.split(separator: "|").last.map(String.init) ?? name
        default: name
        }
    }
    /// Go module path (before "|" in `extra`).
    var goModule: String? { manager == .go ? extra.split(separator: "|").first.map(String.init) : nil }
}

struct ScanResult: Equatable {
    var reports: [ManagerReport] = []
    var packages: [OutdatedPackage] = []
}
