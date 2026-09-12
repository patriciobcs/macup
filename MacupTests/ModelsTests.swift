import XCTest

@testable import Macup

/// The identity and command-line arguments of a package: getting these wrong upgrades the wrong thing.
final class ModelsTests: XCTestCase {
    private func pkg(
        _ manager: Manager, _ name: String, kind: String = "global", extra: String = ""
    )
        -> OutdatedPackage
    {
        OutdatedPackage(manager: manager, name: name, installed: "1.0.0", latest: "2.0.0", kind: kind, extra: extra)
    }

    func testHomebrewIdsCarryTheKindSoAFormulaAndACaskDoNotCollide() {
        let formula = pkg(.brew, "docker", kind: "formula")
        let cask = pkg(.brew, "docker", kind: "cask")
        XCTAssertEqual(formula.id, "brew:formula:docker")
        XCTAssertEqual(cask.id, "brew:cask:docker")
        XCTAssertNotEqual(formula.id, cask.id)
        XCTAssertEqual(pkg(.npm, "lodash").id, "npm:lodash", "every other manager keeps the plain name")
    }

    func testVersionKeyFollowsTheLatestVersion() {
        var p = pkg(.npm, "vite")
        XCTAssertEqual(p.versionKey, "npm:vite@2.0.0")
        p.latest = "3.0.0"
        XCTAssertEqual(p.versionKey, "npm:vite@3.0.0", "a new release is a new key, so its age is timed afresh")
    }

    func testSystemPackagesAreRecognisedByTheirKind() {
        let system = pkg(.gem, "psych", kind: "system-gem")
        XCTAssertTrue(system.isSystem)
        XCTAssertEqual(system.baseKind, "gem", "the marker is not part of the kind the scripts use")
        XCTAssertFalse(pkg(.gem, "rails", kind: "gem").isSystem)
    }

    func testUpgradeArgumentPerManager() {
        XCTAssertEqual(pkg(.npm, "lodash").upgradeArgument, "lodash")
        XCTAssertEqual(pkg(.brew, "jq", kind: "formula").upgradeArgument, "formula:jq")
        XCTAssertEqual(pkg(.brew, "rectangle", kind: "cask").upgradeArgument, "cask:rectangle")
        XCTAssertEqual(
            pkg(.mas, "Xcode", extra: "497799835").upgradeArgument, "497799835", "the App Store takes an id")
        XCTAssertEqual(
            pkg(.go, "gh", extra: "github.com/cli/cli|github.com/cli/cli/v2/cmd/gh").upgradeArgument,
            "github.com/cli/cli/v2/cmd/gh", "go installs the main package, not the module")
    }

    func testGoModuleIsTheFirstHalfOfExtra() {
        XCTAssertEqual(
            pkg(.go, "gh", extra: "github.com/cli/cli|github.com/cli/cli/cmd").goModule, "github.com/cli/cli")
        XCTAssertNil(pkg(.npm, "lodash", extra: "whatever").goModule)
    }

    func testAMissingLatestVersionIsFlaggedForTheRegistry() {
        var p = pkg(.cargo, "ripgrep")
        p.latest = "?"
        XCTAssertTrue(p.needsLatest)
        XCTAssertFalse(pkg(.cargo, "ripgrep").needsLatest)
    }

    func testOSVEcosystemsCoverTheManagersThatHaveOne() {
        XCTAssertEqual(Manager.npm.osvEcosystem, "npm")
        XCTAssertEqual(Manager.bun.osvEcosystem, "npm")
        XCTAssertEqual(Manager.pnpm.osvEcosystem, "npm")
        XCTAssertEqual(Manager.pip.osvEcosystem, "PyPI")
        XCTAssertEqual(Manager.uv.osvEcosystem, "PyPI")
        XCTAssertEqual(Manager.pipx.osvEcosystem, "PyPI")
        XCTAssertEqual(Manager.cargo.osvEcosystem, "crates.io")
        XCTAssertEqual(Manager.gem.osvEcosystem, "RubyGems")
        XCTAssertEqual(Manager.go.osvEcosystem, "Go")
        XCTAssertEqual(Manager.composer.osvEcosystem, "Packagist")
        XCTAssertNil(Manager.brew.osvEcosystem, "OSV does not index Homebrew")
        XCTAssertNil(Manager.macos.osvEcosystem)
    }

    func testManagersMacUpMustNotUninstallFrom() {
        for manager in [Manager.rustup, .mas, .macos, .tools, .mise, .conda] {
            XCTAssertFalse(manager.supportsRemoval, "\(manager.rawValue) must not offer removal")
        }
        for manager in [Manager.npm, .brew, .gem, .cargo, .go, .pip] {
            XCTAssertTrue(manager.supportsRemoval)
        }
    }

    func testOnlyMacOSUpdatesAreAHandOff() {
        XCTAssertTrue(Manager.macos.opensExternally)
        XCTAssertEqual(Manager.allCases.filter(\.opensExternally), [.macos])
    }

    func testEveryManagerHasATitleAndAnIcon() {
        for manager in Manager.allCases {
            XCTAssertFalse(manager.title.isEmpty, "\(manager.rawValue) has no title")
            XCTAssertFalse(manager.symbol.isEmpty, "\(manager.rawValue) has no symbol")
            XCTAssertEqual(manager.id, manager.rawValue)
        }
    }

    func testAdminReportIsTheOneMarkedSo() {
        XCTAssertTrue(ManagerReport(manager: .gem, status: .ok, message: "admin").needsAdmin)
        XCTAssertFalse(ManagerReport(manager: .gem, status: .ok, message: "").needsAdmin)
        XCTAssertFalse(
            ManagerReport(manager: .gem, status: .error, message: "admin").needsAdmin,
            "a failed manager is not asking for a password")
    }

    func testPackagesSurviveASaveAndReload() throws {
        var p = pkg(.brew, "jq", kind: "formula")
        p.releaseDate = Date(timeIntervalSince1970: 1_767_323_045)
        p.dateSource = .homebrew
        p.advisories = ["GHSA-1234"]
        let decoded = try JSONDecoder.iso.decode(
            OutdatedPackage.self, from: try JSONEncoder.iso.encode(p))
        XCTAssertEqual(decoded, p)
    }
}

/// Which updater is in charge. A copy installed by Homebrew must never also update itself.
final class InstallSourceTests: XCTestCase {
    func testHomebrewOnlyWhenTheCaskAndTheApplicationsCopyBothExist() {
        let caskPresent = ["/opt/homebrew/Caskroom/macup", "/usr/local/Caskroom/macup"]
            .contains { FileManager.default.fileExists(atPath: $0) }
        // Running from somewhere else is a direct install whether or not a cask exists.
        XCTAssertEqual(InstallSource.detect(bundlePath: "/Users/someone/Downloads/MacUp.app"), .direct)
        XCTAssertEqual(InstallSource.detect(bundlePath: "/tmp/build/MacUp.app"), .direct)
        // In /Applications it depends on the Caskroom, which is whatever this machine has.
        XCTAssertEqual(
            InstallSource.detect(bundlePath: "/Applications/MacUp.app"), caskPresent ? .homebrew : .direct)
    }
}
