import Foundation
import Observation

/// One meaningful thing the user did through MacUp: an upgrade, a removal, an ignore.
struct ActionRecord: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case upgrade, remove, ignore, unignore, install }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var manager: Manager
    var package: String
    /// "1.2.3 → 1.3.0", the error line, etc.
    var detail: String
    var succeeded: Bool
    /// What the command printed. Kept for a week so a failure can still be read afterwards, then
    /// dropped: the record of what happened is worth keeping, pages of build output are not.
    var output: String?

    var title: String {
        switch kind {
        case .upgrade: succeeded ? "Updated \(package)" : "Failed to update \(package)"
        case .remove: succeeded ? "Removed \(package)" : "Failed to remove \(package)"
        case .ignore: "Ignored \(package)"
        case .unignore: "Stopped ignoring \(package)"
        case .install: succeeded ? "Installed \(package)" : "Failed to install \(package)"
        }
    }
}

/// Append-only history persisted as JSON in Application Support, newest first, capped.
@Observable @MainActor
final class History {
    private(set) var records: [ActionRecord] = []
    private let url: URL
    private let cap = 2000
    /// How long command output is kept. The records themselves stay until the cap pushes them out.
    static let outputLifetime: TimeInterval = 7 * 86_400
    /// The tail of a long output is the part worth keeping; a big build log is not.
    static let outputCap = 20_000
    /// How much output the file may carry in total. Without this, a week of "update all" over a large
    /// set of packages would leave tens of megabytes to re-read at every launch.
    static let outputBudget = 2_000_000

    init(directory: URL) {
        url = directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
            let saved = try? JSONDecoder.iso.decode([ActionRecord].self, from: data)
        {
            records = saved
            // Writing back matters: otherwise a user who never acts again keeps week-old output on
            // disk for good, and pays to decode it at every launch.
            if dropExpiredOutput() { save() }
        }
    }

    func add(_ record: ActionRecord) { add([record]) }

    /// Adds several records in one write. One "update all" produces a record per package, and writing
    /// the whole file after each one costs more than the upgrades themselves on a large machine.
    func add(_ added: [ActionRecord]) {
        guard !added.isEmpty else { return }
        records.insert(contentsOf: added.map(Self.trimmed), at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
        dropExpiredOutput()
        save()
    }

    private static func trimmed(_ record: ActionRecord) -> ActionRecord {
        guard let output = record.output, output.count > outputCap else { return record }
        var record = record
        record.output = String(output.suffix(outputCap))
        return record
    }

    /// Forgets output that is too old or beyond what the file should carry, keeping the record of what
    /// was done. Returns whether anything was dropped.
    @discardableResult
    private func dropExpiredOutput(now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.outputLifetime)
        var changed = false
        var budget = Self.outputBudget
        // Newest first, so the oldest output is what goes when the budget runs out.
        for i in records.indices {
            guard let output = records[i].output else { continue }
            if records[i].date < cutoff || output.count > budget {
                records[i].output = nil
                changed = true
            } else {
                budget -= output.count
            }
        }
        return changed
    }

    func clear() {
        records = []
        save()
    }

    private func save() {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return }
        if let data = try? JSONEncoder.iso.encode(records) { try? data.write(to: url, options: .atomic) }
    }
}
