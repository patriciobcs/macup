import XCTest

@testable import Macup

final class InstallationEcosystemTests: XCTestCase {
    func testGithubArchivedExtensionOffersRemovalAndUsesAuthenticatedCLI() async throws {
        let f = try InstallationFixture()
        let gh = try f.executable("gh")
        f.response(gh, ["extension", "list"], "gh copilot\tgithub/gh-copilot\tv1.1.1\n")
        f.response(gh, ["api", "repos/github/gh-copilot"], #"{"archived":true}"#)
        let result = await InstallationDiscovery(environment: f.environment).scan([.extensions])
        XCTAssertEqual(result.installations.first?.state, .manual)
        XCTAssertNil(result.installations.first?.reference.update)
        XCTAssertEqual(result.installations.first?.reference.remove?.arguments, ["extension", "remove", "gh-copilot"])
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testDotnetListsOnlyGlobalToolsAndRetainsInventoryWhenNugetIsDown() async throws {
        let f = try InstallationFixture()
        let dotnet = try f.executable("dotnet")
        f.response(dotnet, ["nuget", "list", "source", "--format", "short"], "E https://api.nuget.org/v3/index.json")
        f.response(
            dotnet, ["tool", "list", "--global"],
            "Package Id Version Commands\n--- --- ---\ndotnetsay 2.0.0 dotnetsay\n")
        let result = await InstallationDiscovery(environment: f.environment).scan([.dotnet])
        XCTAssertEqual(result.installations.map(\.name), ["dotnetsay"])
        XCTAssertNil(result.installations.first?.latest)
        XCTAssertEqual(
            result.installations.first?.reference.update?.arguments, ["tool", "update", "--global", "dotnetsay"])
        XCTAssertEqual(result.reports.first?.status, .error)
    }

    func testCustomNugetSourceDoesNotLeakPackageNamesToPublicRegistry() async throws {
        let f = try InstallationFixture()
        let dotnet = try f.executable("dotnet")
        f.response(dotnet, ["tool", "list", "--global"], "company.internal 1.0.0 internal\n")
        try f.file(
            f.home.appendingPathComponent(".nuget/NuGet/NuGet.Config"),
            #"<configuration><packageSources><add key="company" value="https://private.example/v3/index.json"/></packageSources></configuration>"#
        )
        let result = await InstallationDiscovery(environment: f.environment).scan([.dotnet])
        XCTAssertNil(result.installations.first?.latest)
        XCTAssertTrue(try XCTUnwrap(result.installations.first).package.manualOnly)
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testDotnetStableVersionAndRemoval() async throws {
        let f = try InstallationFixture()
        let dotnet = try f.executable("dotnet")
        f.response(dotnet, ["nuget", "list", "source", "--format", "short"], "E https://api.nuget.org/v3/index.json")
        f.response(dotnet, ["tool", "list", "--global"], "dotnetsay 1.0.0 dotnetsay")
        try f.json(
            "https://api.nuget.org/v3-flatcontainer/dotnetsay/index.json", ["versions": ["2.0.0", "99.0.0-preview"]])
        let result = await InstallationDiscovery(environment: f.environment).scan([.dotnet])
        XCTAssertEqual(result.packages.first?.latest, "2.0.0")
        XCTAssertEqual(
            result.installations.first?.reference.remove?.arguments, ["tool", "uninstall", "--global", "dotnetsay"])
    }

    func testDartCustomHostAndCacheAndLocalCheckout() async throws {
        let f = try InstallationFixture()
        f.variables["PUB_HOSTED_URL"] = "https://pub.example"
        f.variables["PUB_CACHE"] = f.home.appendingPathComponent("custom pub").path
        let dart = try f.executable("dart")
        f.response(dart, ["pub", "global", "list"], "webdev 1.0.0\nlocaltool 1.0.0 from path /project\n")
        try f.json("https://pub.example/api/packages/webdev", ["latest": ["version": "2.0.0"]])
        let result = await InstallationDiscovery(environment: f.environment).scan([.dart])
        XCTAssertEqual(result.packages.map(\.name), ["webdev"])
        let local = try XCTUnwrap(result.installations.first { $0.name == "localtool" })
        XCTAssertNil(local.reference.update)
        XCTAssertTrue(local.reference.path.hasPrefix(f.variables["PUB_CACHE"] ?? "!"))
        XCTAssertEqual(local.reference.remove?.arguments, ["pub", "global", "deactivate", "localtool"])
        XCTAssertEqual(f.requests, ["https://pub.example/api/packages/webdev"])
    }

    func testNixSelectsExactProfileIgnoresDependencyVersionsAndPreservesLockedReferences() async throws {
        let f = try InstallationFixture()
        let nix = try f.executable("nix")
        let profile = f.home.appendingPathComponent(".nix-profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let document: [String: Any] = [
            "elements": [
                "hello": ["storePaths": ["/nix/store/abc-hello-2.12.1"], "originalUrl": "flake:nixpkgs"],
                "pinned": [
                    "storePaths": ["/nix/store/abc-tool-1.0.0"],
                    "originalUrl": "github:vendor/repo/" + String(repeating: "a", count: 40),
                ],
            ]
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: document), encoding: .utf8) ?? ""
        f.response(nix, ["profile", "list", "--profile", profile.path, "--json"], json)
        f.response(
            nix, ["profile", "upgrade", "--profile", profile.path, "--dry-run", "--", "hello"],
            "upgrading /nix/store/abc-hello-2.12.1 to /nix/store/def-hello-2.12.2\n/nix/store/xyz-llvm-99.0.0")
        let result = await InstallationDiscovery(environment: f.environment).scan([.nixprofile])
        XCTAssertEqual(result.packages.first?.latest, "2.12.2")
        XCTAssertEqual(
            result.packages.first?.installation?.update?.arguments,
            ["profile", "upgrade", "--profile", profile.path, "--", "hello"])
        XCTAssertNil(result.installations.first { $0.name == "pinned" }?.reference.update)
        XCTAssertFalse(f.calls.contains { $0.arguments.contains("pinned") && $0.arguments.contains("upgrade") })
    }

    func testAsdfModernAndLegacyUseHomeSelectionWithoutTouchingProjects() async throws {
        for sdk in ["0.15.0", "0.20.2"] {
            let f = try InstallationFixture()
            let asdf = try f.executable("asdf")
            f.response(asdf, ["current"], "nodejs 22.1.0 /home/.tool-versions\npython 3.12.1 /home/.tool-versions\n")
            f.response(asdf, ["version"], "asdf v\(sdk)")
            f.response(asdf, ["latest", "nodejs", "22."], "22.9.0\n")
            f.response(asdf, ["latest", "python", "3.12."], "3.12.9\n")
            let result = await InstallationDiscovery(environment: f.environment).scan([.asdf])
            XCTAssertEqual(result.packages.count, 2)
            let action = try XCTUnwrap(result.installations.first?.reference.update)
            XCTAssertEqual(action.workingDirectory, f.home.path)
            XCTAssertEqual(action.followUp.first?.arguments.first, sdk == "0.15.0" ? "global" : "set")
            XCTAssertTrue(f.calls.allSatisfy { $0.directory == f.home.path })
        }
    }

    func testVoltaUsesDefaultToolchainAndNodeStaysOnItsMajor() async throws {
        let f = try InstallationFixture()
        let volta = try f.executable("volta")
        f.response(volta, ["list", "--default", "--format", "plain"], "runtime node@22.1.0 (default)\n")
        try f.json(
            "https://nodejs.org/dist/index.json",
            [["version": "v22.9.0"], ["version": "v24.1.0"], ["version": "v22.99.0-rc.1"]])
        let result = await InstallationDiscovery(environment: f.environment).scan([.volta])
        XCTAssertEqual(result.packages.first?.latest, "22.9.0")
        XCTAssertEqual(result.installations.first?.reference.update?.arguments, ["install", "node@22.9.0"])
        XCTAssertEqual(result.installations.first?.reference.update?.workingDirectory, f.home.path)
    }
}
