import XCTest

@testable import Macup

/// Every way a person might type a command, without running any of them.
final class CommandLineRequestTests: XCTestCase {
    private let tool = "/opt/homebrew/bin/macup"
    private let app = "/Applications/MacUp.app/Contents/MacOS/MacUp"

    private func parse(_ args: String..., as path: String? = nil) -> CommandLineRequest.Parsed {
        CommandLineRequest.parse([path ?? tool] + args)
    }

    func testTheToolOnItsOwnShowsTheStatus() {
        XCTAssertEqual(parse(), .run(.init(command: .status)))
        XCTAssertEqual(parse("--json"), .run(.init(command: .status, json: true)))
    }

    func testTheAppLaunchesAsTheAppWhateverLaunchServicesPasses() {
        XCTAssertEqual(parse(as: app), .app)
        XCTAssertEqual(parse("-NSDocumentRevisionsDebugMode", "YES", as: app), .app)
        XCTAssertEqual(parse("-psn_0_12345", as: app), .app)
    }

    func testTheAppsOwnExecutableStillTakesCommands() {
        XCTAssertEqual(parse("upgrade", as: app), .run(.init(command: .upgrade)))
        XCTAssertEqual(parse("--version", as: app), .run(.init(command: .version)))
    }

    func testCommandsWithAndWithoutDashes() {
        for spelling in ["upgrade", "--upgrade", "update", "--update"] {
            XCTAssertEqual(parse(spelling), .run(.init(command: .upgrade)), spelling)
        }
        XCTAssertEqual(parse("list"), .run(.init(command: .status)))
        XCTAssertEqual(parse("-h"), .run(.init(command: .help)))
        XCTAssertEqual(parse("upgrade", "--help"), .run(.init(command: .help)))
        XCTAssertEqual(parse("-v"), .run(.init(command: .version)))
    }

    func testOptionsAndManagersInUpdateAllOrder() {
        // Typed out of order, run in the order Update All uses: rustup before cargo.
        XCTAssertEqual(
            parse("upgrade", "cargo", "Homebrew", "rustup", "--now", "-n", "--skip-admin"),
            .run(
                .init(command: .upgrade, managers: [.brew, .rustup, .cargo], now: true, dryRun: true, skipAdmin: true)))
        XCTAssertEqual(parse("check", "npm", "npm"), .run(.init(command: .check, managers: [.npm])))
    }

    func testManagersByTheNamesPeopleUse() {
        XCTAssertEqual(Manager.named("brew"), .brew)
        XCTAssertEqual(Manager.named("homebrew"), .brew)
        XCTAssertEqual(Manager.named("RubyGems"), .gem)
        XCTAssertEqual(Manager.named("app-store"), .mas)
        XCTAssertEqual(Manager.named("macports"), .port)
        XCTAssertNil(Manager.named("left-pad"))
    }

    func testMistakesAreExplainedNotGuessedAt() {
        guard case .invalid(let unknown) = parse("upgarde") else { return XCTFail("a typo is not a command") }
        XCTAssertTrue(unknown.contains("upgarde"))
        guard case .invalid(let manager) = parse("upgrade", "left-pad") else { return XCTFail("not a manager") }
        XCTAssertTrue(manager.contains("npm"), "it lists the managers it knows")
        guard case .invalid = parse("upgrade", "--force") else { return XCTFail("an unknown option") }
        guard case .invalid = parse("ignore") else { return XCTFail("ignore needs a package") }
        XCTAssertEqual(parse("ignore", "npm:left-pad"), .run(.init(command: .ignore, names: ["npm:left-pad"])))
    }
}

/// The status as text and as JSON, from the same lists the menu bar shows.
@MainActor
final class CommandLineReportTests: StubScriptCase {
    private func report() -> CommandLineReport {
        settings.minAgeHours = 24
        settings.securityMinAgeHours = 4
        let store = store()
        var fresh = pkg("happy")
        fresh.releaseDate = Date().addingTimeInterval(-3600)
        var fix = pkg("lodash")
        fix.advisories = ["GHSA-test"]
        store.loadFixture(
            reports: [ManagerReport(manager: .pnpm, status: .error, message: "pnpm outdated failed")],
            packages: [fix, pkg("jq", manager: .brew, kind: "formula"), fresh], log: "")
        return CommandLineReport(store: store)
    }

    func testTheTextNamesWhatIsReadyWhatWaitsAndWhatFailed() {
        let text = report().text()
        XCTAssertTrue(text.hasPrefix("2 updates ready"), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "Homebrew")).lowerBound, try XCTUnwrap(text.range(of: "npm")).lowerBound,
            "grouped in Update All's order")
        XCTAssertTrue(text.contains("lodash  1.0.0 → 2.0.0"), text)
        XCTAssertTrue(text.contains("security fix"), text)
        XCTAssertTrue(text.contains("Waiting out the minimum age (1)"), text)
        XCTAssertTrue(text.contains("ready in 22h") || text.contains("ready in 23h"), text)
        XCTAssertTrue(text.contains("pnpm  pnpm outdated failed"), text)
        XCTAssertTrue(text.contains("macup upgrade"), text)
        XCTAssertFalse(text.contains("\u{1B}["), "no colour unless writing to a terminal")
    }

    func testJSONIsForScripts() throws {
        let data = try XCTUnwrap(report().json().data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ready = try XCTUnwrap(object["ready"] as? [[String: Any]])
        XCTAssertEqual(ready.map { $0["name"] as? String }, ["lodash", "jq"])
        XCTAssertEqual(ready.first?["security"] as? Bool, true)
        let waiting = try XCTUnwrap(object["waiting"] as? [[String: Any]])
        XCTAssertNotNil(waiting.first?["readyAt"] as? String, "when it will be ready, as an ISO date")
        XCTAssertEqual((object["problems"] as? [[String: Any]])?.first?["manager"] as? String, "pnpm")
    }

    func testColourOnlyForATerminalThatWantsIt() {
        XCTAssertEqual(TerminalStyle.plain.bold("x"), "x")
        XCTAssertEqual(TerminalStyle(enabled: true).bold("x"), "\u{1B}[1mx\u{1B}[0m")
        XCTAssertFalse(TerminalStyle.forOutput(environment: ["NO_COLOR": "1"]).enabled)
        XCTAssertFalse(TerminalStyle.forOutput(environment: ["TERM": "dumb"]).enabled)
    }
}

/// The commands themselves, against stub scripts: the same store, history and rules as the app.
@MainActor
final class CommandLineToolTests: StubScriptCase {
    private func run(_ request: CommandLineRequest, _ store: UpdateStore) async -> Int32 {
        await CommandLineTool.run(request, store: store)
    }

    func testUpgradeRunsWhatIsReadyAndRecordsIt() async {
        settings.minAgeHours = 24
        let store = store(commandLine: true)
        var fresh = pkg("happy")
        fresh.releaseDate = Date()
        store.loadFixture(reports: [], packages: [pkg("lodash"), pkg("boom-pkg"), fresh], log: "")

        let code = await run(.init(command: .upgrade), store)

        XCTAssertEqual(code, CommandLineTool.failed, "boom-pkg failed, and the exit code says so")
        XCTAssertEqual(Set(store.history.records.map(\.package)), ["lodash", "boom-pkg"])
        XCTAssertFalse(store.log.contains("happy"), "a fresh release waits, as it does in the app")
    }

    func testNowIncludesWhatIsStillWaiting() async {
        settings.minAgeHours = 24
        let store = store(commandLine: true)
        var fresh = pkg("happy")
        fresh.releaseDate = Date()
        store.loadFixture(reports: [], packages: [fresh], log: "")

        let nothingReady = await run(.init(command: .upgrade), store)
        XCTAssertEqual(nothingReady, 0)
        XCTAssertEqual(store.history.records, [], "nothing ready, nothing run")
        let withNow = await run(.init(command: .upgrade, now: true), store)
        XCTAssertEqual(withNow, 0)
        XCTAssertEqual(store.history.records.map(\.package), ["happy"])
    }

    func testNamingManagersNarrowsTheRun() async {
        let store = store(commandLine: true)
        store.loadFixture(
            reports: [], packages: [pkg("lodash"), pkg("jq", manager: .brew, kind: "formula")], log: "")

        await _ = run(.init(command: .upgrade, managers: [.brew]), store)

        XCTAssertEqual(store.history.records.map(\.package), ["jq"])
    }

    func testDryRunChangesNothing() async {
        let store = store(commandLine: true)
        store.loadFixture(reports: [], packages: [pkg("lodash")], log: "")

        let dryRun = await run(.init(command: .upgrade, dryRun: true), store)
        XCTAssertEqual(dryRun, 0)
        XCTAssertEqual(store.history.records, [])
    }

    func testPasswordsAreNeverAskedForWithoutSomeoneThere() async {
        let store = store(commandLine: true)
        store.loadFixture(
            reports: [ManagerReport(manager: .gem, status: .ok, message: "admin")],
            packages: [pkg("rake", manager: .gem, kind: "gem"), pkg("lodash")], log: "")

        await _ = run(.init(command: .upgrade, skipAdmin: true), store)

        XCTAssertEqual(store.history.records.map(\.package), ["lodash"], "the gem would need a password")
    }

    func testMacOSUpdatesOnlyWhenAskedForByName() async {
        let store = store(commandLine: true)  // macOS updates are shown in these tests
        store.loadFixture(reports: [], packages: [pkg("Sequoia", manager: .macos), pkg("lodash")], log: "")

        await _ = run(.init(command: .upgrade), store)
        XCTAssertEqual(store.history.records.map(\.package), ["lodash"])
    }

    func testIgnoreAndUnignoreUseTheAppsList() async {
        let store = store(commandLine: true)
        store.loadFixture(reports: [], packages: [pkg("lodash")], log: "")

        let ignored = await run(.init(command: .ignore, names: ["lodash"]), store)
        XCTAssertEqual(ignored, 0)
        XCTAssertEqual(settings.ignoredPackages, ["npm:lodash"])
        XCTAssertEqual(store.visible, [], "gone from the menu bar too")
        let unknown = await run(.init(command: .ignore, names: ["nothere"]), store)
        XCTAssertEqual(unknown, CommandLineTool.failed)
        let unignored = await run(.init(command: .unignore, names: ["lodash"]), store)
        XCTAssertEqual(unignored, 0)
        XCTAssertEqual(settings.ignoredPackages, [])
    }

    func testTheRunningAppPicksUpWhatTheCommandLineSaved() async throws {
        try keepOutdated("left-pad")
        let app = UpdateStore(persist: true, directory: directory, installSource: .direct)
        let terminal = UpdateStore(persist: true, directory: directory, installSource: .direct, commandLine: true)

        await terminal.scan(managers: [.npm])
        terminal.history.add(
            ActionRecord(kind: .upgrade, manager: .npm, package: "lodash", detail: "", succeeded: true))
        XCTAssertEqual(app.packages, [], "the app has not looked yet")

        app.reloadFromDisk()
        XCTAssertEqual(app.packages.map(\.name), ["left-pad"])
        // Saved as an ISO date, so to the second.
        XCTAssertEqual(
            app.lastScan?.timeIntervalSince1970 ?? 0, terminal.lastScan?.timeIntervalSince1970 ?? -9, accuracy: 1)
        XCTAssertEqual(app.history.records.map(\.package), ["lodash"])
    }

    func testACommandLineRunNeitherAnnouncesNorInstallsOnItsOwn() async throws {
        try reportOutdatedToolchain()
        settings.autoUpdate = true
        let store = store(commandLine: true)

        await store.scan(managers: [.rustup])

        XCTAssertEqual(store.history.records, [], "automatic updates belong to the app's schedule")
        XCTAssertNil(store.lastAutoUpdate)
    }
}

/// The app and the command line never change packages at the same time.
@MainActor
final class UpdateLockTests: StubScriptCase {
    func testOneHolderPerProcessAndOthersAreTurnedAway() {
        let url = directory.appendingPathComponent("update.lock")
        let mine = UpdateLock(url: url)
        // A second lock on the same file stands in for another process: flock is per open file.
        let other = UpdateLock(url: url)
        XCTAssertTrue(mine.tryAcquire())
        XCTAssertTrue(mine.tryAcquire(), "the same process taking it twice is not a conflict")
        XCTAssertFalse(other.tryAcquire())
        mine.release()
        XCTAssertFalse(other.tryAcquire(), "still held once")
        mine.release()
        XCTAssertTrue(other.tryAcquire())
        other.release()
    }

    func testTheAppRefusesToUpdateWhileTheCommandLineIs() async throws {
        try keepOutdated("lodash")  // so the rescan after the refusal does not clear its reason
        let store = store()
        store.loadFixture(reports: [], packages: [pkg("lodash")], log: "")
        let commandLine = UpdateLock(url: directory.appendingPathComponent("update.lock"))
        XCTAssertTrue(commandLine.tryAcquire())

        await store.upgrade(pkg("lodash"))
        XCTAssertFalse(store.log.contains("upgraded lodash"))
        XCTAssertNotNil(store.failure(for: pkg("lodash")), "and says why")

        commandLine.release()
        await store.upgrade(pkg("lodash"))
        XCTAssertTrue(store.log.contains("upgraded lodash"))
    }

    func testTheCommandLineWaitsForTheApp() async {
        let app = UpdateLock(url: directory.appendingPathComponent("update.lock"))
        XCTAssertTrue(app.tryAcquire())
        let store = store(commandLine: true)
        store.loadFixture(reports: [], packages: [pkg("lodash")], log: "")

        let run = Task { await CommandLineTool.run(.init(command: .upgrade), store: store) }
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(store.history.records, [], "nothing ran while the app held the lock")
        app.release()

        let finished = await run.value
        XCTAssertEqual(finished, 0)
        XCTAssertEqual(store.history.records.map(\.package), ["lodash"])
    }
}

/// The link Settings puts on the PATH.
final class CommandLineInstallerTests: XCTestCase {
    private var home = URL(fileURLWithPath: "/tmp")
    private var app = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macup-cli-\(UUID().uuidString)")
        app = home.appendingPathComponent("Apps/MacUp.app/Contents/MacOS/MacUp")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app.path, contents: Data())
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testSuggestsTheUsersOwnBinWhenItIsOnThePath() {
        let bin = home.appendingPathComponent(".local/bin").path
        XCTAssertEqual(
            CommandLineInstaller.state(path: "\(bin):/usr/bin", home: home.path, homebrewInstall: false),
            .notInstalled(suggested: URL(fileURLWithPath: bin).appendingPathComponent("macup"), onPath: true))
        if case .notInstalled(_, let onPath) = CommandLineInstaller.state(
            path: "/usr/bin", home: home.path, homebrewInstall: false)
        {
            XCTAssertFalse(onPath, "and says so when it is not")
        } else {
            XCTFail("nothing is installed")
        }
    }

    func testInstallThenRemove() throws {
        let bin = home.appendingPathComponent(".local/bin")
        let link = bin.appendingPathComponent("macup")
        try CommandLineInstaller.install(executable: app, at: link)
        XCTAssertEqual(
            CommandLineInstaller.state(path: bin.path, home: home.path, homebrewInstall: false), .installed(link))
        try CommandLineInstaller.remove(link)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testSomeoneElsesMacupIsLeftAlone() throws {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let other = bin.appendingPathComponent("macup")
        FileManager.default.createFile(atPath: other.path, contents: Data("#!/bin/sh\n".utf8))
        XCTAssertEqual(
            CommandLineInstaller.state(path: bin.path, home: home.path, homebrewInstall: false), .taken(other))
        try CommandLineInstaller.remove(other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "only a link is ever removed")
    }
}

/// The real executable, started the way a terminal starts it.
final class CommandLineProcessTests: XCTestCase {
    /// Exit status, standard output and standard error.
    private func run(_ executable: URL, _ args: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        // Not the test runner's environment: that would inject XCTest into the child as well. A
        // coverage build writes its profile wherever it is told, which here is nowhere.
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LLVM_PROFILE_FILE": "/dev/null"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(bytes: stdout, encoding: .utf8) ?? "",
            String(bytes: stderr, encoding: .utf8) ?? ""
        )
    }

    func testTheAppAnswersAsTheCommandLineAndThroughALink() throws {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let (code, out, _) = try run(executable, ["version"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, "MacUp \(UpdateStore.bundleVersion)\n")

        // Linked as `macup`, as Homebrew does: it still finds the app around it.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macup-link-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("macup")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertEqual(try run(link, ["--version"]).1, out)

        let (usage, _, message) = try run(link, ["upgarde"])
        XCTAssertEqual(usage, CommandLineTool.usageError)
        XCTAssertTrue(message.contains("Unknown command"), message)
    }
}
