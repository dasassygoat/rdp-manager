import XCTest

/// A machine can be left out of the polling, for the laptop that is meant to be off.
@MainActor
final class MonitoringOptOutTests: StoreTestCase {

    func testAnUnmonitoredMachineIsNotProbed() async {
        let store = makeStore()
        var laptop = makeMachine("laptop")
        laptop.monitored = false
        store.add(laptop)
        store.add(makeMachine("shop-pc"))

        let monitor = Monitor(store: store)
        await monitor.runCycle()

        XCTAssertNil(store.statuses[laptop.id],
                     "never probed, so it has no state to report")
        XCTAssertNotNil(store.statuses[store.machines.first { $0.name == "shop-pc" }!.id],
                        "the others are still watched")
    }

    func testTurningMonitoringOffClearsWhatWasKnown() async {
        let store = makeStore()
        store.add(makeMachine("laptop"))
        let id = store.machines[0].id
        let monitor = Monitor(store: store)
        await monitor.runCycle()
        XCTAssertNotNil(store.statuses[id], "watched to begin with")

        var laptop = store.machines[0]
        laptop.monitored = false
        store.update(laptop)
        await monitor.runCycle()

        XCTAssertNil(store.statuses[id],
                     "a stale red dot for a machine nobody is watching is worse than none")
    }
}
