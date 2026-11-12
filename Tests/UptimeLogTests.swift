import XCTest

/// The record of what the poller saw, which it used to compute and throw away.
@MainActor
final class UptimeLogTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private let shop = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rdpmanager-uptime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("uptime.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeLog() -> UptimeLog { UptimeLog(fileURL: fileURL) }
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: minutes * 60) }

    func testAnOutageIsADownAndTheUpThatFollowsIt() {
        let log = makeLog()
        log.record(shop, up: true, at: at(0))
        log.record(shop, up: false, at: at(10))
        log.record(shop, up: true, at: at(25))

        let outages = log.outages(for: shop)
        XCTAssertEqual(outages.count, 1)
        XCTAssertEqual(outages[0].began, at(10))
        XCTAssertEqual(outages[0].ended, at(25))
        XCTAssertEqual(outages[0].duration, 15 * 60)
    }

    func testAMachineStillDownHasAnOpenOutage() {
        let log = makeLog()
        log.record(shop, up: true, at: at(0))
        log.record(shop, up: false, at: at(10))

        let outages = log.outages(for: shop)
        XCTAssertEqual(outages.count, 1)
        XCTAssertNil(outages[0].ended)
        XCTAssertNil(outages[0].duration, "it has not finished, so it has no length yet")
    }

    func testRepeatingTheSameStateIsNotRecorded() {
        let log = makeLog()
        log.record(shop, up: false, at: at(1))
        log.record(shop, up: false, at: at(2))
        log.record(shop, up: false, at: at(3))

        XCTAssertEqual(log.changes.count, 1,
                       "a machine that is simply still down must not fill the file")
    }

    func testOutagesAreNewestFirst() {
        let log = makeLog()
        log.record(shop, up: true, at: at(0))
        log.record(shop, up: false, at: at(10))
        log.record(shop, up: true, at: at(20))
        log.record(shop, up: false, at: at(30))
        log.record(shop, up: true, at: at(40))

        XCTAssertEqual(log.outages(for: shop).map(\.began), [at(30), at(10)])
    }

    func testDowntimeIsCounted() {
        let log = makeLog()
        log.record(shop, up: true, at: at(0))
        log.record(shop, up: false, at: at(10))
        log.record(shop, up: true, at: at(20))   // 10 minutes
        log.record(shop, up: false, at: at(30))
        log.record(shop, up: true, at: at(35))   // 5 minutes

        let summary = log.downtime(for: shop, since: at(0))
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.total, 15 * 60)
    }

    func testOnlyThePartInsideTheWindowIsCounted() {
        let log = makeLog()
        log.record(shop, up: false, at: at(0))
        log.record(shop, up: true, at: at(100))

        // A window that starts in the middle of the outage.
        let summary = log.downtime(for: shop, since: at(60))
        XCTAssertEqual(summary.total, 40 * 60,
                       "a machine down for a week must not report a week against one day")
    }

    func testAnotherMachinesOutagesAreNotCounted() {
        let log = makeLog()
        let other = UUID()
        log.record(shop, up: false, at: at(10))
        log.record(shop, up: true, at: at(20))
        log.record(other, up: false, at: at(10))
        log.record(other, up: true, at: at(90))

        XCTAssertEqual(log.downtime(for: shop, since: at(0)).total, 10 * 60)
    }

    func testAvailabilityIsUnknownWithNothingRecorded() {
        XCTAssertNil(makeLog().availability(for: shop, since: at(0)),
                     "no record is not the same as having been up")
    }

    func testItSurvivesARestart() {
        let first = makeLog()
        first.record(shop, up: false, at: at(10))
        first.record(shop, up: true, at: at(20))

        XCTAssertEqual(makeLog().outages(for: shop).count, 1)
    }

    func testADeletedMachineIsForgotten() {
        let log = makeLog()
        log.record(shop, up: false, at: at(10))
        log.forget(shop)
        XCTAssertTrue(log.outages(for: shop).isEmpty)
        XCTAssertTrue(makeLog().outages(for: shop).isEmpty)
    }

    func testItIsNotKeptInTheSharedList() {
        XCTAssertNotEqual(UptimeLog.defaultFileURL, StoreLocation.defaultFileURL,
                          "polling must not write to the file other Macs merge")
    }
}
