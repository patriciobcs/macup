import Foundation

actor InstallationDiscovery {
    let environment: DiscoveryEnvironment
    var responses: [URL: Data] = [:]
    var failures: [String] = []
    var publicNpmSources: [String: Bool] = [:]

    init(environment: DiscoveryEnvironment) { self.environment = environment }

    static func scanAll(
        _ managers: [Manager], existing: ScanResult, environment: DiscoveryEnvironment,
        onReport: (@Sendable (ManagerReport) -> Void)? = nil
    ) async -> ScanResult {
        let targets = managers.filter { $0.usesInstallationBackend || $0 == .npm || $0 == .tools }
        var result = existing
        await withTaskGroup(of: (Manager, ScanResult).self) { group in
            for manager in targets {
                let seed = ScanResult(
                    reports: existing.reports.filter { $0.manager == manager },
                    packages: existing.packages.filter { $0.manager == manager },
                    tools: manager == .tools ? existing.tools : [])
                group.addTask {
                    let scanner = InstallationDiscovery(environment: environment)
                    return (manager, await scanner.scan([manager], existing: seed))
                }
            }
            for await (manager, scanned) in group {
                result.reports.removeAll { $0.manager == manager }
                result.packages.removeAll { $0.manager == manager }
                result.installations.removeAll { $0.manager == manager }
                result.reports += scanned.reports
                result.packages += scanned.packages
                result.installations += scanned.installations
                if manager == .tools { result.tools = scanned.tools }
                for report in scanned.reports { onReport?(report) }
            }
        }
        return result
    }

    func data(_ address: String) async throws -> Data {
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else {
            throw DiscoveryError.invalid("Invalid vendor metadata URL")
        }
        if let data = responses[url] { return data }
        let data = try await environment.load(url)
        responses[url] = data
        return data
    }

    func json(_ address: String) async throws -> Any {
        try JSONSerialization.jsonObject(with: await data(address))
    }

    func text(_ address: String) async throws -> String {
        guard let text = String(data: try await data(address), encoding: .utf8) else {
            throw DiscoveryError.invalid("Vendor metadata is not valid UTF-8")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scan(_ managers: [Manager], existing: ScanResult = ScanResult()) async -> ScanResult {
        var result = existing
        for manager in managers {
            failures = []
            let items: [InstalledItem]
            switch manager {
            case .npm: items = await npmInstallations(existing: &result)
            case .tools: items = await nativeCLIs()
            case .orbstack: items = await orbStack()
            case .apps: items = await desktopApps()
            case .runtimes: items = await runtimes()
            case .extensions, .dotnet, .dart, .nixprofile, .asdf, .volta:
                items = await managedInstallations(manager)
            default: continue
            }
            result.installations += items
            if manager == .tools {
                for name in ["claude", "devin"] {
                    let item = items.first { $0.name == name }
                    result.tools.removeAll { $0.name == name }
                    result.tools.append(
                        ToolReport(
                            name: name,
                            presence: item.map { $0.state == .managed ? .managed : .found } ?? .missing,
                            detail: item.map { $0.state == .managed ? $0.reference.owner : $0.version } ?? ""))
                }
            }
            for item in items {
                guard let latest = item.latest, item.updateAvailable ?? Version.isNewer(latest, than: item.version),
                    item.reference.update != nil, item.state != .managed
                else { continue }
                let package = item.package
                if !result.packages.contains(where: { $0.id == package.id }) { result.packages.append(package) }
            }
            if manager.usesInstallationBackend || !items.isEmpty {
                let report = ManagerReport(
                    manager: manager, status: failures.isEmpty ? (items.isEmpty ? .missing : .ok) : .error,
                    message: failures.prefix(3).joined(separator: "; "))
                if let index = result.reports.firstIndex(where: { $0.manager == manager }) {
                    // A supplemental native CLI lookup must not hide a legacy manager's failure.
                    if manager.usesInstallationBackend || result.reports[index].status != .error {
                        result.reports[index] = report
                    }
                } else {
                    result.reports.append(report)
                }
            }
        }
        return result
    }

    func packageReference(
        path: URL, root: URL, owner: String, name: String, action: InstallationAction?,
        remove: InstallationAction? = nil, isDefault: Bool = false
    ) -> InstallationReference {
        var update = action
        var removal = remove
        if update?.kind == .command && update?.workingDirectory == nil {
            update?.workingDirectory = environment.home.path
        }
        if removal?.kind == .command && removal?.workingDirectory == nil {
            removal?.workingDirectory = environment.home.path
        }
        return InstallationReference(
            path: path.standardizedFileURL.path, root: root.resolvingSymlinksInPath().path,
            owner: owner, isDefault: isDefault, expectedPackage: name, update: update, remove: removal)
    }

    func version(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+(?:\.\d+)+(?:[-+][A-Za-z0-9.-]+)?"#, options: .regularExpression)
        else { return nil }
        return String(output[range])
    }
}
