import Foundation

enum InstallationVerification {
    static func verify(_ package: OutdatedPackage, removing: Bool, environment: DiscoveryEnvironment) async throws {
        guard let reference = package.installation, let action = removing ? reference.remove : reference.update,
            action.kind == .command
        else { return }
        let scanner = InstallationDiscovery(environment: environment)
        var found: String?
        switch package.manager {
        case .npm:
            found =
                environment.object(URL(fileURLWithPath: reference.path).appendingPathComponent("package.json"))?[
                    "version"] as? String
        case .tools, .orbstack:
            let result = try await environment.execute(
                action.executable, package.manager == .orbstack ? ["version"] : ["--version"])
            guard result.status == 0 else {
                throw DiscoveryError.invalid(
                    "The updater exited successfully, but the installed tool could not be verified")
            }
            found = await scanner.version(result.stdout)
        case .dotnet, .dart, .asdf:
            let args =
                package.manager == .dotnet
                ? ["tool", "list", "--global"]
                : package.manager == .dart ? ["pub", "global", "list"] : ["current"]
            let result = try await environment.execute(action.executable, args)
            guard result.status == 0 else { throw DiscoveryError.invalid("Could not verify the installed tool list") }
            found = await scanner.versionedRows(result.stdout).first { $0.name == package.name }?.version
        case .volta:
            let result = try await environment.execute(action.executable, ["list", "--default", "--format", "plain"])
            guard result.status == 0 else { throw DiscoveryError.invalid("Could not verify Volta's default toolchain") }
            found = result.stdout.components(separatedBy: package.name + "@").dropFirst().first
                .flatMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        case .runtimes:
            let result = try await environment.execute(
                action.executable, ["python", "list", "--only-installed", "--output-format", "json"])
            guard result.status == 0, let data = result.stdout.data(using: .utf8),
                let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                throw DiscoveryError.invalid("Could not verify managed Python installations")
            }
            found = rows.filter { row in
                guard let path = row["path"] as? String else { return false }
                return environment.fileURL(path).path.hasPrefix(reference.root + "/")
            }
            .compactMap { $0["version"] as? String }.filter {
                $0.split(separator: ".").prefix(2) == package.installed.split(separator: ".").prefix(2)
            }
            .max { Version.compare($0, $1) == .orderedAscending }
        case .extensions, .nixprofile:
            // These native updaters can target commits or flake derivations without a version label.
            // Their exit status is recorded as "Ran updater" and the immediate rescan checks again.
            return
        default: return
        }
        if removing {
            guard found == nil else {
                throw DiscoveryError.invalid(
                    "The removal command exited successfully, but this installation is still present")
            }
        } else {
            guard let found else {
                throw DiscoveryError.invalid("The updater exited successfully, but this installation is missing")
            }
            if package.latest == "Available" {
                guard Version.isNewer(found, than: package.installed) else {
                    throw DiscoveryError.invalid(
                        "The updater exited successfully, but the installed version has not changed")
                }
            } else if Version.compare(found, package.latest) == .orderedAscending {
                throw DiscoveryError.invalid(
                    "The updater exited successfully, but this installation is still at \(found); expected \(package.latest)"
                )
            }
        }
    }
}
