import AppKit
import SwiftUI
import XCTest

@testable import Macup

/// Upgrades, removals and tool installs, run end to end against stub scripts. These drive the real
/// subprocess, the real log streaming and the real history writing; only the package manager at the
/// far end is fake, because the alternative is changing packages on whoever runs the tests.
@MainActor
final class UpgradeFlowTests: StubScriptCase {
    // MARK: Upgrading

    func testASuccessfulUpgradeIsLoggedAndRecorded() async {
        let store = store()
        let package = pkg("lodash")
        store.loadFixture(reports: [], packages: [package], log: "")

        await store.upgrade(package)

        XCTAssertTrue(store.log.contains("── npm: lodash ──"), "the log is marked so a row can scroll to it")
        XCTAssertTrue(store.log.contains("upgraded lodash"), "the command's own output is streamed in")
        XCTAssertTrue(store.log.contains("✓ done"))
        XCTAssertNil(store.failure(for: package))
        XCTAssertEqual(store.history.records.first?.kind, .upgrade)
        XCTAssertEqual(store.history.records.first?.succeeded, true)
        XCTAssertEqual(store.history.records.first?.detail, "1.0.0 → 2.0.0")
        XCTAssertEqual(
            store.history.records.first?.output?.contains("upgraded lodash"), true,
            "what the command printed is kept with the record, so the History tab can show it")
        XCTAssertFalse(store.isUpgrading(package), "the lock is released when it finishes")
    }

    func testRustupIsToldWhichOfItsPackagesWasAskedFor() async {
        // rustup itself and a toolchain need different commands from the script, so it has to be told
        // which was asked for. It used to be sent nothing at all, and the script guessed the toolchain
        // one: asking to update rustup ran a command that could never do it, reported success, and
        // offered the very same update again after the next scan.
        let store = store()
        let toolchain = pkg("stable-aarch64-apple-darwin", manager: .rustup, kind: "toolchain")
        store.loadFixture(reports: [], packages: [toolchain], log: "")

        await store.upgrade(toolchain)

        XCTAssertTrue(
            store.log.contains("upgrading stable-aarch64-apple-darwin"),
            "the name reached the script, which is what picks the command: \(store.log)")
    }

    func testAFailedUpgradeKeepsTheErrorAgainstThePackage() async {
        try? keepOutdated("boom-pkg")
        let store = store()
        let package = pkg("boom-pkg")
        store.loadFixture(reports: [], packages: [package], log: "")

        await store.upgrade(package)

        XCTAssertEqual(store.failure(for: package), "Error: could not upgrade boom-pkg")
        XCTAssertEqual(
            store.history.records.first?.output?.contains("Error: could not upgrade boom-pkg"), true,
            "a failure keeps its output, which is the whole point of keeping it")
        XCTAssertTrue(store.log.contains("✗ exited with status 1"))
        XCTAssertEqual(store.history.records.first?.succeeded, false)
        XCTAssertEqual(store.history.records.first?.title, "Failed to update boom-pkg")
    }

    func testUpgradingEverythingEligibleRunsEachManager() async {
        let store = store()
        store.loadFixture(
            reports: [], packages: [pkg("lodash"), pkg("jq", manager: .brew, kind: "formula")], log: "")

        await store.upgradeAllEligible()

        XCTAssertTrue(store.log.contains("upgraded lodash"))
        // Homebrew is handed "formula:jq": the kind travels with the name so a formula and a cask of
        // the same name cannot be confused.
        XCTAssertTrue(store.log.contains("upgraded formula:jq"))
        XCTAssertEqual(store.history.records.count, 2)
        XCTAssertFalse(store.isUpgradingAnything)
    }

    func testUpdateAllLeavesMacOSUpdatesAlone() async {
        let store = store()
        store.loadFixture(reports: [], packages: [pkg("lodash"), pkg("Sequoia", manager: .macos)], log: "")

        await store.upgradeAllEligible()

        XCTAssertTrue(store.log.contains("upgraded lodash"))
        XCTAssertFalse(store.log.contains("Sequoia"), "macOS updates need a restart, so they are a hand-off")
        XCTAssertEqual(store.history.records.map(\.package), ["lodash"])
    }

    func testUpgradingOneManagerOnly() async {
        let store = store()
        store.loadFixture(
            reports: [], packages: [pkg("lodash"), pkg("jq", manager: .brew, kind: "formula")], log: "")

        await store.upgradeAll(.brew)

        XCTAssertTrue(store.log.contains("upgraded formula:jq"))
        XCTAssertFalse(store.log.contains("upgraded lodash"))
    }

    // MARK: Removing

    func testRemovingAPackageIsLoggedAndRecorded() async {
        let store = store()
        let package = pkg("lodash")
        store.loadFixture(reports: [], packages: [package], log: "")

        await store.remove(package)

        XCTAssertTrue(store.log.contains("removed lodash"))
        XCTAssertTrue(store.log.contains("✓ removed"))
        XCTAssertEqual(store.history.records.first?.kind, .remove)
        XCTAssertEqual(store.history.records.first?.detail, "1.0.0", "a removal records the version that went")
    }

    func testAFailedRemovalIsReportedAgainstThePackage() async {
        try? keepOutdated("boom-pkg")
        let store = store()
        let package = pkg("boom-pkg")
        store.loadFixture(reports: [], packages: [package], log: "")

        await store.remove(package)

        XCTAssertEqual(store.failure(for: package), "Error: could not remove boom-pkg")
        XCTAssertEqual(store.history.records.first?.succeeded, false)
    }

    // MARK: Installing a helper tool

    func testInstallingMasIsRecorded() async {
        let store = store()
        store.loadFixture(reports: [], packages: [], log: "")

        await store.installTool(.mas)

        XCTAssertTrue(store.log.contains("── Install mas ──"))
        XCTAssertTrue(store.log.contains("✓ installed"))
        XCTAssertEqual(store.history.records.first?.kind, .install)
        XCTAssertEqual(store.history.records.first?.detail, "via Homebrew")
        XCTAssertFalse(store.isInstalling(.mas))
    }

    func testAFailedToolInstallIsRecordedWithItsError() async {
        let store = store()
        store.loadFixture(reports: [], packages: [], log: "")

        await store.installTool(.conda)

        XCTAssertEqual(store.history.records.first?.succeeded, false)
        XCTAssertTrue(store.log.contains("✗ exited with status 1"))
    }

    // MARK: Scanning through the same stubs

    func testAScanFillsInTheManagersItWasAskedFor() async {
        let store = store()

        await store.scan(managers: [.npm, .brew])

        XCTAssertEqual(store.reports.map(\.manager), [.brew, .npm], "reports are kept in Manager order")
        XCTAssertEqual(store.scanned, [.npm, .brew])
        XCTAssertNotNil(store.lastScan)
        XCTAssertNil(store.scanError)
        XCTAssertFalse(store.isScanning)
    }

    // MARK: What the windows look like while the work happens

    func testTheSetupWindowShowsProgressWhileTheScanRuns() async throws {
        // A scan that takes a moment, so the window can be drawn while managers are still reporting.
        try script(
            "macup-scan",
            #"""
            for m in "$@"; do printf 'M\t%s\tok\t\n' "$m"; sleep 0.4; done
            """#)
        let store = store()
        let scan = Task { await store.scan(managers: [.npm, .brew, .gem, .cargo]) }
        // Let the first manager report, then draw: this is the state that used to be a frozen spinner.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(store.isScanning)
        XCTAssertGreaterThan(store.scanned.count, 0, "at least one manager has reported by now")
        XCTAssertLessThan(store.scanned.count, store.scanTotal, "and the rest are still running")

        renderOffscreen(
            OnboardingView(close: {}).environment(store).environment(settings),
            size: CGSize(width: 560, height: 620))
        renderOffscreen(
            MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 620))
        await scan.value
        XCTAssertEqual(store.scanned.count, store.scanTotal, "every manager reported in the end")
    }

    func testTheWindowsBeforeAnythingHasBeenScanned() {
        // A fresh install: no reports, no packages, no last scan time to show.
        let store = store()
        XCTAssertNil(store.lastScan)
        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 520))
        renderOffscreen(
            OnboardingView(close: {}).environment(store).environment(settings),
            size: CGSize(width: 560, height: 620))
    }

    func testTheRowsAfterAnUpgradeHasFailed() async {
        try? keepOutdated("boom-pkg")
        let store = store()
        let package = pkg("boom-pkg")
        store.loadFixture(reports: [], packages: [package], log: "")
        await store.upgrade(package)
        XCTAssertNotNil(store.failure(for: package), "the row has an error to show")

        renderOffscreen(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 600))
        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 620))
        renderOffscreen(MainWindowView().environment(store).environment(settings))
    }

    func testAHomebrewCopyOffersItsOwnUpdateInThePanel() {
        // Installed by Homebrew, with its own cask outdated: the panel offers to update MacUp itself.
        let store = store(installSource: .homebrew)
        var cask = pkg("macup", manager: .brew, kind: "cask")
        cask.installed = "1.0.0"
        cask.latest = "99.0.0"  // newer than whatever version the tests are hosted in
        store.loadFixture(reports: [], packages: [cask, pkg("lodash")], log: "")

        XCTAssertEqual(store.selfCaskUpdate?.name, "macup")
        XCTAssertFalse(store.visible.contains(cask), "it is offered as an app update, not as a package row")
        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 640))
    }

    /// Every row in the panel lines its icon up at the same place. The app update row is a button and
    /// the package rows are not, and the button style brings its own inset, so it is easy to knock the
    /// two out of line without noticing.
    func testEveryRowInThePanelLinesUp() throws {
        let store = store(installSource: .homebrew)
        var cask = pkg("macup", manager: .brew, kind: "cask")
        cask.installed = "1.0.0"
        cask.latest = "99.0.0"  // newer than whatever version the tests are hosted in
        store.loadFixture(
            reports: [], packages: [cask, pkg("rtk", manager: .brew, kind: "formula"), pkg("wrangler")],
            log: "")

        let rep = try XCTUnwrap(
            renderBitmap(
                MenuBarPanel().environment(store).environment(settings),
                size: CGSize(width: 320, height: 420), settle: 0.4))

        // The icon of each row is a filled accent circle, so the leftmost tinted pixel of each band of
        // rows is where that row starts.
        var starts: [Int] = []
        var run: Int?
        for y in 0..<rep.pixelsHigh {
            let left = (0..<rep.pixelsWide).first { x in
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return c.alphaComponent > 0.9 && c.blueComponent > 0.6 && c.redComponent < 0.5
            }
            switch (left, run) {
            case (let l?, let current): run = min(l, current ?? l)
            case (nil, let current?):
                starts.append(current)
                run = nil
            default: break
            }
        }
        if let run { starts.append(run) }

        XCTAssertEqual(starts.count, 3, "one icon per row: the app update and two packages")
        XCTAssertEqual(Set(starts).count, 1, "all rows start at the same x, got \(starts)")
    }

    func testADirectCopyIgnoresAStrayCask() {
        let store = store(installSource: .direct)
        let cask = pkg("macup", manager: .brew, kind: "cask")
        store.loadFixture(reports: [], packages: [cask], log: "")
        XCTAssertNil(store.selfCaskUpdate, "a downloaded copy updates through Sparkle instead")
    }

    func testTheRowsWhileAnUpgradeIsRunning() async throws {
        // A slow upgrade, so the panel and list can be drawn with the work in flight.
        try script("macup-upgrade", "sleep 1.2; print upgraded")
        let store = store()
        let package = pkg("lodash")
        store.loadFixture(reports: [], packages: [package], log: "")

        let upgrade = Task { await store.upgrade(package) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(store.isUpgrading(package), "the row shows a spinner while this runs")

        renderOffscreen(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 600))
        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 620))
        await upgrade.value
        XCTAssertFalse(store.isUpgrading(package))
    }

    func testTheWindowsWithIgnoredAndSystemPackagesOnShow() {
        let store = store()
        store.loadFixture(
            reports: [ManagerReport(manager: .gem, status: .ok, message: "admin")],
            packages: [pkg("lodash"), pkg("psych", manager: .gem, kind: "system-gem"), pkg("stub")],
            log: "")
        store.ignore(pkg("stub"))
        XCTAssertEqual(store.ignored.map(\.name), ["stub"])
        renderOffscreen(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 700))
        renderOffscreen(SettingsView().environment(store).environment(settings), size: CGSize(width: 520, height: 760))

        settings.hideSystemPackages = false
        XCTAssertEqual(store.hiddenSystemCount, 0)
        renderOffscreen(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 700))
        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 700))
    }

    func testSettingsWithManagersTurnedOff() {
        let store = store()
        store.loadFixture(
            reports: Manager.allCases.map { ManagerReport(manager: $0, status: .ok, message: "") },
            packages: [pkg("lodash")], log: "")
        settings.disabledManagers = [.conda, .nix, .port]
        defer { settings.disabledManagers = [] }
        XCTAssertFalse(settings.enabledManagers.contains(.conda))
        renderOffscreen(SettingsView().environment(store).environment(settings), size: CGSize(width: 520, height: 800))
        renderOffscreen(
            OnboardingView(close: {}).environment(store).environment(settings),
            size: CGSize(width: 560, height: 700))
    }

    func testARescanAskedForDuringAScanIsQueuedRatherThanDropped() async throws {
        // A rescan after an upgrade must not be lost to a scan that is already running.
        try script(
            "macup-scan",
            #"""
            for m in "$@"; do printf 'M\t%s\tok\t\n' "$m"; done
            sleep 0.8
            """#)
        let store = store()
        let running = Task { await store.scan(managers: [.npm]) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(store.isScanning)

        await store.scan(managers: [.brew])  // returns at once: queued behind the running scan
        XCTAssertFalse(store.reports.contains { $0.manager == .brew }, "it has not run yet")

        await running.value
        XCTAssertTrue(
            store.reports.contains { $0.manager == .brew }, "the queued rescan runs once the first finishes")
    }

    func testTheWindowsShowTheNoticeWhenAScanFails() async {
        // The scan script is gone, so every surface has to explain itself rather than look empty.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("macup-scan.sh"))
        let store = store()
        store.loadFixture(reports: [], packages: [pkg("lodash")], log: "")
        await store.scan(managers: [.npm])
        XCTAssertNotNil(store.scanError)

        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 620))
        renderOffscreen(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 600))
    }

    func testALongListOfPackagesStillDraws() {
        // Enough rows to pass whatever point the panel starts scrolling, with a mix of states.
        let store = store()
        var packages = (1...30).map { pkg("package-\($0)") }
        packages[0].advisories = ["GHSA-0001"]
        packages[1].releaseDate = Date()  // still settling, so it lands in the waiting group
        settings.minAgeHours = 24
        store.loadFixture(reports: [], packages: packages, log: "")
        XCTAssertGreaterThan(store.eligible.count, 20)
        XCTAssertEqual(store.waiting.count, 1)

        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 720))
        renderOffscreen(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 720))
    }

    func testAMissingScriptIsReportedRatherThanCrashing() async {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("macup-scan.sh"))
        let store = store()

        await store.scan(managers: [.npm])

        XCTAssertNotNil(store.scanError, "the window shows why the scan could not run")
        XCTAssertFalse(store.isScanning)
    }

    func testOnboardingWhileAToolIsBeingInstalled() async throws {
        // mas is offered when Homebrew is present, and shows its progress while it installs.
        try script("macup-setup", "sleep 1.2; print installed")
        let store = store()
        store.loadFixture(
            reports: [
                ManagerReport(manager: .brew, status: .ok, message: ""),
                ManagerReport(manager: .mas, status: .missing, message: ""),
                ManagerReport(manager: .npm, status: .error, message: "Error: EACCES"),
            ], packages: [], log: "")
        renderOffscreen(
            OnboardingView(close: {}).environment(store).environment(settings),
            size: CGSize(width: 560, height: 700))

        let install = Task { await store.installTool(.mas) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(store.isInstalling(.mas))
        renderOffscreen(
            OnboardingView(close: {}).environment(store).environment(settings),
            size: CGSize(width: 560, height: 700))
        await install.value
        XCTAssertFalse(store.isInstalling(.mas))
    }

    func testTheHistoryPaneWithNothingRecorded() {
        let store = store()
        XCTAssertEqual(store.history.records, [])
        renderOffscreen(
            HistoryView(tab: .constant(1)).environment(store).environment(settings),
            size: CGSize(width: 470, height: 400))
    }

    func testTheVersionAManagerReportedIsAvailableForBugReports() {
        let store = store()
        store.loadFixture(
            reports: [
                ManagerReport(manager: .brew, status: .ok, message: "", version: "4.2.1"),
                ManagerReport(manager: .npm, status: .ok, message: ""),
            ], packages: [], log: "")
        XCTAssertEqual(store.version(of: .brew), "4.2.1")
        XCTAssertEqual(store.version(of: .npm), "", "a manager that reported no version")
        XCTAssertEqual(store.version(of: .conda), "", "a manager that never reported at all")
    }
}
