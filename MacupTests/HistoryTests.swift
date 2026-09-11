import XCTest

@testable import Macup

/// The history is the only record of what MacUp did to a machine, so it has to survive a relaunch.
@MainActor
final class HistoryTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macup-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ kind: ActionRecord.Kind, _ package: String, succeeded: Bool = true) -> ActionRecord {
        ActionRecord(kind: kind, manager: .npm, package: package, detail: "1 → 2", succeeded: succeeded)
    }

    func testRecordsArePersistedAndComeBackNewestFirst() {
        let history = History(directory: directory)
        history.add(record(.upgrade, "first"))
        history.add(record(.remove, "second"))
        XCTAssertEqual(history.records.map(\.package), ["second", "first"])

        let reopened = History(directory: directory)
        XCTAssertEqual(reopened.records.map(\.package), ["second", "first"])
        XCTAssertEqual(reopened.records.first?.kind, .remove)
    }

    func testClearingEmptiesTheFileToo() {
        let history = History(directory: directory)
        history.add(record(.upgrade, "gone"))
        history.clear()
        XCTAssertEqual(history.records, [])
        XCTAssertEqual(History(directory: directory).records, [], "the empty list was written, not just forgotten")
    }

    func testAnEmptyDirectoryStartsAnEmptyHistory() {
        XCTAssertEqual(History(directory: directory).records, [])
    }

    func testCorruptedFileIsIgnoredRatherThanCrashing() throws {
        try Data("not json".utf8).write(to: directory.appendingPathComponent("history.json"))
        XCTAssertEqual(History(directory: directory).records, [])
    }

    func testOldestRecordsFallOffTheEnd() {
        // A directory that does not exist keeps every write in memory, so the cap is cheap to reach.
        let history = History(directory: directory.appendingPathComponent("missing"))
        for i in 0...2000 { history.add(record(.upgrade, "pkg-\(i)")) }
        XCTAssertEqual(history.records.count, 2000)
        XCTAssertEqual(history.records.first?.package, "pkg-2000")
        XCTAssertEqual(history.records.last?.package, "pkg-1", "pkg-0 was pushed out")
    }

    func testTitlesReadAsSentencesForEveryKind() {
        XCTAssertEqual(record(.upgrade, "vite").title, "Updated vite")
        XCTAssertEqual(record(.upgrade, "vite", succeeded: false).title, "Failed to update vite")
        XCTAssertEqual(record(.remove, "vite").title, "Removed vite")
        XCTAssertEqual(record(.remove, "vite", succeeded: false).title, "Failed to remove vite")
        XCTAssertEqual(record(.install, "mas").title, "Installed mas")
        XCTAssertEqual(record(.install, "mas", succeeded: false).title, "Failed to install mas")
        XCTAssertEqual(record(.ignore, "vite").title, "Ignored vite")
        XCTAssertEqual(record(.unignore, "vite").title, "Stopped ignoring vite")
    }
}
