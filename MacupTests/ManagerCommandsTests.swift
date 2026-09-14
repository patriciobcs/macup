import XCTest

@testable import Macup

/// The commands the app shows have to be the commands the scripts run, so they are read from the
/// scripts rather than written out a second time. These cover the reading and what it is used for.
final class ManagerCommandsTests: XCTestCase {
    private let sample = """
        check\tnpm\tnpm outdated -g --json
        update\tnpm\tnpm install -g {names}
        update_all\tnpm\tnpm update -g
        remove\tnpm\tnpm uninstall -g {name}
        check\tbrew\tbrew outdated --json=v2 {greedy}
        update\trustup_self\trustup self update
        """

    func testEveryPhaseOfAManagerIsRead() {
        let book = CommandBook(commandLines: sample)
        XCTAssertEqual(book[.npm].defaults[.check], "npm outdated -g --json")
        XCTAssertEqual(book[.npm].defaults[.update], "npm install -g {names}")
        XCTAssertEqual(book[.npm].defaults[.updateAll], "npm update -g")
        XCTAssertEqual(book[.npm].defaults[.remove], "npm uninstall -g {name}")
        XCTAssertEqual(book[.npm].phases, [.check, .update, .updateAll, .remove])
    }

    func testAManagerShowsOnlyThePhasesItHasACommandFor() {
        // Brew's removal is there in the real table; in this sample it is not, and nothing is invented.
        let book = CommandBook(commandLines: sample)
        XCTAssertEqual(book[.brew].phases, [.check])
        XCTAssertEqual(book[.go].phases, [], "a manager not in the table at all")
    }

    func testRustupsOwnUpdateIsNotAManager() {
        // "rustup_self" is a command, not a package manager, and must not turn into a row of its own.
        let book = CommandBook(commandLines: sample)
        XCTAssertNil(book.byManager.keys.first { $0.rawValue.contains("self") })
    }

    func testJunkLinesAreSkippedRatherThanCrashing() {
        let book = CommandBook(commandLines: "nonsense\nphase\tmanager\n\t\t\ncheck\tnotamanager\tls\n")
        XCTAssertEqual(book.byManager, [:])
    }

    func testTheKeyMatchesWhatTheScriptsLookUp() {
        // macup-commands.sh reads MACUP_CMD_<phase>_<manager>; if these drift, a replacement is ignored
        // silently and the default keeps running.
        XCTAssertEqual(CommandBook.key(.check, .npm), "MACUP_CMD_check_npm")
        XCTAssertEqual(CommandBook.key(.updateAll, .brew), "MACUP_CMD_update_all_brew")
    }

    func testCommandsThatCanRunAsRootAreNotEditable() {
        // MacUp never elevates a command that came from a setting, so those are shown, not offered.
        XCTAssertNotNil(Manager.port.notEditableReason)
        XCTAssertNotNil(Manager.gem.notEditableReason)
        XCTAssertNil(Manager.npm.notEditableReason)
    }

    func testTheRealScriptsAgreeWithTheModel() throws {
        // The table lives in the scripts; this is the one test that reads it, so a rename or a typo in
        // a phase name shows up here rather than as an empty panel in Settings.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Macup/Resources/Scripts/macup-scan.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [url.path, "--commands"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let book = CommandBook(commandLines: String(bytes: data, encoding: .utf8) ?? "")
        XCTAssertFalse(book[.npm].phases.isEmpty, "npm has commands")
        XCTAssertEqual(book[.npm].defaults[.check], "npm outdated -g --json")
        XCTAssertTrue(book[.go].defaults[.check] == nil, "checking Go reads GOBIN, it is not one command")
        XCTAssertTrue(book[.tools].defaults[.check] == nil, "nor is asking GitHub about each tool")
    }
}

/// Replacing a command, and getting back to the original.
@MainActor
final class CommandOverrideTests: XCTestCase {
    private let settings = Preferences.shared
    private var saved: [String: String] = [:]
    private let catalog = CommandCatalog.shared

    override func setUp() async throws {
        saved = settings.commandOverrides
        settings.commandOverrides = [:]
    }

    override func tearDown() async throws { settings.commandOverrides = saved }

    func testAReplacementIsKeptAndTypingTheOriginalBackForgetsIt() async {
        await catalog.loadIfNeeded()
        let original = catalog.book[.npm].defaults[.check]
        try? XCTSkipIf(original == nil)

        catalog.setCommand("npm outdated -g --json --depth=0", .check, .npm, settings: settings)
        XCTAssertTrue(catalog.isChanged(.check, .npm, settings: settings))
        XCTAssertEqual(catalog.command(.check, .npm, settings: settings), "npm outdated -g --json --depth=0")

        // Typing the built-in command back in is the same as never having changed it, so the row stops
        // saying "changed" and nothing is carried in the environment.
        catalog.setCommand(original ?? "", .check, .npm, settings: settings)
        XCTAssertFalse(catalog.isChanged(.check, .npm, settings: settings))
        XCTAssertEqual(settings.commandOverrides, [:])
    }

    func testAnEmptyFieldMeansTheBuiltInCommand() async {
        await catalog.loadIfNeeded()
        catalog.setCommand("something", .remove, .npm, settings: settings)
        catalog.setCommand("   ", .remove, .npm, settings: settings)
        XCTAssertEqual(settings.commandOverrides, [:], "an empty field is not a command, it is a reset")
    }

    func testAReplacementReachesTheScripts() async {
        // The scripts read MACUP_CMD_<phase>_<manager>; this is the step between the text field and
        // there, and it is the one that would fail silently by leaving the default running.
        settings.commandOverrides = ["check_npm": "npm outdated -g --json --depth=0"]
        let env = await ScriptRunner.environment(brewGreedy: false)
        XCTAssertEqual(env["MACUP_CMD_check_npm"], "npm outdated -g --json --depth=0")
    }

    func testNothingIsCarriedWhenNothingWasChanged() async {
        let env = await ScriptRunner.environment(brewGreedy: false)
        XCTAssertNil(env.first { $0.key.hasPrefix("MACUP_CMD_") }, "the scripts use their own defaults")
    }
}
