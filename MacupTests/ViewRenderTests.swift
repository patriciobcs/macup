import SwiftUI
import XCTest

@testable import Macup

/// Draws each view offscreen, the way the screenshot renderer does. The screenshots only ever show a
/// healthy Mac, so these cover what the pictures cannot: failures, being offline, an empty list and
/// first launch. A view that cannot build with that state fails here instead of on someone's machine.
@MainActor
final class ViewRenderTests: XCTestCase {
    private let settings = Preferences.shared

    /// Hosts the view in a real (offscreen) window and forces a layout and display pass.
    private func render<V: View>(
        _ view: V, size: CGSize = CGSize(width: 900, height: 640),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        // A window made in code is released when closed, which over-releases it under ARC.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        defer { window.close() }
        guard let content = window.contentView,
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return XCTFail("the view produced nothing to draw", file: file, line: line) }
        content.cacheDisplay(in: content.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsHigh, 0, "the view drew no pixels", file: file, line: line)
    }

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
        render(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 700))
    }

    func testMenuBarPanelWhenEverythingIsUpToDate() {
        let store = UpdateStore(persist: false)
        store.loadFixture(
            reports: Manager.allCases.map { .init(manager: $0, status: .ok, message: "") },
            packages: [], log: "")
        render(MenuBarPanel().environment(store).environment(settings), size: CGSize(width: 320, height: 500))
    }

    func testMainWindowWithAFailedUpgradeInTheLog() {
        render(MainWindowView().environment(troubledStore()).environment(settings))
    }

    func testUpdatesListAndRightPaneWithNothingToShow() {
        let store = UpdateStore(persist: false)
        store.loadFixture(reports: [], packages: [], log: "")
        render(UpdatesView().environment(store).environment(settings), size: CGSize(width: 430, height: 600))
        render(RightPane().environment(store).environment(settings), size: CGSize(width: 470, height: 600))
    }

    func testSettingsWithManagersDiscoveredAndMissing() {
        render(SettingsView().environment(troubledStore()).environment(settings), size: CGSize(width: 520, height: 700))
    }

    func testOnboardingIsDrawnOnFirstLaunch() {
        render(
            OnboardingView(close: {}).environment(UpdateStore.fixture()).environment(settings),
            size: CGSize(width: 560, height: 620))
    }

    func testProblemRowInBothSizes() {
        let store = troubledStore()
        let report = ManagerReport(manager: .brew, status: .error, message: "Error: permission denied")
        render(ProblemRow(report: report).environment(store), size: CGSize(width: 420, height: 60))
        render(ProblemRow(report: report, compact: true).environment(store), size: CGSize(width: 320, height: 40))
    }
}
