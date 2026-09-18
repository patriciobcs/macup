import SwiftUI
import Vision
import XCTest

@testable import Macup

@MainActor
final class ReleaseReadinessTests: StubScriptCase {
    func testManualBatchDoesNotStartAutomaticUpdatesBetweenManagers() async throws {
        settings.autoUpdate = true
        try script(
            "macup-scan",
            #"""
            for m in "$@"; do
                printf 'M\t%s\tok\t\n' "$m"
                if [[ "$m" == rustup ]]; then
                    printf 'P\trustup\tstable\t1.0.0\t2.0.0\ttoolchain\t2020-01-01\t0\n'
                fi
            done
            """#)
        let subject = store()
        subject.loadFixture(
            reports: [],
            packages: [pkg("jq", manager: .brew, kind: "formula"), pkg("stable", manager: .rustup, kind: "toolchain")],
            log: "")

        await subject.upgradeAllEligible()

        XCTAssertEqual(subject.history.records.map(\.package), ["stable", "jq"])
        XCTAssertNil(subject.lastAutoUpdate, "rescans must not start an unattended batch inside the manual one")
        XCTAssertFalse(subject.isUpgradingAnything, "the locks are released when the batch completes")
    }

    func testHomebrewFailureDetailsDistinguishFormulaAndCaskAfterRelaunch() async {
        let subject = store()
        let formula = pkg("boom-shared", manager: .brew, kind: "formula")
        let cask = pkg("boom-shared", manager: .brew, kind: "cask")
        subject.loadFixture(reports: [], packages: [formula, cask], log: "")
        await subject.upgrade(formula)
        await subject.upgrade(cask)
        let reopened = History(directory: directory)

        subject.reveal(formula)
        let formulaRecord = reopened.latestRecord(for: subject.revealTarget ?? "")
        XCTAssertEqual(formulaRecord?.packageID, formula.id)
        XCTAssertEqual(formulaRecord?.succeeded, false)
        XCTAssertTrue(formulaRecord?.output?.contains("formula:boom-shared") == true)

        subject.reveal(cask)
        let caskRecord = reopened.latestRecord(for: subject.revealTarget ?? "")
        XCTAssertEqual(caskRecord?.packageID, cask.id)
        XCTAssertTrue(caskRecord?.output?.contains("cask:boom-shared") == true)
        XCTAssertNotEqual(formulaRecord?.id, caskRecord?.id)
    }

    func testMissingScanScriptIsVisibleWithNoPackages() async throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("macup-scan.sh"))
        let subject = store()
        await subject.scan(managers: [.npm])

        let text = try renderedText(subject)
        // OCR can confuse the small connecting words at the runner's display scale. Assert the
        // diagnostic itself: the script is named and reported missing, not merely a generic heading.
        XCTAssertTrue(text.contains("macup-scan.sh") && text.contains("missing"), text)
        XCTAssertFalse(text.contains("are up to date"), text)
    }

    func testManagerFailureIsVisibleWithNoPackages() throws {
        let subject = store()
        subject.loadFixture(
            reports: [ManagerReport(manager: .npm, status: .error, message: "Error: release-review-failure")],
            packages: [], log: "")

        let text = try renderedText(subject)
        XCTAssertTrue(text.contains("Could not check all updates"), text)
        XCTAssertTrue(text.contains("npm could not check for updates"), text)
        XCTAssertFalse(text.contains("are up to date"), text)
    }

    func testOfflineNoticeIsVisibleWithNoPackages() throws {
        let subject = store()
        subject.loadFixture(
            reports: [ManagerReport(manager: .npm, status: .error, message: "Could not resolve host")],
            packages: [], log: "")
        XCTAssertTrue(subject.isOffline)

        let text = try renderedText(subject)
        XCTAssertTrue(text.contains("No internet connection"), text)
        XCTAssertFalse(text.contains("are up to date"), text)
    }

    private func renderedText(_ subject: UpdateStore) throws -> String {
        let bitmap = try XCTUnwrap(
            renderBitmap(
                UpdatesView().environment(subject).environment(settings)
                    .environment(\.colorScheme, .light).background(Color.white),
                size: CGSize(width: 800, height: 600)))
        let image = try XCTUnwrap(bitmap.cgImage)
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
        attachment.name = "Rendered update notices"
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
