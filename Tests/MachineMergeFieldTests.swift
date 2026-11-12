import XCTest

/// Two Macs editing the same machine. The old rule took the record with the later timestamp
/// and discarded the other, so an edit here and an unrelated edit there meant one of them
/// was lost — and which one depended on who saved last.
@MainActor
final class MachineMergeFieldTests: StoreTestCase {

    private func base() -> Machine {
        var m = makeMachine("shop-pc", modifiedAt: Date(timeIntervalSince1970: 1_000))
        m.rdpPort = 3389
        m.group = "Office"
        m.notes = "front desk"
        return m
    }

    // MARK: - Fields nobody fought over

    func testTwoUnrelatedEditsBothSurvive() {
        let agreed = base()

        var mine = agreed
        mine.notes = "front desk, upstairs"
        mine.modifiedAt = Date(timeIntervalSince1970: 2_000)

        var theirs = agreed
        theirs.rdpPort = 3390
        theirs.modifiedAt = Date(timeIntervalSince1970: 3_000)   // they saved later

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: agreed)

        XCTAssertEqual(merged.notes, "front desk, upstairs", "my edit is not thrown away")
        XCTAssertEqual(merged.rdpPort, 3390, "and neither is theirs")
    }

    func testAFieldOnlyTheyChangedIsTakenEvenWhenISavedLater() {
        let agreed = base()
        var mine = agreed
        mine.modifiedAt = Date(timeIntervalSince1970: 9_000)   // I saved last, but changed nothing
        var theirs = agreed
        theirs.group = "Servers"
        theirs.modifiedAt = Date(timeIntervalSince1970: 2_000)

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: agreed)

        XCTAssertEqual(merged.group, "Servers")
    }

    func testAFieldOnlyIChangedIsKeptEvenWhenTheySavedLater() {
        let agreed = base()
        var mine = agreed
        mine.audio = .thisMac
        mine.modifiedAt = Date(timeIntervalSince1970: 2_000)
        var theirs = agreed
        theirs.modifiedAt = Date(timeIntervalSince1970: 9_000)

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: agreed)

        XCTAssertEqual(merged.audio, .thisMac,
                       "this is the shape of the bug that dropped the sound setting")
    }

    // MARK: - Fields both sides changed

    func testTheLaterEditWinsTheFieldItActuallyConflictsOn() {
        let agreed = base()
        var mine = agreed
        mine.group = "Mine"
        mine.modifiedAt = Date(timeIntervalSince1970: 2_000)
        var theirs = agreed
        theirs.group = "Theirs"
        theirs.modifiedAt = Date(timeIntervalSince1970: 3_000)

        XCTAssertEqual(MachineMerge.merge(local: mine, remote: theirs, base: agreed).group,
                       "Theirs")
        mine.modifiedAt = Date(timeIntervalSince1970: 4_000)
        XCTAssertEqual(MachineMerge.merge(local: mine, remote: theirs, base: agreed).group,
                       "Mine")
    }

    func testAConflictOnOneFieldDoesNotDecideTheOthers() {
        let agreed = base()
        var mine = agreed
        mine.group = "Mine"
        mine.notes = "only I touched this"
        mine.modifiedAt = Date(timeIntervalSince1970: 2_000)
        var theirs = agreed
        theirs.group = "Theirs"
        theirs.modifiedAt = Date(timeIntervalSince1970: 3_000)

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: agreed)

        XCTAssertEqual(merged.group, "Theirs", "they win the field they fought for")
        XCTAssertEqual(merged.notes, "only I touched this", "and nothing else")
    }

    // MARK: - Without a baseline

    func testWithNothingAgreedOnItFallsBackToTheOldRule() {
        var mine = base()
        mine.group = "Mine"
        mine.modifiedAt = Date(timeIntervalSince1970: 5_000)
        var theirs = base()
        theirs.group = "Theirs"
        theirs.modifiedAt = Date(timeIntervalSince1970: 2_000)

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: nil)

        XCTAssertEqual(merged.group, "Mine", "later record wins whole, as before")
    }

    // MARK: - Observations rather than edits

    func testBothMacsSightingsAreKept() {
        let agreed = base()
        var mine = agreed
        mine.ipHistory = [IPRecord(ip: "192.168.1.20", seenAt: Date(timeIntervalSince1970: 100))]
        var theirs = agreed
        theirs.ipHistory = [IPRecord(ip: "192.168.1.21", seenAt: Date(timeIntervalSince1970: 200))]

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: agreed)

        XCTAssertEqual(merged.ipHistory.map(\.ip), ["192.168.1.20", "192.168.1.21"])
    }

    func testTheSameSightingFromTwoMacsIsOneEntry() {
        let agreed = base()
        let at = Date(timeIntervalSince1970: 100)
        var mine = agreed
        mine.ipHistory = [IPRecord(ip: "192.168.1.20", seenAt: at)]
        var theirs = agreed
        theirs.ipHistory = [IPRecord(ip: "192.168.1.20", seenAt: at)]

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: agreed)

        XCTAssertEqual(merged.ipHistory.count, 1)
    }

    func testTheMoreRecentSightingWins() {
        let agreed = base()
        var mine = agreed
        mine.lastSeen = Date(timeIntervalSince1970: 100)
        var theirs = agreed
        theirs.lastSeen = Date(timeIntervalSince1970: 500)

        XCTAssertEqual(MachineMerge.merge(local: mine, remote: theirs, base: agreed).lastSeen,
                       Date(timeIntervalSince1970: 500))
    }

    // MARK: - A copy that has not caught up

    func testAStaleCopyDoesNotLookLikeAnEditBack() {
        let agreed = base()
        var mine = agreed
        mine.group = "Servers"
        mine.notes = "moved to the rack"
        mine.modifiedAt = Date(timeIntervalSince1970: 5_000)

        // A Mac that has been away from the share, still holding the old record.
        var theirs = agreed
        theirs.modifiedAt = Date(timeIntervalSince1970: 500)

        let merged = MachineMerge.merge(local: mine, remote: theirs, base: agreed)

        XCTAssertEqual(merged.group, "Servers", "their copy is behind, not a change")
        XCTAssertEqual(merged.notes, "moved to the rack")
    }

    // MARK: - Through the store

    func testAnUnrelatedEditOnAnotherMacDoesNotUndoMine() throws {
        let store = makeStore()
        var shop = makeMachine("shop-pc")
        shop.rdpPort = 3389
        store.add(shop)

        // Another Mac picks up the list and changes the port.
        var theirs = try readFromDisk()[0]
        theirs.rdpPort = 3390
        theirs.modifiedAt = Date().addingTimeInterval(10)

        // Meanwhile this Mac changes the sound setting.
        var mine = store.machines[0]
        mine.audio = .thisMac
        store.update(mine)

        try writeToDisk([theirs])
        store.reloadFromDisk()

        XCTAssertEqual(store.machines[0].audio, .thisMac, "my edit survived")
        XCTAssertEqual(store.machines[0].rdpPort, 3390, "so did theirs")
    }

    func testADeleteIsNotUndoneByAnotherMacsCopy() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        let onDisk = try readFromDisk()

        store.remove(store.machines[0].id)
        XCTAssertTrue(store.machines.isEmpty)

        // The other Mac still has it, unchanged, and writes the list back.
        try writeToDisk(onDisk)
        store.reloadFromDisk()

        XCTAssertTrue(store.machines.isEmpty,
                      "a delete that bounces back off a stale copy is not a delete")
    }

    func testADeleteIsRememberedAcrossARestart() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        let onDisk = try readFromDisk()
        store.remove(store.machines[0].id)

        // A fresh store reads the file, tombstone and all, as it would after a relaunch.
        let restarted = makeStore()
        try writeToDisk(onDisk)
        restarted.reloadFromDisk()

        XCTAssertTrue(restarted.machines.isEmpty,
                      "the delete was written down, so it outlives the app that made it")
    }

    func testAnOlderListWithNoDeletesStillLoads() throws {
        let json = """
        { "version": 1, "machines": [ { "name": "shop-pc" } ] }
        """
        try Data(json.utf8).write(to: storeURL)
        XCTAssertEqual(makeStore().machines.map(\.name), ["shop-pc"])
    }

    func testAMachineChangedElsewhereAfterMyDeleteComesBack() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        var onDisk = try readFromDisk()

        store.remove(store.machines[0].id)

        // They did not just still have it — they edited it, so it is a live machine.
        onDisk[0].notes = "still in use, do not remove"
        onDisk[0].modifiedAt = Date().addingTimeInterval(60)
        try writeToDisk(onDisk)
        store.reloadFromDisk()

        XCTAssertEqual(store.machines.map(\.name), ["shop-pc"])
    }
}

/// Polling used to count as editing, which let the Mac that polled most recently win every
/// merge and carry its own stale settings over everyone else's work.
@MainActor
final class ObservationsAreNotEditsTests: StoreTestCase {

    func testRecordingAnIPIsNotAnEdit() {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        let before = store.machines[0].modifiedAt

        store.recordIP("192.168.1.55", for: store.machines[0].id)

        XCTAssertEqual(store.machines[0].lastIP, "192.168.1.55", "it is still recorded")
        XCTAssertEqual(store.machines[0].modifiedAt, before,
                       "but it does not make this Mac's copy look newer than anyone else's")
    }

    func testRecordingASightingIsNotAnEdit() {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))
        let before = store.machines[0].modifiedAt

        store.recordLastSeen(Date(), for: store.machines[0].id)

        XCTAssertNotNil(store.machines[0].lastSeen)
        XCTAssertEqual(store.machines[0].modifiedAt, before)
    }

    func testPollingDoesNotLetThisMacOverwriteAnotherMacsEdit() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))

        // Another Mac renames it.
        var theirs = try readFromDisk()[0]
        theirs.name = "front-desk-pc"
        theirs.modifiedAt = Date().addingTimeInterval(5)

        // This Mac notices a new address a moment later, which used to count as an edit and
        // would then have won on timestamp.
        store.recordIP("192.168.1.55", for: store.machines[0].id)

        try writeToDisk([theirs])
        store.reloadFromDisk()

        XCTAssertEqual(store.machines[0].name, "front-desk-pc", "their edit stands")
        XCTAssertEqual(store.machines[0].lastIP, "192.168.1.55", "and the sighting is kept")
    }
}
