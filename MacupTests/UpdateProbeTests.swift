import Sparkle
import XCTest

@testable import Macup

/// The quiet check at the end of Update All: a window only when there is an update to offer.
final class UpdateProbeTests: XCTestCase {
    func testAProbeThatFindsAnUpdateOpensTheUsualWindow() {
        let probe = UpdateProbe()
        var opened = 0
        probe.onUpdateFound = { opened += 1 }

        probe.begin()
        probe.noteFound()
        XCTAssertTrue(probe.finished(.updateInformation))
        XCTAssertEqual(opened, 1)
    }

    func testAProbeThatFindsNothingStaysQuiet() {
        let probe = UpdateProbe()
        var opened = 0
        probe.onUpdateFound = { opened += 1 }

        probe.begin()
        XCTAssertFalse(probe.finished(.updateInformation))
        XCTAssertEqual(opened, 0, "no window to say MacUp is already up to date")
    }

    func testSparklesOwnChecksAreLeftAlone() {
        let probe = UpdateProbe()
        var opened = 0
        probe.onUpdateFound = { opened += 1 }

        // A scheduled check finding something is Sparkle's to present, not the probe's.
        probe.noteFound()
        XCTAssertFalse(probe.finished(.updatesInBackground))
        probe.begin()
        probe.noteFound()
        XCTAssertFalse(probe.finished(.updatesInBackground), "a different check ending is not the probe's answer")
        XCTAssertTrue(probe.finished(.updateInformation))
        XCTAssertFalse(probe.finished(.updateInformation), "and it answers once")
        XCTAssertEqual(opened, 1)
    }
}
