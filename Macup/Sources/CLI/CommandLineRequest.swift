import Foundation

/// What was asked for on the command line. Parsing is kept apart from running so every spelling a
/// person might type can be checked without starting a scan.
struct CommandLineRequest: Equatable {
    enum Command: String, CaseIterable {
        case status, check, inventory, upgrade, remove, ignore, unignore, help, version
    }

    var command: Command
    var managers: [Manager] = []
    /// Package names or ids, for ignore and unignore.
    var names: [String] = []
    /// Include updates still waiting out the minimum age.
    var now = false
    var dryRun = false
    var json = false
    var skipAdmin = false
    var installationIDs: [String] = []

    enum Parsed: Equatable {
        /// Not a command-line run at all: launch the menu bar app.
        case app
        case run(CommandLineRequest)
        case invalid(String)
    }

    /// The name the tool is linked as. Run under it, MacUp is always the command line, even with
    /// nothing after it; run as the app's own executable, it is only when a command follows.
    static let toolName = "macup"

    private static let aliases: [String: Command] = [
        "status": .status, "list": .status, "ls": .status, "check": .check, "scan": .check,
        "upgrade": .upgrade, "update": .upgrade, "ignore": .ignore, "unignore": .unignore,
        "inventory": .inventory, "installations": .inventory, "remove": .remove,
        "help": .help, "version": .version,
    ]

    static func parse(_ argv: [String]) -> Parsed {
        let asTool = URL(fileURLWithPath: argv.first ?? "").lastPathComponent == toolName
        var args = Array(argv.dropFirst())
        guard let first = args.first else { return asTool ? .run(.init(command: .status)) : .app }

        var request: CommandLineRequest
        if let command = command(for: first) {
            request = .init(command: command)
            args.removeFirst()
        } else if first.hasPrefix("-") {
            // Launch Services and Xcode pass flags of their own (-NSDocumentRevisionsDebugMode YES):
            // only the tool's own name turns a bare flag into a command-line run.
            guard asTool else { return .app }
            request = .init(command: .status)
        } else {
            return asTool || isToolWord(first) ? .invalid("Unknown command “\(first)”.") : .app
        }

        let selectors = installationOptions(args, command: request.command)
        if let error = selectors.error { return .invalid(error) }
        request.installationIDs = selectors.ids
        for arg in selectors.remaining {
            switch arg {
            case "--now": request.now = true
            case "--dry-run", "-n": request.dryRun = true
            case "--json": request.json = true
            case "--skip-admin": request.skipAdmin = true
            case "--help", "-h": return .run(.init(command: .help))
            default:
                if arg.hasPrefix("-") { return .invalid("Unknown option “\(arg)”.") }
                switch request.command {
                case .ignore, .unignore, .remove: request.names.append(arg)
                case .status, .check, .inventory, .upgrade:
                    guard let manager = Manager.named(arg) else {
                        return .invalid(
                            "Unknown package manager “\(arg)”. Known: "
                                + Manager.allCases.map(\.rawValue).joined(separator: ", ") + ".")
                    }
                    if !request.managers.contains(manager) { request.managers.append(manager) }
                case .help, .version: return .invalid("“\(request.command.rawValue)” takes no arguments.")
                }
            }
        }
        if [.ignore, .unignore].contains(request.command), request.names.isEmpty {
            return .invalid("Say which package, e.g. macup \(request.command.rawValue) npm:left-pad")
        }
        if request.command == .remove && request.names.isEmpty && request.installationIDs.isEmpty {
            return .invalid("Say which installation to remove; use macup inventory --json to find its id.")
        }
        // Update All's order, whatever order they were typed in: rustup before cargo, npm's own last.
        request.managers.sort { Manager.allCases.firstIndex(of: $0)! < Manager.allCases.firstIndex(of: $1)! }
        return .run(request)
    }

    /// "upgrade", "--upgrade", "-h": a command, with or without the dashes people reach for.
    private static func installationOptions(
        _ args: [String], command: Command
    ) -> (ids: [String], remaining: [String], error: String?) {
        var ids: [String] = []
        var remaining: [String] = []
        for arg in args {
            if arg.hasPrefix("--installation=") {
                let id = String(arg.dropFirst("--installation=".count))
                guard [.upgrade, .remove].contains(command), !id.isEmpty else {
                    return ([], [], "Use --installation=<id> with upgrade or remove.")
                }
                ids.append(id)
            } else {
                remaining.append(arg)
            }
        }
        return (ids, remaining, nil)
    }

    private static func command(for word: String) -> Command? {
        switch word {
        case "-h", "--help": return .help
        case "-v", "--version": return .version
        default:
            let bare = word.hasPrefix("--") ? String(word.dropFirst(2)) : word
            return aliases[bare]
        }
    }

    /// A word that looks like an attempt at a command, so it is answered rather than opening the app.
    private static func isToolWord(_ word: String) -> Bool { Manager.named(word) != nil }

    static let usage = """
        Usage: macup [command] [package managers…] [options]

        Commands:
          status            What is ready to update and what is still waiting (the default)
          check             Check for updates now, then show the status
          inventory         Installed apps, runtimes and tools, with their paths and owners
          upgrade           Update what is ready, like Update All in the menu bar
          remove <id>       Remove one installation using its recorded package manager
          ignore <package>  Stop offering a package, e.g. macup ignore npm:left-pad
          unignore <package>
          version           Print MacUp's version
          help              Show this help

        Name package managers to narrow a command: macup upgrade npm cargo

        Options:
          --now             With upgrade: include updates still waiting out the minimum age
          -n, --dry-run     With upgrade or remove: print what would run, change nothing
          --skip-admin      With upgrade: leave anything that needs an administrator password
                            (always the case when not run from a terminal, e.g. cron)
          --json            With status, check or inventory: machine-readable output
          --installation=<id>
                            With upgrade or remove: select the exact copy from inventory --json

        Settings, ignored packages and history are the ones the menu bar app uses.
        """
}

extension Manager {
    /// A manager as a person might type it: "npm", "brew", "Homebrew", "rubygems", "app-store".
    static func named(_ word: String) -> Manager? {
        let key = word.lowercased().filter { $0.isLetter || $0.isNumber }
        return allCases.first { $0.rawValue == key }
            ?? allCases.first { $0.title.lowercased().filter { $0.isLetter || $0.isNumber } == key }
            ?? ["homebrew": .brew, "macports": .port, "appstore": .mas, "rust": .rustup, "ruby": .gem][key]
    }
}
