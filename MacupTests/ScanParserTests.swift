import XCTest

@testable import Macup

final class ScanParserTests: XCTestCase {
    func testParsesManagersAndPackages() {
        let text = """
            M\tbrew\tok\t
            P\tbrew\tghostty\t1.2.3\t1.3.1\tcask\t
            M\tgem\tskipped\tgem dir /Library/Ruby/Gems/2.6.0 needs admin rights
            M\tmas\tmissing\t
            P\tcargo\tripgrep\t14.0.0\t?\tcrate\t
            P\tmas\tXcode\t15.0\t15.1\tapp\t497799835\t1788286993
            P\trustup\tstable-aarch64-apple-darwin\t1.93.0\t1.98.1\ttoolchain\t2026-09-01\t
            garbage line
            """
        let r = ScanParser.parse(text)
        XCTAssertEqual(r.reports.count, 3)
        XCTAssertEqual(r.reports[1].status, .skipped)
        XCTAssertTrue(r.reports[1].message.contains("admin"))
        XCTAssertEqual(r.packages.count, 4)
        XCTAssertEqual(r.packages[0].kind, "cask")
        XCTAssertTrue(r.packages[1].needsLatest)
        XCTAssertEqual(r.packages[2].upgradeArgument, "497799835")
        XCTAssertEqual(r.packages[2].updatedAt, Date(timeIntervalSince1970: 1_788_286_993))
        XCTAssertNil(r.packages[3].updatedAt)
        XCTAssertEqual(r.packages[3].dateSource, .registry)
        XCTAssertEqual(ScanParser.dayFormatter.string(from: r.packages[3].releaseDate!), "2026-09-01")
    }

    func testReadsWhichSelfInstalledToolsAreHere() {
        // The tools list is the one place MacUp reports what it did not find, so the user can see that
        // deno was looked for and that bun is Homebrew's to update, not MacUp's.
        let result = ScanParser.parse(
            "T\tuv\tfound\t0.12.13\nT\tbun\tmanaged\tHomebrew\nT\tdeno\tmissing\t\nM\ttools\tok\t\t")

        XCTAssertEqual(result.tools.map(\.name), ["uv", "bun", "deno"])
        XCTAssertEqual(result.tools[0].statusText, "Found · 0.12.13")
        XCTAssertEqual(result.tools[1].statusText, "Updated by Homebrew")
        XCTAssertEqual(result.tools[2].statusText, "not installed")
        XCTAssertEqual(result.reports.count, 1, "the manager line is still read alongside them")
    }

    func testAToolLineThatMakesNoSenseIsSkipped() {
        XCTAssertEqual(ScanParser.parse("T\tuv\tsideways\t1.0\nT\t\tfound\t1.0").tools, [])
    }

    func testIgnoresUnknownManager() {
        let r = ScanParser.parse("M\tzzz\tok\t\nP\tzzz\tfoo\t1\t2\tpkg\t")
        XCTAssertTrue(r.reports.isEmpty)
        XCTAssertTrue(r.packages.isEmpty)
    }
}

final class SystemKindTests: XCTestCase {
    func testSystemPrefix() {
        let r = ScanParser.parse("P\tgem\tcocoapods\t1.11.3\t1.17.0\tsystem-gem\t\nP\tbrew\tghostty\t1\t2\tcask\t")
        XCTAssertTrue(r.packages[0].isSystem)
        XCTAssertEqual(r.packages[0].baseKind, "gem")
        XCTAssertFalse(r.packages[1].isSystem)
        XCTAssertEqual(r.packages[1].baseKind, "cask")
    }
}

final class GoArgumentTests: XCTestCase {
    func testGoArguments() {
        let r = ScanParser.parse(
            "P\tgo\tgopls\tv0.15.0\t?\tbinary\tgolang.org/x/tools/gopls|golang.org/x/tools/gopls\t1700000000")
        XCTAssertEqual(r.packages[0].goModule, "golang.org/x/tools/gopls")
        XCTAssertEqual(r.packages[0].upgradeArgument, "golang.org/x/tools/gopls")
        XCTAssertEqual(r.packages[0].updatedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }
}

final class ReportMessageTests: XCTestCase {
    func testOfflineDetection() {
        let offline = ManagerReport(
            manager: .mas, status: .error,
            message: "mas outdated failed: The Internet connection appears to be offline.")
        XCTAssertTrue(offline.isOffline)
        XCTAssertTrue(offline.friendlyMessage.contains("internet connection"))
        let bug = ManagerReport(
            manager: .npm, status: .error, message: "npm outdated failed: ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING")
        XCTAssertFalse(bug.isOffline)
        XCTAssertEqual(bug.friendlyMessage, "npm could not check for updates.")
    }
}

final class ScanParserFieldTests: XCTestCase {
    func testFiveFieldLineIsIgnoredAndSevenFieldLineParses() {
        let r = ScanParser.parse("P\tnpm\tx\t1\t2\nP\tnpm\ty\t1\t2\tglobal\t")
        XCTAssertEqual(r.packages.map(\.name), ["y"])
    }

    func testBrewIdsSeparateFormulaAndCask() {
        let r = ScanParser.parse("P\tbrew\tdocker\t1\t2\tformula\t\nP\tbrew\tdocker\t1\t2\tcask\t")
        XCTAssertEqual(Set(r.packages.map(\.id)).count, 2)
        XCTAssertEqual(r.packages[1].upgradeArgument, "cask:docker")
    }

    func testAManagerLineCarriesItsVersion() {
        let result = ScanParser.parse("M\tbrew\tok\t\t6.0.22\nM\tgem\tok\tadmin\t3.0.3\nM\tconda\tmissing\t\t")
        XCTAssertEqual(result.reports.map(\.version), ["6.0.22", "3.0.3", ""])
        XCTAssertTrue(result.reports[1].needsAdmin, "the admin marker still reads from the message")
    }

    func testAManagerLineWithoutAVersionStillParses() {
        // State written by an older version of the app, or a header with nothing after the message.
        let result = ScanParser.parse("M\tnpm\tok")
        XCTAssertEqual(result.reports.first?.manager, .npm)
        XCTAssertEqual(result.reports.first?.version, "")
    }
}
