import Foundation

/// Captures the environment of the user's login shell once per launch, so the scripts see the same
/// PATH and variables the user has in Terminal (Homebrew, nvm, PNPM_HOME, GOPATH, CARGO_HOME, …).
/// GUI apps otherwise inherit a minimal environment. An actor, so the cache is safe from any task.
actor ShellEnvironment {
    static let shared = ShellEnvironment()

    private static let marker = "__MACUP_ENV__"
    private var cached: [String: String]?
    /// Session-specific or otherwise meaningless outside the shell that produced them.
    private static let excluded: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "TMPDIR", "HOME", "USER", "LOGNAME", "SHELL", "XPC_SERVICE_NAME", "XPC_FLAGS", "__CF_USER_TEXT_ENCODING",
    ]

    func loginEnvironment() async -> [String: String] {
        if let cached { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env: [String: String] = [:]
        if let result = try? await Subprocess.run(
            executable: shell, arguments: ["-i", "-l", "-c", "echo \(Self.marker); env"],
            environment: nil, timeout: 8),
            let range = result.stdout.range(of: Self.marker + "\n")
        {
            for line in result.stdout[range.upperBound...].split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                    !Self.excluded.contains(key)
                else { continue }
                env[key] = String(line[line.index(after: eq)...])
            }
        }
        // An empty result means the shell hung or printed nothing; try again next time instead of
        // pinning every later scan to the GUI's minimal environment.
        if !env.isEmpty { cached = env }
        return env
    }

    func userPATH() async -> String {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let path = await loginEnvironment()["PATH"] ?? ""
        return path.isEmpty ? fallback : path
    }
}
