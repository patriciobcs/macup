import Foundation

/// What `macup status` shows: the same lists as the menu bar, as text for a person or JSON for a script.
struct CommandLineReport: Encodable, Equatable {
    struct Item: Encodable, Equatable {
        var manager: String
        var name: String
        var installed: String
        var latest: String
        var security: Bool
        /// When the release came out (or MacUp first saw it, when the registry does not say).
        var released: Date?
        /// When a waiting update becomes ready. Absent for one that already is.
        var readyAt: Date?
    }

    struct Problem: Encodable, Equatable {
        var manager: String
        var message: String
    }

    var version: String
    var checkedAt: Date?
    var ready: [Item]
    var waiting: [Item]
    var problems: [Problem]
    var offline: Bool
    /// MacUp's own update, when Homebrew has one.
    var macupUpdate: String?

    @MainActor
    init(store: UpdateStore) {
        let item = { (p: OutdatedPackage, waiting: Bool) -> Item in
            let reference = store.referenceDate(of: p)
            return Item(
                manager: p.manager.rawValue, name: p.name, installed: p.installed, latest: p.latest,
                security: p.isSecurity, released: reference,
                readyAt: waiting ? reference.map { $0.addingTimeInterval(store.settings.threshold(for: p)) } : nil)
        }
        version = store.appVersion
        checkedAt = store.lastScan
        ready = store.eligible.map { item($0, false) }
        waiting = store.waiting.map { item($0, true) }
        problems = store.problems.map { Problem(manager: $0.manager.rawValue, message: $0.message) }
        offline = store.isOffline
        macupUpdate = store.selfCaskUpdate?.latest
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func text(now: Date = Date(), style: TerminalStyle = .plain) -> String {
        var out: [String] = []
        let age = checkedAt.map { now.timeIntervalSince($0) }
        let checked = age.map { $0 < 60 ? "checked just now" : "checked \(DateText.short($0)) ago" } ?? "never checked"
        let headline =
            ready.isEmpty
            ? "Everything is up to date" : "\(ready.count) \(ready.count == 1 ? "update" : "updates") ready"
        out.append(style.bold(headline) + style.dim(" · \(checked)"))

        if !ready.isEmpty {
            out.append("")
            out += table(ready, style: style) { item in
                item.released.map { "\(DateText.short(now.timeIntervalSince($0))) ago" } ?? ""
            }
        }
        if !waiting.isEmpty {
            out.append("")
            out.append(style.bold("Waiting out the minimum age (\(waiting.count))"))
            out += table(waiting, style: style) { item in
                item.readyAt.map { "ready in \(DateText.short($0.timeIntervalSince(now)))" } ?? ""
            }
        }
        if offline {
            out.append("")
            out.append(style.yellow("Offline: some package managers could not reach the network."))
        }
        if !problems.isEmpty {
            out.append("")
            out.append(style.bold("Could not check"))
            for p in problems {
                let title = Manager(rawValue: p.manager)?.title ?? p.manager
                out.append("  " + style.red(title) + "  " + p.message)
            }
        }
        if let macupUpdate {
            out.append("")
            out.append("MacUp \(macupUpdate) is available: brew upgrade --cask macup")
        }
        if !ready.isEmpty {
            out.append("")
            out.append(style.dim("Run `macup upgrade` to update what is ready."))
        } else if !waiting.isEmpty {
            out.append("")
            out.append(style.dim("Run `macup upgrade --now` to update these before the minimum age."))
        }
        return out.joined(separator: "\n")
    }

    /// Grouped by manager in Update All's order, names and versions lined up.
    private func table(_ items: [Item], style: TerminalStyle, note: (Item) -> String) -> [String] {
        let nameWidth = items.map(\.name.count).max() ?? 0
        let versionWidth = items.map { "\($0.installed) → \($0.latest)".count }.max() ?? 0
        var lines: [String] = []
        for manager in Manager.allCases {
            let group = items.filter { $0.manager == manager.rawValue }
            guard !group.isEmpty else { continue }
            lines.append(style.bold(manager.title))
            for item in group {
                let name = item.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                let versions = "\(item.installed) → \(item.latest)"
                    .padding(toLength: versionWidth, withPad: " ", startingAt: 0)
                let security = item.security ? "  " + style.yellow("security fix") : ""
                lines.append("  \(name)  \(versions)  " + style.dim(note(item)) + security)
            }
        }
        return lines
    }
}

/// ANSI styling, only when writing to a terminal that wants it.
struct TerminalStyle: Equatable {
    var enabled: Bool

    static let plain = TerminalStyle(enabled: false)

    static func forStandardOutput() -> TerminalStyle { forOutput(environment: ProcessInfo.processInfo.environment) }

    /// Colour for a terminal, never for a pipe, a file, `NO_COLOR` or `TERM=dumb`.
    static func forOutput(environment: [String: String]) -> TerminalStyle {
        TerminalStyle(
            enabled: isatty(STDOUT_FILENO) == 1 && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb")
    }

    private func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    func bold(_ s: String) -> String { wrap(s, "1") }
    func dim(_ s: String) -> String { s.isEmpty ? s : wrap(s, "2") }
    func red(_ s: String) -> String { wrap(s, "31") }
    func yellow(_ s: String) -> String { wrap(s, "33") }
    func green(_ s: String) -> String { wrap(s, "32") }
}
