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

    func testEveryPhaseEitherHasACommandOrSaysWhyNot() throws {
        // The panel shows all four phases for every manager. A phase with no command has to explain
        // itself, or it reads as something MacUp forgot to do.
        let book = try Self.realBook()
        for manager in Manager.allCases {
            for phase in CommandPhase.allCases {
                let hasCommand = book[manager].defaults[phase] != nil
                let reason = manager.noCommandReason(phase)
                XCTAssertTrue(
                    hasCommand || reason != nil,
                    "\(manager.rawValue) has neither a \(phase.rawValue) command nor a reason")
            }
        }
    }

    func testWhyCheckingIsNotOneCommandIsSpelledOut() {
        XCTAssertEqual(Manager.go.noCommandReason(.check)?.contains("GOBIN"), true)
        XCTAssertEqual(Manager.tools.noCommandReason(.check)?.contains("GitHub"), true)
        XCTAssertNil(Manager.npm.noCommandReason(.check), "npm has a command, so there is nothing to explain")
    }

    func testWhatCannotBeUninstalledSaysSo() {
        for manager in [Manager.rustup, .mas, .macos, .tools, .mise, .conda] {
            XCTAssertNotNil(manager.noCommandReason(.remove), "\(manager.rawValue) explains itself")
        }
        XCTAssertNil(Manager.npm.noCommandReason(.remove))
    }

    func testTheReasonNamesTheManagerItIsAbout() {
        // A blanket sentence would be read as being about all of them at once.
        XCTAssertEqual(Manager.port.notEditableReason?.contains("MacPorts"), true)
        XCTAssertEqual(Manager.gem.notEditableReason?.contains("RubyGems"), true)
    }

    func testEveryPhaseIsNamedForAPerson() {
        for phase in CommandPhase.allCases {
            XCTAssertFalse(phase.title.isEmpty)
            XCTAssertFalse(phase.title.contains("_"), "\(phase.rawValue) shows a raw value, not a name")
        }
        XCTAssertNotNil(CommandPhase.check.note, "checking is the one with a caveat worth stating")
        XCTAssertNil(CommandPhase.remove.note)
    }

    func testOnlyThePlaceholdersAManagerUsesAreExplained() {
        // The legend under a manager's commands is about that manager. Listing all seven everywhere
        // would be noise, and would suggest a command takes something it does not.
        let brew = CommandPlaceholder.used(in: [
            "brew outdated --json=v2 {greedy}", "brew upgrade {greedy} {kind} -- {name}",
        ])
        XCTAssertEqual(brew.map(\.name), ["name", "greedy", "kind"], "in a fixed order, not reshuffled")

        XCTAssertEqual(CommandPlaceholder.used(in: ["npm update -g"]).map(\.name), [])
        XCTAssertEqual(
            CommandPlaceholder.used(in: ["{python} install --upgrade {user} {name}"]).map(\.name),
            ["name", "python", "user"])
    }

    func testEveryPlaceholderInTheRealCommandsHasAMeaning() throws {
        // A placeholder nobody explained reads as a typo in the command.
        let book = try Self.realBook()
        let commands = book.byManager.values.flatMap { $0.defaults.values }
        let known = Set(CommandPlaceholder.meanings.map(\.name))
        for command in commands {
            for part in command.components(separatedBy: "{").dropFirst() {
                let name = String(part.prefix(while: { $0 != "}" }))
                XCTAssertTrue(known.contains(name), "{\(name)} in \"\(command)\" has no explanation")
            }
        }
    }

    func testCommandsThatCanRunAsRootAreNotEditable() {
        // MacUp never elevates a command that came from a setting, so those are shown, not offered.
        XCTAssertNotNil(Manager.port.notEditableReason)
        XCTAssertNotNil(Manager.gem.notEditableReason)
        XCTAssertNil(Manager.npm.notEditableReason)
    }

    /// The table as the scripts define it, so tests check the real thing rather than a copy.
    static func realBook() throws -> CommandBook {
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
        return CommandBook(commandLines: String(bytes: data, encoding: .utf8) ?? "")
    }

    func testTheRealScriptsAgreeWithTheModel() throws {
        // The table lives in the scripts, so a rename or a typo in a phase name shows up here rather
        // than as an empty panel in Settings.
        let book = try Self.realBook()
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

/// What trying out a check command reports back.
final class CommandTestMessageTests: XCTestCase {
    func testACommandThatFailedSaysWhat() {
        let scan = ScanResult(
            reports: [ManagerReport(manager: .npm, status: .error, message: "npm outdated failed: EACCES")],
            packages: [])
        XCTAssertEqual(CommandTest.message(for: scan, manager: .npm), "✗ npm outdated failed: EACCES")
    }

    func testACommandThatWorkedCountsWhatItFound() {
        let scan = ScanResult(
            reports: [ManagerReport(manager: .npm, status: .ok, message: "")],
            packages: [
                OutdatedPackage(manager: .npm, name: "a", installed: "1", latest: "2", kind: "global", extra: ""),
                OutdatedPackage(manager: .npm, name: "b", installed: "1", latest: "2", kind: "global", extra: ""),
            ])
        XCTAssertEqual(CommandTest.message(for: scan, manager: .npm), "✓ understood 2 packages")
    }

    func testOnePackageIsNotCalledOnePackages() {
        let scan = ScanResult(
            reports: [],
            packages: [
                OutdatedPackage(manager: .npm, name: "a", installed: "1", latest: "2", kind: "global", extra: "")
            ])
        XCTAssertEqual(CommandTest.message(for: scan, manager: .npm), "✓ understood 1 package")
    }

    func testNothingUnderstoodOffersBothExplanations() {
        // Up to date and unreadable output look the same from here, so the message says so instead of
        // picking one. Claiming "nothing to update" would be the more comfortable lie.
        let message = CommandTest.message(
            for: ScanResult(reports: [ManagerReport(manager: .npm, status: .ok, message: "")], packages: []),
            manager: .npm)
        XCTAssertTrue(message.contains("nothing to update"))
        XCTAssertTrue(message.contains("not in the shape MacUp reads"))
    }

    func testAnotherManagersErrorIsNotReportedAsThisOnes() {
        let scan = ScanResult(
            reports: [ManagerReport(manager: .brew, status: .error, message: "brew broke")],
            packages: [
                OutdatedPackage(manager: .npm, name: "a", installed: "1", latest: "2", kind: "global", extra: "")
            ])
        XCTAssertEqual(CommandTest.message(for: scan, manager: .npm), "✓ understood 1 package")
    }
}

/// Preferences are the app's memory between launches, so each one has to survive the round trip.
@MainActor
final class PreferencesRoundTripTests: XCTestCase {
    private let settings = Preferences.shared
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        saved = [
            "minAge": settings.minAgeHours, "securityMinAge": settings.securityMinAgeHours,
            "interval": settings.checkIntervalHours, "greedy": settings.brewGreedy,
            "notify": settings.notificationsEnabled, "auto": settings.autoUpdate,
            "autoInterval": settings.autoUpdateIntervalHours, "disabled": settings.disabledManagers,
            "ignored": settings.ignoredPackages, "hideSystem": settings.hideSystemPackages,
            "onboarded": settings.hasOnboarded, "count": settings.showMenuBarCount,
            "overrides": settings.commandOverrides,
        ]
    }

    override func tearDown() async throws {
        settings.minAgeHours = saved["minAge"] as? Double ?? 24
        settings.securityMinAgeHours = saved["securityMinAge"] as? Double ?? 4
        settings.checkIntervalHours = saved["interval"] as? Double ?? 6
        settings.brewGreedy = saved["greedy"] as? Bool ?? false
        settings.notificationsEnabled = saved["notify"] as? Bool ?? true
        settings.autoUpdate = saved["auto"] as? Bool ?? false
        settings.autoUpdateIntervalHours = saved["autoInterval"] as? Double ?? 24
        settings.disabledManagers = saved["disabled"] as? Set<Manager> ?? []
        settings.ignoredPackages = saved["ignored"] as? Set<String> ?? []
        settings.hideSystemPackages = saved["hideSystem"] as? Bool ?? true
        settings.hasOnboarded = saved["onboarded"] as? Bool ?? false
        settings.showMenuBarCount = saved["count"] as? Bool ?? true
        settings.commandOverrides = saved["overrides"] as? [String: String] ?? [:]
    }

    func testEverySettingIsWrittenWhereItCanBeReadBack() {
        let d = UserDefaults.standard
        settings.minAgeHours = 7
        settings.securityMinAgeHours = 3
        settings.checkIntervalHours = 9
        settings.brewGreedy = true
        settings.notificationsEnabled = false
        settings.autoUpdate = true
        settings.autoUpdateIntervalHours = 48
        settings.hideSystemPackages = false
        settings.hasOnboarded = true
        settings.showMenuBarCount = false
        settings.disabledManagers = [.npm, .brew]
        settings.ignoredPackages = ["npm:left-pad"]
        settings.commandOverrides = ["check_npm": "npm outdated -g --json --depth=0"]

        XCTAssertEqual(d.double(forKey: "minAgeHours"), 7)
        XCTAssertEqual(d.double(forKey: "securityMinAgeHours"), 3)
        XCTAssertEqual(d.double(forKey: "checkIntervalHours"), 9)
        XCTAssertTrue(d.bool(forKey: "brewGreedy"))
        XCTAssertFalse(d.bool(forKey: "notificationsEnabled"))
        XCTAssertTrue(d.bool(forKey: "autoUpdate"))
        XCTAssertEqual(d.double(forKey: "autoUpdateIntervalHours"), 48)
        XCTAssertFalse(d.bool(forKey: "hideSystemPackages"))
        XCTAssertTrue(d.bool(forKey: "hasOnboarded"))
        XCTAssertFalse(d.bool(forKey: "showMenuBarCount"))
        XCTAssertEqual(d.stringArray(forKey: "disabledManagers"), ["brew", "npm"], "stored sorted")
        XCTAssertEqual(d.stringArray(forKey: "ignoredPackages"), ["npm:left-pad"])
        XCTAssertEqual(
            d.dictionary(forKey: "commandOverrides") as? [String: String],
            ["check_npm": "npm outdated -g --json --depth=0"])
    }

    func testTheDefaultsAPersonGetsBeforeConfiguringAnything() throws {
        // Read from an empty domain, because on a machine that has run MacUp these are whatever the
        // person chose. They are product decisions: a day before an ordinary update is offered, four
        // hours for a security fix, and nothing installed without being asked.
        let suite = try XCTUnwrap(UserDefaults(suiteName: "macup.tests.\(UUID().uuidString)"))
        defer { UserDefaults.standard.removeSuite(named: suite.description) }
        let fresh = Preferences(defaults: suite)

        XCTAssertEqual(fresh.minAgeHours, 24)
        XCTAssertEqual(fresh.securityMinAgeHours, 4)
        XCTAssertEqual(fresh.checkIntervalHours, 6)
        XCTAssertEqual(fresh.autoUpdateIntervalHours, 24)
        XCTAssertFalse(fresh.autoUpdate, "updating is the user's decision until they say otherwise")
        XCTAssertFalse(fresh.brewGreedy)
        XCTAssertTrue(fresh.notificationsEnabled)
        XCTAssertTrue(fresh.hideSystemPackages, "packages macOS owns stay out of the way")
        XCTAssertTrue(fresh.showMenuBarCount)
        XCTAssertFalse(fresh.hasOnboarded)
        XCTAssertEqual(fresh.disabledManagers, [], "every manager found is used")
        XCTAssertEqual(fresh.ignoredPackages, [])
        XCTAssertEqual(fresh.commandOverrides, [:], "the built-in commands")
    }

    func testWhatWasSavedIsWhatComesBackNextLaunch() throws {
        let name = "macup.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removeSuite(named: name) }

        let first = Preferences(defaults: suite)
        first.minAgeHours = 12
        first.disabledManagers = [.npm, .conda]
        first.ignoredPackages = ["npm:left-pad"]
        first.commandOverrides = ["check_npm": "npm outdated -g --json --depth=0"]
        first.hideSystemPackages = false

        let relaunched = Preferences(defaults: suite)
        XCTAssertEqual(relaunched.minAgeHours, 12)
        XCTAssertEqual(relaunched.disabledManagers, [.npm, .conda])
        XCTAssertEqual(relaunched.ignoredPackages, ["npm:left-pad"])
        XCTAssertEqual(relaunched.commandOverrides, ["check_npm": "npm outdated -g --json --depth=0"])
        XCTAssertFalse(relaunched.hideSystemPackages)
    }

    func testAManagerThatNoLongerExistsIsDroppedOnRead() throws {
        // A name written by an older version that has since been removed must not crash the launch.
        let name = "macup.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removeSuite(named: name) }
        suite.set(["npm", "notamanager"], forKey: "disabledManagers")

        XCTAssertEqual(Preferences(defaults: suite).disabledManagers, [.npm])
    }

    func testEnabledManagersIsWhateverIsNotTurnedOff() {
        settings.disabledManagers = [.npm]
        XCTAssertFalse(settings.enabledManagers.contains(.npm))
        XCTAssertEqual(settings.enabledManagers.count, Manager.allCases.count - 1)
    }

    func testSecurityFixesUseTheShorterThreshold() {
        settings.minAgeHours = 24
        settings.securityMinAgeHours = 4
        var pkg = OutdatedPackage(
            manager: .npm, name: "a", installed: "1", latest: "2", kind: "global", extra: "")
        XCTAssertEqual(settings.threshold(for: pkg), 24 * 3600)
        pkg.advisories = ["CVE-2026-0001"]
        XCTAssertEqual(settings.threshold(for: pkg), 4 * 3600)
    }
}

/// The one line that says what MacUp is doing, at the top of the history.
final class ActivityTitleTests: XCTestCase {
    func testOnePackageIsNamed() {
        XCTAssertEqual(
            Activity.title(packages: ["npm:lodash"], installing: [], managers: []), "Updating lodash")
    }

    func testSeveralPackagesNameOneAndCountTheRest() {
        XCTAssertEqual(
            Activity.title(packages: ["npm:lodash", "npm:vite", "brew:jq"], installing: [], managers: []),
            "Updating jq and 2 more")
    }

    func testAGoImportPathKeepsItsColons() {
        // Ids are "manager:name" and a Go package's name is an import path with colons of its own.
        XCTAssertEqual(
            Activity.title(packages: ["go:golang.org/x/tools/cmd/goimports"], installing: [], managers: []),
            "Updating golang.org/x/tools/cmd/goimports")
    }

    func testInstallingAToolIsSaidPlainly() {
        XCTAssertEqual(
            Activity.title(packages: [], installing: [.mas], managers: []), "Installing App Store (mas)")
    }

    func testAWholeManagerRunningIsNamedByTheManager() {
        XCTAssertEqual(
            Activity.title(packages: [], installing: [], managers: [.brew]), "Updating Homebrew")
    }

    func testAPackageIsMoreSpecificThanTheManagerItBelongsTo() {
        XCTAssertEqual(
            Activity.title(packages: ["brew:jq"], installing: [], managers: [.brew]), "Updating jq")
    }

    func testWithNothingRunningItIsTheScan() {
        XCTAssertEqual(Activity.title(packages: [], installing: [], managers: []), "Checking for updates")
    }
}
