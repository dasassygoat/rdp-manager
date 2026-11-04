import XCTest

/// What a sweep concludes from the ports it found, and whether it recognises a host that is
/// already in the list. The sweep itself is not exercised here — these are the decisions
/// made about its results, which is where getting it wrong would show up as a bad machine.
final class DiscoveryTests: XCTestCase {
    private func host(_ ip: String, ports: Set<Int> = [], hostname: String? = nil,
                      mac: String? = nil) -> Discovery.Host {
        Discovery.Host(ip: ip, hostname: hostname, mac: mac, openPorts: ports)
    }

    // MARK: Identifying what was found

    func testRDPMeansAWindowsMachine() {
        let found = host("192.168.1.10", ports: [3389, 22])
        XCTAssertEqual(found.kind, .windows)
        XCTAssertEqual(found.primary, .rdp)
    }

    func testScreenSharingWithoutRDPMeansAMac() {
        let found = host("192.168.1.11", ports: [5900, 22])
        XCTAssertEqual(found.kind, .mac)
        XCTAssertEqual(found.primary, .vnc)
    }

    func testSSHAloneMeansLinux() {
        let found = host("192.168.1.12", ports: [22])
        XCTAssertEqual(found.kind, .linux)
        XCTAssertEqual(found.primary, .ssh)
    }

    func testOnlyAWebPortMeansADevice() {
        for ports in [Set([80]), Set([443]), Set([80, 443])] {
            let found = host("192.168.1.13", ports: ports)
            XCTAssertEqual(found.kind, .device)
            XCTAssertEqual(found.primary, .web)
        }
    }

    func testRDPWinsOverEverythingElse() {
        let found = host("192.168.1.14", ports: [22, 80, 443, 3389, 5900])
        XCTAssertEqual(found.kind, .windows)
        XCTAssertEqual(found.primary, .rdp)
    }

    /// Found in the ARP cache but listening on nothing the app can open.
    func testAHostWithNoOpenPortsIsSilentAndTreatedAsADevice() {
        let found = host("192.168.1.15")
        XCTAssertTrue(found.isSilent)
        XCTAssertEqual(found.kind, .device)
        XCTAssertEqual(found.primary, .web)
        XCTAssertEqual(found.portSummary, "no open ports")
    }

    func testPortSummaryIsSortedForReading() {
        XCTAssertEqual(host("192.168.1.16", ports: [443, 22, 3389]).portSummary, "22, 443, 3389")
    }

    /// Guards against probing a port whose answer the inference then ignores: every port
    /// in the list has to change what the app would do with the host.
    func testEveryProbedPortChangesTheOutcome() {
        for port in Discovery.probedPorts {
            let found = host("10.0.0.1", ports: [port])
            XCTAssertFalse(found.isSilent, "port \(port) should count as an answer")
            if port == 80 || port == 443 {
                XCTAssertEqual(found.primary, .web, "port \(port)")
            } else {
                XCTAssertNotEqual(found.primary, .web,
                                  "port \(port) should pick a specific client")
            }
        }
    }

    func testProbeSettingsStayReasonable() {
        XCTAssertFalse(Discovery.probedPorts.isEmpty)
        XCTAssertEqual(Set(Discovery.probedPorts).count, Discovery.probedPorts.count,
                       "a duplicated port would be probed twice")
        XCTAssertGreaterThan(Discovery.concurrency, 0)
        XCTAssertGreaterThan(Discovery.probeTimeout, 0)
    }

    // MARK: Naming

    func testTheShortHostnameBecomesTheName() {
        XCTAssertEqual(host("10.0.0.5", hostname: "reception.corp.example.com").suggestedName,
                       "reception")
        XCTAssertEqual(host("10.0.0.5", hostname: "nas.local").suggestedName, "nas")
        XCTAssertEqual(host("10.0.0.5", hostname: "printer").suggestedName, "printer")
    }

    func testWithoutAHostnameTheAddressIsUsed() {
        XCTAssertEqual(host("192.168.1.42").suggestedName, "host-42")
        XCTAssertEqual(host("192.168.1.42", hostname: "").suggestedName, "host-42")
    }

    // MARK: Turning a host into a machine

    func testAddedMachineCarriesWhatTheSweepLearned() {
        let found = host("192.168.1.20", ports: [3389], hostname: "sales-pc.local",
                         mac: "00:00:5E:00:53:04")
        let machine = found.asMachine()
        XCTAssertEqual(machine.name, "sales-pc")
        XCTAssertEqual(machine.hostname, "sales-pc.local")
        XCTAssertEqual(machine.lastIP, "192.168.1.20")
        XCTAssertEqual(machine.macAddress, "00:00:5E:00:53:04")
        XCTAssertEqual(machine.kind, .windows)
        XCTAssertEqual(machine.primary, .rdp)
        XCTAssertEqual(machine.connectHost, "192.168.1.20")
        XCTAssertEqual(machine.ipHistory.map(\.ip), ["192.168.1.20"])
        XCTAssertNotNil(machine.lastSeen, "it answered on a port, so it has been seen")
    }

    func testASilentHostIsNotRecordedAsSeen() {
        XCTAssertNil(host("192.168.1.21", mac: "00:00:5E:00:53:04").asMachine().lastSeen)
    }

    func testAMachineWithNoHostnameFallsBackToTheAddress() {
        let machine = host("192.168.1.22", ports: [22]).asMachine()
        XCTAssertEqual(machine.hostname, "192.168.1.22")
        XCTAssertEqual(machine.macAddress, "", "no MAC found is an empty field, not a crash")
    }

    /// A discovered MAC has to be one Wake-on-LAN will accept, end to end.
    func testADiscoveredMACIsImmediatelyUsableForWake() throws {
        let mac = try XCTUnwrap(ARPTable.normalize("00:00:5e:00:53:02"))
        let machine = host("192.168.1.23", ports: [3389], mac: mac).asMachine()
        XCTAssertNotNil(WakeOnLAN.macBytes(machine.macAddress))
        XCTAssertEqual(machine.broadcastAddress, "192.168.1.255")
    }
}

/// Recognising hosts that are already in the list, which needs a real store.
final class DiscoveryMatchTests: StoreTestCase {
    private func host(_ ip: String, hostname: String? = nil, mac: String? = nil) -> Discovery.Host {
        Discovery.Host(ip: ip, hostname: hostname, mac: mac, openPorts: [3389])
    }

    func testAnUnknownHostMatchesNothing() {
        let store = makeStore()
        store.add(makeMachine("reception", lastIP: "192.168.1.10"))
        XCTAssertNil(Discovery(store: store).match(host("192.168.1.99")))
    }

    func testAHostIsMatchedByItsAddress() {
        let store = makeStore()
        store.add(makeMachine("reception", lastIP: "192.168.1.10"))
        XCTAssertEqual(Discovery(store: store).match(host("192.168.1.10"))?.name, "reception")
    }

    /// The point of matching on MAC: the machine is the same one, on a new lease.
    func testAMachineThatChangedAddressIsMatchedByItsMAC() {
        let store = makeStore()
        var machine = makeMachine("reception", lastIP: "192.168.1.10")
        machine.macAddress = "00:00:5E:00:53:04"
        store.add(machine)

        let moved = host("192.168.1.77", mac: "00:00:5E:00:53:04")
        XCTAssertEqual(Discovery(store: store).match(moved)?.name, "reception")
    }

    func testMACMatchingIgnoresFormatting() {
        let store = makeStore()
        var machine = makeMachine("reception")
        machine.macAddress = "00-00-5e-00-53-04"
        store.add(machine)
        XCTAssertEqual(Discovery(store: store).match(host("10.1.1.1", mac: "00:00:5E:00:53:04"))?.name,
                       "reception")
    }

    /// An empty MAC field must not match every host that has no MAC either.
    func testMachinesWithoutAMACAreNotMatchedByMAC() {
        let store = makeStore()
        store.add(makeMachine("reception", lastIP: "192.168.1.10"))
        XCTAssertNil(Discovery(store: store).match(host("192.168.1.99", mac: nil)))
        XCTAssertNil(Discovery(store: store).match(host("192.168.1.99", mac: "00:00:5E:00:53:04")))
    }

    func testAHostIsMatchedByHostnameWhenTheAddressIsNew() {
        let store = makeStore()
        store.add(makeMachine("reception", lastIP: "192.168.1.10"))
        // makeMachine sets hostname to "<name>.local".
        let found = host("192.168.1.88", hostname: "reception.local")
        XCTAssertEqual(Discovery(store: store).match(found)?.name, "reception")
    }

    func testHostnameMatchingUsesTheShortNameToo() {
        let store = makeStore()
        store.add(makeMachine("reception", lastIP: "192.168.1.10"))
        let found = host("192.168.1.88", hostname: "reception.corp.example.com")
        XCTAssertEqual(Discovery(store: store).match(found)?.name, "reception")
    }

    /// A silent host is listed but not ticked: nothing answered on it, so there is nothing
    /// to connect to, and adding it is the user's call rather than the default.
    func testSilentHostsAreListedButNotTicked() {
        var known = Discovery.Host(ip: "192.168.1.12", openPorts: [3389])
        known.existing = makeMachine("reception", lastIP: "192.168.1.12")
        let found = [Discovery.Host(ip: "192.168.1.10", openPorts: [22]),
                     Discovery.Host(ip: "192.168.1.11", mac: "AA:BB:CC:DD:EE:FF"),
                     known]
        XCTAssertEqual(Discovery.defaultSelection(among: found), ["192.168.1.10"])
    }

    // MARK: Filling in a MAC the list is missing

    /// A machine added before the sweep could read the ARP cache has no MAC, so
    /// Wake-on-LAN cannot work for it until something fills one in.
    func testAKnownMachineWithoutAMACGetsOne() {
        let store = makeStore()
        store.add(makeMachine("reception", lastIP: "192.168.1.10"))
        let discovery = Discovery(store: store)

        var found = host("192.168.1.10", mac: "AA:BB:CC:DD:EE:FF")
        found.existing = discovery.match(found)
        let updated = discovery.backfillMACs(into: [found])

        XCTAssertEqual(discovery.backfilled, 1)
        XCTAssertEqual(store.machines.first?.macAddress, "AA:BB:CC:DD:EE:FF")
        // The row has to show the machine as it now is, not as it was matched.
        XCTAssertEqual(updated.first?.existing?.macAddress, "AA:BB:CC:DD:EE:FF")
    }

    /// A MAC already on record is the user's. A sweep disagreeing with it means the match
    /// is wrong about which machine this is, so overwriting would lose the right answer.
    func testAnExistingMACIsNeverOverwritten() {
        let store = makeStore()
        var machine = makeMachine("reception", lastIP: "192.168.1.10")
        machine.macAddress = "11:22:33:44:55:66"
        store.add(machine)
        let discovery = Discovery(store: store)

        var found = host("192.168.1.10", mac: "AA:BB:CC:DD:EE:FF")
        found.existing = discovery.match(found)
        _ = discovery.backfillMACs(into: [found])

        XCTAssertEqual(discovery.backfilled, 0)
        XCTAssertEqual(store.machines.first?.macAddress, "11:22:33:44:55:66")
    }

    /// A sweep that could not read the cache must not blank out the field.
    func testAHostWithoutAMACChangesNothing() {
        let store = makeStore()
        var machine = makeMachine("reception", lastIP: "192.168.1.10")
        machine.macAddress = "11:22:33:44:55:66"
        store.add(machine)
        let discovery = Discovery(store: store)

        var found = host("192.168.1.10")
        found.existing = discovery.match(found)
        _ = discovery.backfillMACs(into: [found])

        XCTAssertEqual(discovery.backfilled, 0)
        XCTAssertEqual(store.machines.first?.macAddress, "11:22:33:44:55:66")
    }

    /// A host that is not in the list yet is added by Add, not written to behind the scenes.
    func testAnUnknownHostIsNotWrittenToTheList() {
        let store = makeStore()
        let discovery = Discovery(store: store)
        let found = host("192.168.1.77", mac: "AA:BB:CC:DD:EE:FF")

        _ = discovery.backfillMACs(into: [found])

        XCTAssertEqual(discovery.backfilled, 0)
        XCTAssertTrue(store.machines.isEmpty)
    }

    func testAddingOnlyAddsTheNewOnes() {
        let store = makeStore()
        store.add(makeMachine("reception", lastIP: "192.168.1.10"))
        let discovery = Discovery(store: store)

        var known = host("192.168.1.10")
        known.existing = discovery.match(known)
        let fresh = host("192.168.1.11", hostname: "warehouse.local")

        discovery.add([known, fresh])
        XCTAssertEqual(store.machines.count, 2)
        XCTAssertEqual(store.machines.map(\.name).sorted(), ["reception", "warehouse"])
    }
}
