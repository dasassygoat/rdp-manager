import XCTest

/// Which RDP client a connection goes to. This is the difference between signing in with
/// the saved password and being asked for it again on every single connection, which is
/// how the bug this covers presented.
@MainActor
final class RDPRouteTests: StoreTestCase {
    private typealias Route = Launcher.RDPRoute

    private func route(windowsApp: Bool, freeRDP: Bool, password: Bool) -> Route? {
        Launcher.autoRoute(hasWindowsApp: windowsApp, hasFreeRDP: freeRDP,
                           hasSavedPassword: password)
    }

    // MARK: The password decides

    /// The fix. Both clients are there, so before this the connection went to Windows
    /// App, which cannot be handed a password and asked for it every time.
    func testASavedPasswordGoesToFreeRDPEvenWhenWindowsAppIsInstalled() {
        XCTAssertEqual(route(windowsApp: true, freeRDP: true, password: true), .freerdp)
    }

    /// Without a password there is nothing for FreeRDP to carry, so the better client
    /// wins and nothing about the existing behaviour changes.
    func testWithoutASavedPasswordWindowsAppIsStillPreferred() {
        XCTAssertEqual(route(windowsApp: true, freeRDP: true, password: false), .windowsApp)
    }

    // MARK: What is actually installed still constrains it

    /// A password cannot conjure a client. Windows App prompting is better than failing.
    func testASavedPasswordDoesNotRouteToFreeRDPWhenItCannotRun() {
        XCTAssertEqual(route(windowsApp: true, freeRDP: false, password: true), .windowsApp)
    }

    func testFreeRDPIsUsedWhenWindowsAppIsMissing() {
        XCTAssertEqual(route(windowsApp: false, freeRDP: true, password: false), .freerdp)
        XCTAssertEqual(route(windowsApp: false, freeRDP: true, password: true), .freerdp)
    }

    func testWindowsAppIsUsedWhenFreeRDPIsMissing() {
        XCTAssertEqual(route(windowsApp: true, freeRDP: false, password: false), .windowsApp)
    }

    /// Nothing to route to has to stay distinguishable from a choice, so the caller can
    /// explain both missing clients rather than silently doing nothing.
    func testNoClientGivesNoRoute() {
        XCTAssertNil(route(windowsApp: false, freeRDP: false, password: false))
        XCTAssertNil(route(windowsApp: false, freeRDP: false, password: true))
    }

    // MARK: Reading what is saved

    func testAStoredPasswordCounts() {
        let machine = makeMachine("alpha")
        Launcher.savedPassword = { _ in "hunter2" }
        defer { Launcher.savedPassword = { Keychain.password(for: $0) } }
        XCTAssertTrue(Launcher.hasSavedPassword(machine))
    }

    /// An empty string is what a cleared password field leaves behind, and it must not
    /// pull the connection onto FreeRDP with nothing to sign in with.
    func testAnEmptyOrAbsentPasswordDoesNotCount() {
        let machine = makeMachine("alpha")
        defer { Launcher.savedPassword = { Keychain.password(for: $0) } }
        Launcher.savedPassword = { _ in "" }
        XCTAssertFalse(Launcher.hasSavedPassword(machine))
        Launcher.savedPassword = { _ in nil }
        XCTAssertFalse(Launcher.hasSavedPassword(machine))
    }

    /// Each machine is asked about by its own id, so one machine's password cannot send
    /// another machine's connection to a different client.
    func testThePasswordIsLookedUpPerMachine() {
        let alpha = makeMachine("alpha")
        let beta = makeMachine("beta")
        defer { Launcher.savedPassword = { Keychain.password(for: $0) } }
        Launcher.savedPassword = { $0 == alpha.id ? "hunter2" : nil }
        XCTAssertTrue(Launcher.hasSavedPassword(alpha))
        XCTAssertFalse(Launcher.hasSavedPassword(beta))
    }
}
