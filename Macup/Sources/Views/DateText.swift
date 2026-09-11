import Foundation

/// Compact and full phrasing for the two dates on a package row.
enum DateText {
    /// "5m", "3h", "2d", "3w", "5mo", "2y"
    static func short(_ interval: TimeInterval) -> String {
        let s = max(0, interval)
        switch s {
        case ..<3600: return "\(max(1, Int(s / 60)))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(14 * 86_400): return "\(Int(s / 86_400))d"
        case ..<(60 * 86_400): return "\(Int(s / (7 * 86_400)))w"
        case ..<(365 * 86_400): return "\(Int(s / (30 * 86_400)))mo"
        default: return "\(Int(s / (365 * 86_400)))y"
        }
    }

    static func exact(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    /// Tooltip explaining both dates and where the update date comes from.
    static func tooltip(for pkg: OutdatedPackage, referenceDate: Date?) -> String {
        var lines: [String] = []
        if let ref = referenceDate {
            let what: String
            switch pkg.dateSource {
            case .registry: what = "Released"
            case .homebrew: what = "Bumped in Homebrew"
            case .firstSeen: what = "First seen by MacUp"
            }
            lines.append("\(what) \(ref.formatted(.relative(presentation: .named))) (\(exact(ref)))")
        }
        if let up = pkg.updatedAt {
            let how = pkg.manager == .brew ? "from Homebrew's install receipt" : "from the install date on disk"
            lines.append(
                "Last updated on this Mac \(up.formatted(.relative(presentation: .named))) (\(exact(up))), \(how)")
        }
        return lines.joined(separator: "\n")
    }
}
