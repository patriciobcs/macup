import XCTest

@testable import Macup

final class EligibilityTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func pkg(_ name: String, released hoursAgo: Double?, security: Bool = false) -> OutdatedPackage {
        var p = OutdatedPackage(
            manager: .npm, name: name, installed: "1.0.0", latest: "2.0.0", kind: "global", extra: "")
        if let h = hoursAgo {
            p.releaseDate = now.addingTimeInterval(-h * 3600)
            p.dateSource = .registry
        }
        if security { p.advisories = ["GHSA-test"] }
        return p
    }

    func testRegularThreshold() {
        let day: TimeInterval = 24 * 3600
        XCTAssertTrue(
            Eligibility.isEligible(
                pkg("a", released: 30), minAge: day, securityMinAge: 4 * 3600, firstSeen: [:], now: now))
        XCTAssertFalse(
            Eligibility.isEligible(
                pkg("b", released: 3), minAge: day, securityMinAge: 4 * 3600, firstSeen: [:], now: now))
    }

    func testSecurityUsesShorterThreshold() {
        let p = pkg("c", released: 5, security: true)
        XCTAssertTrue(Eligibility.isEligible(p, minAge: 24 * 3600, securityMinAge: 4 * 3600, firstSeen: [:], now: now))
        XCTAssertFalse(
            Eligibility.isEligible(
                pkg("d", released: 5), minAge: 24 * 3600, securityMinAge: 4 * 3600, firstSeen: [:], now: now))
    }

    func testFallsBackToFirstSeen() {
        let p = pkg("e", released: nil)
        let seen = [p.versionKey: now.addingTimeInterval(-48 * 3600)]
        XCTAssertTrue(Eligibility.isEligible(p, minAge: 24 * 3600, securityMinAge: 4 * 3600, firstSeen: seen, now: now))
        XCTAssertFalse(Eligibility.isEligible(p, minAge: 24 * 3600, securityMinAge: 4 * 3600, firstSeen: [:], now: now))
    }

    func testZeroThresholdShowsEverything() {
        XCTAssertTrue(
            Eligibility.isEligible(pkg("f", released: nil), minAge: 0, securityMinAge: 0, firstSeen: [:], now: now))
    }
}
