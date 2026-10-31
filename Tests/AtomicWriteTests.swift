import XCTest

/// Covers saving: the file a reader sees is always a whole document, and a failed write
/// leaves the last good one in place. This is what keeps a shared list on a network share
/// or in iCloud Drive from being read half-written.
@MainActor
final class AtomicWriteTests: StoreTestCase {
    func testSaveWritesADocumentThatCanBeReadBack() throws {
        let store = makeStore()
        store.add(makeMachine("alpha", group: "Office"))

        let data = try Data(contentsOf: storeURL)
        let doc = try Self.decoder().decode(StoreDocument.self, from: data)

        XCTAssertEqual(doc.version, 1)
        XCTAssertEqual(doc.machines.map(\.name), ["alpha"])
        XCTAssertNil(store.lastError)
    }

    func testSaveCreatesMissingDirectories() throws {
        let nested = directory
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("RDP Manager", isDirectory: true)
            .appendingPathComponent("machines.json")
        let store = MachineStore(storeURL: nested, watchForChanges: false)

        store.add(makeMachine("alpha"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertNil(store.lastError)
    }

    func testSaveReplacesTheFileRatherThanTruncatingIt() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let first = try fileNumber(of: storeURL)

        store.add(makeMachine("bravo"))
        let second = try fileNumber(of: storeURL)

        XCTAssertNotEqual(first, second,
                          "an atomic save renames a new file into place, so the inode changes")
    }

    func testSaveLeavesNoTemporaryFilesBehind() throws {
        let store = makeStore()
        for i in 0..<25 { store.add(makeMachine("machine-\(i)")) }

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        XCTAssertEqual(left, ["machines.json"])
    }

    func testAReaderDuringRepeatedSavesNeverSeesAPartialFile() throws {
        let store = makeStore()
        for i in 0..<20 { store.add(makeMachine("machine-\(String(format: "%02d", i))")) }

        let watcher = ConcurrentReader(url: storeURL, expectedCount: 20)
        watcher.start()

        for i in 0..<200 {
            var m = store.machines[i % store.machines.count]
            m.notes = "pass \(i)"
            store.update(m)
        }

        let result = watcher.stop()

        XCTAssertTrue(result.problems.isEmpty, "\(result.problems.prefix(5))")
        XCTAssertGreaterThan(result.reads, 0, "the reader never managed to open the file")
    }

    func testAFailedSaveKeepsTheLastGoodFile() throws {
        let store = makeStore()
        store.add(makeMachine("alpha"))
        let good = try Data(contentsOf: storeURL)

        // Make the directory read-only so the rename cannot land.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        store.add(makeMachine("bravo"))

        XCTAssertNotNil(store.lastError, "the user should be told the write failed")
        XCTAssertEqual(try Data(contentsOf: storeURL), good,
                       "the previous list must still be on disk")
    }

    func testTheNextSuccessfulSaveClearsTheError() throws {
        let store = makeStore()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        store.add(makeMachine("alpha"))
        XCTAssertNotNil(store.lastError)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        store.add(makeMachine("bravo"))

        XCTAssertNil(store.lastError)
        XCTAssertEqual(try readFromDisk().map(\.name), ["alpha", "bravo"])
    }

    private func fileNumber(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? Int) ?? -1
    }
}

/// Reads the store file on a background thread for as long as it is running, so a save
/// that was not atomic shows up as a decode failure or a short list.
private final class ConcurrentReader {
    struct Result {
        var reads: Int
        var problems: [String]
    }

    private let url: URL
    private let expectedCount: Int
    private let lock = NSLock()
    private var stopping = false
    private var result = Result(reads: 0, problems: [])
    private var thread: Thread?

    init(url: URL, expectedCount: Int) {
        self.url = url
        self.expectedCount = expectedCount
    }

    func start() {
        let thread = Thread { [self] in loop() }
        thread.start()
        self.thread = thread
    }

    func stop() -> Result {
        lock.lock(); stopping = true; lock.unlock()
        let deadline = Date() + 5
        while let t = thread, !t.isFinished, Date() < deadline {
            usleep(1000)
        }
        lock.lock(); defer { lock.unlock() }
        return result
    }

    private func loop() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while true {
            lock.lock(); let done = stopping; lock.unlock()
            if done { return }

            guard let data = try? Data(contentsOf: url) else { continue }
            lock.lock()
            do {
                let doc = try decoder.decode(StoreDocument.self, from: data)
                result.reads += 1
                if doc.machines.count != expectedCount {
                    result.problems.append("saw \(doc.machines.count) machines, want \(expectedCount)")
                }
            } catch {
                result.problems.append("could not decode \(data.count) bytes: \(error)")
            }
            lock.unlock()
        }
    }
}
