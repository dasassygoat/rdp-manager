import XCTest

/// The "leave this Mac out" setting. What it must not do is lose the record: it is hidden
/// here and still shared with every other Mac, which is the whole point of the list.
@MainActor
final class HideThisMacTests: StoreTestCase {
    private let me = ThisMac.Identity(macs: ["AA:BB:CC:DD:EE:FF"], names: ["studiogoat"])

    /// A store that believes it is running on "studiogoat".
    private func storePretendingToBeStudio() -> MachineStore {
        let store = makeStore()
        store.identity = me
        store.hidesThisMac = true
        return store
    }

    private func thisMac() -> Machine {
        var m = makeMachine("Studio")
        m.hostname = "studiogoat.local"
        return m
    }

    func testThisMacIsLeftOutOfTheList() throws {
        let store = storePretendingToBeStudio()
        store.add(makeMachine("Front desk"))
        store.add(thisMac())

        XCTAssertEqual(store.listed.map(\.name), ["Front desk"])
        XCTAssertEqual(store.machines.count, 2, "the record itself is still there")
    }

    /// The record is hidden, not deleted. Another Mac reading the same file must still see
    /// it, so the file has to keep both.
    func testTheHiddenRecordIsStillSaved() throws {
        let store = storePretendingToBeStudio()
        store.add(makeMachine("Front desk"))
        store.add(thisMac())

        XCTAssertEqual(try readFromDisk().map(\.name).sorted(), ["Front desk", "Studio"])
    }

    func testTurningTheSettingOffShowsItAgain() throws {
        let store = storePretendingToBeStudio()
        store.add(thisMac())
        XCTAssertTrue(store.listed.isEmpty)

        store.hidesThisMac = false
        XCTAssertEqual(store.listed.map(\.name), ["Studio"])
    }

    func testAMacThatIsNotInTheListHidesNothing() throws {
        let store = makeStore()
        store.identity = ThisMac.Identity(macs: [], names: ["somewhere-else"])
        store.hidesThisMac = true
        store.add(makeMachine("Front desk"))
        store.add(thisMac())

        XCTAssertTrue(store.thisMacIDs.isEmpty)
        XCTAssertEqual(store.listed.count, 2)
    }

    /// What the real list turned out to look like: this Mac under its own name, and twice
    /// more as the `host-NN` records a sweep wrote for its other interfaces. Hiding one of
    /// the three would have looked like the setting half working.
    func testEveryRecordThatIsThisMacIsHidden() throws {
        let store = makeStore()
        store.identity = ThisMac.Identity(
            macs: ["AA:BB:CC:DD:EE:FF", "AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02"], names: [])
        store.hidesThisMac = true
        for (name, mac) in [("StudioMac", "aa:bb:cc:dd:ee:ff"),
                            ("host-152", "aa:bb:cc:dd:ee:01"),
                            ("host-77", "aa:bb:cc:dd:ee:02")] {
            var m = makeMachine(name)
            m.macAddress = mac
            store.add(m)
        }
        store.add(makeMachine("Front desk"))

        XCTAssertEqual(store.thisMacIDs.count, 3)
        XCTAssertEqual(store.listed.map(\.name), ["Front desk"])
        XCTAssertEqual(store.machines.count, 4, "all four are still saved")
    }

    /// The badges next to the list and the count on the menu bar icon are counted over the
    /// same machines the list shows, or they disagree with what is on screen.
    func testCountsAndGroupsFollowTheList() throws {
        let store = storePretendingToBeStudio()
        var mine = thisMac()
        mine.group = "Macs"
        mine.tags = ["mine"]
        store.add(makeMachine("Front desk", group: "Office"))
        store.add(mine)
        store.statuses[store.machines.first { $0.name == "Front desk" }!.id] =
            MachineStatus(state: .online)
        store.statuses[mine.id] = MachineStatus(state: .offline)

        XCTAssertEqual(store.count(where: .online), 1)
        XCTAssertEqual(store.count(where: .offline), 0, "the hidden machine is not counted")
        XCTAssertEqual(store.groups, ["Office"])
        XCTAssertEqual(store.tags, [])
    }

    /// Hiding is this Mac's own view. It is kept in local defaults, so it cannot travel to
    /// the other Macs in the shared file — where it would be wrong for all but one of them.
    func testTheSettingIsNotWrittenToTheSharedFile() throws {
        let store = storePretendingToBeStudio()
        store.add(thisMac())
        let text = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(text.contains("hideThisMac"))
        XCTAssertFalse(text.contains("hidden"))
    }
}
