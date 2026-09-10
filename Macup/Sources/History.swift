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

    init(directory: URL) {
        url = directory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.iso.decode([ActionRecord].self, from: data) {
            records = saved
        }
    }

    func add(_ record: ActionRecord) {
        records.insert(record, at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
        save()
    }

    func clear() { records = []; save() }

    private func save() {
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return }
        if let data = try? JSONEncoder.iso.encode(records) { try? data.write(to: url, options: .atomic) }
    }
}
