import Foundation

/// Loose, dependency-free version comparison good enough for "is B newer than A" across
/// semver, PEP 440 and Homebrew-style versions (1.2.3, 1.2.3_1, 2.0.11.1, 1.0.0-beta.2, 4.0.20).
enum Version {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : .number(0)
            let y = i < pb.count ? pb[i] : .number(0)
            switch (x, y) {
            case let (.number(m), .number(n)):
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (.number, .text):
                return .orderedDescending  // 1.0.0 > 1.0.0-beta
            case (.text, .number):
                return .orderedAscending
            case let (.text(s), .text(t)):
                if s != t { return s < t ? .orderedAscending : .orderedDescending }
            }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private enum Part: Equatable { case number(Int), text(String) }

    private static func parts(_ s: String) -> [Part] {
        var out: [Part] = []
        var cur = ""
        var curIsDigit: Bool?
        func flush() {
            guard !cur.isEmpty else { return }
            out.append(curIsDigit == true ? .number(Int(cur) ?? 0) : .text(cur.lowercased()))
            cur = ""
            curIsDigit = nil
        }
        for ch in s.drop(while: { $0 == "v" || $0 == "V" }) {
            if ".-_+~,".contains(ch) {
                flush()
                continue
            }
            let d = ch.isNumber
            if curIsDigit != nil && curIsDigit != d { flush() }
            curIsDigit = d
            cur.append(ch)
        }
        flush()
        return out
    }
}
