import XCTest

/// The saved password must not reach FreeRDP's command line. Anything else running as this
/// user can read a process's arguments with `ps`, so a password there is a password shared
/// with every other program on the Mac for as long as the session lasts.
@MainActor
final class FreeRDPCredentialTests: XCTestCase {
    private let secret = "hunter2"

    override func tearDown() {
        Launcher.savedPassword = { Keychain.password(for: $0) }
        super.tearDown()
    }

    private func machine(username: String = "admin") -> Machine {
        var m = Machine()
        m.name = "shop-pc"
        m.hostname = "shop-pc.local"
        m.username = username
        return m
    }

    func testThePasswordIsNowhereInTheArguments() {
        Launcher.savedPassword = { _ in self.secret }
        let invocation = Launcher.freeRDPInvocation(for: machine())

        for argument in invocation.arguments {
            XCTAssertFalse(argument.contains(secret), "leaked in \(argument)")
        }
        XCTAssertFalse(invocation.arguments.contains { $0.hasPrefix("/p:") })
    }

    func testThePasswordGoesDownStandardInputInstead() {
        Launcher.savedPassword = { _ in self.secret }
        let invocation = Launcher.freeRDPInvocation(for: machine())

        XCTAssertTrue(invocation.arguments.contains("/from-stdin"),
                      "FreeRDP has to be told to ask")
        XCTAssertEqual(invocation.standardInput, secret + "\n",
                       "one line, ended, so it does not wait for more")
    }

    func testTheUsernameStillGoesOnTheCommandLine() {
        Launcher.savedPassword = { _ in self.secret }
        let invocation = Launcher.freeRDPInvocation(for: machine(username: "WORKGROUP\\admin"))

        XCTAssertTrue(invocation.arguments.contains("/d:WORKGROUP"))
        XCTAssertTrue(invocation.arguments.contains("/u:admin"))
        XCTAssertEqual(invocation.standardInput, secret + "\n",
                       "only the password is secret; the rest is fine to see")
    }

    func testNothingIsSentWithoutAPassword() {
        Launcher.savedPassword = { _ in nil }
        let invocation = Launcher.freeRDPInvocation(for: machine())

        XCTAssertNil(invocation.standardInput)
        XCTAssertFalse(invocation.arguments.contains("/from-stdin"),
                       "nothing to answer with, so let FreeRDP ask in its own window")
    }

    func testAnEmptyPasswordIsTreatedAsNone() {
        Launcher.savedPassword = { _ in "" }
        let invocation = Launcher.freeRDPInvocation(for: machine())

        XCTAssertNil(invocation.standardInput)
        XCTAssertFalse(invocation.arguments.contains("/from-stdin"))
    }

    func testAPasswordWithNoUsernameIsNotSent() {
        Launcher.savedPassword = { _ in self.secret }
        let invocation = Launcher.freeRDPInvocation(for: machine(username: ""))

        // FreeRDP asks for username, domain and password in that order, so a password sent
        // while the username is also missing would be typed into the username.
        XCTAssertNil(invocation.standardInput)
        XCTAssertFalse(invocation.arguments.contains("/from-stdin"))
        for argument in invocation.arguments {
            XCTAssertFalse(argument.contains(secret), "leaked in \(argument)")
        }
    }

    func testAPasswordWithAwkwardCharactersSurvivesIntact() {
        let awkward = "p a$$ \"w'ord\\ \n trailing"
        Launcher.savedPassword = { _ in awkward }
        let invocation = Launcher.freeRDPInvocation(for: machine())

        // Nothing quotes or escapes it: a pipe is bytes, which is most of the point of
        // moving it off a command line that a shell or a log could mangle.
        XCTAssertEqual(invocation.standardInput, awkward + "\n")
    }
}
