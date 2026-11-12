import XCTest

/// An import replaces machines wholesale, over a list that may be shared with other Macs.
/// It should say what it is about to do, and be undoable afterwards.
@MainActor
final class ImportRestoreTests: StoreTestCase {

    private func export(_ machines: [Machine]) throws -> Data {
        try Self.encoder().encode(StoreDocument(version: 1, machines: machines))
    }

    // MARK: - Preview

    func testAPreviewCountsWhatWouldChange() throws {
        let store = makeStore()
        let shop = makeMachine("shop-pc")
        let office = makeMachine("office-pc")
        store.add(shop)
        store.add(office)

        var changed = store.machines.first { $0.name == "office-pc" }!
        changed.notes = "different"
        let preview = try store.previewImport(
            try export([store.machines.first { $0.name == "shop-pc" }!,
                        changed,
                        makeMachine("new-pc")]))

        XCTAssertEqual(preview.added, ["new-pc"])
        XCTAssertEqual(preview.changed, ["office-pc"])
        XCTAssertEqual(preview.unchanged, ["shop-pc"])
        XCTAssertEqual(preview.total, 3)
    }

    func testAPreviewNamesARename() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        var renamed = store.machines[0]
        renamed.name = "front-desk-pc"

        let preview = try store.previewImport(try export([renamed]))

        XCTAssertEqual(preview.changed, ["shop-pc → front-desk-pc"],
                       "so it is obvious which machine is being written over")
    }

    func testAPreviewChangesNothing() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        _ = try store.previewImport(try export([makeMachine("new-pc")]))

        XCTAssertEqual(store.machines.map(\.name), ["shop-pc"], "a look is not a change")
    }

    func testAnEmptyFileIsNotMistakenForAnImport() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        XCTAssertEqual(try store.previewImport(try export([])).total, 0)
    }

    func testAPreviewSaysSomethingReadable() throws {
        let store = makeStore()
        XCTAssertEqual(try store.previewImport(try export([makeMachine("a")])).summary,
                       "1 to add")
        XCTAssertEqual(try store.previewImport(try export([])).summary, "Nothing to import")
    }

    // MARK: - Restore

    func testAnImportCanBeUndone() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        store.add(makeMachine("office-pc"))
        let before = store.machines.map(\.name).sorted()

        _ = try store.importData(try export([makeMachine("not-mine")]))
        XCTAssertTrue(store.machines.map(\.name).contains("not-mine"))

        let latest = try XCTUnwrap(store.backups().first)
        try store.restore(from: latest)

        XCTAssertEqual(store.machines.map(\.name).sorted(), before)
    }

    func testBackupsAreNewestFirst() {
        let store = makeStore()
        for i in 0..<4 { store.add(makeMachine("pc-\(i)")) }

        let backups = store.backups()
        XCTAssertEqual(backups.count, 3, "the first write replaced nothing")
        XCTAssertEqual(backups.map(\.lastPathComponent),
                       backups.map(\.lastPathComponent).sorted(by: >))
    }

    func testARestoreIsItselfUndoable() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        store.add(makeMachine("office-pc"))
        let oldest = try XCTUnwrap(store.backups().last)   // just shop-pc

        try store.restore(from: oldest)
        XCTAssertEqual(store.machines.map(\.name), ["shop-pc"])

        // The two-machine list was kept on the way past.
        let latest = try XCTUnwrap(store.backups().first)
        try store.restore(from: latest)
        XCTAssertEqual(store.machines.map(\.name).sorted(), ["office-pc", "shop-pc"])
    }

    func testRestoringBringsBackADeletedMachine() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        store.add(makeMachine("office-pc"))
        // A saved copy holding both: each save keeps the list as it was *before* that
        // save, so one more change is needed for the two-machine list to have been kept.
        var office = store.machines.first { $0.name == "office-pc" }!
        office.notes = "touch"
        store.update(office)
        let both = try XCTUnwrap(store.backups().first)

        store.remove(store.machines.first { $0.name == "shop-pc" }!.id)
        XCTAssertEqual(store.machines.map(\.name), ["office-pc"])

        try store.restore(from: both)

        XCTAssertEqual(store.machines.map(\.name).sorted(), ["office-pc", "shop-pc"],
                       "restoring a copy that has it is asking for it back")
        // And the delete does not come back to undo the restore on the next merge.
        store.reloadFromDisk()
        XCTAssertEqual(store.machines.count, 2)
    }

    func testARestoredListReachesTheFile() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        store.add(makeMachine("office-pc"))
        let oldest = try XCTUnwrap(store.backups().last)

        try store.restore(from: oldest)

        XCTAssertEqual(try readFromDisk().map(\.name), ["shop-pc"],
                       "the other Macs have to see it too")
    }
}
