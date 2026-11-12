import XCTest

/// The log of sessions started from this Mac: what the detail view and the menu bar's
/// recents are built on.
@MainActor
final class ConnectionLogTests: XCTestCase {
    private var fileURL: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdpmanager-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("connections.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func machine(_ name: String) -> Machine {
        var m = Machine()
        m.name = name
        return m
    }

    private func makeLog() -> ConnectionLog {
        ConnectionLog(fileURL: fileURL)
    }

    func testASessionIsRecorded() {
        let log = makeLog()
        let shop = machine("shop-pc")

        log.record(shop, via: .rdp)

        XCTAssertEqual(log.count(for: shop.id), 1)
        XCTAssertEqual(log.lastConnection(to: shop.id)?.type, .rdp)
    }

    func testTheLastConnectionIsTheMostRecentOne() {
        let log = makeLog()
        let shop = machine("shop-pc")

        log.record(shop, via: .rdp, at: Date(timeIntervalSince1970: 1_000))
        log.record(shop, via: .ssh, at: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(log.lastConnection(to: shop.id)?.type, .ssh)
    }

    func testHistoryIsNewestFirstAndOnlyThisMachine() {
        let log = makeLog()
        let shop = machine("shop-pc")
        let office = machine("office-pc")

        log.record(shop, via: .rdp, at: Date(timeIntervalSince1970: 1_000))
        log.record(office, via: .vnc, at: Date(timeIntervalSince1970: 1_500))
        log.record(shop, via: .ssh, at: Date(timeIntervalSince1970: 2_000))

        let history = log.history(for: shop.id)
        XCTAssertEqual(history.map(\.type), [.ssh, .rdp])
    }

    func testRecentsListEachMachineOnce() {
        let log = makeLog()
        let shop = machine("shop-pc")
        let office = machine("office-pc")

        log.record(shop, via: .rdp, at: Date(timeIntervalSince1970: 1_000))
        log.record(office, via: .rdp, at: Date(timeIntervalSince1970: 2_000))
        log.record(shop, via: .rdp, at: Date(timeIntervalSince1970: 3_000))

        XCTAssertEqual(log.recentMachineIDs(), [shop.id, office.id],
                       "most recent first, and shop-pc is not listed twice")
    }

    func testRecentsAreCapped() {
        let log = makeLog()
        for i in 0..<10 {
            log.record(machine("pc-\(i)"), via: .rdp, at: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(log.recentMachineIDs(limit: 3).count, 3)
    }

    func testTheLogIsTrimmed() {
        let log = makeLog()
        let shop = machine("shop-pc")
        for i in 0...(ConnectionLog.limit + 10) {
            log.record(shop, via: .rdp, at: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(log.entries.count, ConnectionLog.limit)
        XCTAssertEqual(log.lastConnection(to: shop.id)?.at,
                       Date(timeIntervalSince1970: Double(ConnectionLog.limit + 10)),
                       "the newest is kept; the oldest are what go")
    }

    func testItSurvivesARestart() {
        let shop = machine("shop-pc")
        let first = makeLog()
        first.record(shop, via: .rdp, at: Date(timeIntervalSince1970: 1_000))

        let second = makeLog()
        XCTAssertEqual(second.count(for: shop.id), 1)
        XCTAssertEqual(second.lastConnection(to: shop.id)?.at, Date(timeIntervalSince1970: 1_000))
    }

    func testADeletedMachineIsForgotten() {
        let log = makeLog()
        let shop = machine("shop-pc")
        let office = machine("office-pc")
        log.record(shop, via: .rdp)
        log.record(office, via: .rdp)

        log.forget(shop.id)

        XCTAssertEqual(log.count(for: shop.id), 0)
        XCTAssertEqual(log.count(for: office.id), 1, "only the one deleted")
        XCTAssertEqual(makeLog().count(for: shop.id), 0, "and it stays forgotten")
    }

    func testTheLogIsNotKeptInTheSharedList() {
        XCTAssertEqual(ConnectionLog.defaultFileURL.lastPathComponent, "connections.json")
        XCTAssertNotEqual(ConnectionLog.defaultFileURL, StoreLocation.defaultFileURL,
                          "a click on this Mac must not touch the file other Macs merge")
    }
}
