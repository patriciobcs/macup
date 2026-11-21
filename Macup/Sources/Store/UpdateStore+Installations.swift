import Foundation

extension UpdateStore {
    struct InstallationMigration {
        var firstSeen: [String: Date]
        var failures: [String: String]
        var notified: Set<String>
    }

    /// Old npm ids described only the active prefix. Migrate that copy without ignoring every other
    /// prefix with the same package name, and retain its wait period and action history.
    func installationMigration(_ incoming: [OutdatedPackage]) -> InstallationMigration {
        var result = InstallationMigration(firstSeen: firstSeen, failures: failures, notified: notified)
        var mapping: [String: String] = [:]
        for package in incoming where package.installation?.isDefault == true {
            mapping[package.legacyID] = package.id
            if settings.ignoredPackages.remove(package.legacyID) != nil { settings.ignoredPackages.insert(package.id) }
            let oldKey = "\(package.legacyID)@\(package.latest)"
            if let date = result.firstSeen.removeValue(forKey: oldKey) { result.firstSeen[package.versionKey] = date }
            if result.notified.remove(oldKey) != nil { result.notified.insert(package.versionKey) }
            if let failure = result.failures.removeValue(forKey: package.legacyID) {
                result.failures[package.id] = failure
            }
        }
        history.migratePackageIDs(mapping)
        return result
    }

    var hasUncheckedInstallations: Bool {
        installations.contains { $0.state != .managed && $0.latest == nil && settings.isEnabled($0.manager) }
    }
}
