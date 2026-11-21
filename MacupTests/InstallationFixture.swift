import Foundation
import XCTest

@testable import Macup

/// Real files and processes, deterministic network responses. No host installation is writable.
final class InstallationFixture: @unchecked Sendable {
    struct Call {
        var executable: String
        var arguments: [String]
        var directory: String?
    }
    let root: URL
    let home: URL
    let system: URL
    var variables: [String: String]
    private let lock = NSLock()
    private var commands: [String: SubprocessResult] = [:]
    private var metadata: [String: Data] = [:]
    private var recorded: [Call] = []
    private var fetched: [String] = []
    var handler: DiscoveryEnvironment.Runner?
    var downloader: DiscoveryEnvironment.Downloader?

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "macup-installations-\(UUID())")
        home = root.appendingPathComponent("home")
        system = root.appendingPathComponent("system")
        variables = ["HOME": home.path, "PATH": home.appendingPathComponent("bin").path]
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var calls: [Call] { lock.withLock { recorded } }
    var requests: [String] { lock.withLock { fetched } }
    var environment: DiscoveryEnvironment {
        DiscoveryEnvironment(
            home: home, systemRoot: system, variables: variables,
            run: { [self] executable, args, env, timeout, directory in
                lock.withLock { recorded.append(Call(executable: executable, arguments: args, directory: directory)) }
                if let result = lock.withLock({ commands[key(executable, args)] }) { return result }
                if let handler { return try await handler(executable, args, env, timeout, directory) }
                if executable == "/usr/bin/tar" {
                    return try await Subprocess.run(
                        executable: executable, arguments: args, environment: env, timeout: timeout)
                }
                throw DiscoveryError.invalid("Unexpected fixture command: \(executable) \(args)")
            },
            load: { [self] url in
                lock.withLock { fetched.append(url.absoluteString) }
                guard let data = lock.withLock({ metadata[url.absoluteString] }) else {
                    throw DiscoveryError.invalid("Fixture server unavailable")
                }
                return data
            }, download: downloader)
    }

    @discardableResult
    func file(_ url: URL, _ contents: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    func executable(_ name: String) throws -> String {
        let url = try file(home.appendingPathComponent("bin/\(name)"), "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func object(_ url: URL, _ value: Any) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }

    func response(_ executable: String, _ args: [String], _ output: String = "", status: Int32 = 0) {
        lock.withLock { commands[key(executable, args)] = Self.result(output, status: status) }
    }

    func feed(_ address: String, _ contents: String) { lock.withLock { metadata[address] = Data(contents.utf8) } }
    func json(_ address: String, _ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        lock.withLock { metadata[address] = data }
    }

    static func result(_ output: String = "", status: Int32 = 0) -> SubprocessResult {
        SubprocessResult(status: status, stdout: output, stderr: status > 1 ? output : "", combined: output)
    }

    private func key(_ executable: String, _ args: [String]) -> String {
        executable + "\0" + args.joined(separator: "\0")
    }

    func app(_ name: String, version: String = "1.0", build: String = "100", extra: [String: Any] = [:]) throws -> URL {
        let url = system.appendingPathComponent("Applications/\(name).app")
        var info: [String: Any] = [
            "CFBundleIdentifier": "test.\(name)", "CFBundleShortVersionString": version, "CFBundleVersion": build,
        ]
        info.merge(extra) { _, new in new }
        let file = try file(url.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: file)
        return url
    }
}
