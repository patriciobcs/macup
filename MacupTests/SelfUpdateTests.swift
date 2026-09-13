import AppKit
import SwiftUI
import XCTest

@testable import Macup

/// Updating MacUp itself, and installing updates without being asked.
@MainActor
final class SelfUpdateTests: StubScriptCase {
    func testUpdateAllUpdatesMacUpItselfLast() async {
        // The Homebrew upgrade of MacUp relaunches the app, so it has to come after everything else.
        var updatedSelfAfter: [String] = []
        let store = store(installSource: .homebrew) { @MainActor in
            updatedSelfAfter = ["marker"]
        }
        try? reportOutdatedSelfCask()  // Homebrew keeps reporting it until it is actually upgraded
        var cask = pkg("macup", manager: .brew, kind: "cask")
        cask.latest = "99.0.0"
        store.loadFixture(
            reports: [], packages: [cask, pkg("lodash"), pkg("jq", manager: .brew, kind: "formula")], log: "")

        await store.upgradeAllEligible()

        XCTAssertEqual(updatedSelfAfter, ["marker"], "MacUp updates itself as part of Update All")
        XCTAssertTrue(store.log.contains("upgraded lodash"), "and the packages went first")
        XCTAssertTrue(store.log.contains("upgraded formula:jq"))
    }

    func testUpdatingOneManagerLeavesMacUpAlone() async {
        var updatedSelf = false
        let store = store(installSource: .homebrew) { @MainActor in
            updatedSelf = true
        }
        store.loadFixture(reports: [], packages: [pkg("jq", manager: .brew, kind: "formula")], log: "")

        await store.upgradeAll(.brew)

        XCTAssertFalse(updatedSelf, "a section's Update All is not the whole batch")
    }

    func testNothingIsInstalledAutomaticallyUnlessAskedFor() async {
        try? reportOutdatedToolchain()
        settings.autoUpdate = false
        let store = store()

        await store.scan(managers: [.rustup])

        XCTAssertEqual(store.eligible.count, 1, "there is something ready to install")
        XCTAssertEqual(store.history.records, [], "but off by default: updating is the user's call")
        XCTAssertNil(store.lastAutoUpdate)
    }

    func testAutomaticUpdatesRunAfterAScanAndThenWaitForTheInterval() async throws {
        try? reportOutdatedToolchain()
        settings.autoUpdate = true
        settings.autoUpdateIntervalHours = 24
        let store = store()

        await store.scan(managers: [.rustup])

        XCTAssertEqual(store.history.records.map(\.package), ["stable"], "what was ready got installed")
        XCTAssertEqual(store.history.records.first?.kind, .upgrade)
        let firstRun = try XCTUnwrap(store.lastAutoUpdate)

        // A second scan inside the interval must not install anything again.
        await store.scan(managers: [.rustup])
        XCTAssertEqual(store.history.records.count, 1, "the interval has not passed yet")
        XCTAssertEqual(store.lastAutoUpdate, firstRun)
    }

    func testAnUnattendedRunLeavesAnythingNeedingAPasswordAlone() async {
        try? reportOutdatedToolchain()
        try? markNeedsAdmin(.rustup)
        settings.autoUpdate = true
        let store = store()

        await store.scan(managers: [.rustup])

        XCTAssertTrue(store.needsAdmin(.rustup), "this manager would prompt for a password")
        XCTAssertEqual(store.eligible.count, 1, "it is ready, and still offered to the user")
        XCTAssertEqual(store.history.records, [], "but nothing was installed behind a password prompt")
        XCTAssertNotNil(store.lastAutoUpdate, "the run happened, it just had nothing it could do")
    }

    func testAnUpdateTheRunningCopyAlreadyIsIsNotOffered() {
        // Homebrew records the version it installed. A copy replaced by hand is newer than that, and
        // offering it "1.0.1" while 1.0.2 is running is just wrong.
        let store = store(installSource: .homebrew)
        var cask = pkg("macup", manager: .brew, kind: "cask")
        cask.installed = "1.0.0"
        cask.latest = store.appVersion
        store.loadFixture(reports: [], packages: [cask], log: "")
        XCTAssertNil(store.selfCaskUpdate, "the running app already is this version")

        var newer = cask
        newer.latest = "99.0.0"
        store.loadFixture(reports: [], packages: [newer], log: "")
        XCTAssertEqual(store.selfCaskUpdate?.latest, "99.0.0", "a genuinely newer cask is still offered")
    }

    func testAnUnattendedRunLeavesMacUpAloneUntilItHasSettled() async throws {
        // Replacing the app unasked deserves the same settling delay as any other package.
        settings.autoUpdate = true
        settings.minAgeHours = 24
        var updatedSelf = false
        let store = store(installSource: .homebrew) { @MainActor in updatedSelf = true }
        var cask = pkg("macup", manager: .brew, kind: "cask")
        cask.latest = "99.0.0"
        cask.releaseDate = Date()  // just released
        store.loadFixture(reports: [], packages: [cask], log: "")

        XCTAssertNotNil(store.selfCaskUpdate, "it is offered to the user straight away")
        XCTAssertFalse(store.isEligible(cask), "but it has not settled yet")

        await store.updateSelf(unattended: true)
        XCTAssertFalse(updatedSelf, "so an unattended run leaves it")

        await store.updateSelf()
        XCTAssertTrue(updatedSelf, "while asking for it explicitly still works")
    }

    func testAnUnattendedRunSkipsPackagesFromManagersTurnedOff() async throws {
        try reportOutdatedToolchain()
        settings.autoUpdate = true
        settings.disabledManagers = [.rustup]
        let store = store()

        await store.scan(managers: [.rustup])

        XCTAssertEqual(store.eligible, [], "a manager turned off has nothing to offer")
        XCTAssertEqual(store.history.records, [], "and nothing is installed from it")
    }

    func testAnnouncementIsSkippedWhenTheSameScanWillInstall() async throws {
        try reportOutdatedToolchain()
        settings.autoUpdate = true
        settings.notificationsEnabled = true
        let store = store()
        await store.scan(managers: [.rustup])
        XCTAssertEqual(store.history.records.map(\.package), ["stable"], "it was installed")
        // The notification itself needs the user's permission to observe, but the decision behind it is
        // visible: having just run, another unattended run is not due, so there is nothing to announce.
        XCTAssertFalse(store.autoUpdateIsDue)
    }

    // MARK: What the new settings look like

    func testSettingsShowTheIntervalOnlyWhenAutomaticUpdatesAreOn() {
        let store = store()
        store.loadFixture(reports: [], packages: [pkg("lodash")], log: "")

        settings.autoUpdate = false
        renderOffscreen(SettingsView().environment(store).environment(settings), size: CGSize(width: 520, height: 820))

        // Turning it on reveals how often it may run, and what it will leave alone.
        settings.autoUpdate = true
        renderOffscreen(SettingsView().environment(store).environment(settings), size: CGSize(width: 520, height: 860))
        renderOffscreen(
            OnboardingView(close: {}).environment(store).environment(settings),
            size: CGSize(width: 560, height: 700))
    }
}
