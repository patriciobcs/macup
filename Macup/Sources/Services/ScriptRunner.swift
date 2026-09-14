import Foundation

/// Runs the bundled zsh scripts (Resources/Scripts) with the user's shell PATH.
enum ScriptRunner {
    static func scriptURL(_ name: String) -> URL? {
        // Tests point this at stub scripts so the upgrade and removal paths can run for real without
        // touching the machine's packages.
        if let dir = ProcessInfo.processInfo.environment["MACUP_SCRIPT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).sh")
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return Bundle.main.url(forResource: name, withExtension: "sh", subdirectory: "Scripts")
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
        // Commands the user changed. The scripts fall back to their own defaults for everything else,
        // and ignore these entirely for the managers that can run with an administrator password.
        for (key, command) in await MainActor.run(body: { Preferences.shared.commandOverrides })
        where !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["MACUP_CMD_\(key)"] = command
        }
        return env
    }

    /// The commands the scripts would run, read from the scripts themselves so what the app shows is
    /// what runs. Cheap: the script prints its table and exits without going near a package manager.
    static func commands() async -> CommandBook {
        guard let url = scriptURL("macup-scan") else { return CommandBook() }
        let env = await environment(brewGreedy: false)
        let result = try? await Subprocess.run(
            executable: "/bin/zsh", arguments: [url.path, "--commands"],
            environment: env, timeout: 30, label: "Reading the commands")
        return CommandBook(commandLines: result?.stdout ?? "")
    }

    /// Runs one manager's check with a candidate command in place, and reports what came back. The
    /// real scan is used, parser and all, because "is this command still understood" is exactly the
    /// question the parser answers — a command that runs fine but prints something else finds nothing.
    static func testCheck(manager: Manager, command: String, brewGreedy: Bool) async -> ScanResult {
        guard let url = scriptURL("macup-scan") else { return ScanResult(reports: [], packages: []) }
        var env = await environment(brewGreedy: brewGreedy)
        env[CommandBook.key(.check, manager)] = command
        let result = try? await Subprocess.run(
            executable: "/bin/zsh", arguments: [url.path, manager.rawValue],
            environment: env, timeout: 120, label: "Testing the \(manager.title) command")
        return ScanParser.parse(result?.stdout ?? "")
    }

    /// `onReport` is called as each manager finishes, which is what lets the setup window fill in
    /// rather than sit on a spinner until the slowest scanner returns.
    static func scan(
        managers: [Manager], brewGreedy: Bool, onReport: (@Sendable (ManagerReport) -> Void)? = nil
    ) async throws -> ScanResult {
        guard let url = scriptURL("macup-scan") else {
            throw SubprocessError.launchFailed("macup-scan.sh missing from bundle")
        }
        let env = await environment(brewGreedy: brewGreedy)
        let lines = LineBuffer()
        let r = try await Subprocess.run(
            executable: "/bin/zsh", arguments: [url.path] + managers.map(\.rawValue),
            environment: env, timeout: 300, label: "The scan"
        ) { chunk in
            guard let onReport else { return }
            for line in lines.take(chunk) {
                for report in ScanParser.parse(line).reports { onReport(report) }
            }
        }
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

/// Output arrives in chunks that can split a line in half, so the tail is held until the rest lands.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func take(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        guard let last = pending.lastIndex(of: "\n") else { return [] }
        let complete = pending[..<last]
        pending = String(pending[pending.index(after: last)...])
        return complete.split(separator: "\n").map(String.init)
    }
}
