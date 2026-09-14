import Foundation

/// Parses the tab-separated output of `macup-scan.sh`.
enum ScanParser {
    static func parse(_ text: String) -> ScanResult {
        var result = ScanResult()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            switch f[0] {
            case "M":
                guard f.count >= 3, let m = Manager(rawValue: f[1]),
                    let status = ManagerStatus(rawValue: f[2])
                else { continue }
                result.reports.append(
                    ManagerReport(
                        manager: m, status: status, message: f.count > 3 ? f[3] : "",
                        version: f.count > 4 ? f[4] : ""))
            case "P":
                guard f.count >= 6, let m = Manager(rawValue: f[1]), !f[2].isEmpty else { continue }
                var pkg = OutdatedPackage(
                    manager: m, name: f[2], installed: f[3], latest: f[4],
                    kind: f[5], extra: f.count > 6 ? f[6] : "")
                // rustup emits the toolchain build date as extra (YYYY-MM-DD).
                if m == .rustup, let date = Self.dayFormatter.date(from: pkg.extra) {
                    pkg.releaseDate = date
                    pkg.dateSource = .registry
                }
                if f.count > 7, let epoch = TimeInterval(f[7]), epoch > 0 {
                    pkg.updatedAt = Date(timeIntervalSince1970: epoch)
                }
                result.packages.append(pkg)
            case "T":
                guard f.count >= 3, !f[1].isEmpty,
                    let presence = ToolReport.Presence(rawValue: f[2])
                else { continue }
                result.tools.append(
                    ToolReport(name: f[1], presence: presence, detail: f.count > 3 ? f[3] : ""))
            default:
                continue
            }
        }
        return result
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
