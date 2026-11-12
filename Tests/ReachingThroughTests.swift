import XCTest

/// Reaching a machine this Mac cannot reach directly, without the app having to understand
/// sites: SSH through a jump host, RDP through a gateway.
@MainActor
final class ReachingThroughTests: XCTestCase {
    override func tearDown() {
        Launcher.savedPassword = { Keychain.password(for: $0) }
        Launcher.credentialSet = { MachineStore.shared.credential($0) }
        super.tearDown()
    }

    private func machine(_ configure: (inout Machine) -> Void = { _ in }) -> Machine {
        var m = Machine()
        m.name = "shop-pc"
        m.hostname = "shop-pc.local"
        m.lastIP = "10.20.0.5"
        m.username = "admin"
        configure(&m)
        return m
    }

    // MARK: - SSH

    func testTheJumpHostIsPassedToSSH() {
        let m = machine { $0.jumpHost = "gateway.example.com" }
        let command = Launcher.sshCommand(for: m)

        XCTAssertTrue(command.contains("-J 'gateway.example.com'"), command)
        XCTAssertTrue(command.contains("'admin@10.20.0.5'"), "still the real target")
    }

    func testNoJumpHostMeansNoExtraArgument() {
        XCTAssertFalse(Launcher.sshCommand(for: machine()).contains("-J"))
    }

    func testAJumpHostIsQuotedLikeEverythingElse() {
        let m = machine { $0.jumpHost = "odd host; rm -rf /" }
        XCTAssertTrue(Launcher.sshCommand(for: m).contains("-J 'odd host; rm -rf /'"),
                      "a jump host cannot run as part of the command")
    }

    func testTheCommandLineToolUsesItToo() {
        let m = machine { $0.jumpHost = "gateway.example.com" }
        let args = MachineLookup.sshArguments(for: m)

        XCTAssertEqual(args, ["-J", "gateway.example.com", "admin@10.20.0.5"])
    }

    func testTheCommandLineToolKeepsPortAndJumpHostInOrder() {
        let m = machine {
            $0.jumpHost = "gateway.example.com"
            $0.sshPort = 2222
        }
        XCTAssertEqual(MachineLookup.sshArguments(for: m, extra: ["-A"]),
                       ["-p", "2222", "-J", "gateway.example.com", "-A", "admin@10.20.0.5"])
    }

    // MARK: - RDP

    func testTheGatewayIsPassedToFreeRDP() {
        Launcher.credentialSet = { _ in nil }
        let m = machine {
            $0.gateway = "rdgw.example.com"
            $0.domain = "OFFICE"
        }
        let args = Launcher.freeRDPArguments(for: m)

        XCTAssertTrue(args.contains("/gateway:g:rdgw.example.com,u:admin,d:OFFICE"), "\(args)")
    }

    func testTheGatewayPasswordIsNotOnTheCommandLine() {
        Launcher.credentialSet = { _ in nil }
        Launcher.savedPassword = { _ in "hunter2" }
        let m = machine { $0.gateway = "rdgw.example.com" }

        for argument in Launcher.freeRDPInvocation(for: m).arguments {
            XCTAssertFalse(argument.contains("hunter2"), "leaked in \(argument)")
        }
    }

    func testTheGatewayIsInTheFileForWindowsApp() {
        Launcher.credentialSet = { _ in nil }
        let contents = Launcher.rdpFileContents(for: machine { $0.gateway = "rdgw.example.com" })

        XCTAssertTrue(contents.contains("gatewayhostname:s:rdgw.example.com"))
        XCTAssertTrue(contents.contains("gatewayusagemethod:i:1"))
    }

    func testNoGatewayMeansNothingSaidAboutOne() {
        Launcher.credentialSet = { _ in nil }
        let m = machine()
        XCTAssertFalse(Launcher.freeRDPArguments(for: m).contains { $0.hasPrefix("/gateway:") })
        XCTAssertFalse(Launcher.rdpFileContents(for: m).contains("gateway"))
    }

    func testAnOlderListHasNeither() throws {
        let json = """
        { "version": 1, "machines": [ { "name": "shop-pc" } ] }
        """
        let m = try JSONDecoder().decode(StoreDocument.self, from: Data(json.utf8)).machines[0]
        XCTAssertEqual(m.jumpHost, "")
        XCTAssertEqual(m.gateway, "")
    }
}
