import Foundation

/// Pure decision logic: is an update old enough to be shown, given its release/first-seen date?
enum Eligibility {
    /// The moment we start counting from: the registry release date when known, otherwise when Macup first saw it.
    static func referenceDate(for pkg: OutdatedPackage, firstSeen: [String: Date]) -> Date? {
        pkg.releaseDate ?? firstSeen[pkg.versionKey]
    }

    static func age(of pkg: OutdatedPackage, firstSeen: [String: Date], now: Date = Date()) -> TimeInterval {
        guard let ref = referenceDate(for: pkg, firstSeen: firstSeen) else { return 0 }
        return max(0, now.timeIntervalSince(ref))
    }

    static func isEligible(_ pkg: OutdatedPackage, minAge: TimeInterval, securityMinAge: TimeInterval,
                           firstSeen: [String: Date], now: Date = Date()) -> Bool {
        let threshold = pkg.isSecurity ? securityMinAge : minAge
        return age(of: pkg, firstSeen: firstSeen, now: now) >= threshold
    }
}
