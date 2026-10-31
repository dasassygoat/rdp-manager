import XCTest

/// Shared setup for the store tests: every test gets its own empty directory and a store
/// bound to a file inside it, with the watcher off so reloads happen only when a test
/// asks for one.
@MainActor
class StoreTestCase: XCTestCase {
    var directory: URL!
    var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdpmanager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("machines.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func makeStore() -> MachineStore {
        MachineStore(storeURL: storeURL, watchForChanges: false)
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
