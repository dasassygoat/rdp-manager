import XCTest

/// Shared setup for the store tests: every test gets its own empty directory and a store
/// bound to a file inside it, with the watcher off so reloads happen only when a test
/// asks for one.
@MainActor
class StoreTestCase: XCTestCase {
    var directory: URL!
    var storeURL: URL!
    /// Deliberately not inside `directory`: tests assert on exactly what the store's own
    /// folder contains, and saved copies belong somewhere else anyway.
    var backupDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdpmanager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("machines.json")
        backupDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdpmanager-backups-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: backupDirectory)
        try super.tearDownWithError()
    }

    func makeStore() -> MachineStore {
        let store = MachineStore(storeURL: storeURL, watchForChanges: false)
        // Keep saved copies out of the real Application Support folder.
        store.backupDirectory = backupDirectory
        return store
    }

    func backupFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    func readBackup(_ name: String) throws -> [Machine] {
        try Self.decoder()
            .decode(StoreDocument.self,
                    from: Data(contentsOf: backupDirectory.appendingPathComponent(name)))
            .machines
    }

    func makeMachine(
        _ name: String,
        id: UUID = UUID(),
        group: String = "",
        lastIP: String? = nil,
        modifiedAt: Date = Date()
    ) -> Machine {
        var m = Machine()
        m.id = id
        m.name = name
        m.hostname = "\(name).local"
        m.group = group
        m.lastIP = lastIP
        m.modifiedAt = modifiedAt
        return m
    }

    // MARK: - Standing in for another Mac

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Writes the store file the way another Mac on the share would, optionally backdating
    /// it so the merge sees local edits as newer than the file.
    func writeToDisk(_ machines: [Machine], fileDate: Date? = nil) throws {
        let data = try Self.encoder().encode(StoreDocument(version: 1, machines: machines))
        try data.write(to: storeURL, options: .atomic)
        if let fileDate {
            try FileManager.default.setAttributes(
                [.modificationDate: fileDate], ofItemAtPath: storeURL.path)
        }
    }

    func readFromDisk() throws -> [Machine] {
        try Self.decoder()
            .decode(StoreDocument.self, from: Data(contentsOf: storeURL))
            .machines
    }
}
