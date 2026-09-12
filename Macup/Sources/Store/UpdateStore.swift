import AppKit
import Foundation
import Observation
import UserNotifications

/// Single source of truth for the UI: scan results, eligibility, upgrades in flight, and the log.
@Observable @MainActor
final class UpdateStore {
    static let shared = UpdateStore()

    private(set) var reports: [ManagerReport] = []
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

    private let settings = Preferences.shared
    private let registry: Registry
    private let stateURL: URL
    let history: History
    private var scheduler: Task<Void, Never>?
    /// Managers asked for while a scan was running; scanned as soon as it finishes.
    private var pendingRescan: Set<Manager> = []
    /// Advances every few minutes so time-based eligibility re-renders without a new scan.
    private(set) var clock = Date()
    private var notified: Set<String> = []

    private let persistsState: Bool

    /// How this copy was installed, which decides whether MacUp updates itself through Homebrew.
    /// Resolved lazily so a store is cheap to make; tests pass it in rather than moving the app.
    private let installSourceOverride: InstallSource?
    var installSource: InstallSource { installSourceOverride ?? AppUpdater.shared.source }

    /// `persist: false` gives an in-memory store that never reads or writes Application Support
    /// (fixtures). `directory` and `installSource` are only passed by tests.
    init(persist: Bool = true, directory: URL? = nil, installSource: InstallSource? = nil) {
        installSourceOverride = installSource
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
        }
    }

    // MARK: Derived state

    /// Packages minus the ones the user chose to ignore and, by default, the ones macOS owns.
    var visible: [OutdatedPackage] {
        packages.filter {
            !settings.ignoredPackages.contains($0.id) && !(settings.hideSystemPackages && $0.isSystem)
                && !Self.isSelfCask($0)
        }
    }
    var hiddenSystemCount: Int { settings.hideSystemPackages ? packages.filter(\.isSystem).count : 0 }
    var ignored: [OutdatedPackage] { packages.filter { settings.ignoredPackages.contains($0.id) } }

    var eligible: [OutdatedPackage] {
        visible.filter { isEligible($0) }
    }

    var waiting: [OutdatedPackage] {
        visible.filter { !isEligible($0) }
    }

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

    var badgeCount: Int { eligible.count }
    /// What "Update All" will actually run (system updates are a hand-off to System Settings).
    var updatableCount: Int { eligible.filter { !$0.manager.opensExternally }.count }

    func isEligible(_ pkg: OutdatedPackage) -> Bool {
        Eligibility.isEligible(
            pkg, minAge: settings.minAgeHours * 3600,
            securityMinAge: settings.securityMinAgeHours * 3600, firstSeen: firstSeen, now: clock)
    }

    func age(of pkg: OutdatedPackage) -> TimeInterval { Eligibility.age(of: pkg, firstSeen: firstSeen) }
    func referenceDate(of pkg: OutdatedPackage) -> Date? { Eligibility.referenceDate(for: pkg, firstSeen: firstSeen) }

    /// True while this specific package is being upgraded (a manager-wide lock also covers rustup toolchains).
    func isUpgrading(_ pkg: OutdatedPackage) -> Bool {
        upgrading.contains(pkg.id) || (pkg.manager == .rustup && upgrading.contains(pkg.manager.rawValue))
    }
    func isUpgrading(_ manager: Manager) -> Bool { upgrading.contains(manager.rawValue) }
    var isUpgradingAnything: Bool { !upgrading.isEmpty }

    func needsAdmin(_ manager: Manager) -> Bool { reports.first { $0.manager == manager }?.needsAdmin ?? false }

    /// Managers that failed for reasons other than being offline: these deserve a report.
    var problems: [ManagerReport] { reports.filter { $0.status == .error && !$0.isOffline } }
    /// At least one manager could not reach the network in the last scan.
    var isOffline: Bool { reports.contains { $0.isOffline } }

    /// Managers that were found on this Mac (anything except "missing").
    var discoveredManagers: [Manager] { reports.filter { $0.status != .missing }.map(\.manager) }

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

    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    /// MacUp's own Homebrew cask when it is outdated. Only meaningful for Homebrew installs; a direct
    /// install is updated by Sparkle, so a stray cask is ignored there.
    var selfCaskUpdate: OutdatedPackage? {
        guard installSource == .homebrew else { return nil }
        return packages.first { $0.manager == .brew && $0.name == "macup" }
    }

    private static func isSelfCask(_ p: OutdatedPackage) -> Bool { p.manager == .brew && p.name == "macup" }

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
            await notifyIfNeeded()
        } catch {
            scanError = error.localizedDescription
        }
        isScanning = false
        if !pendingRescan.isEmpty {
            let again = Array(pendingRescan)
            pendingRescan.removeAll()
            await scan(managers: again)
        }
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
    }

    /// Runs the upgrade script once. Callers manage the `upgrading` set and the rescan.
    private func runUpgrade(manager: Manager, packages items: [OutdatedPackage]) async {
        // rustup upgrades the whole toolchain set at once; others take explicit names.
        let args = manager == .rustup ? [] : items.map(\.upgradeArgument)
        appendLog("\n\(Self.logMarker(manager: manager, names: items.map(\.name)))\n")
        var failure: String?
        switch await runLogged({ emit in
            try await ScriptRunner.upgrade(
                manager: manager, arguments: args, brewGreedy: self.settings.brewGreedy, onOutput: emit)
        }) {
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
        for item in items {
            if let failure { failures[item.id] = failure } else { failures.removeValue(forKey: item.id) }
            history.add(
                ActionRecord(
                    kind: .upgrade, manager: manager, package: item.name,
                    detail: failure ?? "\(item.installed) → \(item.latest)", succeeded: failure == nil))
        }
    }

    /// Uninstalls a package through its manager, logs the output, records the outcome and rescans.
    func remove(_ pkg: OutdatedPackage) async {
        guard !upgrading.contains(pkg.id), !upgrading.contains(pkg.manager.rawValue) else { return }
        upgrading.insert(pkg.id)
        defer { upgrading.remove(pkg.id) }
        appendLog("\n\(Self.logMarker(manager: pkg.manager, names: [pkg.name])) remove\n")
        var failure: String?
        switch await runLogged({ emit in
            try await ScriptRunner.remove(pkg: pkg, brewGreedy: self.settings.brewGreedy, onOutput: emit)
        }) {
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
        if let failure { failures[pkg.id] = failure } else { failures.removeValue(forKey: pkg.id) }
        history.add(
            ActionRecord(
                kind: .remove, manager: pkg.manager, package: pkg.name,
                detail: failure ?? pkg.installed, succeeded: failure == nil))
        await scan(managers: [pkg.manager])
    }

    func isInstalling(_ manager: Manager) -> Bool { installing.contains(manager) }

    /// Installs an optional helper tool (currently the App Store CLI, mas) and rescans it.
    func installTool(_ manager: Manager) async {
        guard !installing.contains(manager) else { return }
        installing.insert(manager)
        defer { installing.remove(manager) }
        appendLog("\n── Install \(manager.rawValue) ──\n")
        var failure: String?
        switch await runLogged({ emit in try await ScriptRunner.setup(tool: manager.rawValue, onOutput: emit) }) {
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
        history.add(
            ActionRecord(
                kind: .install, manager: manager, package: manager.rawValue,
                detail: failure ?? "via Homebrew", succeeded: failure == nil))
        if failure == nil { await scan(managers: [manager]) }
    }

    /// Asks before uninstalling. Returns true when the user confirmed.
    static func confirmRemoval(of pkg: OutdatedPackage) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove \(pkg.name)?"
        alert.informativeText =
            "This uninstalls \(pkg.name) \(pkg.installed) using \(pkg.manager.title). You can install it again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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

    func failure(for pkg: OutdatedPackage) -> String? { failures[pkg.id] }

    nonisolated static func logMarker(manager: Manager, names: [String]) -> String {
        "── \(manager.title): \(names.joined(separator: ", ")) ──"
    }

    /// Ask the window's log view to scroll to this package's most recent upgrade output.
    func reveal(_ pkg: OutdatedPackage) {
        revealMarker = Self.logMarker(manager: pkg.manager, names: [pkg.name])
        revealCount += 1
    }

    /// The most informative lines of a failed command: error lines if any, otherwise the last few lines.
    nonisolated static func errorSummary(_ output: String, status: Int32) -> String {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("$ ") }
        let errors = lines.filter { $0.localizedCaseInsensitiveContains("error") }
        let picked = (errors.isEmpty ? Array(lines.suffix(3)) : Array(errors.prefix(3)))
        return picked.isEmpty ? "Exited with status \(status)" : picked.joined(separator: "\n")
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    // MARK: Notifications

    private func notifyIfNeeded() async {
        guard settings.notificationsEnabled else { return }
        let fresh = eligible.filter { !notified.contains($0.versionKey) }
        guard !fresh.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        let security = fresh.filter(\.isSecurity).count
        content.title = security > 0 ? "Security updates available" : "Updates available"
        content.body =
            fresh.prefix(4).map { "\($0.name) \($0.latest)" }.joined(separator: ", ")
            + (fresh.count > 4 ? " and \(fresh.count - 4) more" : "")
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        notified.formUnion(fresh.map(\.versionKey))
        persist()
    }

    // MARK: Persistence

    private struct SavedState: Codable {
        var firstSeen: [String: Date]
        var packages: [OutdatedPackage]
        var reports: [ManagerReport]
        var lastScan: Date?
        var notified: Set<String>
    }

    /// Replaces the store's content without scanning (screenshots, previews).
    func loadFixture(reports: [ManagerReport], packages: [OutdatedPackage], log: String) {
        self.reports = reports
        self.packages = packages
        self.log = log
        self.lastScan = Date().addingTimeInterval(-90)
        let now = Date()
        for p in packages { firstSeen[p.versionKey] = now.addingTimeInterval(-3 * 86_400) }
    }

    func persist() {
        guard persistsState else { return }
        let s = SavedState(
            firstSeen: firstSeen, packages: packages, reports: reports, lastScan: lastScan, notified: notified)
        if let data = try? JSONEncoder.iso.encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }
}
