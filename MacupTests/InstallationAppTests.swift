import XCTest

@testable import Macup

final class InstallationAppTests: XCTestCase {
    private let feed = "https://vendor.example/appcast.xml"
    private let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure sparkle:version="101" sparkle:shortVersionString="1.0" /></item>
        <item><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure sparkle:version="900" sparkle:shortVersionString="9.0" /></item>
        <item><sparkle:channel>beta</sparkle:channel><enclosure sparkle:version="800" sparkle:shortVersionString="8.0" /></item>
        </channel></rss>
        """

    func testBuildOnlyAppUpdateSurvivesRegistryAndUsesHandoff() async throws {
        let f = try InstallationFixture()
        let app = try f.app("Example", extra: ["SUFeedURL": feed])
        f.feed(feed, xml)
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        let package = try XCTUnwrap(result.packages.first)
        XCTAssertEqual(package.latest, "1.0 (build 101)")
        XCTAssertTrue(package.opensExternally)
        XCTAssertTrue(package.manualOnly)
        let actionPath = try XCTUnwrap(package.installation?.update?.executable)
        XCTAssertTrue(
            FileManager.default.contentsEqual(
                atPath: actionPath + "/Contents/Info.plist",
                andPath: app.appendingPathComponent("Contents/Info.plist").path))
        let enriched = await Registry(directory: f.root).enrich(result.packages)
        XCTAssertEqual(enriched.map(\.id), result.packages.map(\.id))
    }

    func testReceiptAndCaskOwnedAppsAreNeverHandledTwice() async throws {
        let f = try InstallationFixture()
        let app = try f.app("StoreApp", extra: ["SUFeedURL": feed])
        try f.file(app.appendingPathComponent("Contents/_MASReceipt/receipt"))
        try f.app("BrewApp", extra: ["SUFeedURL": feed])
        try f.object(
            f.system.appendingPathComponent("opt/homebrew/Caskroom/brew-app/.metadata/INSTALL_RECEIPT.json"), [:])
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        XCTAssertEqual(result.installations.count, 2)
        XCTAssertTrue(result.installations.allSatisfy { $0.state == .managed && $0.reference.update == nil })
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testUnknownAppAndFailedFeedRemainVisibleForManualReview() async throws {
        let f = try InstallationFixture()
        try f.app("Unknown")
        try f.app("Offline", extra: ["SUFeedURL": feed])
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        XCTAssertEqual(result.installations.count, 2)
        XCTAssertTrue(result.installations.allSatisfy { $0.latest == nil && $0.reference.update?.isHandoff == true })
        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertEqual(result.reports.first?.status, .error)
    }

    func testIntelHomebrewReceiptDoesNotClaimASeparateUserCopy() async throws {
        let f = try InstallationFixture()
        let systemApp = try f.app("Example")
        try f.object(f.system.appendingPathComponent("usr/local/Caskroom/example/.metadata/INSTALL_RECEIPT.json"), [:])
        let userApp = f.home.appendingPathComponent("Applications/Example.app")
        try FileManager.default.createDirectory(
            at: userApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: systemApp, to: userApp)
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        XCTAssertEqual(result.installations.filter { $0.state == .managed }.count, 1)
        XCTAssertEqual(result.installations.filter { $0.state == .manual }.count, 1)
    }

    func testElectronGithubFiltersDesktopTagsAndPrereleases() async throws {
        let f = try InstallationFixture()
        let app = try f.app("Electron")
        try f.file(
            app.appendingPathComponent("Contents/Resources/app-update.yml"),
            "provider: github\nowner: vendor\nrepo: client\ntagPrefix: desktop-v\n")
        try f.json(
            "https://api.github.com/repos/vendor/client/releases?per_page=30",
            [
                ["tag_name": "cli-v99.0.0"], ["tag_name": "desktop-v2.0.0"],
                ["tag_name": "desktop-v3.0.0", "prerelease": true],
            ])
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        XCTAssertEqual(result.packages.first?.latest, "2.0.0")
    }

    func testElectronGenericAndUnsafeFeedURLs() async throws {
        let f = try InstallationFixture()
        let app = try f.app("Generic")
        try f.file(
            app.appendingPathComponent("Contents/Resources/app-update.yml"),
            "provider: generic\nurl: https://vendor.example/releases\nchannel: stable\n")
        f.feed("https://vendor.example/releases/stable-mac.yml", "version: 2.1.0\nfiles:\n  - url: ignored.dmg")
        try f.app("Unsafe", extra: ["SUFeedURL": "http://vendor.example/feed"])
        let result = await InstallationDiscovery(environment: f.environment).scan([.apps])
        XCTAssertEqual(result.packages.map(\.name), ["Generic"])
        XCTAssertEqual(result.packages.first?.latest, "2.1.0")
        XCTAssertFalse(f.requests.contains { $0.hasPrefix("http:") })
    }

    func testAppcastFiltersOSArchitectureAndChannels() throws {
        let releases =
            try AppcastParser.parse(Data(xml.utf8)) + [
                AppcastRelease(build: "700", version: "7.0", architectures: ["x86_64"])
            ]
        XCTAssertEqual(AppcastParser.latest(releases, os: "15.0", architectures: ["arm64"], channels: [])?.build, "101")
        XCTAssertEqual(
            AppcastParser.latest(releases, os: "15.0", architectures: ["arm64"], channels: ["beta"])?.build, "800")
        XCTAssertThrowsError(try AppcastParser.parse(Data("<rss><item>".utf8)))
    }

    func testBinaryArchitectureReadsIntelARMAndUniversalHeaders() throws {
        let f = try InstallationFixture()
        let file = try f.file(f.root.appendingPathComponent("binary"))
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 1]).write(to: file)
        XCTAssertEqual(BinaryArchitecture.read(file), ["arm64"])
        try Data([0xCF, 0xFA, 0xED, 0xFE, 7, 0, 0, 1]).write(to: file)
        XCTAssertEqual(BinaryArchitecture.read(file), ["x86_64"])
        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2, 1, 0, 0, 0x0C])
        fat.append(Data(repeating: 0, count: 16))
        fat.append(contentsOf: [1, 0, 0, 7])
        fat.append(Data(repeating: 0, count: 16))
        try fat.write(to: file)
        XCTAssertEqual(BinaryArchitecture.read(file), ["arm64", "x86_64"])
    }
}
