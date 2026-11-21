import CryptoKit
import XCTest

@testable import Macup

final class NodeRuntimeUpdaterTests: XCTestCase {
    private func binary(_ f: InstallationFixture, _ url: URL, version: String) throws {
        try f.file(url)
        var data = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 1])
        data.append(Data(version.utf8))
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func prepare(
        _ f: InstallationFixture, corrupt: Bool = false, links: Bool = false
    ) async throws -> OutdatedPackage {
        let prefix = f.home.appendingPathComponent("node prefix")
        try binary(f, prefix.appendingPathComponent("bin/node"), version: "22.1.0")
        try f.file(prefix.appendingPathComponent("include/node/node.h"), "original headers")
        try f.object(
            prefix.appendingPathComponent("lib/node_modules/npm/package.json"), ["name": "npm", "version": "12.0.0"])
        let name = "node-v22.2.0-darwin-arm64"
        let distribution = f.root.appendingPathComponent("distribution/\(name)")
        try binary(f, distribution.appendingPathComponent("bin/node"), version: "22.2.0")
        try f.file(distribution.appendingPathComponent("include/node/node.h"), "new headers")
        if links {
            try FileManager.default.createSymbolicLink(
                atPath: distribution.appendingPathComponent("include/node/escape").path, withDestinationPath: "/tmp")
        }
        let archive = f.root.appendingPathComponent("distribution.tar.gz")
        let packed = try await Subprocess.run(
            executable: "/usr/bin/tar",
            arguments: ["-czf", archive.path, "-C", distribution.deletingLastPathComponent().path, name],
            environment: nil, timeout: 10)
        XCTAssertEqual(packed.status, 0)
        let checksum =
            corrupt
            ? String(repeating: "0", count: 64)
            : SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        f.feed("https://nodejs.org/dist/v22.2.0/SHASUMS256.txt", checksum + "  \(name).tar.gz\n")
        f.downloader = { _, destination in try FileManager.default.copyItem(at: archive, to: destination) }
        f.handler = runtimeRunner(prefix: prefix)
        return InstalledItem(
            manager: .runtimes, name: "Node.js 22", version: "22.1.0",
            reference: InstallationReference(
                path: prefix.appendingPathComponent("bin/node").path, root: prefix.path, owner: "Node.js distribution",
                update: .init(
                    kind: .nodePatch, executable: prefix.appendingPathComponent("bin/node").path,
                    arguments: ["22.2.0", "arm64"])), latest: "22.2.0"
        ).package
    }

    private func runtimeRunner(
        prefix: URL, invalidPublisher: Bool = false, failedInstall: Bool = false
    ) -> DiscoveryEnvironment.Runner {
        { executable, arguments, env, timeout, _ in
            if executable == "/usr/bin/tar" {
                return try await Subprocess.run(
                    executable: executable, arguments: arguments, environment: env, timeout: timeout)
            }
            if executable == "/usr/bin/codesign" {
                if arguments.first == "--verify" { return InstallationFixture.result() }
                let team =
                    invalidPublisher && arguments.last != prefix.appendingPathComponent("bin/node").path
                    ? "OTHER" : "NODETEAM"
                return InstallationFixture.result("TeamIdentifier=\(team)\n")
            }
            if arguments == ["--version"] {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: executable))
                let value = String(data: bytes.dropFirst(8), encoding: .utf8) ?? ""
                let installedFailure =
                    failedInstall && executable == prefix.appendingPathComponent("bin/node").path && value == "22.2.0"
                return InstallationFixture.result("v\(installedFailure ? "22.1.0" : value)\n")
            }
            throw DiscoveryError.invalid("Unexpected runtime command")
        }
    }

    func testVerifiedPatchPreservesGlobalPackagesAndCleansBackups() async throws {
        let f = try InstallationFixture()
        let package = try await prepare(f)
        let result = try await InstallationActions.run(package, environment: f.environment, onOutput: { _ in })
        XCTAssertEqual(result.status, 0)
        let prefix = URL(fileURLWithPath: try XCTUnwrap(package.installation?.root))
        XCTAssertEqual(
            f.environment.object(prefix.appendingPathComponent("lib/node_modules/npm/package.json"))?["version"]
                as? String, "12.0.0")
        XCTAssertEqual(
            try String(contentsOf: prefix.appendingPathComponent("include/node/node.h"), encoding: .utf8), "new headers"
        )
        XCTAssertTrue(
            f.environment.children(prefix.appendingPathComponent("bin")).allSatisfy {
                !$0.lastPathComponent.hasPrefix(".macup-")
            })
    }

    func testChecksumFailureNeverChangesTheInstalledRuntime() async throws {
        let f = try InstallationFixture()
        let package = try await prepare(f, corrupt: true)
        await assertFails(package, fixture: f, message: "checksum")
        try assertOriginal(package, fixture: f)
        XCTAssertFalse(f.calls.contains { $0.executable == "/usr/bin/codesign" })
    }

    func testPublisherMismatchNeverReplacesFiles() async throws {
        let f = try InstallationFixture()
        let package = try await prepare(f)
        let prefix = URL(fileURLWithPath: try XCTUnwrap(package.installation?.root))
        f.handler = runtimeRunner(prefix: prefix, invalidPublisher: true)
        await assertFails(package, fixture: f, message: "signing identity")
        try assertOriginal(package, fixture: f)
    }

    func testFailedInstalledVersionRollsBackBothRuntimeAndHeaders() async throws {
        let f = try InstallationFixture()
        let package = try await prepare(f)
        let prefix = URL(fileURLWithPath: try XCTUnwrap(package.installation?.root))
        f.handler = runtimeRunner(prefix: prefix, failedInstall: true)
        await assertFails(package, fixture: f, message: "restoring")
        try assertOriginal(package, fixture: f)
    }

    func testArchiveSymlinksAreRejectedBeforeExtraction() async throws {
        let f = try InstallationFixture()
        let package = try await prepare(f, links: true)
        await assertFails(package, fixture: f, message: "links")
        try assertOriginal(package, fixture: f)
        XCTAssertFalse(f.calls.contains { $0.arguments.contains("-xzf") })
    }

    func testMajorChangesDowngradesAndUnknownArchitectureAreRejected() throws {
        let package = OutdatedPackage(
            manager: .runtimes, name: "node", installed: "22.1.0", latest: "22.2.0", kind: "installation", extra: "")
        for (target, arch) in [
            ("24.0.0", "arm64"), ("22.0.0", "arm64"), ("22.2.0;touch /tmp/oops", "arm64"), ("22.2.0", "unknown"),
        ] {
            XCTAssertThrowsError(try NodeRuntimeUpdater.validateTarget(package, target: target, architecture: arch))
        }
    }

    private func assertFails(_ package: OutdatedPackage, fixture: InstallationFixture, message: String) async {
        do {
            _ = try await InstallationActions.run(package, environment: fixture.environment, onOutput: { _ in })
            XCTFail("Expected runtime verification failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription) }
    }

    private func assertOriginal(_ package: OutdatedPackage, fixture: InstallationFixture) throws {
        let prefix = URL(fileURLWithPath: try XCTUnwrap(package.installation?.root))
        let data = try Data(contentsOf: prefix.appendingPathComponent("bin/node"))
        XCTAssertEqual(String(data: data.dropFirst(8), encoding: .utf8), "22.1.0")
        XCTAssertEqual(
            try String(contentsOf: prefix.appendingPathComponent("include/node/node.h"), encoding: .utf8),
            "original headers")
        XCTAssertEqual(
            fixture.environment.object(prefix.appendingPathComponent("lib/node_modules/npm/package.json"))?["version"]
                as? String, "12.0.0")
    }
}
