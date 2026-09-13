import AppKit
import Foundation

/// Pieces of the store that stand on their own: the questions the views ask of it, the removal
/// prompt, the shapes of log markers and error summaries, and what is written to disk. Kept apart so
/// UpdateStore itself stays about the state and what changes it.
extension UpdateStore {
    /// Packages minus the ones the user chose to ignore and, by default, the ones macOS owns.
    var visible: [OutdatedPackage] {
        // Packages found before a manager was turned off stay in the list until it is scanned again,
        // so the disabled set is checked here rather than relied on from the last scan.
        packages.filter {
            !settings.disabledManagers.contains($0.manager) && !settings.ignoredPackages.contains($0.id)
                && !(settings.hideSystemPackages && $0.isSystem) && !Self.isSelfCask($0)
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

    /// MacUp's own update counts alongside the packages, in the badge and in "Update all".
    var selfUpdateCount: Int { selfCaskUpdate == nil ? 0 : 1 }
    var badgeCount: Int { eligible.count + selfUpdateCount }

    /// What "Update All" will actually run (system updates are a hand-off to System Settings).
    var updatableCount: Int {
        eligible.filter { !$0.manager.opensExternally }.count + selfUpdateCount
    }

    /// True while this specific package is being upgraded (a manager-wide lock also covers rustup toolchains).
    func isUpgrading(_ pkg: OutdatedPackage) -> Bool {
        upgrading.contains(pkg.id) || (pkg.manager == .rustup && upgrading.contains(pkg.manager.rawValue))
    }

    func isUpgrading(_ manager: Manager) -> Bool { upgrading.contains(manager.rawValue) }

    var isUpgradingAnything: Bool { !upgrading.isEmpty }

    /// Managers that failed for reasons other than being offline: these deserve a report.
    var problems: [ManagerReport] { reports.filter { $0.status == .error && !$0.isOffline } }

    /// At least one manager could not reach the network in the last scan.
    var isOffline: Bool { reports.contains { $0.isOffline } }

    /// Managers that were found on this Mac (anything except "missing").
    var discoveredManagers: [Manager] { reports.filter { $0.status != .missing }.map(\.manager) }

    /// Fixed for the life of the process, and read on every menu bar refresh, so look it up once.
    static let bundleVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    var appVersion: String { Self.bundleVersion }

    /// The version the last scan saw for a manager, for bug reports.
    func version(of manager: Manager) -> String { reports.first { $0.manager == manager }?.version ?? "" }
    func needsAdmin(_ manager: Manager) -> Bool { reports.first { $0.manager == manager }?.needsAdmin ?? false }
    func isInstalling(_ manager: Manager) -> Bool { installing.contains(manager) }
    func failure(for pkg: OutdatedPackage) -> String? { failures[pkg.id] }
    /// Asks before uninstalling. Returns true when the user confirmed.
    static func confirmRemoval(of pkg: OutdatedPackage) -> Bool {
        // Nobody is there to answer a modal in a test or a render, and one raised there would wait for
        // ever rather than fail. Nothing was confirmed, so nothing is removed. See AutomatedRun.
        guard !AutomatedRun.isActive else { return false }
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

    nonisolated static func logMarker(manager: Manager, names: [String]) -> String {
        "── \(manager.title): \(names.joined(separator: ", ")) ──"
    }

    /// The most informative lines of a failed command: error lines if any, otherwise the last few lines.
    nonisolated static func errorSummary(_ output: String, status: Int32) -> String {
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("$ ") }
        let errors = lines.filter { $0.localizedCaseInsensitiveContains("error") }
        let picked = (errors.isEmpty ? Array(lines.suffix(3)) : Array(errors.prefix(3)))
        return picked.isEmpty ? "Exited with status \(status)" : picked.joined(separator: "\n")
    }

    struct SavedState: Codable {
        var firstSeen: [String: Date]
        var packages: [OutdatedPackage]
        var reports: [ManagerReport]
        var lastScan: Date?
        var notified: Set<String>
        var lastAutoUpdate: Date?
    }
}
