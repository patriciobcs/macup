import CryptoKit
import Darwin
import Foundation

/// Only an explicitly selected standalone Node runtime is replaced. npm/global packages are never
/// extracted from the distribution; they remain in the original prefix. A failed swap rolls back.
enum NodeRuntimeUpdater {
    static func run(
        _ package: OutdatedPackage, environment: DiscoveryEnvironment,
        onOutput: @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        guard let reference = package.installation, let action = reference.update,
            action.arguments.count == 2, let download = environment.download
        else { throw DiscoveryError.invalid("Missing runtime update details") }
        let target = action.arguments[0]
        let architecture = action.arguments[1]
        try validateTarget(package, target: target, architecture: architecture)
        let root = URL(fileURLWithPath: reference.root)
        let installed = URL(fileURLWithPath: reference.path)
        guard installed.lastPathComponent == "node", installed.deletingLastPathComponent().lastPathComponent == "bin",
            installed.deletingLastPathComponent().deletingLastPathComponent().path == root.path,
            environment.owner(of: installed.path) == nil
        else { throw DiscoveryError.invalid("This runtime must be updated by its owning version manager") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("macup-node-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suffix = architecture == "arm64" ? "arm64" : "x64"
        let name = "node-v\(target)-darwin-\(suffix)"
        let filename = "\(name).tar.gz"
        let archive = temporary.appendingPathComponent(filename)
        let base = "https://nodejs.org/dist/v\(target)/"
        guard let checksumURL = URL(string: base + "SHASUMS256.txt"), let archiveURL = URL(string: base + filename)
        else {
            throw DiscoveryError.invalid("Invalid runtime download location")
        }
        onOutput("Downloading the official Node.js distribution and checksum…\n")
        let checksums = try await environment.load(checksumURL)
        try await download(archiveURL, archive)
        try verifyChecksum(archive, manifest: checksums, filename: filename)
        let staged = try await extract(archive, name: name, temporary: temporary, environment: environment)
        guard BinaryArchitecture.read(staged.appendingPathComponent("bin/node")).contains(architecture) else {
            throw DiscoveryError.invalid("The downloaded runtime has a different architecture")
        }
        try await verifyPublisher(
            installed, candidate: staged.appendingPathComponent("bin/node"), environment: environment)
        let check = try await environment.execute(staged.appendingPathComponent("bin/node").path, ["--version"])
        guard check.status == 0, check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "v\(target)" else {
            throw DiscoveryError.invalid("The downloaded runtime did not report the expected version")
        }
        onOutput("Verified checksum, signing identity and runtime version. Replacing this prefix's runtime…\n")
        try await swap(staged, root: root, target: target, environment: environment)
        let output = "Updated Node.js to \(target) at \(installed.path); global npm packages were preserved.\n"
        onOutput(output)
        return SubprocessResult(status: 0, stdout: output, stderr: "", combined: output)
    }

    static func validateTarget(_ package: OutdatedPackage, target: String, architecture: String) throws {
        guard target.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
            target.split(separator: ".").first == package.installed.split(separator: ".").first,
            Version.isNewer(target, than: package.installed), ["arm64", "x86_64"].contains(architecture)
        else { throw DiscoveryError.invalid("Runtime updates must stay on the installed Node major and architecture") }
    }

    static func verifyChecksum(_ file: URL, manifest: Data, filename: String) throws {
        guard let manifest = String(data: manifest, encoding: .utf8) else {
            throw DiscoveryError.invalid("Invalid vendor checksum manifest")
        }
        let expected = manifest.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[1] == filename ? String(fields[0]).lowercased() : nil
        }.first
        guard let expected, expected.count == 64 else { throw DiscoveryError.invalid("The vendor checksum is missing") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw DiscoveryError.invalid("Node.js archive checksum mismatch") }
    }

    private static func extract(
        _ archive: URL, name: String, temporary: URL, environment: DiscoveryEnvironment
    ) async throws -> URL {
        let listing = try await environment.execute("/usr/bin/tar", ["-tzf", archive.path])
        guard listing.status == 0,
            listing.stdout.split(separator: "\n").allSatisfy({ path in
                !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && path.hasPrefix(name + "/")
            })
        else { throw DiscoveryError.invalid("The Node.js archive contains unsafe paths") }
        let details = try await environment.execute(
            "/usr/bin/tar",
            [
                "-tvzf", archive.path,
                "\(name)/bin/node", "\(name)/include/node",
            ])
        guard details.status == 0,
            details.stdout.split(separator: "\n").allSatisfy({
                $0.hasPrefix("-") || $0.hasPrefix("d")
            })
        else { throw DiscoveryError.invalid("The runtime archive contains unexpected links") }
        let result = try await environment.execute(
            "/usr/bin/tar",
            [
                "-xzf", archive.path, "-C", temporary.path,
                "\(name)/bin/node", "\(name)/include/node",
            ])
        let root = temporary.appendingPathComponent(name)
        let binary = root.appendingPathComponent("bin/node")
        guard result.status == 0, binary.resolvingSymlinksInPath().path == binary.path,
            FileManager.default.isExecutableFile(atPath: binary.path)
        else { throw DiscoveryError.invalid("The verified archive did not contain the expected runtime") }
        return root
    }

    private static func verifyPublisher(
        _ installed: URL, candidate: URL, environment: DiscoveryEnvironment
    ) async throws {
        let verification = try await environment.execute("/usr/bin/codesign", ["--verify", "--strict", candidate.path])
        let old = try await environment.execute("/usr/bin/codesign", ["-dv", "--verbose=4", installed.path])
        let new = try await environment.execute("/usr/bin/codesign", ["-dv", "--verbose=4", candidate.path])
        func team(_ text: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst(15)) }
        }
        guard verification.status == 0, let previous = team(old.combined), previous != "not set",
            previous == team(new.combined)
        else { throw DiscoveryError.invalid("The new runtime's signing identity does not match this installation") }
    }

    private static func swap(_ staged: URL, root: URL, target: String, environment: DiscoveryEnvironment) async throws {
        let manager = FileManager.default
        let identifier = UUID().uuidString
        let destinations = [root.appendingPathComponent("include/node"), root.appendingPathComponent("bin/node")]
        let sources = [staged.appendingPathComponent("include/node"), staged.appendingPathComponent("bin/node")]
        var replacements: [(destination: URL, backup: URL?)] = []
        do {
            for (source, destination) in zip(sources, destinations) {
                guard destination.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
                else {
                    throw DiscoveryError.invalid("Runtime files now point outside the installation")
                }
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let incoming = destination.deletingLastPathComponent().appendingPathComponent(
                    ".macup-incoming-\(identifier)")
                let backup = destination.deletingLastPathComponent().appendingPathComponent(
                    ".macup-previous-\(identifier)")
                try manager.copyItem(at: source, to: incoming)
                let existed = manager.fileExists(atPath: destination.path)
                let binary = destination.deletingLastPathComponent().lastPathComponent == "bin"
                if existed {
                    if binary {
                        try manager.linkItem(at: destination, to: backup)
                    } else {
                        try manager.moveItem(at: destination, to: backup)
                    }
                }
                replacements.append((destination, existed ? backup : nil))
                do {
                    if binary {
                        try atomicRename(incoming, to: destination)
                    } else {
                        try manager.moveItem(at: incoming, to: destination)
                    }
                } catch {
                    try? manager.removeItem(at: incoming)
                    throw error
                }
            }
            let result = try await environment.execute(root.appendingPathComponent("bin/node").path, ["--version"])
            guard result.status == 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "v\(target)"
            else {
                throw DiscoveryError.invalid(
                    "The installed runtime failed its verification; restoring the previous copy")
            }
        } catch {
            for entry in replacements.reversed() {
                if entry.destination.deletingLastPathComponent().lastPathComponent == "bin", let backup = entry.backup {
                    try? atomicRename(backup, to: entry.destination)
                } else {
                    try? manager.removeItem(at: entry.destination)
                    if let backup = entry.backup { try? manager.moveItem(at: backup, to: entry.destination) }
                }
            }
            throw error
        }
        for entry in replacements { if let backup = entry.backup { try? manager.removeItem(at: backup) } }
    }

    private static func atomicRename(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
