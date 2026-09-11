import Foundation

/// Runs the bundled zsh scripts (Resources/Scripts) with the user's shell PATH.
enum ScriptRunner {
    static func scriptURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "sh", subdirectory: "Scripts")
    }

    static func environment(brewGreedy: Bool) async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // The login shell's variables (PNPM_HOME, GOPATH, NVM_DIR, …) on top of the GUI environment.
        for (k, v) in await ShellEnvironment.shared.loginEnvironment() where k != "PATH" { env[k] = v }
        env["MACUP_USER_PATH"] = await ShellEnvironment.shared.userPATH()
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["TERM"] = "dumb"
        if brewGreedy { env["MACUP_BREW_GREEDY"] = "1" } else { env.removeValue(forKey: "MACUP_BREW_GREEDY") }
        return env
    }

    static func scan(managers: [Manager], brewGreedy: Bool) async throws -> ScanResult {
        guard let url = scriptURL("macup-scan") else {
            throw SubprocessError.launchFailed("macup-scan.sh missing from bundle")
        }
        let env = await environment(brewGreedy: brewGreedy)
        let r = try await Subprocess.run(
            executable: "/bin/zsh", arguments: [url.path] + managers.map(\.rawValue),
            environment: env, timeout: 300, label: "The scan")
        return ScanParser.parse(r.stdout)
    }

    static func upgrade(
        manager: Manager, arguments: [String], brewGreedy: Bool,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> SubprocessResult {
        guard let url = scriptURL("macup-upgrade") else {
            throw SubprocessError.launchFailed("macup-upgrade.sh missing from bundle")
        }
        let env = await environment(brewGreedy: brewGreedy)
        return try await Subprocess.run(
            executable: "/bin/zsh", arguments: [url.path, manager.rawValue] + arguments,
            environment: env, timeout: 3600, label: "The \(manager.title) update", onOutput: onOutput)
    }

    static func remove(
        pkg: OutdatedPackage, brewGreedy: Bool,
        onOutput: @Sendable @escaping (String) -> Void
    ) async throws -> SubprocessResult {
        guard let url = scriptURL("macup-remove") else {
            throw SubprocessError.launchFailed("macup-remove.sh missing from bundle")
        }
        let env = await environment(brewGreedy: brewGreedy)
        // Removal takes the package's own name (Go removes the binary, mas needs the App Store id).
        let name = pkg.manager == .mas ? pkg.extra : pkg.name
        return try await Subprocess.run(
            executable: "/bin/zsh", arguments: [url.path, pkg.manager.rawValue, name, pkg.baseKind],
            environment: env, timeout: 600, label: "Removing \(pkg.name)", onOutput: onOutput)
    }

    static func setup(tool: String, onOutput: @Sendable @escaping (String) -> Void) async throws -> SubprocessResult {
        guard let url = scriptURL("macup-setup") else {
            throw SubprocessError.launchFailed("macup-setup.sh missing from bundle")
        }
        let env = await environment(brewGreedy: false)
        return try await Subprocess.run(
            executable: "/bin/zsh", arguments: [url.path, tool],
            environment: env, timeout: 900, label: "Installing \(tool)", onOutput: onOutput)
    }
}
