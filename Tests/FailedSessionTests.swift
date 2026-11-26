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

    func testAnUnexplainedEarlyExitStillGetsReported() {
        let reason = FreeRDPDiagnostics.explanation(status: 7, lifetime: 1, log: "", host: host)
        XCTAssertTrue(reason?.contains("exited with code 7") == true, reason ?? "nil")
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
