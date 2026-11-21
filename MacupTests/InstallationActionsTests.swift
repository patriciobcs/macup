import XCTest

@testable import Macup

final class InstallationActionsTests: XCTestCase {
    private func package(_ f: InstallationFixture) throws -> OutdatedPackage {
        let root = f.home.appendingPathComponent("prefix")
        let path = root.appendingPathComponent("lib/node_modules/example")
        try f.object(path.appendingPathComponent("package.json"), ["name": "example", "version": "1.0"])
        return InstalledItem(
            manager: .npm, name: "example", version: "1.0",
            reference: .init(
                path: path.path, root: root.path, owner: "npm", expectedPackage: "example",
                update: .init(
                    executable: "/missing/npm",
                    arguments: ["install", "--global", "--prefix", root.path, "example@latest"])), latest: "2.0"
        ).package
    }

    func testDryRunDoesNotExecuteDownloadOrRequireTheInstallationToExist() async throws {
        let f = try InstallationFixture()
        let package = try package(f)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(package.installation?.path))
        let result = try await InstallationActions.run(
            package, environment: f.environment, dryRun: true,
            onOutput: { _ in XCTFail("Dry run must return preview without streaming an execution") })
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("--prefix"))
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testReplacedPackageAndPathOutsideRootAreRejected() throws {
        let f = try InstallationFixture()
        var package = try package(f)
        try f.object(
            URL(fileURLWithPath: try XCTUnwrap(package.installation?.path)).appendingPathComponent("package.json"),
            ["name": "someone-else", "version": "1.0"])
        XCTAssertThrowsError(try InstallationActions.validate(package, removing: false, environment: f.environment))
        package.installation?.root = f.home.appendingPathComponent("another-root").path
        XCTAssertThrowsError(try InstallationActions.validate(package, removing: false, environment: f.environment))
        XCTAssertTrue(f.calls.isEmpty)
    }

    func testMovedAppIdentityIsRecheckedBeforeOpening() async throws {
        let f = try InstallationFixture()
        let app = try f.app("Example")
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        let package = try XCTUnwrap(result.installations.first?.package)
        try f.app("Example", extra: ["CFBundleIdentifier": "other.vendor"])
        XCTAssertThrowsError(try InstallationActions.validate(package, removing: false, environment: f.environment))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testSuccessfulNoOpUpdaterIsReportedAsFailure() async throws {
        let f = try InstallationFixture()
        let package = try package(f)
        f.handler = { _, _, _, _, _ in InstallationFixture.result("Done") }
        do {
            _ = try await InstallationActions.run(package, environment: f.environment, onOutput: { _ in })
            XCTFail("A zero exit status must not claim an unchanged installation was updated")
        } catch { XCTAssertTrue(error.localizedDescription.contains("still at 1.0"), error.localizedDescription) }
    }

    func testHandoffOpensExactAppAndDoesNotClaimItWasUpdated() async throws {
        let f = try InstallationFixture()
        let app = try f.app("Example")
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        let package = try XCTUnwrap(result.installations.first?.package)
        let actionPath = try XCTUnwrap(package.installation?.update?.executable)
        XCTAssertTrue(
            FileManager.default.contentsEqual(
                atPath: actionPath + "/Contents/Info.plist",
                andPath: app.appendingPathComponent("Contents/Info.plist").path))
        f.response("/usr/bin/open", ["-a", actionPath])
        let opened = try await InstallationActions.run(package, environment: f.environment, onOutput: { _ in })
        XCTAssertEqual(opened.status, 0)
        XCTAssertEqual(f.calls.last?.arguments, ["-a", actionPath])
        let record = ActionRecord(
            kind: .handoff, manager: .apps, package: "Example", detail: "Opened app", succeeded: true)
        XCTAssertEqual(record.title, "Opened Example")
    }

    func testCommandPreviewQuotesPathsAndArgumentsWithoutExecutingShellText() {
        let action = InstallationAction(
            executable: "/space path/npm", arguments: ["name'; touch /tmp/nope", "$(whoami)"],
            workingDirectory: "/home/a b")
        let line = InstallationActions.commandLine(action)
        XCTAssertTrue(line.hasPrefix("(cd '/home/a b' && '/space path/npm' "))
        XCTAssertTrue(line.contains("'name'\\''; touch /tmp/nope'"))
        XCTAssertTrue(line.contains("'$(whoami)'"))
    }

    func testMixedScopedBatchIsRejectedBeforeAnyCommandRuns() async throws {
        let f = try InstallationFixture()
        let scoped = try package(f)
        let other = OutdatedPackage(
            manager: .npm, name: "other", installed: "1.0", latest: "2.0", kind: "global", extra: "")
        do {
            _ = try await ScriptRunner.upgrade(packages: [other, scoped], brewGreedy: false, onOutput: { _ in })
            XCTFail("A batch must not silently discard the second installation's prefix")
        } catch { XCTAssertTrue(error.localizedDescription.contains("separately")) }
        XCTAssertTrue(f.calls.isEmpty)
    }
}
