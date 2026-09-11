import XCTest

@testable import Macup

final class ErrorSummaryTests: XCTestCase {
    func testPrefersErrorLines() {
        let out =
            "$ brew upgrade -- x\n==> Upgrading x\nError: x: It seems the App source '/Applications/X.app' is not there.\n"
        XCTAssertEqual(
            UpdateStore.errorSummary(out, status: 1),
            "Error: x: It seems the App source '/Applications/X.app' is not there.")
    }
    func testFallsBackToTail() {
        XCTAssertEqual(UpdateStore.errorSummary("$ cmd\na\nb\nc\nd\n", status: 2), "b\nc\nd")
        XCTAssertEqual(UpdateStore.errorSummary("", status: 3), "Exited with status 3")
    }
}
