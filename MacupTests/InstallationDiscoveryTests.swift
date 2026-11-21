import XCTest

@testable import Macup

final class InstallationDiscoveryTests: XCTestCase {
    func testClaudeRespectsStableChannelAndDisabledUpdates() async throws {
        let f = try InstallationFixture()
        let claude = try f.executable("claude")
        f.response(claude, ["--version"], "2.1.0 (Claude Code)")
        try f.object(f.home.appendingPathComponent(".claude/settings.json"), ["autoUpdatesChannel": "stable"])
        f.feed("https://downloads.claude.ai/claude-code-releases/stable", "2.1.9\n")
        let result = await InstallationDiscovery(environment: f.environment).scan([.tools])
        XCTAssertEqual(result.packages.first?.latest, "2.1.9")
        XCTAssertFalse(try XCTUnwrap(result.packages.first).manualOnly)
        XCTAssertFalse(f.calls.contains { $0.arguments == ["update"] })
        try f.object(f.home.appendingPathComponent(".claude/settings.json"), ["env": ["DISABLE_UPDATES": "1"]])
        let disabled = await InstallationDiscovery(environment: f.environment).scan([.tools])
        XCTAssertNil(disabled.installations.first?.reference.update)
        XCTAssertTrue(disabled.packages.isEmpty)
    }

    func testClaudeMinimumAndMalformedManifestNeverProduceAnInvalidUpdate() async throws {
        let f = try InstallationFixture()
        let claude = try f.executable("claude")
        f.response(claude, ["--version"], "2.1.0")
        try f.object(f.home.appendingPathComponent(".claude/settings.json"), ["minimumVersion": "2.3.0"])
        f.feed("https://downloads.claude.ai/claude-code-releases/latest", "2.2.0")
        let pinned = await InstallationDiscovery(environment: f.environment).scan([.tools])
        XCTAssertNil(pinned.installations.first?.latest)
        XCTAssertTrue(pinned.packages.isEmpty)
        f.feed("https://downloads.claude.ai/claude-code-releases/latest", "server error")
        let invalid = await InstallationDiscovery(environment: f.environment).scan([.tools])
        XCTAssertTrue(invalid.packages.isEmpty)
    }

    func testDevinUsesItsNativeManifestAndManualUpdater() async throws {
        let f = try InstallationFixture()
        let devin = try f.executable("devin")
        f.response(devin, ["--version"], "Devin 3000.11.92")
        try f.json("https://static.devin.ai/cli/current/manifest.json", ["version": "3000.14.30821"])
        let result = await InstallationDiscovery(environment: f.environment).scan([.tools])
        XCTAssertEqual(result.packages.first?.latest, "3000.14.30821")
        XCTAssertTrue(try XCTUnwrap(result.packages.first).manualOnly)
        XCTAssertEqual(result.installations.first?.reference.update?.arguments, ["update"])
    }

    func testOrbStackUsesExitCodeAndKeepsUnknownTargetUpdatesThroughEnrichment() async throws {
        let f = try InstallationFixture()
        let orb = try f.executable("orbctl")
        f.response(orb, ["version"], "OrbStack 2.2.5")
        f.response(orb, ["update", "--check"], "An update is available", status: 3)
        let result = await InstallationDiscovery(environment: f.environment).scan([.orbstack])
        XCTAssertEqual(result.packages.first?.latest, "Available")
        XCTAssertNotNil(result.packages.first?.installation?.release)
        XCTAssertFalse(f.calls.contains { $0.arguments == ["update"] })
        let enriched = await Registry(directory: f.root).enrich(result.packages)
        XCTAssertEqual(enriched.count, 1)
        f.response(orb, ["update", "--check"])
        let current = await InstallationDiscovery(environment: f.environment).scan([.orbstack])
        XCTAssertTrue(current.packages.isEmpty)
        XCTAssertEqual(current.installations.first?.latest, "2.2.5")
    }

    func testPackageOwnedNativeExecutablesAreInventoryOnly() async throws {
        let f = try InstallationFixture()
        let target = try f.file(f.system.appendingPathComponent("opt/homebrew/Cellar/claude/2/bin/claude"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = f.home.appendingPathComponent("bin/claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        f.response(link.path, ["--version"], "2.1.0")
        let result = await InstallationDiscovery(environment: f.environment).scan([.tools])
        XCTAssertEqual(result.installations.first?.state, .managed)
        XCTAssertNil(result.installations.first?.reference.update)
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testManagedPythonMatchesVariantArchitectureAndHasStableIdentity() async throws {
        let f = try InstallationFixture()
        let uv = try f.executable("uv")
        let root = f.home.appendingPathComponent(".local/share/uv/python")
        #if arch(arm64)
            let native = "aarch64"
            let foreign = "x86_64"
        #else
            let native = "x86_64"
            let foreign = "aarch64"
        #endif
        func row(_ version: String, _ arch: String? = nil, _ variant: String = "default") -> [String: Any] {
            let architecture = arch ?? native
            return [
                "version": version,
                "path": root.appendingPathComponent("cpython-\(version)-\(architecture)/bin/python3").path,
                "implementation": "cpython", "arch": architecture, "variant": variant, "os": "macos", "libc": "none",
            ]
        }
        func output(_ rows: [[String: Any]]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8) ?? ""
        }
        f.response(uv, ["python", "list", "--only-installed", "--output-format", "json"], try output([row("3.12.1")]))
        f.response(
            uv, ["python", "list", "--all-versions", "--only-downloads", "--output-format", "json"],
            try output([
                row("3.12.8"), row("3.12.99", foreign), row("3.12.98", native, "freethreaded"), row("3.13.9"),
            ]))
        let one = await InstallationDiscovery(environment: f.environment).scan([.runtimes])
        XCTAssertEqual(one.installations.first?.latest, "3.12.8")
        XCTAssertEqual(one.installations.first?.reference.update?.arguments, ["python", "upgrade", "3.12"])
        f.response(uv, ["python", "list", "--only-installed", "--output-format", "json"], try output([row("3.12.8")]))
        let two = await InstallationDiscovery(environment: f.environment).scan([.runtimes])
        XCTAssertEqual(one.installations.first?.id, two.installations.first?.id)
    }

    func testPythonInventorySurvivesDownloadMetadataFailure() async throws {
        let f = try InstallationFixture()
        let uv = try f.executable("uv")
        let row = [
            "version": "3.12.1",
            "path": f.home.appendingPathComponent(".local/share/uv/python/3.12.1/bin/python3").path,
        ]
        let output = String(data: try JSONSerialization.data(withJSONObject: [row]), encoding: .utf8) ?? ""
        f.response(uv, ["python", "list", "--only-installed", "--output-format", "json"], output)
        f.response(
            uv, ["python", "list", "--all-versions", "--only-downloads", "--output-format", "json"], "offline",
            status: 2)
        let result = await InstallationDiscovery(environment: f.environment).scan([.runtimes])
        XCTAssertEqual(result.installations.count, 1)
        XCTAssertNil(result.installations.first?.latest)
        XCTAssertEqual(result.reports.first?.status, .error)
    }

    func testJavaInventoryReadsMetadataAndNeverLaunchesTheJavaStub() async throws {
        let f = try InstallationFixture()
        try f.file(
            f.system.appendingPathComponent("Library/Java/JavaVirtualMachines/legacy.jdk/Contents/Home/release"),
            "JAVA_VERSION=\"11.0.1\"\nIMPLEMENTOR=\"Oracle Corporation\"\nOS_ARCH=\"x86_64\"")
        let result = await InstallationDiscovery(environment: f.environment).scan([.runtimes])
        XCTAssertEqual(result.installations.first?.name, "Java 11")
        XCTAssertEqual(result.installations.first?.reference.update?.kind, .openURL)
        XCTAssertNil(result.installations.first?.latest)
        XCTAssertTrue(f.calls.isEmpty)
    }

    func testUvRelativeJSONPathsAreRelativeToItsWorkingDirectory() async throws {
        let f = try InstallationFixture()
        let uv = try f.executable("uv")
        f.response(
            uv, ["python", "list", "--only-installed", "--output-format", "json"],
            #"[{"version":"3.12.1","path":".local/share/uv/python/cpython-3.12.1/bin/python3.12"}]"#)
        f.response(
            uv, ["python", "list", "--all-versions", "--only-downloads", "--output-format", "json"],
            #"[{"version":"3.12.9"}]"#)
        let result = await InstallationDiscovery(environment: f.environment).scan([.runtimes])
        XCTAssertEqual(
            result.installations.first?.reference.path,
            f.home.appendingPathComponent(".local/share/uv/python/cpython-3.12.1/bin/python3.12").path)
        XCTAssertEqual(result.installations.first?.latest, "3.12.9")
    }
}
