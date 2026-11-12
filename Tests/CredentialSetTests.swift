import XCTest

/// A sign-in shared by several machines. One domain account across twenty machines used to
/// mean typing the password twenty times, and twenty edits when it rotated.
@MainActor
final class CredentialSetTests: StoreTestCase {
    override func tearDownWithError() throws {
        Launcher.savedPassword = { Keychain.password(for: $0) }
        Launcher.credentialSet = { MachineStore.shared.credential($0) }
        try super.tearDownWithError()
    }

    private func set(_ name: String, username: String, domain: String = "") -> CredentialSet {
        var c = CredentialSet()
        c.name = name
        c.username = username
        c.domain = domain
        return c
    }

    // MARK: - Where the sign-in comes from

    func testAMachineWithNoSetUsesItsOwn() {
        var m = makeMachine("shop-pc")
        m.username = "local"
        Launcher.credentialSet = { _ in nil }

        let login = Launcher.login(for: m)
        XCTAssertEqual(login.username, "local")
        XCTAssertEqual(login.passwordKey, m.id, "its own Keychain entry, as before")
    }

    func testAMachineUsingASetSignsInAsTheSet() {
        let admin = set("Domain admin", username: "administrator", domain: "OFFICE")
        var m = makeMachine("shop-pc")
        m.username = "ignored-local"
        m.credentialID = admin.id
        Launcher.credentialSet = { $0 == admin.id ? admin : nil }

        let login = Launcher.login(for: m)
        XCTAssertEqual(login.username, "administrator")
        XCTAssertEqual(login.domain, "OFFICE")
        XCTAssertEqual(login.passwordKey, admin.id,
                       "the password is the set's, so changing it once changes it everywhere")
    }

    func testOneChangeReachesEveryMachineUsingIt() {
        let admin = set("Domain admin", username: "administrator", domain: "OFFICE")
        Launcher.credentialSet = { $0 == admin.id ? admin : nil }
        Launcher.savedPassword = { $0 == admin.id ? "rotated" : nil }

        for name in ["shop-pc", "office-pc", "back-pc"] {
            var m = makeMachine(name)
            m.credentialID = admin.id
            XCTAssertEqual(Launcher.freeRDPInvocation(for: m).standardInput, "rotated\n",
                           "\(name) picks up the new password without being edited")
        }
    }

    func testAMissingSetFallsBackToTheMachinesOwn() {
        // The set was deleted on another Mac and this one has not reloaded yet.
        var m = makeMachine("shop-pc")
        m.username = "local"
        m.credentialID = UUID()
        Launcher.credentialSet = { _ in nil }

        let login = Launcher.login(for: m)
        XCTAssertEqual(login.username, "local", "better than signing in as nobody")
        XCTAssertEqual(login.passwordKey, m.id)
    }

    func testBothClientsUseTheSet() {
        let admin = set("Domain admin", username: "administrator", domain: "OFFICE")
        var m = makeMachine("shop-pc")
        m.credentialID = admin.id
        Launcher.credentialSet = { $0 == admin.id ? admin : nil }
        Launcher.savedPassword = { _ in "" }

        XCTAssertTrue(Launcher.freeRDPArguments(for: m).contains("/u:administrator"))
        XCTAssertTrue(Launcher.freeRDPArguments(for: m).contains("/d:OFFICE"))
        XCTAssertTrue(Launcher.rdpFileContents(for: m).contains("username:s:administrator"))
        XCTAssertTrue(Launcher.rdpFileContents(for: m).contains("domain:s:OFFICE"))
    }

    func testSSHUsesTheSetToo() {
        let admin = set("Shared", username: "ops")
        var m = makeMachine("nas")
        m.credentialID = admin.id
        Launcher.credentialSet = { $0 == admin.id ? admin : nil }

        XCTAssertTrue(Launcher.sshCommand(for: m).contains("ops@"))
    }

    // MARK: - Through the store

    func testASetIsSharedButItsPasswordIsNot() throws {
        let store = makeStore()
        let admin = set("Domain admin", username: "administrator", domain: "OFFICE")
        store.addCredential(admin, password: "hunter2")
        defer { Keychain.deletePassword(for: admin.id) }

        let written = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(written.contains("administrator"), "the account is not a secret")
        XCTAssertTrue(written.contains("Domain admin"))
        XCTAssertFalse(written.contains("hunter2"),
                       "the password must never reach the shared file")
        XCTAssertEqual(Keychain.password(for: admin.id), "hunter2")
    }

    func testDeletingASetPutsItsMachinesBackOnTheirOwn() {
        let store = makeStore()
        let admin = set("Domain admin", username: "administrator")
        store.addCredential(admin, password: "")
        var m = makeMachine("shop-pc")
        m.credentialID = admin.id
        store.add(m)
        XCTAssertEqual(store.machineCount(usingCredential: admin.id), 1)

        store.removeCredential(admin.id)

        XCTAssertTrue(store.credentials.isEmpty)
        XCTAssertNil(store.machines[0].credentialID,
                     "no machine is left pointing at something that is gone")
    }

    func testTheNameCanBeEditedWithoutRetypingThePassword() {
        let store = makeStore()
        var admin = set("Domain admin", username: "administrator")
        store.addCredential(admin, password: "hunter2")
        defer { Keychain.deletePassword(for: admin.id) }

        admin.name = "Domain administrator"
        store.updateCredential(admin, password: nil)

        XCTAssertEqual(store.credentials[0].name, "Domain administrator")
        XCTAssertEqual(Keychain.password(for: admin.id), "hunter2", "left alone")
    }

    func testSetsSurviveSaveAndLoad() {
        let store = makeStore()
        store.addCredential(set("Domain admin", username: "administrator", domain: "OFFICE"),
                            password: "")

        let reopened = makeStore()
        XCTAssertEqual(reopened.credentials.map(\.username), ["administrator"])
        XCTAssertEqual(reopened.credentials[0].domain, "OFFICE")
    }

    func testASetAddedOnAnotherMacIsPickedUp() throws {
        let store = makeStore()
        store.add(makeMachine("shop-pc"))

        let theirs = set("Theirs", username: "ops")
        let doc = StoreDocument(version: 1, machines: try readFromDisk(), credentials: [theirs])
        try Self.encoder().encode(doc).write(to: storeURL, options: .atomic)
        store.reloadFromDisk()

        XCTAssertEqual(store.credentials.map(\.name), ["Theirs"])
    }

    func testTheLaterEditOfASetWins() throws {
        let store = makeStore()
        var mine = set("Mine", username: "ops")
        store.addCredential(mine, password: "")

        var theirs = mine
        theirs.name = "Renamed elsewhere"
        theirs.modifiedAt = Date().addingTimeInterval(60)
        let doc = StoreDocument(version: 1, machines: [], credentials: [theirs])
        try Self.encoder().encode(doc).write(to: storeURL, options: .atomic)
        store.reloadFromDisk()

        XCTAssertEqual(store.credentials.map(\.name), ["Renamed elsewhere"])

        // And the other way round: an edit here, against a copy on the share that is older.
        // `updateCredential` stamps the edit with the time it happens, so the local record
        // cannot be backdated — the other side's has to be the old one, which is the real
        // case anyway: a Mac saving a list it picked up a while ago.
        mine = store.credentials[0]
        mine.name = "Renamed here"
        store.updateCredential(mine, password: nil)

        var stale = theirs
        stale.name = "Stale copy"
        stale.modifiedAt = Date().addingTimeInterval(-3600)
        let older = StoreDocument(version: 1, machines: [], credentials: [stale])
        try Self.encoder().encode(older).write(to: storeURL, options: .atomic)
        store.reloadFromDisk()

        XCTAssertEqual(store.credentials.map(\.name), ["Renamed here"])
    }

    func testAListWrittenBeforeSignInsExistedStillLoads() throws {
        let json = """
        { "version": 1, "machines": [ { "name": "shop-pc" } ] }
        """
        try Data(json.utf8).write(to: storeURL)
        let store = makeStore()
        XCTAssertEqual(store.machines.map(\.name), ["shop-pc"])
        XCTAssertTrue(store.credentials.isEmpty)
        XCTAssertNil(store.machines[0].credentialID)
    }
}
