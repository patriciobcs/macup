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

    func testCommandOutputIsKeptWithTheRecord() {
        let history = History(directory: directory)
        history.add(
            ActionRecord(
                kind: .upgrade, manager: .brew, package: "jq", detail: "1.7 → 1.8", succeeded: true,
                output: "==> Upgrading jq\n🍺 done"))

        XCTAssertEqual(history.records.first?.output, "==> Upgrading jq\n🍺 done")
        XCTAssertEqual(
            History(directory: directory).records.first?.output, "==> Upgrading jq\n🍺 done",
            "and it survives a relaunch, so a failure can be read the next morning")
    }

    func testOutputOlderThanAWeekIsForgottenButTheRecordStays() {
        let history = History(directory: directory)
        let old = ActionRecord(
            id: UUID(), date: Date().addingTimeInterval(-8 * 86_400), kind: .upgrade, manager: .npm,
            package: "lodash", detail: "1 → 2", succeeded: false, output: "pages and pages of build output")
        history.add(old)

        XCTAssertEqual(history.records.count, 1, "what was done is still on record")
        XCTAssertEqual(history.records.first?.title, "Failed to update lodash")
        XCTAssertNil(history.records.first?.output, "but a week-old build log is not worth keeping")
    }

    func testFreshOutputIsNotForgotten() {
        let history = History(directory: directory)
        history.add(
            ActionRecord(
                id: UUID(), date: Date().addingTimeInterval(-6 * 86_400), kind: .upgrade, manager: .npm,
                package: "lodash", detail: "1 → 2", succeeded: true, output: "six days old"))
        XCTAssertEqual(history.records.first?.output, "six days old")
    }

    func testAVeryLongOutputKeepsItsTail() {
        // The end of a failed build is the part that says why it failed.
        let history = History(directory: directory)
        let long = String(repeating: "x", count: History.outputCap + 5_000) + "Error: the last line"
        history.add(
            ActionRecord(kind: .upgrade, manager: .brew, package: "big", detail: "", succeeded: false, output: long))

        let stored = history.records.first?.output
        XCTAssertEqual(stored?.count, History.outputCap)
        XCTAssertEqual(stored?.hasSuffix("Error: the last line"), true)
    }

    func testOutputStopsAtABudgetSoTheFileCannotGrowForever() {
        // Newest first, so what goes is the oldest output, not the one just recorded.
        let history = History(directory: directory)
        let chunk = String(repeating: "x", count: History.outputCap)
        for i in 1...(History.outputBudget / History.outputCap + 3) {
            history.add(
                ActionRecord(
                    kind: .upgrade, manager: .npm, package: "p\(i)", detail: "", succeeded: true,
                    output: chunk))
        }

        let kept = history.records.compactMap(\.output)
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.count }, History.outputBudget)
        XCTAssertNotNil(history.records.first?.output, "the newest run keeps its output")
        XCTAssertNil(history.records.last?.output, "the oldest gives it up")
    }

    func testExpiredOutputIsWrittenBackNotJustForgottenInMemory() throws {
        let stale = ActionRecord(
            id: UUID(), date: Date().addingTimeInterval(-9 * 86_400), kind: .upgrade, manager: .npm,
            package: "old", detail: "", succeeded: true, output: "a week and a half of nothing")
        try JSONEncoder.iso.encode([stale]).write(to: directory.appendingPathComponent("history.json"))

        _ = History(directory: directory)  // loading prunes

        let onDisk = try JSONDecoder.iso.decode(
            [ActionRecord].self, from: Data(contentsOf: directory.appendingPathComponent("history.json")))
        XCTAssertNil(onDisk.first?.output, "the file no longer carries it either")
        XCTAssertEqual(onDisk.first?.package, "old")
    }
}
