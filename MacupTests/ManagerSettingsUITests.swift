import SwiftUI
import XCTest

@testable import Macup

/// Settings and onboarding: which managers are shown, and the commands each one runs.
@MainActor
final class ManagerSettingsUITests: StubScriptCase {
    func testSettingsAndOnboardingWithManagersFoundAndMissing() {
        // The lists separate what is on this Mac from what is not, and the tools row breaks apart into
        // the individual tools, so both halves need to draw with a mixture of the two.
        let store = store()
        store.loadFixture(
            reports: [
                ManagerReport(manager: .brew, status: .ok, message: "", version: "4.2.1"),
                ManagerReport(manager: .npm, status: .ok, message: ""),
                ManagerReport(manager: .tools, status: .ok, message: ""),
                ManagerReport(manager: .conda, status: .missing, message: ""),
                ManagerReport(manager: .port, status: .missing, message: ""),
                ManagerReport(manager: .mas, status: .missing, message: ""),
            ], packages: [pkg("lodash")], log: "",
            tools: [
                ToolReport(name: "uv", presence: .found, detail: "0.12.13"),
                ToolReport(name: "bun", presence: .managed, detail: "Homebrew"),
                ToolReport(name: "deno", presence: .missing, detail: ""),
            ])

        renderOffscreen(
            SettingsView().environment(store).environment(settings), size: CGSize(width: 520, height: 900))
        renderOffscreen(
            OnboardingView(close: {}).environment(store).environment(settings),
            size: CGSize(width: 560, height: 700))
    }

    func testTheCommandsForAManagerDraw() {
        // Including a manager whose commands are shown but cannot be edited, and one MacUp checks by
        // reading files rather than by running anything.
        let store = store()
        store.loadFixture(reports: [], packages: [], log: "")
        // Drawn inside a Form, which is where these live: a bare hosting view measures its content
        // differently and says nothing about how the settings window behaves.
        // npm is the ordinary case, MacPorts is shown but not editable, Go and the self-installed
        // tools have phases MacUp does by procedure and has to explain instead of offering an editor.
        for manager in [Manager.npm, .port, .go, .tools, .rustup] {
            renderOffscreen(
                Form { ManagerCommandsView(manager: manager) }
                    .formStyle(.grouped).environment(store).environment(settings),
                size: CGSize(width: 480, height: 420))
        }
    }

    func testACommandThatWasChangedShowsAsChanged() async {
        // A replaced command gets a badge and a Reset, which is a different arrangement of the row.
        let store = store()
        store.loadFixture(reports: [], packages: [], log: "")
        await CommandCatalog.shared.loadIfNeeded()
        settings.commandOverrides = ["check_npm": "npm outdated -g --json --depth=0"]
        defer { settings.commandOverrides = [:] }

        renderOffscreen(
            Form { ManagerCommandsView(manager: .npm) }
                .formStyle(.grouped).environment(store).environment(settings),
            size: CGSize(width: 480, height: 420))
    }

    func testTheToolsListInEveryState() {
        let store = store()
        // All three kinds at once, then the two edge cases: nothing found, and nothing scanned yet.
        store.loadFixture(
            reports: [], packages: [], log: "",
            tools: [
                ToolReport(name: "uv", presence: .found, detail: "0.12.13"),
                ToolReport(name: "bun", presence: .managed, detail: "Homebrew"),
                ToolReport(name: "deno", presence: .missing, detail: ""),
            ])
        renderOffscreen(
            Form { SelfInstalledToolsList() }.formStyle(.grouped).environment(store).environment(settings),
            size: CGSize(width: 480, height: 260))

        store.loadFixture(
            reports: [], packages: [], log: "",
            tools: [ToolReport(name: "deno", presence: .missing, detail: "")])
        renderOffscreen(
            Form { SelfInstalledToolsList() }.formStyle(.grouped).environment(store).environment(settings),
            size: CGSize(width: 480, height: 260))

        store.loadFixture(reports: [], packages: [], log: "")
        renderOffscreen(
            Form { SelfInstalledToolsList() }.formStyle(.grouped).environment(store).environment(settings),
            size: CGSize(width: 480, height: 260))
    }

    func testTryingOutACheckCommandReportsWhatCameBack() async throws {
        // The Test button's path end to end: the stub scan stands in for the manager, and what comes
        // back is what the button would show.
        try keepOutdated("lodash")
        let store = store()
        _ = store

        let scan = await ScriptRunner.testCheck(
            manager: .npm, command: "npm outdated -g --json", brewGreedy: false)

        XCTAssertEqual(scan.packages.map(\.name), ["lodash"])
        XCTAssertEqual(CommandTest.message(for: scan, manager: .npm), "✓ understood 1 package")
    }

    func testTheRunningRowSaysWhatIsHappening() async throws {
        // The history pane leads with a row for work in flight, which is all that is left of the output
        // pane. It has to name the thing being worked on, not just spin.
        try script("macup-upgrade", "sleep 1.2; print done")
        let store = store()
        let package = pkg("lodash")
        store.loadFixture(reports: [], packages: [package], log: "")

        let work = Task { await store.upgrade(package) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(store.activityTitle, "Updating lodash")

        await work.value
        XCTAssertFalse(store.isBusy, "and the row goes when there is nothing to report")
    }

    func testTheRunningRowCountsManagersWhileScanning() async throws {
        let store = store()
        let scan = Task { await store.scan(managers: [.npm, .cargo, .gem]) }
        try await Task.sleep(for: .milliseconds(120))
        if store.isScanning {
            XCTAssertEqual(store.activityDetail?.contains("package managers checked"), true)
        }
        await scan.value
        XCTAssertNil(store.activityDetail, "nothing to count once it has finished")
    }

    func testShowDetailsNamesThePackageSoTheHistoryCanOpenIt() {
        // With the output pane gone, "show details" opens that action in the history instead.
        let store = store()
        let package = pkg("vite")
        store.loadFixture(reports: [], packages: [package], log: "")

        store.reveal(package)

        XCTAssertEqual(store.revealTarget, "npm:vite")
        XCTAssertEqual(store.revealCount, 1)
    }

    func testTheHistoryPaneWithRecordsAcrossSeveralDays() {
        // Grouped by day, an expandable row for what a command printed, and one old enough that its
        // output has been dropped and so has no arrow.
        let store = store()
        let now = Date()
        store.loadFixture(reports: [], packages: [], log: "")
        store.history.add([
            ActionRecord(
                id: UUID(), date: now, kind: .upgrade, manager: .brew, package: "jq", detail: "1.7 → 1.8",
                succeeded: true, output: "==> Upgrading jq\n🍺 done"),
            ActionRecord(
                id: UUID(), date: now.addingTimeInterval(-3600), kind: .upgrade, manager: .npm,
                package: "lodash", detail: "Error: EACCES", succeeded: false, output: "npm ERR! EACCES"),
            ActionRecord(
                id: UUID(), date: now.addingTimeInterval(-26 * 3600), kind: .remove, manager: .cargo,
                package: "old", detail: "0.1.0", succeeded: true, output: nil),
            ActionRecord(
                id: UUID(), date: now.addingTimeInterval(-9 * 86_400), kind: .ignore, manager: .gem,
                package: "psych", detail: "", succeeded: true, output: nil),
        ])

        renderOffscreen(
            HistoryView().environment(store).environment(settings), size: CGSize(width: 470, height: 620))
    }

    func testTheHistoryPaneWhileSomethingIsRunning() async throws {
        // The live row and its output, which is what replaced the output pane.
        try script("macup-upgrade", "print '==> upgrading'; sleep 1.5; print done")
        let store = store()
        let package = pkg("lodash")
        store.loadFixture(reports: [], packages: [package], log: "==> upgrading lodash\nresolving…")

        let work = Task { await store.upgrade(package) }
        try await Task.sleep(for: .milliseconds(350))
        renderOffscreen(
            HistoryView().environment(store).environment(settings), size: CGSize(width: 470, height: 620))
        await work.value
    }

    func testTheHistoryPaneWithNothingRecordedAndNothingRunning() {
        let store = store()
        store.loadFixture(reports: [], packages: [], log: "")
        XCTAssertFalse(store.isBusy)
        renderOffscreen(
            HistoryView().environment(store).environment(settings), size: CGSize(width: 470, height: 400))
    }

    func testARecordOpenedToShowWhatTheCommandPrinted() {
        // Expansion is held by the pane, so the row can be drawn open directly.
        let store = store()
        store.loadFixture(reports: [], packages: [], log: "")
        let record = ActionRecord(
            kind: .upgrade, manager: .brew, package: "jq", detail: "1.7 → 1.8", succeeded: true,
            output: String(repeating: "==> Pouring jq--1.8.arm64.bottle.tar.gz\n", count: 40))

        renderOffscreen(
            List { HistoryRow(record: record, expanded: true, toggle: {}) }
                .environment(store).environment(settings),
            size: CGSize(width: 470, height: 420))
        renderOffscreen(
            List { HistoryRow(record: record, expanded: false, toggle: {}) }
                .environment(store).environment(settings),
            size: CGSize(width: 470, height: 200))
    }

    func testTheRunningRowOpenedToShowTheLiveOutput() {
        // The live log, which is the part of the old output pane worth keeping.
        let store = store()
        store.loadFixture(
            reports: [], packages: [],
            log: String(repeating: "==> resolving dependencies\n", count: 60))

        renderOffscreen(
            List { RunningRow(expanded: .constant(true)) }.environment(store).environment(settings),
            size: CGSize(width: 470, height: 460))
        renderOffscreen(
            List { RunningRow(expanded: .constant(false)) }.environment(store).environment(settings),
            size: CGSize(width: 470, height: 200))
    }
}
