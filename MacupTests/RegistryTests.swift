import XCTest

@testable import Macup

/// The registry talks to eight public APIs, each with its own JSON shape. These tests feed it the
/// shapes those APIs really return and check what it makes of them.
final class RegistryTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macup-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// An exact UTC instant, written out rather than as an epoch number nobody can check by eye.
    private func utc(_ text: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: text) ?? .distantPast
    }

    /// A release date matters to the second; the last bits of a Double do not, and ISO parsing and
    /// DateComponents disagree there.
    private func assertDate(
        _ actual: Date?, _ expected: Date, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else { return XCTFail("no date resolved. \(message)", file: file, line: line) }
        XCTAssertEqual(
            actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.01, message,
            file: file, line: line)
    }

    private func registry() -> Registry {
        Registry(directory: directory, session: StubURLProtocol.session())
    }

    private func pkg(
        _ manager: Manager, _ name: String, installed: String = "1.0.0", latest: String = "?", extra: String = ""
    ) -> OutdatedPackage {
        OutdatedPackage(
            manager: manager, name: name, installed: installed, latest: latest, kind: "global", extra: extra)
    }

    // MARK: Latest version

    func testResolvesLatestVersionFromEachRegistry() async {
        StubURLProtocol.serve([
            ("registry.npmjs.org/typescript", .init(#"{"dist-tags":{"latest":"5.9.2"}}"#)),
            ("pypi.org/pypi/ruff/json", .init(#"{"info":{"version":"0.14.1"}}"#)),
            ("crates.io/api/v1/crates/ripgrep", .init(#"{"crate":{"max_stable_version":"14.1.1"}}"#)),
            ("proxy.golang.org/github.com/cli/cli/@latest", .init(#"{"Version":"v2.63.0"}"#)),
        ])
        let resolved = await registry().enrich([
            pkg(.npm, "typescript"),
            pkg(.pip, "ruff", installed: "0.13.0"),
            pkg(.cargo, "ripgrep"),
            pkg(.go, "gh", extra: "github.com/cli/cli|github.com/cli/cli/v2"),
        ])
        let latest = Dictionary(uniqueKeysWithValues: resolved.map { ($0.name, $0.latest) })
        XCTAssertEqual(latest["typescript"], "5.9.2")
        XCTAssertEqual(latest["ruff"], "0.14.1")
        XCTAssertEqual(latest["ripgrep"], "14.1.1")
        XCTAssertEqual(latest["gh"], "v2.63.0")
    }

    func testDropsPackagesThatTurnOutToBeUpToDate() async {
        StubURLProtocol.serve([
            ("registry.npmjs.org/eslint", .init(#"{"dist-tags":{"latest":"9.0.0"}}"#))
        ])
        // The scanner said "outdated", but the registry's newest version is the one installed.
        let resolved = await registry().enrich([pkg(.npm, "eslint", installed: "9.0.0")])
        XCTAssertEqual(resolved, [])
    }

    func testUnresolvableLatestVersionDropsThePackage() async {
        StubURLProtocol.serve([])  // every request fails: offline
        let resolved = await registry().enrich([pkg(.npm, "typescript")])
        XCTAssertEqual(resolved, [], "a package whose latest version is unknown cannot be shown as an update")
    }

    // MARK: Release dates

    func testReleaseDateFromEachRegistry() async {
        StubURLProtocol.serve([
            ("registry.npmjs.org/vite", .init(#"{"time":{"6.0.0":"2026-01-02T03:04:05.123Z"}}"#)),
            (
                "pypi.org/pypi/black/25.1.0/json",
                .init(#"{"urls":[{"upload_time_iso_8601":"2026-02-03T04:05:06.123456Z"}]}"#)
            ),
            (
                "crates.io/api/v1/crates/serde/1.0.2",
                .init(#"{"version":{"created_at":"2026-03-04T05:06:07.000+00:00"}}"#)
            ),
            (
                "rubygems.org/api/v1/versions/rails.json",
                .init(#"[{"number":"8.0.1","created_at":"2026-04-05T06:07:08.000Z"}]"#)
            ),
            ("proxy.golang.org/github.com/cli/cli/@v/v2.63.0.info", .init(#"{"Time":"2026-05-06T07:08:09Z"}"#)),
        ])
        let resolved = await registry().enrich([
            pkg(.npm, "vite", latest: "6.0.0"),
            pkg(.pip, "black", latest: "25.1.0"),
            pkg(.cargo, "serde", latest: "1.0.2"),
            pkg(.gem, "rails", latest: "8.0.1"),
            pkg(.go, "gh", latest: "v2.63.0", extra: "github.com/cli/cli|github.com/cli/cli"),
        ])
        let dates = Dictionary(uniqueKeysWithValues: resolved.compactMap { p in p.releaseDate.map { (p.name, $0) } })
        assertDate(dates["vite"], utc("2026-01-02 03:04:05.123"))
        assertDate(dates["black"], utc("2026-02-03 04:05:06.123"))
        assertDate(dates["serde"], utc("2026-03-04 05:06:07.000"))
        assertDate(dates["rails"], utc("2026-04-05 06:07:08.000"))
        assertDate(dates["gh"], utc("2026-05-06 07:08:09.000"))
        XCTAssertTrue(resolved.allSatisfy { $0.dateSource == .registry })
    }

    func testComposerMatchesATagWithOrWithoutItsVPrefix() async {
        let body = #"{"packages":{"laravel/framework":[{"version":"v11.2.0","time":"2026-06-07T08:09:10+00:00"}]}}"#
        StubURLProtocol.serve([("repo.packagist.org/p2/laravel/framework.json", .init(body))])
        let resolved = await registry().enrich([pkg(.composer, "laravel/framework", latest: "11.2.0")])
        assertDate(resolved.first?.releaseDate, utc("2026-06-07 08:09:10.000"))
    }

    func testSelfInstalledToolUsesItsGitHubReleaseDate() async {
        StubURLProtocol.serve([
            (
                "api.github.com/repos/astral-sh/uv/releases/tags/0.9.2",
                .init(#"{"published_at":"2026-07-08T09:10:11Z"}"#)
            )
        ])
        let resolved = await registry().enrich([
            pkg(.tools, "uv", installed: "0.9.0", latest: "0.9.2", extra: "astral-sh/uv:0.9.2")
        ])
        assertDate(resolved.first?.releaseDate, utc("2026-07-08 09:10:11.000"))
    }

    func testHomebrewUsesTheFormulaBumpCommitAndItsOwnSource() async {
        let body = #"[{"commit":{"committer":{"date":"2026-08-09T10:11:12Z"}}}]"#
        StubURLProtocol.serve([("Homebrew/homebrew-core/commits", .init(body))])
        var formula = pkg(.brew, "jq", latest: "1.8.0")
        formula.kind = "formula"
        let resolved = await registry().enrich([formula])
        assertDate(resolved.first?.releaseDate, utc("2026-08-09 10:11:12.000"))
        XCTAssertEqual(resolved.first?.dateSource, .homebrew, "Homebrew dates are a bump commit, not a release")
        XCTAssertTrue(
            StubURLProtocol.requests.contains { $0.contains("Formula/j/jq.rb") },
            "formulae are sharded by first letter")
    }

    func testHomebrewLooksUpCasksAndLibrariesInTheirOwnPlaces() async {
        StubURLProtocol.serve([("Homebrew/", .init("[]"))])
        var cask = pkg(.brew, "rectangle", installed: "0.8", latest: "0.9")
        cask.kind = "cask"
        var lib = pkg(.brew, "libpng", latest: "1.7")
        lib.kind = "formula"
        _ = await registry().enrich([cask, lib])
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.contains("homebrew-cask") && $0.contains("Casks/r") })
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.contains("Formula/lib/libpng.rb") })
    }

    func testThirdPartyTapIsNotLookedUp() async {
        StubURLProtocol.serve([("Homebrew/", .init("[]"))])
        var tapped = pkg(.brew, "someone/tap/thing", latest: "2.0")
        tapped.kind = "formula"
        _ = await registry().enrich([tapped])
        XCTAssertEqual(StubURLProtocol.requestCount(matching: "api.github.com"), 0)
    }

    func testManagersWithoutAKnownRegistryAskForNothing() async {
        StubURLProtocol.serve([])
        let resolved = await registry().enrich([
            pkg(.rustup, "stable", latest: "1.85.0"),
            pkg(.nix, "hello", latest: "2.13"),
            pkg(.mise, "node", latest: "22.0.0"),
            pkg(.conda, "numpy", latest: "2.2"),
            pkg(.port, "wget", latest: "1.25"),
            pkg(.mas, "Xcode", latest: "17.0"),
            pkg(.macos, "Sequoia", latest: "15.4"),
        ])
        XCTAssertEqual(resolved.count, 7, "they are still shown, just without a date")
        XCTAssertTrue(resolved.allSatisfy { $0.releaseDate == nil })
        XCTAssertEqual(StubURLProtocol.requests, [])
    }

    // MARK: Advisories

    func testAttachesAdvisoriesFromOSV() async {
        let osv = #"{"results":[{"vulns":[{"id":"GHSA-1111"},{"id":"CVE-2026-9999"}]}]}"#
        StubURLProtocol.serve([
            ("api.osv.dev/v1/querybatch", .init(osv)),
            ("registry.npmjs.org", .init("{}")),
        ])
        let resolved = await registry().enrich([pkg(.npm, "lodash", installed: "4.17.20", latest: "4.17.21")])
        XCTAssertEqual(resolved.first?.advisories, ["GHSA-1111", "CVE-2026-9999"])
        XCTAssertEqual(resolved.first?.isSecurity, true)
    }

    func testAPackageWithNoVulnerabilitiesIsNotMarkedAsSecurity() async {
        StubURLProtocol.serve([
            ("api.osv.dev/v1/querybatch", .init(#"{"results":[{}]}"#)),
            ("registry.npmjs.org", .init("{}")),
        ])
        let resolved = await registry().enrich([pkg(.npm, "chalk", installed: "5.0.0", latest: "5.3.0")])
        XCTAssertEqual(resolved.first?.advisories, [])
        XCTAssertEqual(resolved.first?.isSecurity, false)
    }

    func testAdvisoriesAreCachedPerInstalledVersion() async {
        StubURLProtocol.serve([
            ("api.osv.dev/v1/querybatch", .init(#"{"results":[{"vulns":[{"id":"GHSA-2222"}]}]}"#)),
            ("registry.npmjs.org", .init("{}")),
        ])
        let pkg = pkg(.npm, "lodash", installed: "4.17.20", latest: "4.17.21")
        _ = await registry().enrich([pkg])
        let again = await registry().enrich([pkg])
        XCTAssertEqual(again.first?.advisories, ["GHSA-2222"])
        XCTAssertEqual(StubURLProtocol.requestCount(matching: "osv.dev"), 1, "the answer came from the cache")
    }

    func testManagersWithoutAnOSVEcosystemAreNotQueried() async {
        StubURLProtocol.serve([("Homebrew/", .init("[]"))])
        var formula = pkg(.brew, "jq", latest: "1.8.0")
        formula.kind = "formula"
        _ = await registry().enrich([formula])
        XCTAssertEqual(StubURLProtocol.requestCount(matching: "osv.dev"), 0)
    }

    // MARK: Cache

    func testAnswersAreCachedOnDiskAndReusedByTheNextRegistry() async {
        StubURLProtocol.serve([
            ("registry.npmjs.org/vite", .init(#"{"time":{"6.0.0":"2026-01-02T03:04:05.123Z"}}"#))
        ])
        let first = await registry().enrich([pkg(.npm, "vite", latest: "6.0.0")])
        XCTAssertEqual(StubURLProtocol.requestCount(matching: "registry.npmjs.org"), 1)

        // A second registry (a later launch) reads the cache file rather than the network.
        let second = await registry().enrich([pkg(.npm, "vite", latest: "6.0.0")])
        // To the second: the cache is JSON with ISO-8601 dates, which carry no fractional part.
        XCTAssertEqual(
            first.first?.releaseDate?.timeIntervalSince1970 ?? 0,
            second.first?.releaseDate?.timeIntervalSince1970 ?? 0, accuracy: 1)
        XCTAssertEqual(
            StubURLProtocol.requestCount(matching: "registry.npmjs.org"), 1, "the date was already known")
    }

    func testARateLimitedLookupIsRetriedRatherThanRememberedAsAMiss() async {
        StubURLProtocol.serve([("api.github.com", .init(#"{"message":"rate limit"}"#, status: 403))])
        var formula = pkg(.brew, "jq", latest: "1.8.0")
        formula.kind = "formula"
        _ = await registry().enrich([formula])
        let afterFirst = StubURLProtocol.requestCount(matching: "api.github.com")
        XCTAssertEqual(afterFirst, 1)
        _ = await registry().enrich([formula])
        XCTAssertEqual(
            StubURLProtocol.requestCount(matching: "api.github.com"), 2,
            "a 403 is not an answer, so the next scan asks again")
    }

    func testAMissingDateIsRememberedSoTheAPIIsNotHammered() async {
        StubURLProtocol.serve([("registry.npmjs.org/vite", .init(#"{"time":{}}"#))])
        _ = await registry().enrich([pkg(.npm, "vite", latest: "6.0.0")])
        _ = await registry().enrich([pkg(.npm, "vite", latest: "6.0.0")])
        XCTAssertEqual(
            StubURLProtocol.requestCount(matching: "registry.npmjs.org"), 1,
            "the registry answered, it just had no date for that version")
    }

    // MARK: URL building

    func testScopedAndPathLikeNamesAreEncodedPerSegment() {
        XCTAssertEqual(Registry.seg("@types/node"), "@types%2Fnode")
        XCTAssertEqual(Registry.seg("simple"), "simple")
        XCTAssertEqual(Registry.segPath("laravel/framework"), "laravel/framework")
        XCTAssertEqual(Registry.segPath("weird name/pkg"), "weird%20name/pkg")
    }

    func testGoModuleEscapingLowercasesWithABang() {
        XCTAssertEqual(Registry.goEscape("github.com/BurntSushi/toml"), "github.com/!burnt!sushi/toml")
        XCTAssertEqual(Registry.goEscape("github.com/cli/cli"), "github.com/cli/cli")
    }

    func testParsesBothISO8601ShapesTheRegistriesUse() {
        assertDate(Registry.parseISO("2026-01-02T03:04:05.123Z"), utc("2026-01-02 03:04:05.123"))
        assertDate(Registry.parseISO("2026-01-02T03:04:05Z"), utc("2026-01-02 03:04:05.000"))
        assertDate(Registry.parseISO("2026-01-02T03:04:05+00:00"), utc("2026-01-02 03:04:05.000"))
        assertDate(Registry.parseISO("2026-01-02T04:04:05+01:00"), utc("2026-01-02 03:04:05.000"), "offsets apply")
        XCTAssertNil(Registry.parseISO("last tuesday"))
    }
}
