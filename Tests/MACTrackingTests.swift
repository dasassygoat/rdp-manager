import XCTest

/// Finding a machine by its MAC when its name does not resolve and its address has moved.
/// Without this a machine on plain DHCP with no DNS record simply stayed offline after a
/// lease change until somebody edited it by hand.
@MainActor
final class MACTrackingTests: XCTestCase {

    private func machine(mac: String = "00:11:22:AA:BB:CC", lastIP: String? = nil) -> Machine {
        var m = Machine()
        m.name = "shop-pc"
        m.hostname = "shop-pc"
        m.macAddress = mac
        m.lastIP = lastIP
        return m
    }

    // MARK: - The cache read backwards

    func testAMACIsFoundInTheCache() {
        let table = ["192.168.1.20": "aa:bb:cc:dd:ee:ff", "192.168.1.21": "00:11:22:aa:bb:cc"]
        XCTAssertEqual(ARPTable.address(ofMAC: "00:11:22:AA:BB:CC", table: table), "192.168.1.21")
    }

    func testTheWrittenFormDoesNotMatter() {
        let table = ["192.168.1.21": "0:11:22:aa:bb:cc"]
        XCTAssertEqual(ARPTable.address(ofMAC: "00-11-22-AA-BB-CC".replacingOccurrences(of: "-", with: ":"),
                                        table: table),
                       "192.168.1.21")
    }

    func testAMACThatIsNotInTheCacheIsNotFound() {
        XCTAssertNil(ARPTable.address(ofMAC: "00:11:22:AA:BB:CC",
                                      table: ["192.168.1.20": "aa:bb:cc:dd:ee:ff"]))
    }

    func testNonsenseIsNotAMAC() {
        XCTAssertNil(ARPTable.address(ofMAC: "", table: ["1.2.3.4": "00:11:22:aa:bb:cc"]))
        XCTAssertNil(ARPTable.address(ofMAC: "not a mac", table: ["1.2.3.4": "00:11:22:aa:bb:cc"]))
    }

    func testSeveralAddressesForOneMACGiveTheSameAnswerEveryTime() {
        let table = ["192.168.1.30": "00:11:22:aa:bb:cc", "192.168.1.9": "00:11:22:aa:bb:cc"]
        // Numeric order, not string order: .9 is lower than .30.
        XCTAssertEqual(ARPTable.address(ofMAC: "00:11:22:AA:BB:CC", table: table), "192.168.1.9")
    }

    // MARK: - What the poller tries, and in what order

    func testTheNameComesFirst() {
        let order = Monitor.addressesToTry(
            for: machine(lastIP: "192.168.1.20"),
            resolved: "192.168.1.25",
            arpTable: ["192.168.1.30": "00:11:22:aa:bb:cc"])

        XCTAssertEqual(order, ["192.168.1.25", "192.168.1.20", "192.168.1.30"])
    }

    func testTheMACIsTheLastResort() {
        let order = Monitor.addressesToTry(
            for: machine(lastIP: "192.168.1.20"),
            resolved: nil,
            arpTable: ["192.168.1.30": "00:11:22:aa:bb:cc"])

        XCTAssertEqual(order, ["192.168.1.20", "192.168.1.30"],
                       "the address on file is still tried first; it is usually right")
    }

    func testAMovedMachineWithNoNameIsStillFound() {
        // Nothing resolves, and the address on file now belongs to something else.
        let order = Monitor.addressesToTry(
            for: machine(lastIP: "192.168.1.20"),
            resolved: nil,
            arpTable: ["192.168.1.77": "00:11:22:aa:bb:cc"])

        XCTAssertTrue(order.contains("192.168.1.77"))
    }

    func testTheSameAddressIsNotTriedTwice() {
        let order = Monitor.addressesToTry(
            for: machine(lastIP: "192.168.1.20"),
            resolved: "192.168.1.20",
            arpTable: ["192.168.1.20": "00:11:22:aa:bb:cc"])

        XCTAssertEqual(order, ["192.168.1.20"])
    }

    func testAMachineWithNoMACIsUnaffected() {
        let order = Monitor.addressesToTry(
            for: machine(mac: "", lastIP: "192.168.1.20"),
            resolved: nil,
            arpTable: ["192.168.1.30": "00:11:22:aa:bb:cc"])

        XCTAssertEqual(order, ["192.168.1.20"])
    }

    func testAMachineWithNothingToGoOnHasNowhereToLook() {
        XCTAssertTrue(Monitor.addressesToTry(
            for: machine(mac: "", lastIP: nil), resolved: nil, arpTable: [:]).isEmpty)
    }
}
