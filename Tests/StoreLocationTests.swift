import XCTest

/// Covers how `rdpm` finds the same file the app writes, which is the whole point of the
/// command: an IP the app recorded seconds ago is the one it hands to ssh.
@MainActor
final class StoreLocationTests: StoreTestCase {
    private func scratchDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "rdpmanager.tests.\(UUID().uuidString)")!
        addTeardownBlock { suite.removePersistentDomain(forName: suite.description) }
        return suite
    }

    func testDefaultsToApplicationSupport() {
        let url = StoreLocation.resolve(environment: [:], defaults: scratchDefaults())
        XCTAssertEqual(url, StoreLocation.defaultFileURL)
        XCTAssertEqual(url.lastPathComponent, "machines.json")
    }

    func testTheAppsConfiguredFolderIsUsed() {
        let defaults = scratchDefaults()
        defaults.set("/Volumes/Share/RDP/machines.json", forKey: StoreLocation.pathKey)

        XCTAssertEqual(StoreLocation.resolve(environment: [:], defaults: defaults).path,
                       "/Volumes/Share/RDP/machines.json",
                       "a list shared from the app's Settings must be what the command reads")
    }

    func testEnvironmentBeatsTheAppSetting() {
        let defaults = scratchDefaults()
        defaults.set("/Volumes/Share/machines.json", forKey: StoreLocation.pathKey)

        let url = StoreLocation.resolve(
            environment: [StoreLocation.environmentKey: "/tmp/other.json"], defaults: defaults)

        XCTAssertEqual(url.path, "/tmp/other.json")
    }

    func testExplicitPathBeatsEverything() {
        let defaults = scratchDefaults()
        defaults.set("/Volumes/Share/machines.json", forKey: StoreLocation.pathKey)

        let url = StoreLocation.resolve(
            explicit: "/tmp/explicit.json",
            environment: [StoreLocation.environmentKey: "/tmp/env.json"],
            defaults: defaults)

        XCTAssertEqual(url.path, "/tmp/explicit.json")
    }

    func testTildeIsExpanded() {
        let url = StoreLocation.resolve(explicit: "~/machines.json", environment: [:], defaults: nil)
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertTrue(url.path.hasPrefix(NSHomeDirectory()))
    }

    func testEmptyValuesAreIgnored() {
        let defaults = scratchDefaults()
        defaults.set("", forKey: StoreLocation.pathKey)

        let url = StoreLocation.resolve(
            explicit: "", environment: [StoreLocation.environmentKey: ""], defaults: defaults)

        XCTAssertEqual(url, StoreLocation.defaultFileURL)
    }

    func testTheAppAndTheCommandAgreeOnTheDefault() {
        XCTAssertEqual(MachineStore.defaultStoreURL, StoreLocation.defaultFileURL,
                       "one definition, or the command would read a different file")
    }

    func testLoadReadsWhatTheStoreWrote() throws {
        let store = makeStore()
        store.add(makeMachine("nas", lastIP: "192.168.1.9"))
        store.add(makeMachine("shop-pc"))

        let loaded = try StoreLocation.load(storeURL)

        XCTAssertEqual(loaded.map(\.name).sorted(), ["nas", "shop-pc"])
        XCTAssertEqual(loaded.first { $0.name == "nas" }?.lastIP, "192.168.1.9")
    }

    func testLoadThrowsOnAMissingFile() {
        XCTAssertThrowsError(
            try StoreLocation.load(directory.appendingPathComponent("absent.json")))
    }
}
