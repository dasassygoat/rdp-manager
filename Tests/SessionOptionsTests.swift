import XCTest

/// The per-machine session options, which have to mean the same thing whichever RDP client
/// carries the connection.
@MainActor
final class SessionOptionsTests: XCTestCase {
    override func tearDown() {
        Launcher.savedPassword = { Keychain.password(for: $0) }
        super.tearDown()
    }

    private func machine(_ configure: (inout Machine) -> Void = { _ in }) -> Machine {
        var m = Machine()
        m.name = "shop-pc"
        m.hostname = "shop-pc.local"
        m.lastIP = "192.168.1.20"
        configure(&m)
        return m
    }

    // MARK: - Domain

    func testTheDomainFieldIsUsedWhenFilled() {
        let m = machine {
            $0.username = "admin"
            $0.domain = "WORKGROUP"
        }
        XCTAssertEqual(m.login.domain, "WORKGROUP")
        XCTAssertEqual(m.login.username, "admin")
        XCTAssertTrue(Launcher.freeRDPArguments(for: m).contains("/d:WORKGROUP"))
        XCTAssertTrue(Launcher.rdpFileContents(for: m).contains("domain:s:WORKGROUP"))
    }

    func testABackslashInTheUsernameStillWorks() {
        // Nothing already saved has to be retyped.
        let m = machine { $0.username = "OFFICE\\bryan" }
        XCTAssertEqual(m.login.domain, "OFFICE")
        XCTAssertEqual(m.login.username, "bryan")
        XCTAssertTrue(Launcher.freeRDPArguments(for: m).contains("/d:OFFICE"))
        XCTAssertTrue(Launcher.freeRDPArguments(for: m).contains("/u:bryan"))
    }

    func testTheDomainFieldWinsOverABackslash() {
        let m = machine {
            $0.username = "OLD\\bryan"
            $0.domain = "NEW"
        }
        XCTAssertEqual(m.login.domain, "NEW")
        XCTAssertEqual(m.login.username, "OLD\\bryan",
                       "the field was filled in deliberately, so it is taken literally")
    }

    func testNoDomainMeansNoDomainArgument() {
        let m = machine { $0.username = "admin" }
        XCTAssertFalse(Launcher.freeRDPArguments(for: m).contains { $0.hasPrefix("/d:") })
        XCTAssertFalse(Launcher.rdpFileContents(for: m).contains("domain:s:"))
    }

    func testASavedPasswordStillGoesToStdinWithASeparateDomain() {
        Launcher.savedPassword = { _ in "hunter2" }
        let m = machine {
            $0.username = "admin"
            $0.domain = "WORKGROUP"
        }
        XCTAssertEqual(Launcher.freeRDPInvocation(for: m).standardInput, "hunter2\n")
    }

    // MARK: - Both clients agree

    func testMultipleMonitors() {
        let on = machine { $0.multipleMonitors = true }
        XCTAssertTrue(Launcher.freeRDPArguments(for: on).contains("/multimon"))
        XCTAssertTrue(Launcher.rdpFileContents(for: on).contains("use multimon:i:1"))

        let off = machine()
        XCTAssertFalse(Launcher.freeRDPArguments(for: off).contains("/multimon"))
        XCTAssertTrue(Launcher.rdpFileContents(for: off).contains("use multimon:i:0"))
    }

    func testTheClipboardCanBeKeptToThisMac() {
        let shared = machine()
        XCTAssertTrue(shared.shareClipboard, "sharing is the default, as it was before")
        XCTAssertTrue(Launcher.freeRDPArguments(for: shared).contains("+clipboard"))
        XCTAssertTrue(Launcher.rdpFileContents(for: shared).contains("redirectclipboard:i:1"))

        let private_ = machine { $0.shareClipboard = false }
        XCTAssertTrue(Launcher.freeRDPArguments(for: private_).contains("-clipboard"))
        XCTAssertFalse(Launcher.freeRDPArguments(for: private_).contains("+clipboard"))
        XCTAssertTrue(Launcher.rdpFileContents(for: private_).contains("redirectclipboard:i:0"))
    }

    func testScaling() {
        let big = machine { $0.displayScale = 180 }
        XCTAssertTrue(Launcher.freeRDPArguments(for: big).contains("/scale:180"))
        XCTAssertTrue(Launcher.rdpFileContents(for: big).contains("desktopscalefactor:i:180"))

        // 100 is the default both clients already use, so there is nothing to say.
        let normal = machine()
        XCTAssertFalse(Launcher.freeRDPArguments(for: normal).contains { $0.hasPrefix("/scale:") })
        XCTAssertTrue(Launcher.rdpFileContents(for: normal).contains("desktopscalefactor:i:100"))
    }

    func testAScaleTheClientsWouldRejectIsNotPassedOn() throws {
        // A hand-edited list, or one from a future version. A scale factor the client
        // refuses fails the whole connection, so it is not worth honouring.
        let json = """
        { "version": 1, "machines": [ { "name": "shop-pc", "displayScale": 137 } ] }
        """
        let decoded = try JSONDecoder().decode(StoreDocument.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.machines[0].displayScale, 100)
    }

    func testASharedFolderGoesToFreeRDPOnly() {
        let m = machine { $0.sharedFolder = "/Users/looper/Transfer" }
        XCTAssertTrue(Launcher.freeRDPArguments(for: m).contains("/drive:Mac,/Users/looper/Transfer"))
        // Windows App does not take a folder from a .rdp file it is handed, so claiming one
        // would promise something that silently does not happen.
        XCTAssertFalse(Launcher.rdpFileContents(for: m).contains("Transfer"))
    }

    func testNoFolderMeansNoDriveArgument() {
        XCTAssertFalse(Launcher.freeRDPArguments(for: machine())
            .contains { $0.hasPrefix("/drive:") })
    }

    // MARK: - Defaults for a list written before any of this existed

    func testAnOlderListGetsTheOldBehaviour() throws {
        let json = """
        { "version": 1, "machines": [ { "name": "shop-pc" } ] }
        """
        let m = try JSONDecoder().decode(StoreDocument.self, from: Data(json.utf8)).machines[0]

        XCTAssertTrue(m.monitored, "machines were all monitored before this was a choice")
        XCTAssertTrue(m.shareClipboard, "the clipboard was always shared")
        XCTAssertFalse(m.multipleMonitors)
        XCTAssertEqual(m.displayScale, 100)
        XCTAssertEqual(m.sharedFolder, "")
        XCTAssertEqual(m.domain, "")
    }
}
