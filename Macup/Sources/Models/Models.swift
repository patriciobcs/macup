import Foundation

/// A package manager Macup knows how to scan and upgrade.
enum Manager: String, CaseIterable, Codable, Identifiable, Hashable {
    // Order is display and "Update all" order: rustup runs before cargo so crates needing a newer rustc can build.
    case macos, brew, port, npm, bun, pnpm, pip, pipx, uv, conda, rustup, cargo, go, gem, composer, nix, mise,
        gcloud, tailscale, tools, mas, orbstack, apps, runtimes, extensions, dotnet, dart, nixprofile, asdf, volta

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
        case .gcloud: "Google Cloud CLI"
        case .tailscale: "Tailscale"
        case .orbstack: "OrbStack"
        case .apps: "Desktop apps"
        case .runtimes: "Language runtimes"
        case .extensions: "GitHub extensions"
        case .dotnet: ".NET tools"
        case .dart: "Dart global tools"
        case .nixprofile: "Nix profiles"
        case .asdf: "asdf runtimes"
        case .volta: "Volta runtimes"
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
        case .gcloud: "cloud"
        case .tailscale: "network"
        case .orbstack: "shippingbox"
        case .apps: "app.dashed"
        case .runtimes, .asdf, .volta: "terminal"
        case .extensions: "puzzlepiece.extension"
        case .dotnet, .dart, .nixprofile: "cube"
        }
    }

    /// Managers whose update opens another updater; excluded from Update All.
    var opensExternally: Bool { self == .macos || self == .tailscale }

    var updateButtonTitle: String {
        switch self {
        case .macos: "Open Settings"
        case .tailscale: "Open Updater"
        default: "Update"
        }
    }

    var externalUpdateHelp: String {
        self == .tailscale ? "Open the Tailscale updater" : "Open Software Update in System Settings"
    }

    /// Managers whose packages MacUp can uninstall. Toolchains, OS updates, self-installed tools and the
    /// conda base environment are left alone.
    var supportsRemoval: Bool {
        ![
            .rustup, .mas, .macos, .tools, .mise, .conda, .gcloud, .tailscale, .apps, .runtimes, .asdf, .volta,
            .orbstack,
        ].contains(self)
    }

    /// These adapters use structured output and installation-scoped actions in the native backend.
    var usesInstallationBackend: Bool {
        [.orbstack, .apps, .runtimes, .extensions, .dotnet, .dart, .nixprofile, .asdf, .volta].contains(self)
    }

    /// OSV.dev ecosystem name used for vulnerability lookups, when the manager maps to one.
    var osvEcosystem: String? {
        switch self {
        case .npm, .bun, .pnpm: "npm"
        case .pip, .uv, .pipx: "PyPI"
        case .cargo: "crates.io"
        case .gem: "RubyGems"
        case .go: "Go"
        case .composer: "Packagist"
        case .dotnet: "NuGet"
        case .dart: "Pub"
        case .brew, .rustup, .mas, .macos, .port, .conda, .nix, .mise, .tools, .gcloud, .tailscale,
            .orbstack, .apps, .runtimes, .extensions, .nixprofile, .asdf, .volta:
            nil
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
    /// The manager's own version, when it is installed. Reported so a bug report says which one it is.
    var version: String = ""
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
    /// Absent in old state files and legacy scanners. Default installations retain their old ids.
    var installation: InstallationReference?

    /// Homebrew can have a formula and a cask with the same name, so brew ids carry the kind.
    var id: String {
        guard let installation else { return legacyID }
        return "\(legacyID)@installation=\(installation.key)"
    }
    var legacyID: String { manager == .brew ? "brew:\(baseKind):\(name)" : "\(manager.rawValue):\(name)" }
    var versionKey: String { "\(id)@\(installation?.release ?? latest)" }
    /// Lives in a location owned by macOS (system Ruby, Xcode's Python, a root-owned npm prefix).
    var isSystem: Bool { kind.hasPrefix("system-") }
    /// Kind without the "system-" marker, e.g. "cask", "gem".
    var baseKind: String { isSystem ? String(kind.dropFirst("system-".count)) : kind }
    /// A Homebrew cask whose upgrade runs part of itself through sudo (an installer package, a system
    /// launch service or file to remove). sudo only asks for a password in a terminal, so the scan marks
    /// these with "admin" in `extra`.
    var needsAdmin: Bool { manager == .brew && extra == "admin" }
    var isSecurity: Bool { !advisories.isEmpty }
    var needsLatest: Bool { latest == "?" }

    /// The identifier passed to the upgrade script: mas uses App Store ids and Go uses the main package's
    /// import path, both carried in `extra`.
    var upgradeArgument: String {
        switch manager {
        case .mas: extra
        case .go: extra.split(separator: "|").last.map(String.init) ?? name
        case .brew: "\(baseKind):\(name)"
        default: name
        }
    }
    /// Go module path (before "|" in `extra`).
    var goModule: String? { manager == .go ? extra.split(separator: "|").first.map(String.init) : nil }
}

/// One self-installed tool and whether it is on this Mac. These are the tools nothing else updates
/// (uv, bun, deno, pnpm, mise), so MacUp lists the ones it found and folds the rest away.
struct ToolReport: Equatable, Identifiable, Codable {
    enum Presence: String, Codable { case found, managed, missing }
    var name: String
    var presence: Presence
    /// The version for a tool that is here, or who looks after it when another manager does.
    var detail: String
    var id: String { name }

    var statusText: String {
        switch presence {
        case .found: detail.isEmpty ? "Found" : "Found · \(detail)"
        case .managed: "Updated by \(detail)"
        case .missing: "not installed"
        }
    }
}

struct ScanResult: Equatable {
    var reports: [ManagerReport] = []
    var packages: [OutdatedPackage] = []
    var tools: [ToolReport] = []
    var installations: [InstalledItem] = []
}

/// What MacUp is doing at this moment, in one line.
///
/// Kept apart from the store so every case can be checked without arranging for real work to be in
/// flight: a tool installing, a whole manager running, one package, several at once, or nothing but a
/// scan.
enum Activity {
    static func title(packages: [String], installing: Set<Manager>, managers: [Manager]) -> String {
        if let id = packages.min() {
            // Package ids are "manager:name"; a name may itself contain a colon (a Go import path).
            let name = id.components(separatedBy: "@installation=")[0]
                .split(separator: ":").dropFirst().joined(separator: ":")
            return packages.count > 1 ? "Updating \(name) and \(packages.count - 1) more" : "Updating \(name)"
        }
        if let manager = installing.min(by: { $0.rawValue < $1.rawValue }) {
            return "Installing \(manager.title)"
        }
        if let manager = managers.min(by: { $0.rawValue < $1.rawValue }) {
            return "Updating \(manager.title)"
        }
        return "Checking for updates"
    }
}
