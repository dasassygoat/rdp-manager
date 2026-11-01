import XCTest

final class ARPTableTests: XCTestCase {
    /// Copied from `arp -an` on a real Mac, including the awkward parts: an incomplete
    /// entry, the same router listed once per interface, and link-local noise.
    private let sample = """
    ? (169.254.169.254) at (incomplete) on en0 [ethernet]
    ? (169.254.172.36) at 9c:b6:d0:bc:7f:9f on en0 [ethernet]
    ? (192.168.1.1) at 6e:63:f8:38:d8:a2 on en10 ifscope [ethernet]
    ? (192.168.1.1) at 6e:63:f8:38:d8:a2 on en1 ifscope [ethernet]
    ? (192.168.1.51) at a8:b1:3b:20:5c:d9 on en0 ifscope [ethernet]
    ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
    """

    func testCompleteEntriesAreRead() {
        let table = ARPTable.parse(sample)
        XCTAssertEqual(table["192.168.1.1"], "6E:63:F8:38:D8:A2")
        XCTAssertEqual(table["192.168.1.51"], "A8:B1:3B:20:5C:D9")
        XCTAssertEqual(table["169.254.172.36"], "9C:B6:D0:BC:7F:9F")
    }

    func testIncompleteEntriesAreLeftOut() {
        XCTAssertNil(ARPTable.parse(sample)["169.254.169.254"])
    }

    func testTheBroadcastAddressIsNotAMachine() {
        XCTAssertNil(ARPTable.parse(sample)["192.168.1.255"])
    }

    func testDuplicateInterfacesDoNotDuplicateHosts() {
        let table = ARPTable.parse(sample)
        XCTAssertEqual(table.keys.filter { $0 == "192.168.1.1" }.count, 1)
        XCTAssertEqual(table.count, 3)
    }

    func testEmptyAndJunkInputProduceNothing() {
        XCTAssertTrue(ARPTable.parse("").isEmpty)
        XCTAssertTrue(ARPTable.parse("no parentheses here\nnor here").isEmpty)
        XCTAssertTrue(ARPTable.parse("? (not-an-ip) at 11:22:33:44:55:66 on en0").isEmpty)
    }

    // MARK: Normalising

    func testOctetsWithoutALeadingZeroArePaddedAndUppercased() {
        XCTAssertEqual(ARPTable.normalize("0:1e:c2:3:4:5f"), "00:1E:C2:03:04:5F")
        XCTAssertEqual(ARPTable.normalize("AC:84:C6:1A:2B:3C"), "AC:84:C6:1A:2B:3C")
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
        let mac = try XCTUnwrap(ARPTable.normalize("0:1e:c2:3:4:5f"))
        XCTAssertEqual(WakeOnLAN.macBytes(mac), [0x00, 0x1E, 0xC2, 0x03, 0x04, 0x5F])
    }
}
