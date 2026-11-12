import XCTest

/// Where the wake packet is aimed, and the wait that follows it.
@MainActor
final class WakeTests: XCTestCase {

    // MARK: - The broadcast address

    private func interface(_ address: String, _ prefix: Int) -> LocalInterfaces.Interface {
        LocalInterfaces.Interface(
            name: "en0",
            subnet: IPv4Subnet(address: IPv4Subnet.parse(address)!, prefixLength: prefix))
    }

    func testTheBroadcastComesFromTheInterfaceMask() {
        // A /23: the broadcast is .1.255, not the .0.255 a /24 assumption produces.
        let found = WakeOnLAN.directedBroadcast(
            for: "192.168.0.40", interfaces: [interface("192.168.0.10", 23)])

        XCTAssertEqual(found, "192.168.1.255")
    }

    func testA24StillGivesTheSameAnswerAsBefore() {
        let found = WakeOnLAN.directedBroadcast(
            for: "10.0.5.40", interfaces: [interface("10.0.5.10", 24)])

        XCTAssertEqual(found, "10.0.5.255")
    }

    func testAWideMaskIsNotRoundedToA24() {
        let found = WakeOnLAN.directedBroadcast(
            for: "172.16.4.9", interfaces: [interface("172.16.1.10", 16)])

        XCTAssertEqual(found, "172.16.255.255")
    }

    func testTheRightInterfaceIsPickedOutOfSeveral() {
        let found = WakeOnLAN.directedBroadcast(
            for: "10.8.0.40",
            interfaces: [interface("192.168.1.10", 24), interface("10.8.0.1", 24)])

        XCTAssertEqual(found, "10.8.0.255")
    }

    func testAMachineOnNoLocalSubnetHasNoDirectedBroadcast() {
        XCTAssertNil(WakeOnLAN.directedBroadcast(
            for: "203.0.113.5", interfaces: [interface("192.168.1.10", 24)]))
    }

    func testAnUnknownAddressHasNoDirectedBroadcast() {
        XCTAssertNil(WakeOnLAN.directedBroadcast(for: nil, interfaces: [interface("192.168.1.10", 24)]))
        XCTAssertNil(WakeOnLAN.directedBroadcast(for: "", interfaces: [interface("192.168.1.10", 24)]))
        XCTAssertNil(WakeOnLAN.directedBroadcast(for: "not-an-ip",
                                                 interfaces: [interface("192.168.1.10", 24)]))
    }

    func testTheFallbackIsStillThere() {
        var m = Machine()
        m.lastIP = "192.168.1.40"
        XCTAssertEqual(m.broadcastAddress, "192.168.1.255",
                       "what is used when the machine is on no subnet this Mac is on")
    }

    // MARK: - Waking and then connecting

    private func machine() -> Machine {
        var m = Machine()
        m.name = "shop-pc"
        m.macAddress = "00:11:22:AA:BB:CC"
        return m
    }

    /// A session wired up so nothing touches the network and nothing sleeps for real.
    private func makeSession() -> WakeSession {
        let session = WakeSession()
        session.pollInterval = 0
        session.sendPacket = { _ in }
        session.probe = { _ in false }
        session.onReady = { _ in }
        session.onGaveUp = { _ in }
        // Left to itself this puts up a modal alert, which inside a test run never returns.
        session.onFailedToSend = { _, _ in }
        return session
    }

    func testItConnectsOnceTheMachineAnswers() async {
        let session = makeSession()
        let shop = machine()
        var attempts = 0
        session.probe = { _ in
            attempts += 1
            return attempts >= 3
        }
        var connected: [String] = []
        session.onReady = { connected.append($0.name) }

        session.wakeAndConnect(shop)
        await session.settle(shop.id)

        XCTAssertEqual(connected, ["shop-pc"])
        XCTAssertEqual(attempts, 3, "it kept trying until the port answered")
        XCTAssertFalse(session.isWaiting(for: shop.id))
    }

    func testItDoesNotConnectWhileTheMachineIsStillDown() async {
        let session = makeSession()
        let shop = machine()
        // Time runs out rather than the port ever opening.
        var clock = Date()
        session.now = { clock }
        session.probe = { _ in
            clock.addTimeInterval(30)
            return false
        }
        var connected = 0
        var gaveUp = 0
        session.onReady = { _ in connected += 1 }
        session.onGaveUp = { _ in gaveUp += 1 }

        session.wakeAndConnect(shop)
        await session.settle(shop.id)

        XCTAssertEqual(connected, 0, "connecting to a machine that never came back is the bug")
        XCTAssertEqual(gaveUp, 1, "and the user is told, rather than it ending in silence")
        XCTAssertFalse(session.isWaiting(for: shop.id))
    }

    func testTheWaitIsVisibleWhileItRuns() {
        let session = makeSession()
        let shop = machine()
        session.probe = { _ in false }

        session.wakeAndConnect(shop)

        XCTAssertTrue(session.isWaiting(for: shop.id), "the UI has something to show")
        session.cancel(shop.id)
        XCTAssertFalse(session.isWaiting(for: shop.id))
    }

    func testCancellingStopsItConnecting() async {
        let session = makeSession()
        let shop = machine()
        var connected = 0
        session.onReady = { _ in connected += 1 }
        session.probe = { _ in true }

        session.wakeAndConnect(shop)
        session.cancel(shop.id)
        await session.settle(shop.id)

        XCTAssertEqual(connected, 0)
    }

    func testAFailedPacketStopsBeforeTheWait() {
        let session = makeSession()
        let shop = machine()
        session.sendPacket = { _ in throw WakeOnLAN.WOLError.badMAC }
        session.onGaveUp = { _ in XCTFail("it never got as far as waiting") }
        var told = 0
        session.onFailedToSend = { _, _ in told += 1 }

        session.wakeAndConnect(shop)

        XCTAssertEqual(told, 1, "and the user hears why")

        XCTAssertFalse(session.isWaiting(for: shop.id),
                       "nothing was woken, so there is nothing to wait for")
    }

    func testAskingTwiceDoesNotStartTwoWaits() {
        let session = makeSession()
        let shop = machine()
        var packets = 0
        session.sendPacket = { _ in packets += 1 }

        session.wakeAndConnect(shop)
        session.wakeAndConnect(shop)

        XCTAssertEqual(packets, 1)
        session.cancel(shop.id)
    }
}
