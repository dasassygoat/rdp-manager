import XCTest

/// Covers `reloadFromDisk`, which is what runs when another Mac writes the shared file.
/// Merging is last-writer-wins per machine, by `modifiedAt`.
@MainActor
final class MachineStoreMergeTests: StoreTestCase {
    private let hour: TimeInterval = 3600

    func testRemoteEditWinsWhenItIsNewer() throws {
        let id = UUID()
        try writeToDisk([makeMachine("beta", id: id, modifiedAt: Date() - hour)], fileDate: Date() - hour)
        let store = makeStore()
        XCTAssertEqual(store.machines.count, 1)

        try writeToDisk([makeMachine("beta-renamed", id: id, modifiedAt: Date())])
        store.reloadFromDisk()

        XCTAssertEqual(store.machines.map(\.name), ["beta-renamed"])
    }

    func testLocalEditWinsWhenItIsNewerAndIsWrittenBack() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let id = store.machines[0].id

        // Another Mac writes a copy of the same machine that is older than our edit.
        try writeToDisk([makeMachine("alpha-stale", id: id, modifiedAt: Date() - hour)])
        store.reloadFromDisk()

        XCTAssertEqual(store.machines.map(\.name), ["alpha"])
        XCTAssertEqual(try readFromDisk().map(\.name), ["alpha"],
                       "the kept local copy should be saved back so the other Mac sees it")
    }

    func testMachineAddedElsewhereIsPickedUp() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let mine = store.machines[0]

        try writeToDisk([mine, makeMachine("zulu", modifiedAt: Date() - hour)])
        store.reloadFromDisk()

        XCTAssertEqual(store.machines.map(\.name), ["alpha", "zulu"])
    }

    func testMachineDeletedElsewhereIsDropped() throws {
        let id = UUID()
        try writeToDisk([makeMachine("doomed", id: id, modifiedAt: Date() - hour)],
                        fileDate: Date() - hour)
        let store = makeStore()
        XCTAssertEqual(store.machines.count, 1)

        // The file is written after our copy was last touched, so the delete wins.
        try writeToDisk([], fileDate: Date())
        store.reloadFromDisk()

        XCTAssertTrue(store.machines.isEmpty)
    }

    func testMachineAddedLocallyAfterTheFileWasWrittenSurvives() throws {
        let store = makeStore()
        store.add(makeMachine("local-only"))

        // A file written before our add must not take the new machine away again.
        try writeToDisk([makeMachine("remote", modifiedAt: Date() - hour)], fileDate: Date() - hour)
        store.reloadFromDisk()

        XCTAssertEqual(store.machines.map(\.name).sorted(), ["local-only", "remote"])
        XCTAssertEqual(try readFromDisk().count, 2,
                       "the locally added machine should be written back to the share")
    }

    func testStatusIsForgottenForAMachineDeletedElsewhere() throws {
        let id = UUID()
        try writeToDisk([makeMachine("doomed", id: id, modifiedAt: Date() - hour)],
                        fileDate: Date() - hour)
        let store = makeStore()
        store.statuses[id] = MachineStatus(state: .online)

        try writeToDisk([], fileDate: Date())
        store.reloadFromDisk()

        XCTAssertNil(store.statuses[id], "status of a machine that is gone should not linger")
    }

    func testMergeSortsByGroupThenName() throws {
        let store = makeStore()
        try writeToDisk([
            makeMachine("shop-pc", group: "Shop", modifiedAt: Date() - hour),
            makeMachine("ungrouped", modifiedAt: Date() - hour),
            makeMachine("office-pc", group: "Office", modifiedAt: Date() - hour),
            makeMachine("office-nas", group: "Office", modifiedAt: Date() - hour),
        ], fileDate: Date() - hour)
        store.reloadFromDisk()

        XCTAssertEqual(store.machines.map(\.name),
                       ["office-nas", "office-pc", "shop-pc", "ungrouped"])
    }

    func testReloadIgnoresAnUnchangedFile() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let before = store.machines

        store.reloadFromDisk()

        XCTAssertEqual(store.machines, before)
    }

    func testReloadKeepsTheListWhenTheFileIsCorrupt() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))

        try Data("{ not json".utf8).write(to: storeURL)
        store.reloadFromDisk()

        XCTAssertEqual(store.machines.map(\.name), ["alpha"],
                       "a half-written or hand-mangled file must not empty the list")
    }

    func testPasswordsAreNeverWrittenToTheSharedFile() throws {
        let store = makeStore()
        var m = makeMachine("alpha")
        m.username = "admin"
        store.add(m)

        let text = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(text.contains("admin"))
        XCTAssertFalse(text.lowercased().contains("password"))
    }
}
