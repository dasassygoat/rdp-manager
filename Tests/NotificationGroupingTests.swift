import XCTest

/// One event affecting many machines should be one notification. A switch going down used to
/// mean twenty alerts with twenty sounds arriving at once, which is the moment the alerts
/// matter most and the moment they turn into noise.
@MainActor
final class NotificationGroupingTests: XCTestCase {

    private func machine(_ name: String, group: String = "") -> Machine {
        var m = Machine()
        m.name = name
        m.group = group
        return m
    }

    func testOneMachineReadsAsItAlwaysDid() {
        let (title, body) = Monitor.summary([machine("shop-pc")], did: "went offline")
        XCTAssertEqual(title, "shop-pc went offline")
        XCTAssertTrue(body.isEmpty, "the caller fills in the detail for a single machine")
    }

    func testSeveralMachinesAreCounted() {
        let (title, body) = Monitor.summary(
            [machine("a"), machine("b"), machine("c")], did: "went offline")

        XCTAssertEqual(title, "3 machines went offline")
        XCTAssertEqual(body, "a, b, c")
    }

    func testASharedGroupIsNamed() {
        let (title, _) = Monitor.summary(
            [machine("a", group: "Oak St"), machine("b", group: "Oak St")],
            did: "went offline")

        XCTAssertEqual(title, "2 machines in Oak St went offline",
                       "a site-wide outage should read as a site")
    }

    func testMixedGroupsAreNotNamed() {
        let (title, _) = Monitor.summary(
            [machine("a", group: "Oak St"), machine("b", group: "Elm St")],
            did: "went offline")

        XCTAssertEqual(title, "2 machines went offline")
    }

    func testAnUngroupedMachineStopsTheGroupBeingNamed() {
        let (title, _) = Monitor.summary(
            [machine("a", group: "Oak St"), machine("b")], did: "went offline")

        XCTAssertEqual(title, "2 machines went offline",
                       "naming Oak St would be claiming something untrue of one of them")
    }

    func testALongListIsCutShort() {
        let names = (1...10).map { machine("pc-\($0)") }
        let (title, body) = Monitor.summary(names, did: "went offline")

        XCTAssertEqual(title, "10 machines went offline")
        XCTAssertTrue(body.hasSuffix("and 4 more"), body)
        XCTAssertFalse(body.contains("pc-9"), "a notification is not a report")
    }

    func testNamesAreSorted() {
        let (_, body) = Monitor.summary(
            [machine("zulu"), machine("alpha"), machine("mike")], did: "are back online")

        XCTAssertEqual(body, "alpha, mike, zulu", "so the same outage reads the same way twice")
    }
}
