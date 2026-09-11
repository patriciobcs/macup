import Foundation
import Observation
import ServiceManagement

/// User preferences. Defaults are chosen so the app works with zero configuration.
@Observable @MainActor
final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    /// Regular updates are shown once the release is at least this old (hours). Default: 1 day.
    var minAgeHours: Double { didSet { d.set(minAgeHours, forKey: "minAgeHours") } }
    /// Security updates are shown once the release is at least this old (hours). Default: 4 hours.
    var securityMinAgeHours: Double { didSet { d.set(securityMinAgeHours, forKey: "securityMinAgeHours") } }
    /// Background scan interval (hours). Default: 6 hours.
    var checkIntervalHours: Double { didSet { d.set(checkIntervalHours, forKey: "checkIntervalHours") } }
    /// Include Homebrew casks that update themselves (brew outdated --greedy).
    var brewGreedy: Bool { didSet { d.set(brewGreedy, forKey: "brewGreedy") } }
    var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    var disabledManagers: Set<Manager> {
        didSet { d.set(disabledManagers.map(\.rawValue).sorted(), forKey: "disabledManagers") }
    }
    /// Package ids ("manager:name") the user never wants to see, e.g. stub crates that cannot be upgraded.
    var ignoredPackages: Set<String> { didSet { d.set(ignoredPackages.sorted(), forKey: "ignoredPackages") } }
    /// Hide packages that belong to macOS itself (system Ruby gems, Xcode Python). Default: on.
    var hideSystemPackages: Bool { didSet { d.set(hideSystemPackages, forKey: "hideSystemPackages") } }
    var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    /// Show the number of ready updates next to the menu bar icon. Default: on.
    var showMenuBarCount: Bool { didSet { d.set(showMenuBarCount, forKey: "showMenuBarCount") } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSLog("Launch at login failed: \(error)") }
        }
    }

    private init() {
        minAgeHours = d.object(forKey: "minAgeHours") as? Double ?? 24
        securityMinAgeHours = d.object(forKey: "securityMinAgeHours") as? Double ?? 4
        checkIntervalHours = d.object(forKey: "checkIntervalHours") as? Double ?? 6
        brewGreedy = d.bool(forKey: "brewGreedy")
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        disabledManagers = Set((d.stringArray(forKey: "disabledManagers") ?? []).compactMap(Manager.init(rawValue:)))
        ignoredPackages = Set(d.stringArray(forKey: "ignoredPackages") ?? [])
        hideSystemPackages = d.object(forKey: "hideSystemPackages") as? Bool ?? true
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        showMenuBarCount = d.object(forKey: "showMenuBarCount") as? Bool ?? true
    }

    var enabledManagers: [Manager] { Manager.allCases.filter { !disabledManagers.contains($0) } }

    func threshold(for pkg: OutdatedPackage) -> TimeInterval {
        (pkg.isSecurity ? securityMinAgeHours : minAgeHours) * 3600
    }
}
