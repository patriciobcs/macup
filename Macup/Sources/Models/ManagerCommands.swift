import Foundation

/// What MacUp runs for a manager, and what the user has put in its place.
///
/// The defaults are read from the scripts themselves (`macup-scan.sh --commands`) rather than written
/// out a second time here, so what the app shows is what actually runs. A replacement travels back to
/// the scripts in the environment as `MACUP_CMD_<phase>_<manager>`.
enum CommandPhase: String, CaseIterable, Codable, Identifiable, Hashable {
    case check
    case update
    case updateAll = "update_all"
    case remove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .check: "Check for updates"
        case .update: "Update a package"
        case .updateAll: "Update everything"
        case .remove: "Remove a package"
        }
    }

    /// What the command's output is used for, which is what limits how far it can be changed.
    var note: String? {
        switch self {
        case .check:
            "MacUp reads this command's output to find packages, so a replacement has to print what the "
                + "manager's own command prints. Use Test to check it is still understood."
        default: nil
        }
    }
}

extension Manager {
    /// Managers whose commands can end up running with administrator privileges. What runs as root is
    /// never taken from a setting — only a root-owned executable the script names itself is elevated —
    /// so their commands are shown but cannot be replaced.
    var runsElevated: Bool { self == .port || self == .gem }

    /// Why this manager's commands cannot be edited, for the UI to show instead of an editor.
    var notEditableReason: String? {
        guard runsElevated else { return nil }
        return "\(title) asks for an administrator password to change anything, and MacUp will not run a "
            + "command as root that came from a setting — only the program it names itself. You can see "
            + "exactly what it runs, but not replace it."
    }

    /// Why a phase has no one command, so the app can say so rather than leave a gap where an editor
    /// would be. Returns nil when there is a command, which is the ordinary case.
    func noCommandReason(_ phase: CommandPhase) -> String? {
        switch phase {
        case .check:
            switch self {
            case .go:
                return "Go has no command that lists outdated programs. MacUp reads the module recorded "
                    + "inside each binary in GOBIN and asks the module proxy what is newer."
            case .tools:
                return "These tools share no command. MacUp asks each one its version, and GitHub for its "
                    + "latest release."
            default: return nil
            }
        case .update:
            return self == .tools
                ? "Each tool updates itself its own way, with its installer as a fallback, so there is no "
                    + "one command to show."
                : nil
        case .updateAll:
            return "MacUp updates \(title) one package at a time, so there is no all-at-once command."
        case .remove:
            return supportsRemoval
                ? nil
                : "MacUp does not uninstall these. A toolchain, an App Store app or a tool that manages "
                    + "itself is left to the thing that installed it."
        }
    }
}

/// One manager's commands: the defaults read from the scripts, and any replacements.
struct ManagerCommands: Equatable {
    /// Defaults by phase, as the scripts define them.
    var defaults: [CommandPhase: String] = [:]

    /// The phases this manager actually has a single command for. Checking for Go updates reads every
    /// binary in GOBIN, and self-installed tools ask GitHub per tool: those are procedures, not one
    /// command, and are left out rather than shown as something that could be edited.
    var phases: [CommandPhase] { CommandPhase.allCases.filter { defaults[$0] != nil } }
}

/// The command table for every manager, as the scripts define it.
struct CommandBook: Equatable {
    private(set) var byManager: [Manager: ManagerCommands] = [:]

    subscript(manager: Manager) -> ManagerCommands { byManager[manager] ?? ManagerCommands() }

    /// Parses `phase<TAB>manager<TAB>command` lines. Unknown managers (rustup_self, which is rustup's
    /// own update rather than a manager) are skipped.
    init(commandLines: String) {
        for line in commandLines.split(separator: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3, let phase = CommandPhase(rawValue: parts[0]),
                let manager = Manager(rawValue: parts[1]), !parts[2].isEmpty
            else { continue }
            byManager[manager, default: ManagerCommands()].defaults[phase] = parts[2]
        }
    }

    init() {}

    /// How a replacement is filed in preferences, e.g. "check_npm".
    static func storeKey(_ phase: CommandPhase, _ manager: Manager) -> String {
        "\(phase.rawValue)_\(manager.rawValue)"
    }

    /// The environment key a replacement travels in, matching what the scripts look up.
    static func key(_ phase: CommandPhase, _ manager: Manager) -> String {
        "MACUP_CMD_" + storeKey(phase, manager)
    }
}

/// What comes back from trying a check command out.
enum CommandTest {
    /// The verdict on a test run, kept out of the view so it can be checked without drawing anything.
    ///
    /// The awkward case is the middle one: the command ran, exited cleanly, and nothing was understood.
    /// That is either an up-to-date machine or a command printing something MacUp cannot read, and from
    /// here the two look identical — so it says both rather than picking one and being wrong.
    static func message(for scan: ScanResult, manager: Manager) -> String {
        if let report = scan.reports.first(where: { $0.manager == manager }), report.status == .error {
            return "✗ \(report.message)"
        }
        if scan.packages.isEmpty {
            return "✓ ran, but nothing was understood. Either there is nothing to update, or the output "
                + "is not in the shape MacUp reads."
        }
        let count = scan.packages.count
        return "✓ understood \(count) package\(count == 1 ? "" : "s")"
    }
}

/// The {placeholders} in a command, and what each stands for.
///
/// They are filled in when the command runs — a name always shell-quoted, so that a package called
/// "evil; rm -rf ~" stays one argument. Someone reading a command in Settings needs to know what they
/// are, and someone editing one needs to keep them.
enum CommandPlaceholder {
    static let meanings: [(name: String, meaning: String)] = [
        ("name", "one package"),
        ("names", "every package being updated"),
        ("python", "the python the scan settled on"),
        ("greedy", "--greedy, when that preference is on"),
        ("kind", "--cask or --formula"),
        ("user", "--user, for a package pip put in the user site"),
        ("gobin", "where go install puts programs"),
    ]

    /// Only the ones these commands actually use, in a fixed order so the line does not reshuffle.
    static func used(in commands: [String]) -> [(name: String, meaning: String)] {
        meanings.filter { placeholder in commands.contains { $0.contains("{\(placeholder.name)}") } }
    }
}
