import XCTest

/// Covers installing rdpm onto the PATH. Everything runs against a temp directory, so no
/// test touches /usr/local/bin or raises an administrator prompt.
@MainActor
final class CommandLineToolTests: StoreTestCase {
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Stand in for the copy inside the app bundle, at a path carrying the same marker
        // the real one does.
        let helpers = directory
            .appendingPathComponent("RDP Manager.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        source = helpers.appendingPathComponent("rdpm")
        try Data("#!/bin/sh\necho stub\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        destination = directory.appendingPathComponent("bin/rdpm")
    }

    func testInstallCreatesASymlinkIntoTheBundle() throws {
        let installed = try CommandLineTool.install(source: source, at: destination)

        XCTAssertEqual(installed, destination)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
                       source.path,
                       "a copy would go stale when the app is replaced")
    }

    func testInstallCreatesTheDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        try CommandLineTool.install(source: source, at: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTheInstalledCommandRuns() throws {
        try CommandLineTool.install(source: source, at: destination)

        let process = Process()
        process.executableURL = destination
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines),
                       "stub", "the link has to be executable through the symlink")
    }

    func testInstallingTwiceReplacesTheOldLink() throws {
        let other = directory.appendingPathComponent("old-rdpm")
        try Data("#!/bin/sh\n".utf8).write(to: other)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: other)

        try CommandLineTool.install(source: source, at: destination)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
                       source.path)
    }

    func testInstalledSourceReportsNothingWhenAbsent() {
        XCTAssertNil(CommandLineTool.installedSource(at: destination))
    }

    func testInstalledSourceFollowsTheLink() throws {
        try CommandLineTool.install(source: source, at: destination)
        XCTAssertEqual(CommandLineTool.installedSource(at: destination)?.path, source.path)
    }

    func testInstalledSourceSeesAPlainFileToo() throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: destination)

        XCTAssertEqual(CommandLineTool.installedSource(at: destination)?.path, destination.path,
                       "someone else's rdpm should still be reported, so Settings can warn")
    }

    func testUninstallRemovesOurOwnLink() throws {
        try CommandLineTool.install(source: source, at: destination)
        try CommandLineTool.uninstall(at: destination)

        XCTAssertNil(CommandLineTool.installedSource(at: destination))
    }

    func testUninstallLeavesSomebodyElsesCommandAlone() throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: destination)

        XCTAssertThrowsError(try CommandLineTool.uninstall(at: destination)) { error in
            guard case CommandLineTool.Failure.notOurs = error else {
                return XCTFail("expected notOurs, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
                      "deleting an unrelated binary from /usr/local/bin would be destructive")
    }

    func testUninstallIsFineWhenNothingIsInstalled() throws {
        XCTAssertNoThrow(try CommandLineTool.uninstall(at: destination))
    }

    func testMissingBinaryIsReportedClearly() {
        let absent = directory.appendingPathComponent("RDP Manager.app/Contents/Helpers/absent")
        XCTAssertThrowsError(try CommandLineTool.install(source: absent, at: destination))
    }

    func testTheMarkerMatchesWhereTheBinaryActuallyShips() {
        XCTAssertTrue(source.path.contains(CommandLineTool.bundleMarker),
                      "the uninstall guard depends on this path shape")
    }
}
