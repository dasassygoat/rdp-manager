import XCTest

/// A session that FreeRDP could not start used to end in silence: the client's own error
/// dialog closes with the process, and the app never looked at how it ended. These pin
/// down which exits get an explanation and which are a session simply ending.
final class FailedSessionTests: XCTestCase {
    private let host = "10.0.0.5:3389"

    /// Captured from sdl-freerdp 3.32.2 against a closed port.
    private let refusedLog = """
    [17:52:39:822] [6611:6f90b001] [ERROR][com.freerdp.core.nego] - [nego_connect]: Failed to connect
    [17:52:39:849] [6611:f6579301] [ERROR][com.freerdp.client.SDL] - [handleShow]: ERRCONNECT_CONNECT_FAILED [0x00020006]
    The connection failed.
    """

    func testARefusedConnectionSaysNothingAnswered() {
        let reason = FreeRDPDiagnostics.explanation(status: 141, lifetime: 1.2, log: refusedLog, host: host)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("Nothing answered on \(host)") == true, reason ?? "nil")
    }

    func testARejectedPasswordSaysSo() {
        let log = "[ERROR][com.freerdp.core] - [rdp_set_error_info]: ERRCONNECT_LOGON_FAILURE [0x00020014]"
        let reason = FreeRDPDiagnostics.explanation(status: 131, lifetime: 2, log: log, host: host)
        XCTAssertTrue(reason?.contains("username or password was rejected") == true, reason ?? "nil")
    }

    func testACleanExitIsNotAnError() {
        XCTAssertNil(FreeRDPDiagnostics.explanation(status: 0, lifetime: 600, log: "", host: host))
    }

    func testASessionTheUserEndedIsNotAnError() {
        let log = "[INFO][com.freerdp.core] - [rdp_print_errinfo]: ERRINFO_LOGOFF_BY_USER [0x0001000B]"
        XCTAssertNil(FreeRDPDiagnostics.explanation(status: 2, lifetime: 900, log: log, host: host))
    }

    func testALongSessionThatEndedWithoutAnErrorLineIsNotAnError() {
        XCTAssertNil(FreeRDPDiagnostics.explanation(status: 1, lifetime: 3600, log: "[INFO] closing", host: host))
    }

    func testAShortSessionWithOnlyAWarningIsStillReported() {
        let log = "[WARN][com.freerdp.core] - [rdp_recv_callback]: connection closed by peer"
        XCTAssertNotNil(FreeRDPDiagnostics.explanation(status: 1, lifetime: 45, log: log, host: host))
    }

    func testAnEarlyQuietExitIsReportedEvenAfterTwentySeconds() {
        XCTAssertNotNil(FreeRDPDiagnostics.explanation(status: 1, lifetime: 30, log: "", host: host))
    }

    func testAnUnexplainedEarlyExitStillGetsReported() {
        let reason = FreeRDPDiagnostics.explanation(status: 7, lifetime: 1, log: "", host: host)
        XCTAssertTrue(reason?.contains("exited with code 7") == true, reason ?? "nil")
    }

    func testAPromptFreeRDPCouldNotShowIsNotMistakenForTheUserCancelling() {
        let log = "[ERROR][com.freerdp.core] - [nla_client_setup_identity]: ERRCONNECT_CONNECT_CANCELLED [0x0002000B]"
        let reason = FreeRDPDiagnostics.explanation(status: 145, lifetime: 1, log: log, host: host)
        XCTAssertTrue(reason?.contains("could not ask") == true, reason ?? "nil")
    }

    func testACancelAfterAWhileIsTheUsers() {
        let log = "ERRCONNECT_CONNECT_CANCELLED"
        XCTAssertNil(FreeRDPDiagnostics.explanation(status: 145, lifetime: 40, log: log, host: host))
    }

    func testTypedDomainAndUserAreSplit() {
        let key = UUID()
        let typed = TypedCredentials(username: "SHOP\\bryan", password: "x", remember: false)
        let login = typed.login(passwordKey: key)
        XCTAssertEqual(login.domain, "SHOP")
        XCTAssertEqual(login.username, "bryan")
        XCTAssertEqual(TypedCredentials(username: "bryan@shop.local", password: "x", remember: false)
                        .login(passwordKey: key).username, "bryan@shop.local")
    }

    @MainActor
    func testATypedPasswordGoesDownStandardInput() {
        var m = Machine()
        m.name = "goat7"
        m.hostname = "192.168.1.120"
        let login = Launcher.Login(username: "administrator", domain: "", passwordKey: m.id)
        let invocation = Launcher.freeRDPInvocation(for: m, login: login, password: "typed")
        XCTAssertTrue(invocation.arguments.contains("/from-stdin"))
        XCTAssertEqual(invocation.standardInput, "typed\n")
        XCTAssertFalse(invocation.arguments.contains { $0.contains("typed") })
        let none = Launcher.freeRDPInvocation(for: m, login: login, password: nil)
        XCTAssertFalse(none.arguments.contains("/from-stdin"))
        XCTAssertNil(none.standardInput)
    }

    func testNoProbeThroughAGatewayOrJumpHost() {
        var m = Machine()
        m.name = "remote"
        XCTAssertTrue(shouldProbeBeforeConnecting(m, via: .rdp))
        XCTAssertTrue(shouldProbeBeforeConnecting(m, via: .ssh))
        XCTAssertFalse(shouldProbeBeforeConnecting(m, via: .web))
        m.gateway = "gw.example.com"
        XCTAssertFalse(shouldProbeBeforeConnecting(m, via: .rdp))
        m.jumpHost = "bastion"
        XCTAssertFalse(shouldProbeBeforeConnecting(m, via: .ssh))
    }
}
