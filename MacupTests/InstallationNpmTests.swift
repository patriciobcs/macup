import XCTest

@testable import Macup

final class InstallationNpmTests: XCTestCase {
    func testPrefixesHaveIndependentIdentityAndUseNativeRegistryConfiguration() async throws {
        let f = try InstallationFixture()
        let npm = try f.executable("npm")
        let active = f.home.appendingPathComponent(".local/share/node/v22.1.0")
        let other = f.system.appendingPathComponent("usr/local")
        for root in [active, other] {
            try f.object(
                root.appendingPathComponent("lib/node_modules/@team/tool/package.json"),
                ["name": "@team/tool", "version": "1.0.0"])
        }
        f.response(npm, ["prefix", "-g"], active.path)
        f.response(
            npm, ["outdated", "--global", "--prefix", other.path, "--json"], #"{"@team/tool":{"latest":"3.0.0"}}"#,
            status: 1)
        let old = OutdatedPackage(
            manager: .npm, name: "@team/tool", installed: "1.0.0", latest: "2.0.0", kind: "global", extra: "")
        let result = await InstallationDiscovery(environment: f.environment).scan(
            [.npm], existing: ScanResult(reports: [.init(manager: .npm, status: .ok, message: "")], packages: [old]))
        XCTAssertEqual(result.installations.count, 2)
        XCTAssertEqual(Set(result.packages.map(\.id)).count, 2)
        let secondary = try XCTUnwrap(result.installations.first { $0.reference.root == other.path })
        XCTAssertEqual(secondary.latest, "3.0.0")
        XCTAssertTrue(secondary.package.manualOnly)
        XCTAssertEqual(
            secondary.reference.update?.arguments, ["install", "--global", "--prefix", other.path, "@team/tool@latest"])
        XCTAssertEqual(
            secondary.reference.remove?.arguments, ["uninstall", "--global", "--prefix", other.path, "@team/tool"])
        XCTAssertTrue(f.requests.isEmpty, "Never leak private package names to the public npm API")
    }

    func testMissingNpmStillInventoriesLeftoversWithoutAnUpdater() async throws {
        let f = try InstallationFixture()
        try f.object(
            f.system.appendingPathComponent("usr/local/lib/node_modules/old/package.json"),
            ["name": "old", "version": "1.0"])
        let result = await InstallationDiscovery(environment: f.environment).scan([.npm])
        XCTAssertEqual(result.installations.map(\.name), ["old"])
        XCTAssertNil(result.installations.first?.reference.update)
        XCTAssertEqual(result.reports.first?.status, .error)
    }

    func testFailedRegistryAndOrphanedCommandStayVisibleWithoutFalseLatest() async throws {
        let f = try InstallationFixture()
        let npm = try f.executable("npm")
        let root = f.system.appendingPathComponent("opt/homebrew")
        try f.object(
            root.appendingPathComponent("lib/node_modules/old/package.json"),
            ["name": "old", "version": "1.0", "bin": ["old": "cli.js"]])
        f.response(npm, ["prefix", "-g"], f.home.path)
        f.response(
            npm, ["outdated", "--global", "--prefix", root.path, "--json"], #"{"error":{"code":"E401"}}"#, status: 1)
        let result = await InstallationDiscovery(environment: f.environment).scan([.npm])
        XCTAssertEqual(result.installations.first?.state, .orphaned)
        XCTAssertNil(result.installations.first?.latest)
        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertEqual(result.reports.first?.status, .error)
    }

    func testLinkedCheckoutIsNeverUpdatedThroughNpm() async throws {
        let f = try InstallationFixture()
        let npm = try f.executable("npm")
        let root = f.system.appendingPathComponent("usr/local")
        let checkout = f.home.appendingPathComponent("project")
        try f.object(checkout.appendingPathComponent("package.json"), ["name": "linked", "version": "1.0"])
        let link = root.appendingPathComponent("lib/node_modules/linked")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: checkout)
        f.response(npm, ["prefix", "-g"], root.path)
        let legacy = OutdatedPackage(
            manager: .npm, name: "linked", installed: "1.0", latest: "2.0", kind: "global", extra: "")
        let result = await InstallationDiscovery(environment: f.environment).scan(
            [.npm], existing: ScanResult(packages: [legacy]))
        XCTAssertEqual(result.installations.first?.state, .manual)
        XCTAssertNil(result.installations.first?.reference.update)
        XCTAssertNotNil(result.installations.first?.reference.remove)
        XCTAssertTrue(result.packages.isEmpty, "The legacy row must not retain an updater for a linked checkout")
    }

    func testHomebrewBundledNpmPackageStaysWithItsFormula() async throws {
        let f = try InstallationFixture()
        let npm = try f.executable("npm")
        let root = f.system.appendingPathComponent("opt/homebrew")
        let target = root.appendingPathComponent("Cellar/node/22/lib/node_modules/corepack")
        try f.object(target.appendingPathComponent("package.json"), ["name": "corepack", "version": "1.0"])
        let link = root.appendingPathComponent("lib/node_modules/corepack")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        f.response(npm, ["prefix", "-g"], root.path)
        let legacy = OutdatedPackage(
            manager: .npm, name: "corepack", installed: "1.0", latest: "2.0", kind: "global", extra: "")
        let result = await InstallationDiscovery(environment: f.environment).scan(
            [.npm], existing: ScanResult(packages: [legacy]))
        XCTAssertEqual(result.installations.first?.state, .managed)
        XCTAssertNil(result.installations.first?.reference.update)
        XCTAssertNil(result.installations.first?.reference.remove)
        XCTAssertTrue(result.packages.isEmpty)
    }

    func testExactPrefixUpdateAndRemovalUseRealFixtureProcesses() async throws {
        let f = try InstallationFixture()
        let npm = try f.executable("npm")
        let roots = [f.home.appendingPathComponent("one prefix"), f.home.appendingPathComponent("other prefix")]
        for root in roots {
            try f.object(
                root.appendingPathComponent("lib/node_modules/example/package.json"),
                ["name": "example", "version": "1.0"])
        }
        let script = """
            #!/bin/zsh
            [[ "$3" == --prefix && -n "$4" ]] || exit 9
            if [[ "$1" == install ]]; then
              printf '%s' '{"name":"example","version":"2.0"}' > "$4/lib/node_modules/example/package.json"
            elif [[ "$1" == uninstall ]]; then
              /bin/rm -rf -- "$4/lib/node_modules/example"
            else exit 8; fi
            """
        try script.write(toFile: npm, atomically: true, encoding: .utf8)
        f.handler = { exe, args, env, timeout, directory in
            try await Subprocess.run(
                executable: exe, arguments: args, environment: env, timeout: timeout,
                workingDirectory: directory.map { URL(fileURLWithPath: $0) })
        }
        let scanner = InstallationDiscovery(environment: f.environment)
        let reference = await scanner.packageReference(
            path: roots[0].appendingPathComponent("lib/node_modules/example"), root: roots[0], owner: "npm",
            name: "example",
            action: .init(
                executable: npm, arguments: ["install", "--global", "--prefix", roots[0].path, "example@latest"]),
            remove: .init(executable: npm, arguments: ["uninstall", "--global", "--prefix", roots[0].path, "example"]))
        let package = InstalledItem(manager: .npm, name: "example", version: "1.0", reference: reference, latest: "2.0")
            .package
        let update = try await InstallationActions.run(package, environment: f.environment, onOutput: { _ in })
        XCTAssertEqual(update.status, 0)
        XCTAssertEqual(
            f.environment.object(roots[0].appendingPathComponent("lib/node_modules/example/package.json"))?["version"]
                as? String, "2.0")
        XCTAssertEqual(
            f.environment.object(roots[1].appendingPathComponent("lib/node_modules/example/package.json"))?["version"]
                as? String, "1.0")
        let remove = try await InstallationActions.run(
            package, removing: true, environment: f.environment, onOutput: { _ in })
        XCTAssertEqual(remove.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reference.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: roots[1].appendingPathComponent("lib/node_modules/example").path))
    }
}
