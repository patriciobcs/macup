import Foundation

struct InventoryReport: Encodable {
    struct Item: Encodable {
        var id: String
        var manager: String
        var name: String
        var version: String
        var path: String
        var owner: String
        var state: String
        var latest: String?
        var action: String?
        var note: String
    }

    var checkedAt: Date?
    var installations: [Item]

    init(items: [InstalledItem], checkedAt: Date?) {
        self.checkedAt = checkedAt
        installations = InstallationList.filtered(items, query: "", needsReview: false).map {
            Item(
                id: $0.package.id, manager: $0.manager.rawValue, name: $0.name, version: $0.version,
                path: $0.reference.path, owner: $0.reference.owner, state: $0.state.rawValue,
                latest: $0.latest, action: $0.reference.update?.title, note: $0.note)
        }
    }

    func json() -> String {
        let encoder = JSONEncoder.iso
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func text() -> String {
        var lines = ["\(installations.count) installations"]
        for item in installations {
            lines.append("\(item.name) \(item.version) · \(item.owner) · \(item.state)")
            lines.append("  \(item.path)")
            if !item.note.isEmpty { lines.append("  \(item.note)") }
            lines.append("  id: \(item.id)")
        }
        return lines.joined(separator: "\n")
    }
}
