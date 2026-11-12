import XCTest

/// A sweep knew which hosts matched the list and used that only to grey out rows. The same
/// information answers more useful questions: what moved, what changed, and what is on this
/// network that nobody has written down.
@MainActor
final class DiscoveryReconcileTests: StoreTestCase {

    private func host(_ ip: String, mac: String? = nil, ports: Set<Int> = [3389],
                      existing: Machine? = nil) -> Discovery.Host {
        var h = Discovery.Host(ip: ip, mac: mac, openPorts: ports)
        h.existing = existing
        return h
    }

    private func machine(_ name: String, at ip: String?, primary: ConnectionType = .rdp) -> Machine {
        var m = makeMachine(name)
        m.lastIP = ip
        m.primary = primary
        return m
    }

    // MARK: - Standing

    func testAHostNotInTheListIsUnknown() {
        XCTAssertEqual(host("192.168.1.99").standing, .unknown)
    }

    func testAHostWhereTheListSaysItIsIsKnown() {
        let m = machine("shop-pc", at: "192.168.1.20")
        XCTAssertEqual(host("192.168.1.20", existing: m).standing, .known)
    }

    func testAHostSomewhereElseHasMoved() {
        let m = machine("shop-pc", at: "192.168.1.20")
        XCTAssertEqual(host("192.168.1.77", existing: m).standing,
                       .moved(from: "192.168.1.20"))
    }

    func testAMatchedMachineWithNoAddressYetCountsAsMoved() {
        let m = machine("shop-pc", at: nil)
        XCTAssertEqual(host("192.168.1.77", existing: m).standing, .moved(from: nil))
    }

    // MARK: - Ports that were not expected

    func testExtraPortsAreNoticed() {
        let m = machine("shop-pc", at: "192.168.1.20", primary: .rdp)
        let found = host("192.168.1.20", ports: [3389, 22, 80], existing: m)

        XCTAssertEqual(found.unexpectedPorts, [22, 80],
                       "the port it is reached on is expected; the others are a change")
    }

    func testAMachineAnsweringOnlyAsExpectedHasNone() {
        let m = machine("shop-pc", at: "192.168.1.20", primary: .rdp)
        XCTAssertTrue(host("192.168.1.20", ports: [3389], existing: m).unexpectedPorts.isEmpty)
    }

    func testAnUnknownHostHasNoExpectations() {
        XCTAssertTrue(host("192.168.1.99", ports: [22, 80]).unexpectedPorts.isEmpty,
                      "nothing is unexpected about a machine nobody has described yet")
    }

    // MARK: - Machines that did not answer

    func testAMachineOnTheSweptRangeThatDidNotAnswerIsReported() async {
        let store = makeStore()
        store.add(machine("shop-pc", at: "192.168.1.20"))
        store.add(machine("office-pc", at: "192.168.1.21"))
        let discovery = Discovery(store: store)

        // Only office-pc answered.
        let swept: Set<String> = ["192.168.1.20", "192.168.1.21", "192.168.1.22"]
        discovery.setHostsForTesting([host("192.168.1.21",
                                          existing: store.machines.first { $0.name == "office-pc" })])

        XCTAssertEqual(discovery.unseenMachines(in: swept).map(\.name), ["shop-pc"])
    }

    func testAMachineOutsideTheSweptRangeHasNotGoneMissing() {
        let store = makeStore()
        store.add(machine("far-pc", at: "10.9.9.9"))
        let discovery = Discovery(store: store)
        discovery.setHostsForTesting([])

        XCTAssertTrue(discovery.unseenMachines(in: ["192.168.1.20"]).isEmpty,
                      "it was not looked at, which is not the same as not answering")
    }

    func testAMachineWithNoAddressIsNotReportedMissing() {
        let store = makeStore()
        store.add(machine("new-pc", at: nil))
        let discovery = Discovery(store: store)
        discovery.setHostsForTesting([])

        XCTAssertTrue(discovery.unseenMachines(in: ["192.168.1.20"]).isEmpty)
    }

    // MARK: - Writing the moves back

    func testApplyingMovesRecordsTheNewAddress() {
        let store = makeStore()
        store.add(machine("shop-pc", at: "192.168.1.20"))
        let mine = store.machines[0]
        let before = mine.modifiedAt
        let discovery = Discovery(store: store)
        discovery.setHostsForTesting([host("192.168.1.77", existing: mine)])

        XCTAssertEqual(discovery.applyMoves(), 1)

        XCTAssertEqual(store.machines[0].lastIP, "192.168.1.77")
        XCTAssertEqual(store.machines[0].ipHistory.last?.ip, "192.168.1.77")
        XCTAssertEqual(store.machines[0].modifiedAt, before,
                       "finding a machine is a sighting, not an edit")
    }

    func testApplyingMovesLeavesOtherMachinesAlone() {
        let store = makeStore()
        store.add(machine("shop-pc", at: "192.168.1.20"))
        store.add(machine("office-pc", at: "192.168.1.21"))
        let shop = store.machines.first { $0.name == "shop-pc" }!
        let discovery = Discovery(store: store)
        discovery.setHostsForTesting([host("192.168.1.77", existing: shop)])

        discovery.applyMoves()

        XCTAssertEqual(store.machines.first { $0.name == "office-pc" }?.lastIP, "192.168.1.21")
    }

    func testUnknownHostsAreListedInAddressOrder() {
        let store = makeStore()
        let discovery = Discovery(store: store)
        discovery.setHostsForTesting([host("192.168.1.30"), host("192.168.1.9"),
                                      host("192.168.1.100")])

        XCTAssertEqual(discovery.unknownHosts.map(\.ip),
                       ["192.168.1.9", "192.168.1.30", "192.168.1.100"],
                       "numeric order, so the list reads like a network and not like text")
    }
}
