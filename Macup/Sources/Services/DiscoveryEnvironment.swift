import Foundation

/// All effects are injected. Tests run the same discovery/action code against disposable trees and
/// real fixture executables, with deterministic vendor responses instead of a person's software.
struct DiscoveryEnvironment: @unchecked Sendable {
    typealias Runner =
        @Sendable (String, [String], [String: String], TimeInterval, String?) async throws -> SubprocessResult
    typealias Loader = @Sendable (URL) async throws -> Data
    typealias Downloader = @Sendable (URL, URL) async throws -> Void

    var home: URL
    var systemRoot: URL
    var variables: [String: String]
    var run: Runner
    var load: Loader
    var download: Downloader?
    var now = Date()

    static func live(_ provided: [String: String]) -> DiscoveryEnvironment {
        var variables = provided
        if let preferred = variables["MACUP_USER_PATH"], !preferred.isEmpty { variables["PATH"] = preferred }
        let home = URL(fileURLWithPath: variables["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        let root = URL(fileURLWithPath: variables["MACUP_DISCOVERY_ROOT"] ?? "/", isDirectory: true)
        return DiscoveryEnvironment(
            home: home, systemRoot: root, variables: variables,
            run: { executable, arguments, environment, timeout, directory in
                try await Subprocess.run(
                    executable: executable, arguments: arguments, environment: environment,
                    timeout: timeout, label: URL(fileURLWithPath: executable).lastPathComponent,
                    workingDirectory: directory.map { URL(fileURLWithPath: $0) })
            },
            load: { url in
                guard url.scheme == "https", url.user == nil, url.password == nil else {
                    throw DiscoveryError.invalid("Update metadata must use HTTPS without embedded credentials")
                }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                request.setValue("MacUp", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                    response.url?.scheme == "https",
                    data.count <= 8 * 1_024 * 1_024
                else { throw DiscoveryError.invalid("The update server did not return usable metadata") }
                return data
            },
            download: { url, destination in
                guard url.scheme == "https", url.user == nil, url.password == nil else {
                    throw DiscoveryError.invalid("Invalid vendor download URL")
                }
                let (temporary, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                    response.url?.scheme == "https",
                    (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 512 * 1_024 * 1_024
                else { throw DiscoveryError.invalid("Invalid or oversized vendor download") }
                try FileManager.default.moveItem(at: temporary, to: destination)
            })
    }

    func system(_ path: String) -> URL {
        systemRoot.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// Native CLIs sometimes print paths relative to the directory they were run in (our home).
    func fileURL(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
    }

    func executable(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let path = variables["MACUP_USER_PATH"] ?? variables["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let directories =
            path.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            + [
                home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".cargo/bin"),
                system("opt/homebrew/bin"), system("usr/local/bin"),
            ]
        for directory in directories {
            let candidate = directory.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func execute(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 20
    ) async throws -> SubprocessResult {
        try await run(executable, arguments, variables, timeout, home.path)
    }

    func children(_ root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    func object(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func plist(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    func owner(of executable: String) -> String? {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        for (key, owner) in [
            ("ASDF_DATA_DIR", "asdf"), ("VOLTA_HOME", "Volta"), ("NVM_DIR", "nvm"),
            ("FNM_DIR", "fnm"), ("MISE_DATA_DIR", "mise"),
        ] {
            if let configured = variables[key], !configured.isEmpty {
                let root = fileURL(configured).resolvingSymlinksInPath().path
                if path == root || path.hasPrefix(root + "/") { return owner }
            }
        }
        if path.contains("/Cellar/") || path.contains("/Caskroom/") { return "Homebrew" }
        if path.contains("/node_modules/") { return "npm" }
        if path.contains("/nix/store/") { return "Nix" }
        if path.contains("/mise/") { return "mise" }
        if path.contains("/.asdf/") { return "asdf" }
        if path.contains("/.volta/") { return "Volta" }
        if path.contains("/.nvm/") { return "nvm" }
        if path.contains("/fnm/") { return "fnm" }
        if path.contains("/opt/local/") { return "MacPorts" }
        return nil
    }
}

enum DiscoveryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}
