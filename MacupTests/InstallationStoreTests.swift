import SwiftUI
import XCTest

@testable import Macup

@MainActor
final class InstallationStoreTests: StubScriptCase {
    private func item(_ path: String, defaultPrefix: Bool = false) -> InstalledItem {
        InstalledItem(
            manager: .npm, name: "example", version: "1.0.0",
            reference: .init(
                path: path + "/lib/node_modules/example", root: path, owner: "npm", isDefault: defaultPrefix,
                update: .init(executable: "/npm", arguments: ["update"], manualOnly: !defaultPrefix)),
            latest: "2.0.0")
    }

    func testLegacyIgnoresHistoryAndWaitPeriodMigrateOnlyToDefaultPrefix() throws {
        let store = store()
        let original = pkg("example")
        store.loadFixture(reports: [], packages: [original], log: "")
        settings.ignoredPackages = [original.id]
        store.history.add(ActionRecord(kind: .ignore, manager: .npm, package: "example", detail: "", succeeded: true))
        let oldDate = try XCTUnwrap(store.firstSeen[original.versionKey])
        let active = item("/home/current", defaultPrefix: true)
        let other = item("/usr/local")
        store.merge(
            ScanResult(packages: [active.package, other.package], installations: [active, other]), scanned: [.npm])
        XCTAssertEqual(settings.ignoredPackages, [active.package.id])
        XCTAssertEqual(store.firstSeen[active.package.versionKey], oldDate)
        XCTAssertEqual(store.history.records.first?.packageID, active.package.id)
        XCTAssertEqual(store.visible.map(\.id), [other.package.id])
    }

    func testAutomaticBatchSkipsManualCopiesAndHandoffs() {
        let store = store()
        let active = item("/current", defaultPrefix: true)
        let other = item("/usr/local")
        store.loadFixture(
            reports: [], packages: [active.package, other.package], log: "", installations: [active, other])
        XCTAssertEqual(store.updatableCount, 1)
        XCTAssertEqual(store.badgeCount, 2, "Manual updates remain visible")
    }

    func testInventoryPersistsAndOldStateWithoutInventoryStillLoads() throws {
        let store = UpdateStore(persist: true, directory: directory, installSource: .direct)
        let item = item("/current")
        store.loadFixture(reports: [], packages: [item.package], log: "", installations: [item])
        store.persist()
        let reloaded = UpdateStore(persist: true, directory: directory, installSource: .direct)
        XCTAssertEqual(reloaded.installations, [item])
        let file = directory.appendingPathComponent("state.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object.removeValue(forKey: "installations")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        XCTAssertTrue(UpdateStore(persist: true, directory: directory, installSource: .direct).installations.isEmpty)
    }

    func testInventorySearchReviewAndJSONExposeScopedIDsWithoutCommandsOrEnvironment() throws {
        var other = item("/usr/local")
        other.state = .orphaned
        other.reference.update?.environment = ["SECRET": "do-not-serialize"]
        let active = item("/current", defaultPrefix: true)
        XCTAssertEqual(InstallationList.filtered([other, active], query: "/usr", needsReview: true), [other])
        let report = InventoryReport(items: [other, active], checkedAt: Date())
        let json = report.json()
        XCTAssertTrue(json.contains("@installation="))
        XCTAssertFalse(json.contains("do-not-serialize"))
        XCTAssertTrue(report.text().contains("/usr/local/lib/node_modules/example"))
    }

    func testAmbiguousCLISelectionAndManagerMismatchFailBeforeRunning() async {
        let store = store(commandLine: true)
        let one = item("/one", defaultPrefix: true)
        let two = item("/two")
        store.loadFixture(reports: [], packages: [one.package, two.package], log: "", installations: [one, two])
        let ambiguous = await CommandLineTool.run(
            .init(command: .upgrade, now: true, dryRun: true, installationIDs: ["example"]), store: store)
        XCTAssertEqual(ambiguous, CommandLineTool.usageError)
        let mismatch = await CommandLineTool.run(
            .init(command: .upgrade, managers: [.dart], now: true, dryRun: true, installationIDs: [one.package.id]),
            store: store)
        XCTAssertEqual(mismatch, CommandLineTool.usageError)
        XCTAssertTrue(store.history.records.isEmpty)
    }

    func testIgnoreRejectsAmbiguousLegacyNamesAndUnignoreAcceptsScopedName() async {
        let store = store(commandLine: true)
        let one = item("/one", defaultPrefix: true)
        let two = item("/two")
        store.loadFixture(reports: [], packages: [one.package, two.package], log: "", installations: [one, two])
        let ambiguous = await CommandLineTool.run(.init(command: .ignore, names: ["npm:example"]), store: store)
        XCTAssertEqual(ambiguous, CommandLineTool.failed)
        XCTAssertTrue(settings.ignoredPackages.isEmpty)
        _ = await CommandLineTool.run(.init(command: .ignore, names: [one.package.id]), store: store)
        XCTAssertEqual(settings.ignoredPackages, [one.package.id])
        _ = await CommandLineTool.run(.init(command: .unignore, names: ["example"]), store: store)
        XCTAssertTrue(settings.ignoredPackages.isEmpty)
    }

    func testInventoryViewRendersDuplicatesAndUnknownVersions() throws {
        let store = store()
        var unknown = item("/usr/local")
        unknown.latest = nil
        unknown.note = "Could not check this prefix"
        store.loadFixture(
            reports: [], packages: [], log: "", installations: [item("/current", defaultPrefix: true), unknown])
        XCTAssertTrue(store.hasUncheckedInstallations)
        XCTAssertTrue(CommandLineReport(store: store).text().contains("No known updates"))
        let bitmap = try XCTUnwrap(renderBitmap(InstallationsView().environment(store).environment(settings)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let output = ProcessInfo.processInfo.environment["MACUP_INSTALLATION_RENDER"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }

    func testNewCLICommandsParseExactInstallationSelectors() {
        XCTAssertEqual(
            CommandLineRequest.parse(["macup", "inventory", "apps", "--json"]),
            .run(.init(command: .inventory, managers: [.apps], json: true)))
        XCTAssertEqual(
            CommandLineRequest.parse(["macup", "remove", "--installation=npm:example@installation=path", "--dry-run"]),
            .run(.init(command: .remove, dryRun: true, installationIDs: ["npm:example@installation=path"])))
        guard case .invalid = CommandLineRequest.parse(["macup", "remove"]) else {
            return XCTFail("Removal requires an exact selection")
        }
    }
}
