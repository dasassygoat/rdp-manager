import XCTest

/// The list is often a file on a share that several Macs write. These tests cover what
/// happens when that file cannot be read, which used to end with the unreadable copy being
/// replaced by the empty one shown in its place.
@MainActor
final class StoreSafetyTests: StoreTestCase {

    // MARK: - Refusing to save over a list we could not read

    func testAnUnparseableFileIsNeverOverwritten() throws {
        let original = Data("{ this is not a machine list".utf8)
        try original.write(to: storeURL)

        let store = makeStore()
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.machines.isEmpty, "nothing could be read, so nothing is shown")

        store.add(makeMachine("new-pc"))

        XCTAssertEqual(try Data(contentsOf: storeURL), original,
                       "the file we could not read must still be there, untouched")
    }

    func testAFileThatCannotBeReadIsNeverOverwritten() throws {
        try writeToDisk([makeMachine("shop-pc")])
        let original = try Data(contentsOf: storeURL)
        // Unreadable rather than unparseable: the same situation a share with permissions
        // trouble produces.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: storeURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: storeURL.path)
        }

        let store = makeStore()
        XCTAssertTrue(store.loadFailed)
        store.add(makeMachine("new-pc"))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: storeURL.path)
        XCTAssertEqual(try Data(contentsOf: storeURL), original)
    }

    func testTheReasonIsSaidOutLoud() throws {
        try Data("nonsense".utf8).write(to: storeURL)
        let store = makeStore()
        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.contains("machines.json"), "names the file: \(error)")
        XCTAssertTrue(error.contains("Nothing will be saved"), "says what it means: \(error)")
    }

    // MARK: - A share that has not mounted

    func testAListOnAnUnmountedShareStopsSaving() throws {
        let gone = URL(fileURLWithPath:
            "/Volumes/rdpmanager-not-mounted-\(UUID().uuidString)/RDP Manager/machines.json")
        let store = MachineStore(storeURL: gone, watchForChanges: false)
        store.backupDirectory = backupDirectory

        XCTAssertTrue(store.loadFailed, "an unmounted volume is not an empty list")
        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.contains("not mounted"), error)

        store.add(makeMachine("shop-pc"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: gone.deletingLastPathComponent().path),
            "a folder here would shadow the mount point and split the list in two")
    }

    func testAMissingFileAtAnExistingFolderIsJustAFirstRun() {
        let store = makeStore()
        XCTAssertFalse(store.loadFailed)
        store.add(makeMachine("shop-pc"))
        XCTAssertEqual(try? readFromDisk().map(\.name), ["shop-pc"])
    }

    func testAShareThatMountsLateRecoversOnItsOwn() throws {
        try Data("not a list yet".utf8).write(to: storeURL)
        let store = makeStore()
        XCTAssertTrue(store.loadFailed)

        // The real file turns up where the unreadable one was.
        try writeToDisk([makeMachine("shop-pc")])
        store.reloadFromDisk()

        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.machines.map(\.name), ["shop-pc"])
    }

    func testEditsAreAcceptedAgainOnceTheListCanBeRead() throws {
        try Data("not a list yet".utf8).write(to: storeURL)
        let store = makeStore()
        store.add(makeMachine("ignored-while-broken"))
        XCTAssertEqual(try? Data(contentsOf: storeURL), Data("not a list yet".utf8))

        try writeToDisk([makeMachine("shop-pc")])
        store.retryLoad()
        store.add(makeMachine("new-pc"))

        XCTAssertEqual(try readFromDisk().map(\.name).sorted(), ["new-pc", "shop-pc"])
    }

    // MARK: - Backups

    func testTheReplacedCopyIsKept() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        XCTAssertEqual(backupFiles().count, 0, "nothing was replaced by the first write")

        store.add(makeMachine("office-pc"))
        XCTAssertEqual(backupFiles().count, 1)

        XCTAssertEqual(try readBackup(backupFiles()[0]).map(\.name), ["shop-pc"],
                       "the copy kept is the one that was replaced")
    }

    func testOnlyTheLastTenBackupsAreKept() {
        let store = makeStore()
        for i in 0...(MachineStore.backupCount + 3) {
            store.add(makeMachine("pc-\(i)"))
        }
        XCTAssertEqual(backupFiles().count, MachineStore.backupCount)
    }

    func testAnImportCanBeUndoneFromABackup() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        store.add(makeMachine("office-pc"))

        let wrong = try Self.encoder().encode(
            StoreDocument(version: 1, machines: [makeMachine("not-mine")]))
        _ = try store.importData(wrong)

        let latest = try XCTUnwrap(backupFiles().last)
        XCTAssertEqual(try readBackup(latest).map(\.name).sorted(), ["office-pc", "shop-pc"],
                       "what the list looked like before the import is recoverable")
    }
}
