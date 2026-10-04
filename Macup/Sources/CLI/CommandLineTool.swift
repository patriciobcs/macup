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
        case .upgrade: code = await upgrade(request, store: store)
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
        // Nobody may be there to type a password: cron, launchd, a script with its input redirected.
        if request.skipAdmin || isatty(STDIN_FILENO) == 0 {
            for manager in targets where store.needsAdmin(manager) {
                print("Skipping \(manager.title): it needs an administrator password.")
            }
            targets.removeAll { store.needsAdmin($0) }
        }
        let pool = request.now ? store.visible : store.eligible
        // macOS updates are a hand-off to System Settings, run only when asked for by name.
        let candidates = pool.filter {
            targets.contains($0.manager) && (!$0.manager.opensExternally || request.managers == [$0.manager])
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

        // What happened is what the history says: the rescan afterwards forgets a failure as soon as
        // the package stops being reported, so the failure list alone can undercount.
        let records = store.history.records.filter { $0.kind == .upgrade && $0.date >= started }
        let failures = records.filter { !$0.succeeded }
        let updated = records.count - failures.count
        print("")
        if updated > 0 { print(style.green("Updated \(updated) \(updated == 1 ? "package" : "packages").")) }
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
        for manager in Manager.allCases {
            let items = candidates.filter { $0.manager == manager }
            guard !items.isEmpty else { continue }
            print("")
            print(style.bold(manager.title))
            // One command per package, as Update All runs them; rustup takes its toolchains together.
            let batches = manager == .rustup ? [items] : items.map { [$0] }
            for batch in batches {
                let result = try? await ScriptRunner.upgrade(
                    manager: manager, arguments: batch.map(\.upgradeArgument), brewGreedy: brewGreedy,
                    onOutput: { _ in })
                for line in (result?.stdout ?? "").split(separator: "\n") { print("  \(line)") }
            }
        }
        return 0
    }

    private static func ignore(_ names: [String], store: UpdateStore) -> Int32 {
        var code: Int32 = 0
        for name in names {
            let matches = store.packages.filter { $0.id == name || $0.name == name }
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
            let ids = store.settings.ignoredPackages.filter { $0 == name || $0.hasSuffix(":\(name)") }
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
        guard !AutomatedRun.isActive else { return }
        DistributedNotificationCenter.default().postNotificationName(
            UpdateStore.changedElsewhere, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
