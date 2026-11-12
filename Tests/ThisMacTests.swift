import XCTest

/// Recognising this Mac in the shared list, which is what the "leave this Mac out"
/// setting acts on. The identity is injected: a test cannot be run on a Mac whose real
/// name happens to suit it.
final class ThisMacTests: XCTestCase {
    private let me = ThisMac.Identity(
        macs: ["AA:BB:CC:DD:EE:FF"],
        names: ["studiogoat", "bryan's mac studio"])

    private func machine(name: String = "Something",
                         hostname: String = "something.local",
                         mac: String = "") -> Machine {
        var m = Machine()
        m.name = name
        m.hostname = hostname
        m.macAddress = mac
        return m
    }

    func testAMatchingMACIsThisMac() {
        XCTAssertTrue(ThisMac.matches(machine(mac: "aa:bb:cc:dd:ee:ff"), identity: me))
        XCTAssertTrue(ThisMac.matches(machine(mac: "AA:BB:CC:DD:EE:FF"), identity: me))
        // Written the way a router's page tends to, without the leading zeros.
        XCTAssertTrue(ThisMac.matches(
            machine(mac: "a:bb:cc:dd:ee:ff"),
            identity: ThisMac.Identity(macs: ["0A:BB:CC:DD:EE:FF"], names: [])))
    }

    func testAnotherMACIsNot() {
        XCTAssertFalse(ThisMac.matches(machine(mac: "11:22:33:44:55:66"), identity: me))
    }

    func testTheHostnameMatchesWithOrWithoutLocal() {
        XCTAssertTrue(ThisMac.matches(machine(hostname: "studiogoat"), identity: me))
        XCTAssertTrue(ThisMac.matches(machine(hostname: "studiogoat.local"), identity: me))
        XCTAssertTrue(ThisMac.matches(machine(hostname: "StudioGoat.local."), identity: me))
        XCTAssertTrue(ThisMac.matches(machine(hostname: " studiogoat "), identity: me))
    }

    /// The name macOS reports has the apostrophe macOS types; the one in the list has
    /// whatever was typed into the app.
    func testTheComputerNameMatchesEitherApostrophe() {
        XCTAssertTrue(ThisMac.matches(machine(name: "Bryan's Mac Studio", hostname: ""),
                                      identity: me))
        XCTAssertTrue(ThisMac.matches(machine(name: "Bryan\u{2019}s Mac Studio", hostname: ""),
                                      identity: me))
    }

    /// The case this has to get right to be safe to leave on: a record with nothing filled
    /// in is not this Mac. An empty string agreeing with an empty string would hide the
    /// first half-written machine in the list.
    func testAnEmptyRecordIsNotThisMac() {
        XCTAssertFalse(ThisMac.matches(machine(name: "", hostname: "", mac: ""), identity: me))
        XCTAssertFalse(ThisMac.matches(
            machine(name: "", hostname: "", mac: ""),
            identity: ThisMac.Identity(macs: [], names: [])))
    }

    func testNothingMatchesAnEmptyIdentity() {
        XCTAssertFalse(ThisMac.matches(machine(hostname: "studiogoat", mac: "aa:bb:cc:dd:ee:ff"),
                                       identity: ThisMac.Identity()))
    }

    func testIdentifyFindsEveryRecordForThisMac() {
        let others = [machine(name: "Front desk", hostname: "front.local"),
                      machine(name: "Server", hostname: "server.local")]
        var mine = machine(name: "Studio", hostname: "studiogoat.local")
        mine.id = UUID()
        // The same Mac again, as a sweep writes it when it answers on another interface.
        var alsoMine = machine(name: "host-152", hostname: "", mac: "aa:bb:cc:dd:ee:ff")
        alsoMine.id = UUID()

        XCTAssertEqual(ThisMac.identify(in: others + [mine, alsoMine], identity: me),
                       [mine.id, alsoMine.id])
        XCTAssertEqual(ThisMac.identify(in: others, identity: me), [])
        XCTAssertEqual(ThisMac.identify(in: [], identity: me), [])
    }

    /// macOS gives a process without Local Network access the same made-up address for
    /// every interface. Taking it as an identity would match any record carrying it.
    func testThePlaceholderAddressIsNeverAnIdentity() {
        let addresses = ThisMac.hardwareAddresses()
        for placeholder in ThisMac.placeholders {
            XCTAssertFalse(addresses.contains(placeholder),
                           "\(placeholder) is not an identity")
        }
    }

    /// Whatever this Mac is called, it is called something, and nothing in the set is blank.
    func testThisMacKnowsItsOwnNames() {
        let names = ThisMac.hostNames()
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(names.contains(""))
        XCTAssertEqual(names, Set(names.map(ThisMac.fold)))
    }

    func testFoldLeavesNothingToDecide() {
        XCTAssertEqual(ThisMac.fold("  Front-Desk.local. "), "front-desk")
        XCTAssertEqual(ThisMac.fold("front-desk"), "front-desk")
        XCTAssertEqual(ThisMac.fold(""), "")
        XCTAssertEqual(ThisMac.fold("."), "")
        // Only a trailing ".local" goes: it is a suffix, not a word to be deleted.
        XCTAssertEqual(ThisMac.fold("local.server.local"), "local.server")
    }
}
