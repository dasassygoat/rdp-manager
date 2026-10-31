import XCTest

/// Covers what `rdpm ssh nas` has to get right: picking the machine the user meant, and
/// refusing to guess when the name is ambiguous.
@MainActor
final class MachineLookupTests: StoreTestCase {
    private func named(_ names: [String]) -> [Machine] {
        names.map { makeMachine($0) }
    }

    private func name(of result: MachineLookup.Result) -> String? {
        if case .found(let machine) = result { return machine.name }
        return nil
    }

    func testExactNameWins() {
        let result = MachineLookup.find("nas", in: named(["nas", "nas-backup", "nas-old"]))
        XCTAssertEqual(name(of: result), "nas",
                       "an exact name must not be called ambiguous by its own prefixes")
    }

    func testMatchIgnoresCaseAndSurroundingSpace() {
        XCTAssertEqual(name(of: MachineLookup.find("  NAS  ", in: named(["nas"]))), "nas")
    }

    func testHostnameMatchesWhenTheNameDoesNot() {
        var m = makeMachine("Office PC")
        m.hostname = "office-pc.local"
        XCTAssertEqual(name(of: MachineLookup.find("office-pc.local", in: [m])), "Office PC")
    }

    func testUniquePrefixMatches() {
        XCTAssertEqual(name(of: MachineLookup.find("sh", in: named(["shop-pc", "nas"]))), "shop-pc")
    }

    func testUniqueSubstringMatches() {
        XCTAssertEqual(name(of: MachineLookup.find("shop", in: named(["the-shop-pc", "nas"]))),
                       "the-shop-pc")
    }

    func testSeveralPrefixMatchesAreAmbiguous() {
        let result = MachineLookup.find("nas-", in: named(["nas-backup", "nas-old", "shop"]))
        XCTAssertEqual(result, .ambiguous(query: "nas-", names: ["nas-backup", "nas-old"]),
                       "guessing between two machines could open a session on the wrong one")
    }

    func testNothingMatches() {
        XCTAssertEqual(MachineLookup.find("printer", in: named(["nas"])),
                       .notFound(query: "printer"))
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertEqual(MachineLookup.find("   ", in: named(["nas"])), .notFound(query: "   "))
        XCTAssertEqual(MachineLookup.find("", in: named(["nas"])), .notFound(query: ""))
    }

    func testEmptyListMatchesNothing() {
        XCTAssertEqual(MachineLookup.find("nas", in: []), .notFound(query: "nas"))
    }

    // MARK: - Address and ssh arguments

    func testAddressPrefersTheRecordedIP() {
        var m = makeMachine("nas", lastIP: "192.168.1.9")
        m.hostname = "nas.local"
        XCTAssertEqual(MachineLookup.address(of: m), "192.168.1.9")
    }

    func testAddressFallsBackToTheHostname() {
        var m = makeMachine("nas")
        m.hostname = "nas.local"
        m.lastIP = nil
        XCTAssertEqual(MachineLookup.address(of: m), "nas.local")
    }

    func testEmptyIPIsNotUsedAsAnAddress() {
        var m = makeMachine("nas")
        m.hostname = "nas.local"
        m.lastIP = ""
        XCTAssertEqual(MachineLookup.address(of: m), "nas.local")
    }

    func testSSHArgumentsCarryUserAndAddress() {
        var m = makeMachine("nas", lastIP: "192.168.1.9")
        m.username = "admin"
        XCTAssertEqual(MachineLookup.sshArguments(for: m), ["admin@192.168.1.9"])
    }

    func testSSHArgumentsOmitTheDefaultPort() {
        let m = makeMachine("nas", lastIP: "192.168.1.9")
        XCTAssertEqual(MachineLookup.sshArguments(for: m), ["192.168.1.9"])
    }

    func testSSHArgumentsIncludeANonDefaultPortBeforeTheTarget() {
        var m = makeMachine("nas", lastIP: "192.168.1.9")
        m.sshPort = 2222
        XCTAssertEqual(MachineLookup.sshArguments(for: m), ["-p", "2222", "192.168.1.9"])
    }

    func testExtraArgumentsLandBeforeTheTarget() {
        let m = makeMachine("nas", lastIP: "192.168.1.9")
        XCTAssertEqual(MachineLookup.sshArguments(for: m, extra: ["-A", "-L", "8080:localhost:80"]),
                       ["-A", "-L", "8080:localhost:80", "192.168.1.9"],
                       "ssh ignores options written after the destination")
    }
}
