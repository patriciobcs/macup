import XCTest

@testable import Macup

/// These really do start the user's login shell: that is the whole point of the type, and a mock
/// would prove nothing about whether the scripts end up seeing the same PATH as Terminal.
final class ShellEnvironmentTests: XCTestCase {
    func testCapturesAUsablePATHFromTheLoginShell() async {
        let path = await ShellEnvironment.shared.userPATH()
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.contains("/bin"), "a login shell always has some bin directory on its PATH")
    }

    func testSessionSpecificVariablesAreLeftBehind() async {
        let env = await ShellEnvironment.shared.loginEnvironment()
        // These say something about the shell that produced them, not about the user's tools.
        for key in ["PWD", "SHLVL", "_", "TERM_SESSION_ID", "TMPDIR"] {
            XCTAssertNil(env[key], "\(key) is meaningless outside the shell it came from")
        }
    }

    func testTheSecondCallIsServedFromTheCache() async {
        let first = await ShellEnvironment.shared.loginEnvironment()
        let started = Date()
        let second = await ShellEnvironment.shared.loginEnvironment()
        XCTAssertEqual(first, second)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "a second shell must not be started")
    }

    func testScriptEnvironmentCarriesWhatTheScriptsExpect() async {
        let env = await ScriptRunner.environment(brewGreedy: false)
        XCTAssertFalse(env["MACUP_USER_PATH"]?.isEmpty ?? true, "the scripts run with the user's PATH")
        XCTAssertEqual(env["TERM"], "dumb", "package managers must not draw progress bars")
        XCTAssertFalse(env["HOME"]?.isEmpty ?? true)
        XCTAssertFalse(env["LANG"]?.isEmpty ?? true)
        XCTAssertNil(env["MACUP_BREW_GREEDY"])
    }

    func testGreedyHomebrewIsPassedThroughAsAFlag() async {
        let env = await ScriptRunner.environment(brewGreedy: true)
        XCTAssertEqual(env["MACUP_BREW_GREEDY"], "1")
    }

    func testTheBundledScriptsAreWhereTheAppLooksForThem() {
        for name in ["macup-scan", "macup-upgrade", "macup-remove", "macup-setup"] {
            XCTAssertNotNil(ScriptRunner.scriptURL(name), "\(name).sh is missing from the app bundle")
        }
        XCTAssertNil(ScriptRunner.scriptURL("macup-nonexistent"))
    }
}
