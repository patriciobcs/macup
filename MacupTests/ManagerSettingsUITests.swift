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
}
