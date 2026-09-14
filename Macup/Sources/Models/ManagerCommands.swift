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
        runsElevated
            ? "These can run with an administrator password, and MacUp never elevates a command that came "
                + "from a setting."
            : nil
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
