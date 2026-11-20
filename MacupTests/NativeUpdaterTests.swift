import XCTest

@testable import Macup

@MainActor
final class NativeUpdaterTests: StubScriptCase {
    func testUpdateAllLeavesNativeUpdatersForAnExplicitAction() async {
        let store = store()
        store.loadFixture(
            reports: [],
            packages: [pkg("lodash"), pkg("Tailscale", manager: .tailscale), pkg("gcloud", manager: .gcloud)],
            log: "")

        XCTAssertEqual(store.updatableCount, 1)
        await store.upgradeAllEligible()

        XCTAssertEqual(store.history.records.map(\.package), ["lodash"])
        XCTAssertFalse(store.log.contains("upgraded Tailscale"))
        XCTAssertFalse(store.log.contains("upgraded gcloud"))
    }

    func testGcloudOpensTheGuardedScriptInTerminalWithoutClaimingAnUpgrade() async {
        let store = store()
        let package = pkg("gcloud", manager: .gcloud)
        store.loadFixture(reports: [], packages: [package], log: "")

        XCTAssertTrue(store.updatesInTerminal(package))
        XCTAssertTrue(store.terminalUpdateHelp(package).contains("system Python"))
        await store.upgrade(package)

        XCTAssertTrue(store.log.contains("in Terminal"))
        XCTAssertTrue(store.log.contains("macup-upgrade.sh' gcloud 'gcloud'"))
        XCTAssertTrue(store.history.records.isEmpty)
        XCTAssertEqual(store.packages, [package])
    }

    func testCommandLineListsTheGcloudCommandWithoutStartingItsInstaller() async {
        let store = store(commandLine: true)
        let package = pkg("gcloud", manager: .gcloud)
        store.loadFixture(reports: [], packages: [package], log: "")

        let status = await CommandLineTool.run(.init(command: .upgrade, managers: [.gcloud]), store: store)

        XCTAssertEqual(status, 0)
        XCTAssertTrue(store.history.records.isEmpty)
        XCTAssertFalse(store.log.contains("upgraded gcloud"))
        XCTAssertEqual(store.packages, [package])
    }

    func testCommandLineBatchDoesNotStartEitherNativeUpdater() async {
        let store = store(commandLine: true)
        store.loadFixture(
            reports: [],
            packages: [pkg("lodash"), pkg("gcloud", manager: .gcloud), pkg("Tailscale", manager: .tailscale)],
            log: "")

        let status = await CommandLineTool.run(.init(command: .upgrade), store: store)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(store.history.records.map(\.package), ["lodash"])
    }

    func testOpeningTailscalesUpdaterDoesNotClaimTheVPNWasUpgraded() async {
        let store = store()
        let package = pkg("Tailscale", manager: .tailscale)
        store.loadFixture(reports: [], packages: [package], log: "")

        await store.upgrade(package)

        XCTAssertEqual(store.history.records.first?.detail, "Opened updater")
        XCTAssertTrue(store.log.contains("✓ opened updater"))
        XCTAssertNil(store.failure(for: package))
    }
}
