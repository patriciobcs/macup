import XCTest

@testable import Macup

/// The lists the UI reads: what is shown, what is still waiting, and what the badge counts.
@MainActor
final class StoreStateTests: XCTestCase {
    private let settings = Preferences.shared
    private var savedIgnored: Set<String> = []
    private var savedHideSystem = true
    private var savedMinAge: Double = 24
    private var savedSecurityMinAge: Double = 4

    override func setUp() async throws {
        // Preferences is a singleton backed by the real defaults, so put back whatever was there.
        savedIgnored = settings.ignoredPackages
        savedHideSystem = settings.hideSystemPackages
        savedMinAge = settings.minAgeHours
        savedSecurityMinAge = settings.securityMinAgeHours
        settings.ignoredPackages = []
        settings.hideSystemPackages = true
        // What counts as settled is the subject of several of these tests, so it is pinned rather than
        // inherited: another class that leaves the thresholds at zero, or a person whose own copy is
        // configured differently, would otherwise decide the outcome here.
        settings.minAgeHours = 24
        settings.securityMinAgeHours = 4
    }

    override func tearDown() async throws {
        settings.ignoredPackages = savedIgnored
        settings.hideSystemPackages = savedHideSystem
        settings.minAgeHours = savedMinAge
        settings.securityMinAgeHours = savedSecurityMinAge
    }

    private func pkg(
        _ name: String, manager: Manager = .npm, kind: String = "global", released: TimeInterval? = nil,
        security: Bool = false
    ) -> OutdatedPackage {
        var p = OutdatedPackage(
            manager: manager, name: name, installed: "1.0.0", latest: "2.0.0", kind: kind, extra: "")
        if let released {
            p.releaseDate = Date().addingTimeInterval(-released)
            p.dateSource = .registry
        }
        if security { p.advisories = ["GHSA-test"] }
        return p
    }

    private func store(_ packages: [OutdatedPackage], reports: [ManagerReport] = []) -> UpdateStore {
        let store = UpdateStore(persist: false)
        store.loadFixture(reports: reports, packages: packages, log: "")
        return store
    }

    // MARK: What is shown

    func testIgnoredAndSystemPackagesAreKeptOutOfSight() {
        let store = store([pkg("shown"), pkg("hidden"), pkg("psych", manager: .gem, kind: "system-gem")])
        settings.ignoredPackages = ["npm:hidden"]
        XCTAssertEqual(store.visible.map(\.name), ["shown"])
        XCTAssertEqual(store.ignored.map(\.name), ["hidden"])
        XCTAssertEqual(store.hiddenSystemCount, 1)
    }

    func testSystemPackagesComeBackWhenTheUserAsksForThem() {
        let store = store([pkg("shown"), pkg("psych", manager: .gem, kind: "system-gem")])
        settings.hideSystemPackages = false
        XCTAssertEqual(store.visible.map(\.name).sorted(), ["psych", "shown"])
        XCTAssertEqual(store.hiddenSystemCount, 0)
    }

    // MARK: Waiting for a release to settle

    func testAFreshReleaseWaitsAndAnOldOneIsReady() {
        let store = store([pkg("fresh", released: 3600), pkg("settled", released: 30 * 3600)])
        XCTAssertEqual(store.eligible.map(\.name), ["settled"])
        XCTAssertEqual(store.waiting.map(\.name), ["fresh"])
        XCTAssertEqual(store.badgeCount, 1)
    }

    func testASecurityFixWaitsForTheShorterThreshold() {
        let store = store([pkg("cve", released: 5 * 3600, security: true), pkg("plain", released: 5 * 3600)])
        XCTAssertEqual(store.eligible.map(\.name), ["cve"])
        XCTAssertEqual(store.waiting.map(\.name), ["plain"])
    }

    func testUpdateAllCountsEverythingItCanActuallyRun() {
        let store = store([
            pkg("lodash", released: 30 * 3600),
            pkg("Sequoia", manager: .macos, released: 30 * 3600),
        ])
        XCTAssertEqual(store.badgeCount, 2)
        XCTAssertEqual(store.updatableCount, 1, "macOS updates are a hand-off to System Settings")
    }

    func testAgeAndReferenceDateFollowTheReleaseDate() {
        let released = pkg("dated", released: 7200)
        let undated = pkg("undated")
        let store = store([released, undated])
        XCTAssertEqual(store.age(of: released), 7200, accuracy: 5)
        XCTAssertEqual(store.referenceDate(of: released), released.releaseDate)
        // Without a release date the clock starts when MacUp first saw the version.
        XCTAssertEqual(store.age(of: undated), 3 * 86_400, accuracy: 5)
    }

    // MARK: Manager reports

    func testProblemsExcludeManagersThatAreMerelyOffline() {
        let store = store(
            [],
            reports: [
                ManagerReport(manager: .brew, status: .error, message: "could not resolve host"),
                ManagerReport(manager: .npm, status: .error, message: "Error: EACCES"),
                ManagerReport(manager: .pip, status: .ok, message: ""),
            ])
        XCTAssertEqual(store.problems.map(\.manager), [.npm], "being offline is one notice, not a list of errors")
        XCTAssertTrue(store.isOffline)
    }

    func testDiscoveredManagersAreTheOnesFoundOnThisMac() {
        let store = store(
            [],
            reports: [
                ManagerReport(manager: .brew, status: .ok, message: ""),
                ManagerReport(manager: .npm, status: .error, message: "boom"),
                ManagerReport(manager: .conda, status: .missing, message: ""),
            ])
        XCTAssertEqual(store.discoveredManagers, [.brew, .npm])
    }

    func testNeedsAdminComesFromTheManagersOwnReport() {
        let store = store([], reports: [ManagerReport(manager: .gem, status: .ok, message: "admin")])
        XCTAssertTrue(store.needsAdmin(.gem))
        XCTAssertFalse(store.needsAdmin(.npm))
    }

    // MARK: Ignoring

    func testIgnoringAPackageHidesItAndIsRecorded() {
        let store = store([pkg("stub")])
        store.ignore(pkg("stub"))
        XCTAssertEqual(store.visible, [])
        XCTAssertEqual(store.history.records.first?.kind, .ignore)
        XCTAssertEqual(store.history.records.first?.package, "stub")
    }

    func testUnignoringPutsItBackAndIsRecorded() {
        let store = store([pkg("stub")])
        store.ignore(pkg("stub"))
        store.unignore(id: "npm:stub")
        XCTAssertEqual(store.visible.map(\.name), ["stub"])
        XCTAssertEqual(store.history.records.first?.kind, .unignore)
        XCTAssertEqual(store.history.records.first?.package, "stub")
    }

    func testUnignoringSomethingThatIsNotAPackageIdIsHarmless() {
        let store = store([])
        store.unignore(id: "nonsense")
        XCTAssertEqual(store.history.records, [])
    }

    // MARK: Upgrades in flight

    func testLogMarkerNamesTheManagerAndItsPackages() {
        XCTAssertEqual(UpdateStore.logMarker(manager: .brew, names: ["jq", "wget"]), "── Homebrew: jq, wget ──")
    }

    func testRevealPointsTheLogAtAPackageAndFiresAgainForTheSameOne() {
        let store = store([pkg("vite")])
        store.reveal(pkg("vite"))
        XCTAssertEqual(store.revealMarker, "── npm: vite ──")
        XCTAssertEqual(store.revealCount, 1)
        store.reveal(pkg("vite"))
        XCTAssertEqual(store.revealCount, 2, "asking twice for the same section must scroll twice")
    }

    // MARK: Reporting while the scan runs

    func testEachManagerShowsUpAsItFinishes() {
        let store = UpdateStore(persist: false)
        XCTAssertEqual(store.scanned, [])

        store.noteScanned(ManagerReport(manager: .npm, status: .ok, message: ""))
        XCTAssertEqual(store.scanned, [.npm], "the setup window counts this one as checked")
        XCTAssertEqual(store.reports.map(\.manager), [.npm])

        // brew finishes second but sorts first, so the list stays in a stable order while it fills in.
        store.noteScanned(ManagerReport(manager: .brew, status: .error, message: "boom"))
        XCTAssertEqual(store.reports.map(\.manager), [.brew, .npm])
        XCTAssertEqual(store.scanned, [.npm, .brew])
    }

    func testAManagerReportingTwiceReplacesItsRow() {
        let store = UpdateStore(persist: false)
        store.noteScanned(ManagerReport(manager: .npm, status: .ok, message: ""))
        store.noteScanned(ManagerReport(manager: .npm, status: .missing, message: ""))
        XCTAssertEqual(store.reports.count, 1, "the row is replaced, not duplicated")
        XCTAssertEqual(store.reports.first?.status, .missing)
        XCTAssertEqual(store.scanned, [.npm])
    }

    // MARK: Merging scans

    func testAManagerThatWasNotScannedKeepsItsPackagesAndReport() {
        let store = store(
            [pkg("lodash"), pkg("jq", manager: .brew)],
            reports: [
                ManagerReport(manager: .npm, status: .ok, message: ""),
                ManagerReport(manager: .brew, status: .ok, message: ""),
            ])
        store.merge(
            ScanResult(reports: [ManagerReport(manager: .npm, status: .ok, message: "")], packages: []),
            scanned: [.npm])
        XCTAssertEqual(store.packages.map(\.name), ["jq"], "only npm was rescanned")
        XCTAssertEqual(store.reports.map(\.manager), [.brew, .npm], "reports stay in Manager order")
    }

    func testClearingTheLogEmptiesIt() {
        let store = UpdateStore(persist: false)
        store.loadFixture(reports: [], packages: [], log: "some output")
        XCTAssertEqual(store.log, "some output")
        store.clearLog()
        XCTAssertEqual(store.log, "")
    }
}

/// What the store keeps on disk, so a relaunch does not forget how long an update has been waiting.
@MainActor
final class StorePersistenceTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macup-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pkg(_ name: String) -> OutdatedPackage {
        OutdatedPackage(manager: .npm, name: name, installed: "1.0.0", latest: "2.0.0", kind: "global", extra: "")
    }

    func testScanResultsComeBackAfterARelaunch() {
        let package = pkg("lodash")
        let store = UpdateStore(persist: true, directory: directory)
        store.merge(
            ScanResult(reports: [ManagerReport(manager: .npm, status: .ok, message: "")], packages: [package]),
            scanned: [.npm])
        store.persist()

        let relaunched = UpdateStore(persist: true, directory: directory)
        XCTAssertEqual(relaunched.packages.map(\.name), ["lodash"])
        XCTAssertEqual(relaunched.reports.map(\.manager), [.npm])
        XCTAssertNotNil(
            relaunched.firstSeen[package.versionKey],
            "the clock on how long this version has been out must survive a relaunch")
    }

    func testAFixtureStoreNeverWritesToDisk() {
        let store = UpdateStore(persist: false, directory: directory)
        store.loadFixture(reports: [], packages: [pkg("vite")], log: "")
        store.persist()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path),
            "previews and screenshots must not touch real state")
    }

    func testACorruptStateFileStartsEmptyRatherThanCrashing() throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent("state.json"))
        let store = UpdateStore(persist: true, directory: directory)
        XCTAssertEqual(store.packages, [])
        XCTAssertEqual(store.reports, [])
    }
}
