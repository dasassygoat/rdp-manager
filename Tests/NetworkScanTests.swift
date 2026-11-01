import XCTest

final class NetworkScanTests: XCTestCase {
    // MARK: Address arithmetic

    func testAddressesRoundTripThroughTheirDottedForm() {
        for text in ["0.0.0.0", "10.0.0.1", "192.168.1.254", "255.255.255.255"] {
            guard let value = IPv4Subnet.parse(text) else { return XCTFail("could not parse \(text)") }
            XCTAssertEqual(IPv4Subnet.format(value), text)
        }
    }

    func testNonAddressesAreRejected() {
        for text in ["", "192.168.1", "192.168.1.256", "hello", "::1", "192.168.1.1.1"] {
            XCTAssertNil(IPv4Subnet.parse(text), "\(text) should not parse")
        }
    }

    func testMaskLengthsAreReadFromContiguousMasks() {
        XCTAssertEqual(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("255.255.255.0")!), 24)
        XCTAssertEqual(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("255.255.254.0")!), 23)
        XCTAssertEqual(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("255.255.255.252")!), 30)
        XCTAssertEqual(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("255.255.255.255")!), 32)
        XCTAssertEqual(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("0.0.0.0")!), 0)
    }

    /// A mask with a gap is not a mask. Counting bits alone would call this a /24.
    func testMasksWithGapsAreRejected() {
        XCTAssertNil(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("255.255.0.255")!))
        XCTAssertNil(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("0.255.255.255")!))
        XCTAssertNil(IPv4Subnet.prefixLength(ofMask: IPv4Subnet.parse("255.255.255.1")!))
    }

    // MARK: Subnet geometry

    private func subnet(_ address: String, _ mask: String) throws -> IPv4Subnet {
        try XCTUnwrap(IPv4Subnet(address: address, netmask: mask))
    }

    func testNetworkAndBroadcastComeFromTheMask() throws {
        let net = try subnet("192.168.1.50", "255.255.255.0")
        XCTAssertEqual(IPv4Subnet.format(net.networkAddress), "192.168.1.0")
        XCTAssertEqual(IPv4Subnet.format(net.broadcastAddress), "192.168.1.255")
        XCTAssertEqual(net.description, "192.168.1.0/24")
    }

    func testHostAddressesSkipNetworkBroadcastAndThisMac() throws {
        let net = try subnet("192.168.1.50", "255.255.255.0")
        let hosts = net.hostAddresses.map(IPv4Subnet.format)
        XCTAssertEqual(hosts.count, 253, "254 usable addresses, minus this Mac")
        XCTAssertFalse(hosts.contains("192.168.1.0"))
        XCTAssertFalse(hosts.contains("192.168.1.255"))
        XCTAssertFalse(hosts.contains("192.168.1.50"), "no point probing ourselves")
        XCTAssertTrue(hosts.contains("192.168.1.1"))
        XCTAssertTrue(hosts.contains("192.168.1.254"))
    }

    func testASlashThirtyLeavesOneNeighbour() throws {
        let net = try subnet("192.168.1.5", "255.255.255.252")
        XCTAssertEqual(net.hostAddresses.map(IPv4Subnet.format), ["192.168.1.6"])
    }

    func testPointToPointAndSingleHostSubnetsHaveNoRange() throws {
        XCTAssertTrue(try subnet("192.168.1.5", "255.255.255.254").hostAddresses.isEmpty)
        XCTAssertTrue(try subnet("192.168.1.5", "255.255.255.255").hostAddresses.isEmpty)
    }

    // MARK: Refusing to sweep something enormous

    func testASlashTwentyTwoIsStillScannable() throws {
        let net = try subnet("10.0.0.1", "255.255.252.0")
        XCTAssertTrue(net.isScannable)
        XCTAssertEqual(net.hostCount, 1021)
    }

    func testBiggerThanTheLimitIsNotScanned() throws {
        for mask in ["255.255.248.0", "255.255.0.0", "255.0.0.0"] {
            let net = try subnet("10.0.0.1", mask)
            XCTAssertFalse(net.isScannable, "\(net) should be refused")
            XCTAssertTrue(net.hostAddresses.isEmpty,
                          "\(net) must not enumerate addresses it refuses to scan")
        }
    }

    func testTheLimitIsNotAccidentallyZero() {
        XCTAssertGreaterThanOrEqual(IPv4Subnet.maximumHosts, 256,
                                    "a /24 has to fit or discovery is useless")
    }

    // MARK: This Mac

    /// Machine-dependent, so it checks shape rather than values: whatever interfaces exist,
    /// each one must carry a mask that parsed and an address inside its own subnet.
    func testActiveInterfacesAreInternallyConsistent() {
        for interface in LocalInterfaces.active() {
            XCTAssertFalse(interface.name.isEmpty)
            let net = interface.subnet
            XCTAssertGreaterThan(net.prefixLength, 0, "\(interface.name) has a zero prefix")
            XCTAssertEqual(net.address & net.mask, net.networkAddress)
            XCTAssertFalse(net.hostAddresses.map(IPv4Subnet.format)
                .contains(IPv4Subnet.format(net.address)))
        }
    }
}
