import XCTest

final class ARPTableTests: XCTestCase {
    /// Builds the bytes the routing socket hands back for one cache entry: a `rt_msghdr`,
    /// the IPv4 address it is for, and the link address holding the MAC. Assembling real
    /// structs rather than a fixture keeps the layout the same as the kernel's.
    private func message(ip: String, mac: [UInt8]?, interface: String = "en0",
                         addrs: Int32 = RTA_DST | RTA_GATEWAY) -> [UInt8] {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_addr.s_addr = IPv4Subnet.parse(ip)!.bigEndian
        let dstBytes = withUnsafeBytes(of: destination) { [UInt8]($0) }

        let name = Array(interface.utf8)
        let address = mac ?? []
        var gateway: [UInt8] = [
            UInt8(8 + name.count + address.count),  // sdl_len
            UInt8(AF_LINK),                         // sdl_family
            0, 0,                                   // sdl_index
            6,                                      // sdl_type
            UInt8(name.count),                      // sdl_nlen
            UInt8(address.count),                   // sdl_alen
            0,                                      // sdl_slen
        ] + name + address
        while gateway.count % 4 != 0 { gateway.append(0) }

        var header = rt_msghdr()
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_addrs = addrs
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + dstBytes.count + gateway.count)
        return withUnsafeBytes(of: header) { [UInt8]($0) } + dstBytes + gateway
    }

    /// The awkward parts of a real cache: an entry still resolving, the same router listed
    /// once per interface, link-local noise and the broadcast address.
    private var sample: [UInt8] {
        message(ip: "169.254.169.254", mac: nil)
            + message(ip: "169.254.172.36", mac: [0x00, 0x00, 0x5E, 0x00, 0x53, 0x03])
            + message(ip: "192.168.1.1", mac: [0x00, 0x00, 0x5E, 0x00, 0x53, 0x01],
                      interface: "en10")
            + message(ip: "192.168.1.1", mac: [0x00, 0x00, 0x5E, 0x00, 0x53, 0x01],
                      interface: "en1")
            + message(ip: "192.168.1.51", mac: [0x00, 0x00, 0x5E, 0x00, 0x53, 0x02])
            + message(ip: "192.168.1.255", mac: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testCompleteEntriesAreRead() {
        let table = ARPTable.macs(inRoutingMessages: sample)
        XCTAssertEqual(table["192.168.1.1"], "00:00:5E:00:53:01")
        XCTAssertEqual(table["192.168.1.51"], "00:00:5E:00:53:02")
        XCTAssertEqual(table["169.254.172.36"], "00:00:5E:00:53:03")
    }

    func testIncompleteEntriesAreLeftOut() {
        XCTAssertNil(ARPTable.macs(inRoutingMessages: sample)["169.254.169.254"])
    }

    func testTheBroadcastAddressIsNotAMachine() {
        XCTAssertNil(ARPTable.macs(inRoutingMessages: sample)["192.168.1.255"])
    }

    func testDuplicateInterfacesDoNotDuplicateHosts() {
        let table = ARPTable.macs(inRoutingMessages: sample)
        XCTAssertEqual(table.count, 3)
    }

    /// The MAC sits after the interface name, so a name longer than the fixed part of the
    /// struct must not push it out of reach.
    func testALongInterfaceNameDoesNotLoseTheMAC() {
        let table = ARPTable.macs(inRoutingMessages: message(
            ip: "192.168.1.9", mac: [0x11, 0x22, 0x33, 0x44, 0x55, 0x66],
            interface: "awdl0bridge100"))
        XCTAssertEqual(table["192.168.1.9"], "11:22:33:44:55:66")
    }

    func testEntriesWithoutAGatewayAreSkipped() {
        let table = ARPTable.macs(inRoutingMessages: message(
            ip: "192.168.1.9", mac: [0x11, 0x22, 0x33, 0x44, 0x55, 0x66], addrs: RTA_DST))
        XCTAssertTrue(table.isEmpty)
    }

    func testEmptyAndTruncatedInputProduceNothing() {
        XCTAssertTrue(ARPTable.macs(inRoutingMessages: []).isEmpty)
        XCTAssertTrue(ARPTable.macs(inRoutingMessages: [UInt8](repeating: 0, count: 12)).isEmpty)
        // A length the message does not live up to must stop the walk, not read past it.
        XCTAssertTrue(ARPTable.macs(inRoutingMessages: Array(sample.prefix(40))).isEmpty)
    }

    /// A zero length would leave the walk standing on the same message forever.
    func testAZeroLengthMessageDoesNotHang() {
        var bytes = sample
        bytes[0] = 0
        bytes[1] = 0
        XCTAssertTrue(ARPTable.macs(inRoutingMessages: bytes).isEmpty)
    }

    // MARK: Normalising

    func testOctetsWithoutALeadingZeroArePaddedAndUppercased() {
        XCTAssertEqual(ARPTable.normalize("0:0:5e:0:53:4"), "00:00:5E:00:53:04")
        XCTAssertEqual(ARPTable.normalize("00:00:5E:00:53:05"), "00:00:5E:00:53:05")
    }

    func testThingsThatAreNotMACsAreRejected() {
        for text in ["(incomplete)", "", "11:22:33:44:55", "11:22:33:44:55:66:77",
                     "11:22:33:44:55:zz", "112233445566", "1111:22:33:44:55:66"] {
            XCTAssertNil(ARPTable.normalize(text), "\(text) should not normalize")
        }
    }

    func testTheBroadcastMACIsRejected() {
        XCTAssertNil(ARPTable.normalize("ff:ff:ff:ff:ff:ff"))
        XCTAssertNil(ARPTable.normalize("FF:FF:FF:FF:FF:FF"))
    }

    /// The normalised form has to be what Wake-on-LAN already accepts, or a discovered MAC
    /// would land in the field and then fail to send.
    func testNormalisedMACsAreUsableForWakeOnLAN() throws {
        let mac = try XCTUnwrap(ARPTable.normalize("0:0:5e:0:53:4"))
        XCTAssertEqual(WakeOnLAN.macBytes(mac), [0x00, 0x00, 0x5E, 0x00, 0x53, 0x04])
    }
}
