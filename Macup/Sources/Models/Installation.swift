import Foundation

/// The installer and location are part of an update's identity. Two npm prefixes, or two runtime
/// managers, must never share an update command merely because their packages have the same name.
struct InstallationReference: Codable, Hashable {
    var path: String
    var root: String
    var owner: String
    var isDefault = false
    var identityPath: String?
    var release: String?
    var publicPackage: Bool?
    var expectedPackage: String?
    var update: InstallationAction?
    var remove: InstallationAction?

    var key: String {
        Data((identityPath ?? path).utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Actions contain argv, never a shell command assembled from an app name or a registry response.
struct InstallationAction: Codable, Hashable {
    enum Kind: String, Codable { case command, openApp, openURL, nodePatch }

    var kind: Kind = .command
    var executable: String
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var workingDirectory: String?
    var manualOnly = true
    var title = "Update"
    var followUp: [InstallationCommand] = []

    var isHandoff: Bool { kind == .openApp || kind == .openURL }
    var successDetail: String {
        switch kind {
        case .openApp: "Opened app"
        case .openURL: "Opened vendor updates"
        case .command, .nodePatch: "Updated"
        }
    }
}

struct InstallationCommand: Codable, Hashable {
    var executable: String
    var arguments: [String]
}

struct InstalledItem: Identifiable, Codable, Hashable {
    enum State: String, Codable { case active, inactive, managed, manual, orphaned }

    var manager: Manager
    var name: String
    var version: String
    var reference: InstallationReference
    var state: State = .active
    var latest: String?
    var updateAvailable: Bool?
    var note = ""

    var id: String { "\(manager.rawValue):\(reference.key):\(name)" }
    var package: OutdatedPackage {
        var result = OutdatedPackage(
            manager: manager, name: name, installed: version, latest: latest ?? version,
            kind: "installation", extra: "")
        result.installation = reference
        return result
    }
}

extension OutdatedPackage {
    var opensExternally: Bool { installation?.update?.isHandoff ?? manager.opensExternally }
    var manualOnly: Bool { installation?.update?.manualOnly ?? manager.opensExternally }
    var supportsRemoval: Bool {
        installation.map { $0.remove != nil } ?? manager.supportsRemoval
    }
    var updateButtonTitle: String { installation?.update?.title ?? manager.updateButtonTitle }
    var updateHelp: String {
        if let installation {
            return "\(updateButtonTitle) using \(installation.owner) · \(installation.path)"
        }
        return manager.externalUpdateHelp
    }
}
