import Foundation

/// `macup` in a terminal. The same store the menu bar uses, so what is ready, what is ignored, the
/// minimum age and the commands run are all the app's: the terminal is another way in, not a second
/// set of rules.
@MainActor
enum CommandLineTool {
    /// Exit codes: 0 done, 1 something failed, 64 the command itself was wrong (sysexits' EX_USAGE).
    static let failed: Int32 = 1
    static let usageError: Int32 = 64

    /// Runs the request and exits; the app is never started.
    static func start(_ request: CommandLineRequest) -> Never {
        // Line by line, so package manager output appears as it happens even through a pipe.
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { exit(await run(request)) }
        dispatchMain()
    }

    static func fail(_ message: String) -> Never {
        printError("macup: \(message)\nRun `macup help` for usage.")
        exit(usageError)
    }

    static func run(_ request: CommandLineRequest, store: UpdateStore? = nil) async -> Int32 {
        switch request.command {
        case .help:
            print(CommandLineRequest.usage)
            return 0
        case .version:
            print("MacUp \(UpdateStore.bundleVersion)")
            return 0
        default: break
        }
        let store = store ?? makeStore()
        let code: Int32
        switch request.command {
        case .status: code = await status(request, store: store)
        case .check: code = await check(request, store: store)
        case .inventory: code = await inventory(request, store: store)
        case .upgrade: code = await upgrade(request, store: store)
        case .remove: code = await remove(request, store: store)
        case .ignore: code = ignore(request.names, store: store)
        case .unignore: code = unignore(request.names, store: store)
        case .help, .version: code = 0
        }
        store.settings.flush()
        return code
    }

    /// The real state, or the one in MACUP_STATE_DIR (tests). Its install source is worked out here so
    /// that nothing starts Sparkle, which has no business in a terminal.
    static func makeStore(environment: [String: String] = ProcessInfo.processInfo.environment) -> UpdateStore {
        let directory = environment["MACUP_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return UpdateStore(
            persist: true, directory: directory, installSource: InstallSource.detect(), commandLine: true)
    }

    // MARK: Commands

    private static func status(_ request: CommandLineRequest, store: UpdateStore) async -> Int32 {
        // Nothing to show yet (a fresh Mac, or the app never ran): check rather than say "never checked".
        if store.lastScan == nil { await scan(request, store: store) }
        show(store, json: request.json)
        return 0
    }

    private static func check(_ request: CommandLineRequest, store: UpdateStore) async -> Int32 {
        await scan(request, store: store)
        show(store, json: request.json)
        return store.scanError == nil ? 0 : failed
    }

    private static func inventory(_ request: CommandLineRequest, store: UpdateStore) async -> Int32 {
        await scan(request, store: store)
        let items = store.installations.filter { request.managers.isEmpty || request.managers.contains($0.manager) }
        let report = InventoryReport(items: items, checkedAt: store.lastScan)
        print(request.json ? report.json() : report.text())
        return store.scanError == nil ? 0 : failed
    }

    private static func upgrade(_ request: CommandLineRequest, store: UpdateStore) async -> Int32 {
        let style = TerminalStyle.forStandardOutput()
        // The app checks on its own schedule; an hour-old check is still a fair picture, an older one
        // could offer what was already updated, or miss what came out since.
        if store.lastScan.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            await scan(request, store: store)
        }
        let off = request.managers.filter { !store.settings.isEnabled($0) }
        for manager in off { print("\(manager.title) is turned off in MacUp's settings, so it is left alone.") }

        var targets = request.managers.isEmpty ? Manager.allCases : request.managers.filter { !off.contains($0) }
        var pool = request.now ? store.visible : store.eligible
        if !request.installationIDs.isEmpty {
            guard let selected = selectedInstallations(request.installationIDs, store: store) else { return usageError }
            guard
                selected.allSatisfy({
                    store.settings.isEnabled($0.manager)
                        && (request.managers.isEmpty || request.managers.contains($0.manager))
                        && $0.installation?.update != nil
                })
            else {
                printError(
                    "The selected installation is disabled, outside the requested managers, or has no supported updater."
                )
                return usageError
            }
            pool = selected.filter { request.now || store.isEligible($0) }
            if request.managers.isEmpty {
                targets = Manager.allCases.filter { manager in selected.contains { $0.manager == manager } }
            }
        }
        // Nobody may be there to type a password: cron, launchd, a script with its input redirected.
        if request.skipAdmin || isatty(STDIN_FILENO) == 0 {
            for manager in targets where store.needsAdmin(manager) {
                print("Skipping \(manager.title): it needs an administrator password.")
            }
            targets.removeAll { store.needsAdmin($0) }
            // A cask that runs part of its upgrade through sudo asks for the password the same way.
            for pkg in pool where targets.contains(pkg.manager) && store.needsAdmin(pkg) {
                print("Skipping \(pkg.name): it needs an administrator password.")
            }
            pool.removeAll { store.needsAdmin($0) }
        }
        // Native updaters need an explicit action. gcloud's Python installer must run directly in a
        // terminal; this CLI captures subprocess output, so show the guarded command instead.
        if pool.contains(where: { $0.manager == .gcloud }), targets.contains(.gcloud), !request.dryRun {
            print("Google Cloud CLI updates may install system Python; use Update in Terminal in MacUp.")
            if request.managers == [.gcloud],
                let package = pool.first(where: { $0.manager == .gcloud }),
                let command = await ScriptRunner.interactiveUpgradeCommand(package)
            {
                print("Or run directly in Terminal:\n\(command)")
                return 0
            }
        }
        let candidates = pool.filter {
            targets.contains($0.manager)
                && ($0.manager != .gcloud || request.dryRun)
                && (!$0.manualOnly || !request.installationIDs.isEmpty
                    || (request.managers == [$0.manager] && $0.manager != .npm))
        }
        guard !candidates.isEmpty else {
            let waiting = store.waiting.filter { targets.contains($0.manager) }.count
            print(
                request.now || waiting == 0
                    ? "Nothing to update."
                    : "Nothing ready to update. \(waiting) waiting out the minimum age: macup upgrade --now")
            return 0
        }
        if request.dryRun { return await dryRun(candidates, style: style) }

        var waited = false
        while !store.updateLock.tryAcquire() {
            if !waited { print("Waiting for MacUp to finish updating…") }
            waited = true
            try? await Task.sleep(for: .seconds(1))
        }
        store.logSink = { chunk in FileHandle.standardOutput.write(Data(chunk.utf8)) }
        let started = Date()
        await store.upgradeAll(managers: targets, candidates: candidates)
        store.updateLock.release()
        store.logSink = nil
        tellTheApp()

        return reportUpgradeOutcome(store, started: started, style: style)
    }

    private static func reportUpgradeOutcome(_ store: UpdateStore, started: Date, style: TerminalStyle) -> Int32 {
        // What happened is what the history says: the rescan afterwards forgets a failure as soon as
        // the package stops being reported, so the failure list alone can undercount.
        let records = store.history.records.filter {
            ($0.kind == .upgrade || $0.kind == .handoff) && $0.date >= started
        }
        let failures = records.filter { !$0.succeeded }
        let updated = records.filter { $0.kind == .upgrade && $0.succeeded && $0.detail != "Ran updater" }.count
        let ran = records.filter { $0.kind == .upgrade && $0.succeeded && $0.detail == "Ran updater" }.count
        let opened = records.filter { $0.kind == .handoff && $0.succeeded }.count
        print("")
        if updated > 0 { print(style.green("Updated \(updated) \(updated == 1 ? "package" : "packages").")) }
        if opened > 0 { print("Opened \(opened) vendor updater\(opened == 1 ? "" : "s").") }
        if ran > 0 {
            print("Ran \(ran) native updater\(ran == 1 ? "" : "s"); check the refreshed inventory for its result.")
        }
        if !failures.isEmpty {
            print(style.red("\(failures.count) failed: ") + failures.map(\.package).joined(separator: ", "))
        }
        if let cask = store.selfCaskUpdate {
            print("MacUp \(cask.latest) is available: brew upgrade --cask macup")
        }
        return failures.isEmpty ? 0 : failed
    }

    /// What `upgrade` would run, printed by the upgrade script itself so it is exactly what would run.
    private static func dryRun(_ candidates: [OutdatedPackage], style: TerminalStyle) async -> Int32 {
        setenv("MACUP_DRY_RUN", "1", 1)
        defer { unsetenv("MACUP_DRY_RUN") }
        let brewGreedy = Preferences.shared.brewGreedy
        print(style.bold("Would update \(candidates.count) \(candidates.count == 1 ? "package" : "packages"):"))
        var code: Int32 = 0
        for manager in Manager.allCases {
            let items = candidates.filter { $0.manager == manager }
            guard !items.isEmpty else { continue }
            print("")
            print(style.bold(manager.title))
            // One command per package, as Update All runs them; rustup takes its toolchains together.
            let batches = manager == .rustup ? [items] : items.map { [$0] }
            for batch in batches {
                do {
                    let result = try await ScriptRunner.upgrade(
                        packages: batch, brewGreedy: brewGreedy,
                        onOutput: { _ in })
                    for line in result.stdout.split(separator: "\n") { print("  \(line)") }
                    if result.status != 0 { code = failed }
                } catch {
                    printError(error.localizedDescription)
                    code = failed
                }
            }
        }
        return code
    }

    private static func selectedInstallations(_ ids: [String], store: UpdateStore) -> [OutdatedPackage]? {
        var selected: [OutdatedPackage] = []
        for id in ids {
            let matches = store.installations.filter {
                $0.package.id == id || $0.id == id || $0.name == id || $0.package.legacyID == id
                    || $0.reference.path == id
            }
            guard matches.count == 1, let item = matches.first else {
                printError(
                    "\(id): \(matches.isEmpty ? "installation not found" : "multiple installations match; use the exact id or path")"
                )
                return nil
            }
            if !selected.contains(where: { $0.id == item.package.id }) { selected.append(item.package) }
        }
        return selected
    }

    private static func remove(_ request: CommandLineRequest, store: UpdateStore) async -> Int32 {
        if store.lastScan == nil { await scan(request, store: store) }
        guard let selected = selectedInstallations(request.installationIDs + request.names, store: store),
            !selected.isEmpty
        else { return usageError }
        guard selected.allSatisfy(\.supportsRemoval) else {
            printError("One of these installations must be removed through its original installer.")
            return usageError
        }
        if request.dryRun {
            setenv("MACUP_DRY_RUN", "1", 1)
            defer { unsetenv("MACUP_DRY_RUN") }
            for package in selected {
                do {
                    let result = try await ScriptRunner.remove(
                        pkg: package, brewGreedy: store.settings.brewGreedy, onOutput: { _ in })
                    print(result.stdout, terminator: "")
                } catch {
                    printError(error.localizedDescription)
                    return failed
                }
            }
            return 0
        }
        let started = Date()
        var waited = false
        while !store.updateLock.tryAcquire() {
            if !waited { print("Waiting for MacUp to finish updating…") }
            waited = true
            try? await Task.sleep(for: .seconds(1))
        }
        defer {
            store.updateLock.release()
            store.logSink = nil
        }
        store.logSink = { chunk in FileHandle.standardOutput.write(Data(chunk.utf8)) }
        for package in selected { await store.remove(package) }
        tellTheApp()
        return store.history.records.contains { $0.date >= started && $0.kind == .remove && !$0.succeeded } ? failed : 0
    }

    private static func ignore(_ names: [String], store: UpdateStore) -> Int32 {
        var code: Int32 = 0
        for name in names {
            var known = store.packages
            for item in store.installations where !known.contains(where: { $0.id == item.package.id }) {
                known.append(item.package)
            }
            let matches = known.filter { $0.id == name || $0.legacyID == name || $0.name == name }
            if matches.count == 1, let pkg = matches.first {
                store.ignore(pkg)
                print("Ignoring \(pkg.id).")
            } else if matches.count > 1 {
                printError("“\(name)” is more than one package: \(matches.map(\.id).joined(separator: ", "))")
                code = failed
            } else if name.contains(":"), Manager(rawValue: String(name.split(separator: ":")[0])) != nil {
                // Not outdated right now, but named exactly: it stays out of the way when it is.
                store.settings.ignoredPackages.insert(name)
                print("Ignoring \(name).")
            } else {
                printError("No outdated package called “\(name)”. Use manager:name, e.g. npm:left-pad")
                code = failed
            }
        }
        tellTheApp()
        return code
    }

    private static func unignore(_ names: [String], store: UpdateStore) -> Int32 {
        var code: Int32 = 0
        for name in names {
            let ids = store.settings.ignoredPackages.filter {
                let legacy = $0.components(separatedBy: "@installation=")[0]
                return $0 == name || legacy == name || legacy.hasSuffix(":\(name)")
            }
            if ids.count == 1, let id = ids.first {
                store.unignore(id: id)
                print("No longer ignoring \(id).")
            } else {
                printError(
                    ids.isEmpty
                        ? "“\(name)” is not ignored."
                        : "“\(name)” matches more than one: \(ids.sorted().joined(separator: ", "))")
                code = failed
            }
        }
        tellTheApp()
        return code
    }

    // MARK: Pieces

    private static func scan(_ request: CommandLineRequest, store: UpdateStore) async {
        let managers = request.managers.isEmpty ? nil : request.managers.filter { store.settings.isEnabled($0) }
        if !request.json { printError("Checking for updates…") }
        await store.scan(managers: managers)
        if let error = store.scanError { printError("macup: \(error)") }
        tellTheApp()
    }

    private static func show(_ store: UpdateStore, json: Bool) {
        let report = CommandLineReport(store: store)
        print(json ? report.json() : report.text(style: .forStandardOutput()))
    }

    /// A running menu bar app reloads what this run wrote, instead of later saving over it.
    private static func tellTheApp() {
        // A test's store is not the one a running app shows, so there is nothing to tell it.
        guard !AutomatedRun.isActive, ProcessInfo.processInfo.environment["MACUP_STATE_DIR"] == nil else { return }
        DistributedNotificationCenter.default().postNotificationName(
            UpdateStore.changedElsewhere, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
