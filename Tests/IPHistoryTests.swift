import XCTest

/// Covers `recordIP`, which is what the monitor calls every poll, and the history it keeps.
@MainActor
final class IPHistoryTests: StoreTestCase {
    func testFirstAddressIsRecorded() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let id = store.machines[0].id

        XCTAssertTrue(store.recordIP("192.168.1.10", for: id))
        XCTAssertEqual(store.machine(id)?.lastIP, "192.168.1.10")
        XCTAssertEqual(store.machine(id)?.ipHistory.map(\.ip), ["192.168.1.10"])
    }

    func testUnchangedAddressIsNotRecordedAgain() throws {
        let store = makeStore()
        store.add(makeMachine("alpha", lastIP: "192.168.1.10"))
        let id = store.machines[0].id

        XCTAssertFalse(store.recordIP("192.168.1.10", for: id),
                       "an unchanged address should not report a change")
        XCTAssertTrue(store.machine(id)?.ipHistory.isEmpty ?? false)
    }

    func testEachChangeIsAppendedInOrder() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let id = store.machines[0].id

        for ip in ["192.168.1.10", "192.168.1.11", "192.168.1.10"] {
            XCTAssertTrue(store.recordIP(ip, for: id))
        }

        XCTAssertEqual(store.machine(id)?.ipHistory.map(\.ip),
                       ["192.168.1.10", "192.168.1.11", "192.168.1.10"])
        XCTAssertEqual(store.machine(id)?.lastIP, "192.168.1.10")
    }

    func testRecordingForAnUnknownMachineDoesNothing() throws {
        let store = makeStore()
        XCTAssertFalse(store.recordIP("192.168.1.10", for: UUID()))
    }

    func testHistoryIsCappedKeepingTheNewestEntries() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let id = store.machines[0].id

        for i in 0..<250 { store.recordIP("10.0.0.\(i % 250)", for: id) }

        let history = store.machine(id)?.ipHistory ?? []
        XCTAssertEqual(history.count, 200)
        XCTAssertEqual(history.last?.ip, "10.0.0.249")
        XCTAssertEqual(history.first?.ip, "10.0.0.50", "the oldest entries should be the ones dropped")
    }

    func testRecordingAnAddressBumpsModifiedAt() throws {
        let store = makeStore()
        store.add(makeMachine("alpha", modifiedAt: Date() - 3600))
        let id = store.machines[0].id
        let before = store.machine(id)!.modifiedAt

        store.recordIP("192.168.1.10", for: id)

        XCTAssertGreaterThan(store.machine(id)!.modifiedAt, before,
                             "another Mac must see this as the newer copy")
    }

    func testHistorySurvivesSaveAndLoad() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let id = store.machines[0].id
        store.recordIP("192.168.1.10", for: id)
        store.recordIP("192.168.1.11", for: id)
        let saved = store.machine(id)!.ipHistory

        let reopened = makeStore()
        let loaded = reopened.machine(id)?.ipHistory ?? []

        XCTAssertEqual(loaded.map(\.ip), saved.map(\.ip))
        XCTAssertEqual(loaded.map(\.id), saved.map(\.id))
        for (a, b) in zip(loaded, saved) {
            XCTAssertEqual(a.seenAt.timeIntervalSince1970, b.seenAt.timeIntervalSince1970, accuracy: 1,
                           "timestamps are what the IP History list shows")
        }
    }

    func testHistoryFromAnotherMacIsMergedIn() throws {
        let id = UUID()
        var remote = makeMachine("alpha", id: id, lastIP: "192.168.1.20", modifiedAt: Date())
        remote.ipHistory = [IPRecord(ip: "192.168.1.19", seenAt: Date() - 60),
                            IPRecord(ip: "192.168.1.20")]
        try writeToDisk([remote], fileDate: Date() - 3600)

        let store = makeStore()

        XCTAssertEqual(store.machine(id)?.ipHistory.map(\.ip), ["192.168.1.19", "192.168.1.20"])
        XCTAssertEqual(store.machine(id)?.lastIP, "192.168.1.20")
    }

    func testLastSeenIsRecorded() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let id = store.machines[0].id
        let seen = Date() - 30

        store.recordLastSeen(seen, for: id)

        XCTAssertEqual(store.machine(id)?.lastSeen?.timeIntervalSince1970 ?? 0,
                       seen.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try readFromDisk().first?.lastSeen?.timeIntervalSince1970 ?? 0,
                       seen.timeIntervalSince1970, accuracy: 1)
    }
}
