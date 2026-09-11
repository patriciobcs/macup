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
            case (.number(let m), .text(let t)):
                // 1.0.0 > 1.0.0-beta, but 1.0.0 < 1.0.0.post1
                return Self.isPostRelease(t) && m == 0 ? .orderedAscending : .orderedDescending
            case (.text(let t), .number(let n)):
                return Self.isPostRelease(t) && n == 0 ? .orderedDescending : .orderedAscending
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

    /// PEP 440 post-release markers come after the release; everything else textual is a pre-release.
    private static func isPostRelease(_ t: String) -> Bool {
        t.hasPrefix("post") || t == "rev" || t == "r" || t == "p"
    }

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
