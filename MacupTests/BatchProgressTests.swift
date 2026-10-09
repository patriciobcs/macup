import XCTest

@testable import Macup

/// What the list shows while Update All is still working through one manager's packages.
@MainActor
final class BatchProgressTests: StubScriptCase {
    func testEachPackageLeavesTheListAsSoonAsItIsUpgraded() async throws {
        // Within one manager the rescan waits for the last package, so eight Homebrew updates used to
        // stay listed until all eight were done. A package that upgraded cleanly goes straight away.
        let hold = directory.appendingPathComponent("hold")
        try "".write(to: hold, atomically: true, encoding: .utf8)
        try script(
            "macup-upgrade",
            """
            [[ "$2" == *libssh* ]] && for _ in {1..100}; do [[ -e "${0:A:h}/hold" ]] || break; sleep 0.1; done
            print "upgraded $2"
            """)
        let store = store()
        let first = pkg("ffmpeg", manager: .brew, kind: "formula")
        let second = pkg("libssh", manager: .brew, kind: "formula")
        store.loadFixture(reports: [], packages: [first, second], log: "")

        let batch = Task { await store.upgradeAll(.brew) }
        for _ in 0..<100 where !store.isUpgrading(second) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(store.isUpgrading(second))
        XCTAssertEqual(store.packages.map(\.name), ["libssh"], "ffmpeg is gone while libssh is still running")
        try FileManager.default.removeItem(at: hold)
        await batch.value
        XCTAssertTrue(store.packages.isEmpty)
    }

    func testAFailedPackageStaysListedDuringTheBatch() async throws {
        try keepOutdated("boom-pkg")
        let store = store()
        store.loadFixture(reports: [], packages: [pkg("boom-pkg"), pkg("lodash")], log: "")

        await store.upgradeAll(.npm)

        XCTAssertEqual(store.packages.map(\.name), ["boom-pkg"], "only the clean upgrade leaves")
    }
}
