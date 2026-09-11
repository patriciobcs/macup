import XCTest

@testable import Macup

@MainActor
final class UpdateStoreTests: XCTestCase {
    private func pkg(_ name: String, latest: String = "2") -> OutdatedPackage {
        OutdatedPackage(manager: .npm, name: name, installed: "1", latest: latest, kind: "global", extra: "")
    }

    func testFirstSeenSurvivesATemporaryAbsence() {
        let store = UpdateStore(persist: false)
        store.loadFixture(reports: [], packages: [pkg("a"), pkg("b")], log: "")
        let a = pkg("a"), b = pkg("b")
        let seenA = store.firstSeen[a.versionKey]
        XCTAssertNotNil(seenA)
        // A scan that could not resolve "b" (offline) must not forget when it was first seen.
        store.merge(ScanResult(reports: [], packages: [a]), scanned: [.npm])
        XCTAssertEqual(store.firstSeen[a.versionKey], seenA)
        XCTAssertNotNil(store.firstSeen[b.versionKey], "kept for a grace period")
        XCTAssertEqual(store.packages.map(\.name), ["a"])
    }

    func testSelfCaskStaysOutOfTheVisibleList() {
        let store = UpdateStore(persist: false)
        let cask = OutdatedPackage(manager: .brew, name: "macup", installed: "1", latest: "2", kind: "cask", extra: "")
        store.loadFixture(reports: [], packages: [cask, pkg("x")], log: "")
        XCTAssertEqual(store.visible.map(\.name), ["x"])
    }
}
