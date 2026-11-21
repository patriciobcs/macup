import Foundation

enum InstallationActions {
    static func commandLine(_ action: InstallationAction) -> String {
        let arguments: [String]
        switch action.kind {
        case .command: arguments = [action.executable] + action.arguments
        case .openApp: arguments = ["/usr/bin/open", "-a", action.executable]
        case .openURL: arguments = ["/usr/bin/open", action.executable]
        case .nodePatch: return "Verified Node.js \(action.arguments.first ?? "patch") at \(action.executable)"
        }
        let command =
            arguments.map(quote).joined(separator: " ")
            + action.followUp.map { " && " + ([$0.executable] + $0.arguments).map(quote).joined(separator: " ") }
            .joined()
        return action.workingDirectory.map { "(cd \(quote($0)) && \(command))" } ?? command
    }

    static func run(
        _ package: OutdatedPackage, removing: Bool = false, environment: DiscoveryEnvironment,
        dryRun: Bool = false, onOutput: @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        guard let reference = package.installation,
            let action = removing ? reference.remove : reference.update
        else { throw DiscoveryError.invalid("This installation has no supported action") }
        let line = "$ \(commandLine(action))\n"
        if dryRun { return SubprocessResult(status: 0, stdout: line, stderr: "", combined: line) }
        try validate(package, removing: removing, environment: environment)
        onOutput(line)
        if action.kind == .nodePatch {
            return try await NodeRuntimeUpdater.run(package, environment: environment, onOutput: onOutput)
        }
        var variables = environment.variables
        for (key, value) in action.environment { variables[key] = value }
        let executable: String
        let arguments: [String]
        switch action.kind {
        case .openApp:
            executable = "/usr/bin/open"
            arguments = ["-a", action.executable]
        case .openURL:
            guard let url = URL(string: action.executable), url.scheme == "https", url.user == nil, url.password == nil
            else {
                throw DiscoveryError.invalid("Vendor updates must use an HTTPS URL")
            }
            executable = "/usr/bin/open"
            arguments = [url.absoluteString]
        case .command:
            executable = action.executable
            arguments = action.arguments
        case .nodePatch: throw DiscoveryError.invalid("Invalid runtime action")
        }
        var result = try await environment.run(
            executable, arguments, variables, 3_600, action.workingDirectory ?? environment.home.path)
        onOutput(result.combined)
        if result.status == 0 {
            for command in action.followUp {
                let next = try await environment.run(
                    command.executable, command.arguments, variables, 3_600, environment.home.path)
                onOutput(next.combined)
                result.stdout += next.stdout
                result.stderr += next.stderr
                result.combined += next.combined
                result.status = next.status
                if next.status != 0 { break }
            }
        }
        if result.status == 0 {
            try await InstallationVerification.verify(package, removing: removing, environment: environment)
        }
        return result
    }

    static func validate(_ package: OutdatedPackage, removing: Bool, environment: DiscoveryEnvironment) throws {
        guard let reference = package.installation else {
            throw DiscoveryError.invalid("Missing installation identity")
        }
        let path = URL(fileURLWithPath: reference.path).standardizedFileURL
        let root = URL(fileURLWithPath: reference.root).standardizedFileURL
        guard FileManager.default.fileExists(atPath: path.path),
            path.path == root.path || path.path.hasPrefix(root.path + "/")
        else {
            throw DiscoveryError.invalid(
                "The recorded installation is missing or outside its original location; check again")
        }
        let canonical = path.resolvingSymlinksInPath().path
        let canonicalRoot = root.resolvingSymlinksInPath().path
        let allowedLink = package.manager == .nixprofile || (removing && package.manager == .npm)
        guard allowedLink || canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") else {
            throw DiscoveryError.invalid("The installation now points somewhere else; check again before updating")
        }
        if package.manager == .npm {
            let document = environment.object(path.appendingPathComponent("package.json"))
            guard document?["name"] as? String == reference.expectedPackage else {
                throw DiscoveryError.invalid("The npm package at this location has changed")
            }
            guard !canonical.contains("/Cellar/") else {
                throw DiscoveryError.invalid("Homebrew now owns this package; update it with Homebrew")
            }
        }
        if package.manager == .apps {
            let identifier =
                environment.plist(path.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
            guard identifier == reference.expectedPackage else {
                throw DiscoveryError.invalid("The app at this path has a different identity; check again")
            }
        }
        if package.manager == .tools || package.manager == .orbstack {
            guard environment.owner(of: reference.path) == nil else {
                throw DiscoveryError.invalid("Another package manager now owns this tool; check again")
            }
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
