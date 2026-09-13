import SwiftUI
import XCTest

@testable import Macup

/// Draws each view offscreen, the way the screenshot renderer does. The screenshots only ever show a
/// healthy Mac, so these cover what the pictures cannot: failures, being offline, an empty list and
/// first launch. A view that cannot build with that state fails here instead of on someone's machine.
@MainActor
final class ViewRenderTests: XCTestCase {
    private let settings = Preferences.shared

    private func pkg(
        _ name: String, manager: Manager = .npm, kind: String = "global", released: TimeInterval = 30 * 3600,
        security: Bool = false
    ) -> OutdatedPackage {
        var p = OutdatedPackage(
            manager: manager, name: name, installed: "1.0.0", latest: "2.0.0", kind: kind, extra: "")
        p.releaseDate = Date().addingTimeInterval(-released)
        p.dateSource = .registry
        p.updatedAt = Date().addingTimeInterval(-90 * 86_400)
        if security { p.advisories = ["GHSA-test", "CVE-2026-0001"] }
        return p
    }

    /// A Mac where several managers are unhappy and a security fix is waiting to settle.
    private func troubledStore() -> UpdateStore {
        let store = UpdateStore(persist: false)
        store.loadFixture(
            reports: [
                ManagerReport(manager: .brew, status: .error, message: "Error: permission denied @ dir_s_mkdir"),
                ManagerReport(manager: .npm, status: .error, message: "could not resolve host: registry.npmjs.org"),
                ManagerReport(manager: .gem, status: .ok, message: "admin"),
                ManagerReport(manager: .pip, status: .skipped, message: "turned off in Settings"),
                ManagerReport(manager: .conda, status: .missing, message: ""),
            ],
            packages: [
                pkg("lodash", released: 1800, security: true),
                pkg("psych", manager: .gem, kind: "system-gem"),
                pkg("Sequoia 15.4", manager: .macos),
                pkg("stable-aarch64-apple-darwin", manager: .rustup, kind: "toolchain"),
                pkg("jq", manager: .brew, kind: "formula"),
            ],
            log: "── Homebrew: jq ──\n$ brew upgrade -- jq\nError: permission denied\n✗ exited with status 1\n")
        return store
    }

    func testMenuBarPanelWithFailuresOfflineAndAWaitingSecurityFix() {
        let store = troubledStore()
        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 700))
    }

    func testMenuBarPanelWhenEverythingIsUpToDate() {
        let store = UpdateStore(persist: false)
        store.loadFixture(
            reports: Manager.allCases.map { .init(manager: $0, status: .ok, message: "") },
            packages: [], log: "")
        renderOffscreen(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 500))
    }

    func testMainWindowWithAFailedUpgradeInTheLog() {
        renderOffscreen(MainWindowView().environment(troubledStore()).environment(settings))
    }

    func testUpdatesListAndRightPaneWithNothingToShow() {
        let store = UpdateStore(persist: false)
        store.loadFixture(reports: [], packages: [], log: "")
        renderOffscreen(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 600))
        renderOffscreen(RightPane().environment(store).environment(settings), size: CGSize(width: 470, height: 600))
    }

    func testSettingsWithManagersDiscoveredAndMissing() {
        renderOffscreen(
            SettingsView().environment(troubledStore()).environment(settings), size: CGSize(width: 520, height: 700))
    }

    func testOnboardingIsDrawnOnFirstLaunch() {
        renderOffscreen(
            OnboardingView(close: {}).environment(UpdateStore.fixture()).environment(settings),
            size: CGSize(width: 560, height: 620))
    }

    /// A store with history, a log, an ignored package and a hidden system one: the states the
    /// screenshot fixture never reaches.
    private func busyStore() -> UpdateStore {
        let store = UpdateStore(persist: false)
        store.loadFixture(
            reports: [
                ManagerReport(manager: .brew, status: .ok, message: ""),
                ManagerReport(manager: .gem, status: .ok, message: "admin"),
                ManagerReport(manager: .npm, status: .error, message: "Error: EACCES"),
            ],
            packages: [
                pkg("lodash", released: 40 * 3600, security: true),
                pkg("jq", manager: .brew, kind: "formula"),
                pkg("psych", manager: .gem, kind: "system-gem"),
                pkg("fresh", released: 600),
                pkg("Sequoia 15.4", manager: .macos),
            ],
            log: (1...40).map { "line \($0) of streamed output" }.joined(separator: "\n"))
        for kind in [ActionRecord.Kind.upgrade, .remove, .ignore, .install] {
            store.history.add(
                ActionRecord(
                    kind: kind, manager: .npm, package: "lodash", detail: "1.0.0 → 2.0.0",
                    succeeded: kind != .remove,
                    // With output kept, the row offers to show it.
                    output: kind == .ignore ? nil : (1...12).map { "output line \($0)" }.joined(separator: "\n")))
        }
        return store
    }

    func testTheLogAndHistoryPanesWithContent() {
        let store = busyStore()
        renderOffscreen(
            LogView(tab: .constant(0)).environment(store).environment(settings), size: CGSize(width: 470, height: 560))
        renderOffscreen(
            HistoryView(tab: .constant(1)).environment(store).environment(settings),
            size: CGSize(width: 470, height: 560))
    }

    func testTheUpdatesListWithEverySortOfRow() {
        // Security, waiting, system, a hand-off to System Settings, and a failed manager, together.
        renderOffscreen(
            UpdatesView().environment(busyStore()).environment(settings), size: CGSize(width: 430, height: 700))
    }

    func testTheMenuBarPanelWithABusyStore() {
        renderOffscreen(
            MenuBarPanel().environment(busyStore()).environment(settings), size: CGSize(width: 320, height: 760))
    }

    func testTheWholeWindowWithContent() {
        renderOffscreen(MainWindowView().environment(busyStore()).environment(settings))
    }

    func testProblemRowInBothSizes() {
        let store = troubledStore()
        let report = ManagerReport(manager: .brew, status: .error, message: "Error: permission denied")
        renderOffscreen(ProblemRow(report: report).environment(store), size: CGSize(width: 420, height: 60))
        renderOffscreen(
            ProblemRow(report: report, compact: true).environment(store), size: CGSize(width: 320, height: 40))
    }
}
