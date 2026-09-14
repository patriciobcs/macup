import AppKit
import Foundation
import Observation
import UserNotifications

/// Single source of truth for the UI: scan results, eligibility, upgrades in flight, and the log.
@Observable @MainActor
final class UpdateStore {
    static let shared = UpdateStore()

    private(set) var reports: [ManagerReport] = []
    /// The self-installed tools the last scan looked for, whether or not they are here.
    private(set) var tools: [ToolReport] = []
    private(set) var packages: [OutdatedPackage] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var scanError: String?
    private(set) var upgrading: Set<String> = []
    private(set) var log = ""
    private(set) var firstSeen: [String: Date] = [:]
    /// Last failed upgrade per package id, with the tail of the command output.
    private(set) var failures: [String: String] = [:]
    /// Log section the window should scroll to; the counter makes repeated reveals of the same section fire.
    private(set) var revealMarker: String?
    private(set) var revealCount = 0
    private(set) var installing: Set<Manager> = []
    /// Managers that have reported during the scan in flight, and how many were asked for. The setup
    /// window uses these to show what has been checked instead of a spinner that cannot move.
    private(set) var scanned: Set<Manager> = []
    private(set) var scanTotal = 0
    /// When updates were last installed without being asked, so the interval is honoured across launches.
    private(set) var lastAutoUpdate: Date?

    /// The same object the views bind to; not private only so the derived lists can live in their own
    /// file without reaching for the singleton a second way.
    let settings = Preferences.shared
    private let registry: Registry
    private let stateURL: URL
    let history: History
    private var scheduler: Task<Void, Never>?
    /// Managers asked for while a scan was running; scanned as soon as it finishes.
    private var pendingRescan: Set<Manager> = []
    /// Advances every few minutes so time-based eligibility re-renders without a new scan.
    private(set) var clock = Date()
    /// Versions already announced. Read and written by the notification code, which lives in
    /// UpdateStore+Support.swift.
    var notified: Set<String> = []

    private let persistsState: Bool

    /// How this copy was installed, which decides whether MacUp updates itself through Homebrew.
    /// Resolved lazily so a store is cheap to make; tests pass it in rather than moving the app.
    private let installSourceOverride: InstallSource?
    var installSource: InstallSource { installSourceOverride ?? AppUpdater.shared.source }

    /// `persist: false` gives an in-memory store that never reads or writes Application Support
    /// (fixtures). `directory` and `installSource` are only passed by tests.
    /// Updating MacUp itself replaces the running app, so tests substitute this rather than have the
    /// test runner restart itself halfway through.
    private let selfUpdateOverride: (@MainActor () async -> Void)?

    init(
        persist: Bool = true, directory: URL? = nil, installSource: InstallSource? = nil,
        selfUpdate: (@MainActor () async -> Void)? = nil
    ) {
        installSourceOverride = installSource
        selfUpdateOverride = selfUpdate
        persistsState = persist
        let dir =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(persist ? "Macup" : "Macup-fixture", isDirectory: true)
        if persist { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        stateURL = dir.appendingPathComponent("state.json")
        history = History(directory: dir)
        // A store told where to live keeps its registry cache there too, so tests never touch the real one.
        registry = Registry(directory: directory)
        if persist, let data = try? Data(contentsOf: stateURL),
            let saved = try? JSONDecoder.iso.decode(SavedState.self, from: data)
        {
            firstSeen = saved.firstSeen
            packages = saved.packages
            reports = saved.reports
            lastScan = saved.lastScan
            notified = saved.notified
            lastAutoUpdate = saved.lastAutoUpdate
        }
    }

    // MARK: Derived state

    func ignore(_ pkg: OutdatedPackage) {
        settings.ignoredPackages.insert(pkg.id)
        failures.removeValue(forKey: pkg.id)
        history.add(
            ActionRecord(
                kind: .ignore, manager: pkg.manager, package: pkg.name, detail: "\(pkg.installed) → \(pkg.latest)",
                succeeded: true))
    }

    func unignore(id: String) {
        settings.ignoredPackages.remove(id)
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let m = Manager(rawValue: parts[0]) {
            history.add(ActionRecord(kind: .unignore, manager: m, package: parts[1], detail: "", succeeded: true))
        }
    }

    func isEligible(_ pkg: OutdatedPackage) -> Bool {
        Eligibility.isEligible(
            pkg, minAge: settings.minAgeHours * 3600,
            securityMinAge: settings.securityMinAgeHours * 3600, firstSeen: firstSeen, now: clock)
    }

    func age(of pkg: OutdatedPackage) -> TimeInterval { Eligibility.age(of: pkg, firstSeen: firstSeen) }
    func referenceDate(of pkg: OutdatedPackage) -> Date? { Eligibility.referenceDate(for: pkg, firstSeen: firstSeen) }

    // MARK: Scanning

    func start() {
        scheduler?.cancel()
        scheduler = Task { [weak self] in
            var nextScan = Date()
            while !Task.isCancelled {
                guard let self else { return }
                if Date() >= nextScan {
                    await self.scan()
                    nextScan = Date().addingTimeInterval(max(0.25, self.settings.checkIntervalHours) * 3600)
                }
                self.clock = Date()
                // Wake every five minutes so a package crossing its minimum age shows up without a new scan,
                // and so a shorter check interval chosen in Settings takes effect soon.
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Called when the check interval changes: the next scan is rescheduled from now.
    func restartSchedule() { start() }

    /// MacUp's own Homebrew cask when it is outdated. Only meaningful for Homebrew installs; a direct
    /// install is updated by Sparkle, so a stray cask is ignored there.
    var selfCaskUpdate: OutdatedPackage? {
        guard installSource == .homebrew else { return nil }
        guard let cask = packages.first(where: { $0.manager == .brew && $0.name == "macup" }) else { return nil }
        // Homebrew compares against the version it recorded when it installed, which is not always what
        // is running: a copy replaced by hand is newer than the Caskroom thinks. Never offer an update
        // that the running app already is.
        return Version.isNewer(cask.latest, than: appVersion) ? cask : nil
    }

    static func isSelfCask(_ p: OutdatedPackage) -> Bool { p.manager == .brew && p.name == "macup" }

    func scan(managers: [Manager]? = nil) async {
        let targets = managers ?? settings.enabledManagers
        if isScanning {
            // Queue instead of dropping: a rescan after an upgrade must not be lost to a running scan.
            pendingRescan.formUnion(targets)
            return
        }
        isScanning = true
        scanError = nil
        scanned = []
        scanTotal = targets.count
        do {
            let onReport: @Sendable (ManagerReport) -> Void = { report in
                Task { @MainActor [weak self] in self?.noteScanned(report) }
            }
            var result = try await ScriptRunner.scan(
                managers: targets, brewGreedy: settings.brewGreedy, onReport: onReport)
            result.packages = await enrichVisible(result.packages)
            merge(result, scanned: targets)
            lastScan = Date()
            clock = Date()
            persist()
            // No point announcing updates that are about to be installed a moment later.
            if !autoUpdateIsDue { await notifyIfNeeded() }
        } catch {
            scanError = error.localizedDescription
        }
        isScanning = false
        if !pendingRescan.isEmpty {
            let again = Array(pendingRescan)
            pendingRescan.removeAll()
            await scan(managers: again)
        }
        // Only once the scan is over: an upgrade rescans, and that would otherwise just be queued.
        await autoUpdateIfDue()
    }

    /// One manager finished. Its result is shown straight away; the authoritative merge still happens
    /// when the whole scan returns.
    func noteScanned(_ report: ManagerReport) {
        scanned.insert(report.manager)
        if let i = reports.firstIndex(where: { $0.manager == report.manager }) {
            reports[i] = report
        } else {
            reports.append(report)
            reports.sort { Manager.allCases.firstIndex(of: $0.manager)! < Manager.allCases.firstIndex(of: $1.manager)! }
        }
    }

    /// Release dates and advisories are looked up only for packages the user can see; hidden system
    /// packages and ignored ones skip the network entirely.
    private func enrichVisible(_ packages: [OutdatedPackage]) async -> [OutdatedPackage] {
        let hidden = packages.filter {
            settings.ignoredPackages.contains($0.id) || (settings.hideSystemPackages && $0.isSystem)
        }
        let shown = packages.filter { !hidden.contains($0) }
        return await registry.enrich(shown) + hidden.filter { !$0.needsLatest }
    }

    func merge(_ result: ScanResult, scanned: [Manager]) {
        let set = Set(scanned)
        // A package that is no longer outdated was upgraded after all; forget its failure.
        let stillOutdated = Set(result.packages.map(\.id))
        failures = failures.filter {
            !set.contains(Manager(rawValue: $0.key.split(separator: ":")[0].description)!)
                || stillOutdated.contains($0.key)
        }
        reports = (reports.filter { !set.contains($0.manager) } + result.reports)
            .sorted { Manager.allCases.firstIndex(of: $0.manager)! < Manager.allCases.firstIndex(of: $1.manager)! }
        packages = packages.filter { !set.contains($0.manager) } + result.packages
        // Only a scan that looked at the tools knows about them; a scan of one other manager must not
        // wipe the list.
        if set.contains(.tools) { tools = result.tools }
        // Track when each (package, version) pair was first observed. Pairs that vanish are kept for a
        // week, so a scan run offline (which cannot resolve some latest versions) does not reset the clock.
        let now = Date()
        var seen: [String: Date] = firstSeen.filter { now.timeIntervalSince($0.value) < 7 * 86_400 }
        for p in packages { seen[p.versionKey] = firstSeen[p.versionKey] ?? now }
        firstSeen = seen
        notified = notified.intersection(Set(packages.map(\.versionKey)))
    }

    // MARK: Upgrading

    func upgrade(_ pkg: OutdatedPackage) async {
        guard !upgrading.contains(pkg.id), !upgrading.contains(pkg.manager.rawValue) else { return }
        upgrading.insert(pkg.id)
        await runUpgrade(manager: pkg.manager, packages: [pkg])
        upgrading.remove(pkg.id)
        if Self.isSelfCask(pkg), failures[pkg.id] == nil {
            history.add(
                ActionRecord(kind: .upgrade, manager: .brew, package: "MacUp", detail: "relaunching", succeeded: true))
            AppUpdater.relaunch()
            return
        }
        await scan(managers: [pkg.manager])
    }

    func upgradeAll(_ manager: Manager) async {
        await upgradeAll(managers: [manager])
    }

    func upgradeAllEligible() async {
        await upgradeAll(managers: Manager.allCases)
        // Last: updating MacUp replaces the running app, which would cut the batch short.
        await updateSelf()
    }

    /// Upgrades one package at a time so each row gets its own result, then rescans once.
    private func upgradeAll(managers: [Manager]) async {
        let grouped = Dictionary(grouping: eligible, by: \.manager)
        var touched: [Manager] = []
        for manager in managers where !(manager.opensExternally && managers.count > 1) {
            guard let items = grouped[manager], !upgrading.contains(manager.rawValue) else { continue }
            touched.append(manager)
            upgrading.insert(manager.rawValue)
            defer { upgrading.remove(manager.rawValue) }
            if manager == .rustup {
                await runUpgrade(manager: manager, packages: items)
                continue
            }
            // npm must upgrade itself last, after the packages installed through it.
            let ordered = items.sorted { ($0.name == "npm" ? 1 : 0) < ($1.name == "npm" ? 1 : 0) }
            for item in ordered {
                upgrading.insert(item.id)
                await runUpgrade(manager: manager, packages: [item])
                upgrading.remove(item.id)
            }
        }
        if !touched.isEmpty { await scan(managers: touched) }
        // MacUp updates itself last: a Homebrew upgrade relaunches the app, which would cut the rest of
        // the batch short, and Sparkle takes over the window once it starts.
    }

    /// Updates MacUp itself the way this copy was installed. Nothing happens when it is already current.
    /// The decision is made here; only the act of updating is substituted in tests, so the rules below
    /// are the ones that actually run.
    func updateSelf(unattended: Bool = false) async {
        switch installSource {
        case .homebrew:
            guard let cask = selfCaskUpdate else { return }
            // Replacing the app unasked deserves the same settling delay as everything else, and the
            // cask goes through Homebrew, so it is subject to the same password rule.
            if unattended, !isEligible(cask) || needsAdmin(.brew) { return }
            if let selfUpdateOverride { return await selfUpdateOverride() }
            await upgrade(cask)
        case .direct:
            // Sparkle puts a window on screen and takes focus, which has no place in a run nobody asked
            // for. A direct install updates itself when the user checks.
            guard !unattended else { return }
            if let selfUpdateOverride { return await selfUpdateOverride() }
            AppUpdater.shared.checkForUpdates()
        }
    }

    /// Installs what is ready, at most once per chosen interval. Called after a scan, so it follows the
    /// same schedule as checking.
    var autoUpdateIsDue: Bool {
        guard settings.autoUpdate, !isUpgradingAnything else { return false }
        let interval = max(1, settings.autoUpdateIntervalHours) * 3600
        if let lastAutoUpdate, Date().timeIntervalSince(lastAutoUpdate) < interval { return false }
        return !eligible.isEmpty || selfCaskUpdate != nil
    }

    private func autoUpdateIfDue() async {
        guard autoUpdateIsDue else { return }
        lastAutoUpdate = Date()
        persist()
        // Anything that would ask for an administrator password is left for the user to do knowingly:
        // an unattended run must never put a password prompt on screen out of nowhere.
        await upgradeAll(managers: Manager.allCases.filter { !needsAdmin($0) })
        await updateSelf(unattended: true)
    }

    /// Runs the upgrade script once. Callers manage the `upgrading` set and the rescan.
    private func runUpgrade(manager: Manager, packages items: [OutdatedPackage]) async {
        let args = items.map(\.upgradeArgument)
        appendLog("\n\(Self.logMarker(manager: manager, names: items.map(\.name)))\n")
        var failure: String?
        let outcome = await runLogged({ emit in
            try await ScriptRunner.upgrade(
                manager: manager, arguments: args, brewGreedy: self.settings.brewGreedy, onOutput: emit)
        })
        switch outcome {
        case .success(let result):
            let status = result.status
            if status == 0 {
                appendLog("✓ done\n")
            } else {
                appendLog("✗ exited with status \(status)\n")
                failure = Self.errorSummary(result.combined, status: status)
            }
        case .failure(let error):
            appendLog("✗ \(error.localizedDescription)\n")
            failure = error.localizedDescription
        }
        // What the command printed, or the reason it never ran.
        let output = (try? outcome.get())?.combined ?? failure ?? ""
        for item in items {
            if let failure { failures[item.id] = failure } else { failures.removeValue(forKey: item.id) }
        }
        history.add(
            items.enumerated().map { index, item in
                ActionRecord(
                    kind: .upgrade, manager: manager, package: item.name,
                    detail: failure ?? "\(item.installed) → \(item.latest)", succeeded: failure == nil,
                    // One command covered them all, so the output hangs off the first row rather than
                    // being stored once per package.
                    output: index == 0 ? output : nil)
            })
    }

    /// Uninstalls a package through its manager, logs the output, records the outcome and rescans.
    func remove(_ pkg: OutdatedPackage) async {
        guard !upgrading.contains(pkg.id), !upgrading.contains(pkg.manager.rawValue) else { return }
        upgrading.insert(pkg.id)
        defer { upgrading.remove(pkg.id) }
        appendLog("\n\(Self.logMarker(manager: pkg.manager, names: [pkg.name])) remove\n")
        var failure: String?
        let outcome = await runLogged({ emit in
            try await ScriptRunner.remove(pkg: pkg, brewGreedy: self.settings.brewGreedy, onOutput: emit)
        })
        switch outcome {
        case .success(let result):
            let status = result.status
            if status == 0 {
                appendLog("✓ removed\n")
            } else {
                appendLog("✗ exited with status \(status)\n")
                failure = Self.errorSummary(result.combined, status: status)
            }
        case .failure(let error):
            appendLog("✗ \(error.localizedDescription)\n")
            failure = error.localizedDescription
        }
        // What the command printed, or the reason it never ran.
        let output = (try? outcome.get())?.combined ?? failure ?? ""
        if let failure { failures[pkg.id] = failure } else { failures.removeValue(forKey: pkg.id) }
        history.add(
            ActionRecord(
                kind: .remove, manager: pkg.manager, package: pkg.name,
                detail: failure ?? pkg.installed, succeeded: failure == nil, output: output))
        await scan(managers: [pkg.manager])
    }

    /// Installs an optional helper tool (currently the App Store CLI, mas) and rescans it.
    func installTool(_ manager: Manager) async {
        guard !installing.contains(manager) else { return }
        installing.insert(manager)
        defer { installing.remove(manager) }
        appendLog("\n── Install \(manager.rawValue) ──\n")
        var failure: String?
        let outcome = await runLogged({ emit in
            try await ScriptRunner.setup(tool: manager.rawValue, onOutput: emit)
        })
        switch outcome {
        case .success(let result):
            let status = result.status
            if status == 0 {
                appendLog("✓ installed\n")
            } else {
                appendLog("✗ exited with status \(status)\n")
                failure = Self.errorSummary(result.combined, status: status)
            }
        case .failure(let error):
            appendLog("✗ \(error.localizedDescription)\n")
            failure = error.localizedDescription
        }
        // What the command printed, or the reason it never ran.
        let output = (try? outcome.get())?.combined ?? failure ?? ""
        history.add(
            ActionRecord(
                kind: .install, manager: manager, package: manager.rawValue,
                detail: failure ?? "via Homebrew", succeeded: failure == nil, output: output))
        if failure == nil { await scan(managers: [manager]) }
    }

    func clearLog() { log = "" }

    /// Runs a script while appending its output to the log in arrival order.
    private func runLogged(
        _ body: @escaping (@escaping @Sendable (String) -> Void) async throws -> SubprocessResult
    ) async -> Result<SubprocessResult, Error> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await chunk in stream { self?.appendLog(chunk) }
        }
        let outcome: Result<SubprocessResult, Error>
        do { outcome = .success(try await body { continuation.yield($0) }) } catch { outcome = .failure(error) }
        continuation.finish()
        await consumer.value
        return outcome
    }

    /// Ask the window's log view to scroll to this package's most recent upgrade output.
    func reveal(_ pkg: OutdatedPackage) {
        revealMarker = Self.logMarker(manager: pkg.manager, names: [pkg.name])
        revealCount += 1
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    // MARK: Persistence

    /// Replaces the store's content without scanning (screenshots, previews).
    func loadFixture(
        reports: [ManagerReport], packages: [OutdatedPackage], log: String, tools: [ToolReport] = []
    ) {
        self.reports = reports
        self.tools = tools
        self.packages = packages
        self.log = log
        self.lastScan = Date().addingTimeInterval(-90)
        let now = Date()
        for p in packages { firstSeen[p.versionKey] = now.addingTimeInterval(-3 * 86_400) }
    }

    func persist() {
        guard persistsState else { return }
        let s = SavedState(
            firstSeen: firstSeen, packages: packages, reports: reports, lastScan: lastScan, notified: notified,
            lastAutoUpdate: lastAutoUpdate)
        if let data = try? JSONEncoder.iso.encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }
}
