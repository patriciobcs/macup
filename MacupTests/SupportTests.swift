import XCTest

@testable import Macup

/// What a user sees when something breaks: one readable sentence, and a report they can paste.
final class SupportTests: XCTestCase {
    private func report(_ status: ManagerStatus, _ message: String) -> ManagerReport {
        ManagerReport(manager: .brew, status: status, message: message)
    }

    func testDetailsNameTheManagerAndKeepTheOutput() {
        let text = Support.details(title: "Homebrew failed", manager: .brew, raw: "Error: no such keg")
        XCTAssertTrue(text.hasPrefix("Homebrew failed"))
        XCTAssertTrue(text.contains("Manager: Homebrew (brew)"))
        XCTAssertTrue(text.contains("Error: no such keg"))
        XCTAssertTrue(text.contains("MacUp"), "the environment line helps when triaging")
    }

    func testDetailsHideTheHomeDirectory() {
        let raw = "could not write \(NSHomeDirectory())/Library/Caches/x"
        let text = Support.details(title: "t", manager: .npm, raw: raw)
        XCTAssertTrue(text.contains("~/Library/Caches/x"))
        XCTAssertFalse(text.contains(NSHomeDirectory()), "a pasted report must not carry the user's name")
    }

    func testDetailsSayWhenThereWasNoOutput() {
        XCTAssertTrue(Support.details(title: "t", manager: .npm, raw: "").contains("(none)"))
    }

    func testIssueURLCarriesAPrefilledTitleAndBody() throws {
        let url = Support.issueURL(title: "brew failed", body: "Output:\nError: x")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.path, "/patriciobcs/macup/issues/new")
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "brew failed")
        XCTAssertEqual(items.first { $0.name == "body" }?.value, "Output:\nError: x")
    }

    func testOfflineFailuresAreRecognisedFromTheirWording() {
        for message in [
            "curl: (6) Could not resolve host: registry.npmjs.org",
            "Network is unreachable",
            "connection refused",
            "operation timed out",
            "nodename nor servname provided",
        ] {
            XCTAssertTrue(report(.error, message).isOffline, "\(message) reads as being offline")
        }
    }

    func testARealFailureIsNotMistakenForBeingOffline() {
        XCTAssertFalse(report(.error, "Error: permission denied").isOffline)
        XCTAssertFalse(report(.ok, "could not resolve").isOffline, "only failures can be offline")
    }

    func testFriendlyMessagePerStatus() {
        XCTAssertEqual(
            report(.error, "could not resolve host").friendlyMessage,
            "Homebrew needs an internet connection to check for updates.")
        XCTAssertEqual(
            report(.error, "Error: permission denied").friendlyMessage,
            "Homebrew could not check for updates.")
        XCTAssertEqual(report(.skipped, "disabled in Settings").friendlyMessage, "disabled in Settings")
        XCTAssertEqual(report(.ok, "anything").friendlyMessage, "")
        XCTAssertEqual(report(.missing, "anything").friendlyMessage, "", "a manager you do not have is not a problem")
    }
}
