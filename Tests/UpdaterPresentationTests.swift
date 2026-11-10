import XCTest

/// Getting an answer in front of the user.
///
/// The app goes on running after its last window is closed, so "Check for Updates…" has
/// to be able to show its answer from nothing: the update window is opened first, and
/// only then is the answer raised. Before this, the check ran, found the update, and
/// displayed nothing at all.
@MainActor
final class UpdaterPresentationTests: XCTestCase {
    private var updater: Updater { Updater.shared }
    private var savedSkipped: String?
    private var windowsOpened = 0

    override func setUp() async throws {
        try await super.setUp()
        savedSkipped = updater.skippedVersion
        updater.skippedVersion = nil
        windowsOpened = 0
        updater.prepareToPresent = { [weak self] in self?.windowsOpened += 1 }
        // No app bundle wraps the tests, so the updater is told what it is running.
        updater.runningVersion = { AppVersion("1.0.0") }
        updater.dismiss()
    }

    override func tearDown() async throws {
        updater.prepareToPresent = {}
        updater.runningVersion = { AppVersion.running }
        updater.skippedVersion = savedSkipped
        updater.dismiss()
        try await super.tearDown()
    }

    /// Releases as GitHub lists them, newest first.
    private func releases(tag: String) -> Data {
        Data("""
        [{"tag_name":"\(tag)","name":"\(tag)","body":"notes","draft":false,"prerelease":false,
          "assets":[{"name":"RDP-Manager-\(tag).zip",
                     "browser_download_url":"https://example.invalid/a.zip","size":1}]}]
        """.utf8)
    }

    private func check(userInitiated: Bool, answering data: Data?) async {
        updater.fetch = { _ in
            guard let data else { throw URLError(.notConnectedToInternet) }
            return data
        }
        updater.check(userInitiated: userInitiated)
        // The check runs in a Task of its own, so wait for that rather than poll `state`:
        // polling sees the value from *before* the task has started and reads it as done.
        await updater.settle()
        XCTAssertFalse(updater.state.isBusy, "the check never finished")
    }

    func testAnOfferedUpdateOpensSomewhereToShowItFirst() async {
        await check(userInitiated: true, answering: releases(tag: "99.0.0"))
        XCTAssertEqual(updater.state.release?.tag, "99.0.0")
        XCTAssertTrue(updater.isPresenting)
        XCTAssertEqual(windowsOpened, 1)
    }

    func testBeingUpToDateIsSaidOutLoudWhenAsked() async {
        await check(userInitiated: true, answering: releases(tag: "0.0.1"))
        XCTAssertEqual(updater.state, .upToDate)
        XCTAssertTrue(updater.isPresenting)
        XCTAssertEqual(windowsOpened, 1)
    }

    func testAFailedCheckIsSaidOutLoudWhenAsked() async {
        await check(userInitiated: true, answering: nil)
        guard case .failed = updater.state else {
            return XCTFail("expected a failure, got \(updater.state)")
        }
        XCTAssertTrue(updater.isPresenting)
        XCTAssertEqual(windowsOpened, 1)
    }

    /// A silent check that finds nothing stays silent, and opens nothing.
    func testABackgroundCheckThatFindsNothingSaysNothing() async {
        await check(userInitiated: false, answering: releases(tag: "0.0.1"))
        XCTAssertEqual(updater.state, .upToDate)
        XCTAssertFalse(updater.isPresenting)
        XCTAssertEqual(windowsOpened, 0)
    }

    /// One that *did* find something interrupts, so it needs a window too.
    func testABackgroundCheckThatFindsAnUpdateOpensAWindow() async {
        await check(userInitiated: false, answering: releases(tag: "99.0.0"))
        XCTAssertTrue(updater.isPresenting)
        XCTAssertEqual(windowsOpened, 1)
    }

    /// The invariant behind all of the above, and the whole of the bug: the answer is
    /// never raised without somewhere to raise it.
    func testNothingIsEverShownWithoutOpeningAWindowForIt() async {
        for (userInitiated, data) in [(true, releases(tag: "99.0.0")),
                                      (true, releases(tag: "0.0.1")),
                                      (true, nil),
                                      (false, releases(tag: "99.0.0")),
                                      (false, releases(tag: "0.0.1"))] {
            windowsOpened = 0
            updater.dismiss()
            await check(userInitiated: userInitiated, answering: data)
            XCTAssertEqual(updater.isPresenting, windowsOpened == 1,
                           "shown without a window for userInitiated=\(userInitiated)")
        }
    }

    func testSkippingPutsItAway() async {
        await check(userInitiated: true, answering: releases(tag: "99.0.0"))
        guard let release = updater.state.release else { return XCTFail("no release") }
        updater.skip(release)
        XCTAssertFalse(updater.isPresenting)
        XCTAssertEqual(updater.skippedVersion, "99.0.0")
    }

    func testDismissingPutsItAway() async {
        await check(userInitiated: true, answering: releases(tag: "99.0.0"))
        updater.dismiss()
        XCTAssertFalse(updater.isPresenting)
    }
}
