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

    // MARK: Finding the bundled OpenSSL providers

    private func layout(bundledModules: Bool) throws -> URL {
        let root = directory.appendingPathComponent("freerdp-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if bundledModules {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("lib/ossl-modules"),
                withIntermediateDirectories: true)
        }
        return bin.appendingPathComponent("sdl-freerdp")
    }

    /// Without this the bundled FreeRDP has no MD4, so no NTLM, so NLA fails with
    /// SEC_E_NO_CREDENTIALS and a saved password looks like it was ignored.
    func testTheBundledProvidersAreFound() throws {
        let executable = try layout(bundledModules: true)
        let found = Launcher.opensslModulesDirectory(forExecutableAt: executable)
        XCTAssertEqual(found?.lastPathComponent, "ossl-modules")
        XCTAssertEqual(found?.deletingLastPathComponent().lastPathComponent, "lib")
    }

    /// Nothing is pointed anywhere when there is no providers directory to point at.
    /// Setting OPENSSL_MODULES to a folder that is not there would break a FreeRDP that
    /// was finding its own providers perfectly well.
    func testNothingIsFoundWhenThereAreNoBundledProviders() throws {
        let executable = try layout(bundledModules: false)
        XCTAssertNil(Launcher.opensslModulesDirectory(forExecutableAt: executable))
    }

    /// Homebrew lays its install out the same way — `bin/sdl-freerdp` beside
    /// `lib/ossl-modules` — so the same relative walk lands on its own providers rather
    /// than on nothing. Worth pinning: it means one rule covers both installs.
    func testAHomebrewLayoutResolvesToItsOwnProviders() throws {
        let prefix = directory.appendingPathComponent("opt/homebrew")
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("lib/ossl-modules"),
            withIntermediateDirectories: true)
        let found = Launcher.opensslModulesDirectory(
            forExecutableAt: prefix.appendingPathComponent("bin/sdl-freerdp"))
        XCTAssertEqual(found?.path, prefix.appendingPathComponent("lib/ossl-modules").path)
    }

    /// A file where the directory should be is not a providers directory.
    func testAFileNamedLikeTheDirectoryIsNotUsed() throws {
        let executable = try layout(bundledModules: false)
        let impostor = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/ossl-modules")
        try FileManager.default.createDirectory(
            at: impostor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: impostor)
        XCTAssertNil(Launcher.opensslModulesDirectory(forExecutableAt: executable))
    }
}
