import XCTest

/// Mach-O headers are built by hand here rather than taken from real binaries on the Mac
/// running the tests: the case that matters is a binary for the *other* architecture, which
/// this machine by definition does not have lying around.
final class ExecutableArchitectureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arch-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: Building headers

    private func write(_ bytes: [UInt8], executable: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(bytes).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
         UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        Array(littleEndian(value).reversed())
    }

    /// A thin Mach-O: host-order magic, then cputype.
    private func thin(_ cpu: UInt32, magic: UInt32 = 0xfeed_facf) -> [UInt8] {
        littleEndian(magic) + littleEndian(cpu)
    }

    /// A fat binary: big-endian magic and slice count, then one entry per slice with
    /// cputype first. Entries are 20 bytes, or 32 for the 64-bit layout.
    private func fat(_ cpus: [UInt32], magic: UInt32 = 0xcafe_babe) -> [UInt8] {
        let stride = magic == 0xcafe_babf ? 32 : 20
        var bytes = bigEndian(magic) + bigEndian(UInt32(cpus.count))
        for cpu in cpus {
            bytes += bigEndian(cpu) + [UInt8](repeating: 0, count: stride - 4)
        }
        return bytes
    }

    // MARK: Reading architectures

    func testThinARM64BinaryReportsAppleSilicon() throws {
        let url = try write(thin(ExecutableArchitecture.cpuARM64))
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url),
                       [ExecutableArchitecture.cpuARM64])
    }

    func testThinIntelBinaryReportsIntel() throws {
        let url = try write(thin(ExecutableArchitecture.cpuX86_64))
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url),
                       [ExecutableArchitecture.cpuX86_64])
    }

    func testThirtyTwoBitMagicIsAlsoRead() throws {
        let url = try write(thin(ExecutableArchitecture.cpuX86_64, magic: 0xfeed_face))
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url),
                       [ExecutableArchitecture.cpuX86_64])
    }

    func testUniversalBinaryReportsEverySlice() throws {
        let url = try write(fat([ExecutableArchitecture.cpuX86_64,
                                 ExecutableArchitecture.cpuARM64]))
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url),
                       [ExecutableArchitecture.cpuX86_64, ExecutableArchitecture.cpuARM64])
    }

    func testSixtyFourBitFatHeaderUsesWiderEntries() throws {
        let url = try write(fat([ExecutableArchitecture.cpuARM64], magic: 0xcafe_babf))
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url),
                       [ExecutableArchitecture.cpuARM64])
    }

    func testAbsurdSliceCountIsRefused() throws {
        // Claiming 100,000 slices should not make the reader allocate for them.
        let url = try write(bigEndian(0xcafe_babe) + bigEndian(100_000))
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url), [])
    }

    func testTruncatedSliceTableIsRefused() throws {
        var bytes = fat([ExecutableArchitecture.cpuARM64, ExecutableArchitecture.cpuX86_64])
        bytes.removeLast(10)
        let url = try write(bytes)
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url), [])
    }

    func testFileTooShortForAHeaderIsNotMachO() throws {
        let url = try write([0xcf, 0xfa, 0xed])
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url), [])
    }

    func testShellScriptHasNoArchitecture() throws {
        let url = try write(Array("#!/bin/sh\nexec ssh \"$@\"\n".utf8))
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url), [])
    }

    func testMissingFileHasNoArchitecture() {
        let url = directory.appendingPathComponent("not-there")
        XCTAssertEqual(ExecutableArchitecture.architectures(ofFileAt: url), [])
        XCTAssertFalse(ExecutableArchitecture.canRun(fileAt: url))
    }

    // MARK: Deciding what can run

    func testThisMacCanRunASystemBinary() {
        XCTAssertTrue(ExecutableArchitecture.canRun(fileAt: URL(fileURLWithPath: "/bin/ls")))
    }

    func testRunnableIsNeverEmpty() {
        XCTAssertFalse(ExecutableArchitecture.runnable.isEmpty)
    }

    /// The bug this whole type exists for: present, executable, and unusable.
    func testBinaryForTheOtherArchitectureCannotRun() throws {
        let runnable = ExecutableArchitecture.runnable
        try XCTSkipIf(runnable.contains(ExecutableArchitecture.cpuARM64)
                      && runnable.contains(ExecutableArchitecture.cpuX86_64),
                      "running translated, so both architectures start")
        let other = runnable.contains(ExecutableArchitecture.cpuARM64)
            ? ExecutableArchitecture.cpuX86_64
            : ExecutableArchitecture.cpuARM64
        let url = try write(thin(other))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                      "the permission bits are what the old check looked at")
        XCTAssertFalse(ExecutableArchitecture.canRun(fileAt: url))
    }

    func testBinaryForThisArchitectureCanRun() throws {
        let url = try write(thin(ExecutableArchitecture.runnable.first!))
        XCTAssertTrue(ExecutableArchitecture.canRun(fileAt: url))
    }

    func testUniversalBinaryCanRun() throws {
        let url = try write(fat([ExecutableArchitecture.cpuX86_64,
                                 ExecutableArchitecture.cpuARM64]))
        XCTAssertTrue(ExecutableArchitecture.canRun(fileAt: url))
    }

    func testScriptIsGivenTheBenefitOfTheDoubt() throws {
        let url = try write(Array("#!/bin/sh\necho hi\n".utf8))
        XCTAssertTrue(ExecutableArchitecture.canRun(fileAt: url),
                      "a shebang wrapper has no architecture of its own")
    }

    func testFileWithoutTheExecutableBitCannotRun() throws {
        let url = try write(thin(ExecutableArchitecture.runnable.first!), executable: false)
        XCTAssertFalse(ExecutableArchitecture.canRun(fileAt: url))
    }

    // MARK: What the app reports about FreeRDP

    /// These hold on any Mac, with or without FreeRDP installed, which is what makes them
    /// safe to run on CI: they assert the status agrees with the lookup, not which case it is.
    @MainActor
    func testStatusAgreesWithTheLookup() {
        switch Launcher.freerdpStatus {
        case .usable(let url):
            XCTAssertEqual(Launcher.freerdpURL(), url)
            XCTAssertTrue(ExecutableArchitecture.canRun(fileAt: url))
        case .wrongArchitecture(let url, _):
            XCTAssertNil(Launcher.freerdpURL(), "an unrunnable binary must not be offered")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
            XCTAssertFalse(ExecutableArchitecture.canRun(fileAt: url))
        case .absent:
            XCTAssertNil(Launcher.freerdpURL())
        }
    }

    @MainActor
    func testEveryCandidateIsAnAbsolutePath() {
        for url in Launcher.freerdpCandidates {
            XCTAssertTrue(url.path.hasPrefix("/"), "\(url.path) is not absolute")
            XCTAssertEqual(url.lastPathComponent, "sdl-freerdp")
        }
    }

    /// The candidate list is overridden so these do not depend on what FreeRDP the machine
    /// running them has installed, and so a binary for the *other* architecture — which no
    /// real install provides — can be put in front of the picker.
    @MainActor
    private func withCandidates(_ urls: [URL], _ body: () -> Void) {
        Launcher.freerdpCandidateOverride = urls
        defer { Launcher.freerdpCandidateOverride = nil }
        body()
    }

    private func otherArchitecture() throws -> UInt32 {
        let runnable = ExecutableArchitecture.runnable
        try XCTSkipIf(runnable.contains(ExecutableArchitecture.cpuARM64)
                      && runnable.contains(ExecutableArchitecture.cpuX86_64),
                      "running translated, so both architectures start")
        return runnable.contains(ExecutableArchitecture.cpuARM64)
            ? ExecutableArchitecture.cpuX86_64
            : ExecutableArchitecture.cpuARM64
    }

    @MainActor
    func testAnUnrunnableCandidateIsPassedOverForARunnableOne() throws {
        let unrunnable = try write(thin(try otherArchitecture()))
        let runnable = try write(thin(ExecutableArchitecture.runnable.first!))
        withCandidates([unrunnable, runnable]) {
            XCTAssertEqual(Launcher.freerdpURL(), runnable)
        }
    }

    /// Exactly the Intel case: the bundled binary is there, the permission bits say
    /// executable, and the old check would have handed it to `Process.run`.
    @MainActor
    func testAnUnrunnableSoleCandidateIsNotOffered() throws {
        let unrunnable = try write(thin(try otherArchitecture()))
        withCandidates([unrunnable]) {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: unrunnable.path))
            XCTAssertNil(Launcher.freerdpURL())
            guard case .wrongArchitecture(let url, let built) = Launcher.freerdpStatus else {
                return XCTFail("expected wrongArchitecture, got \(Launcher.freerdpStatus)")
            }
            XCTAssertEqual(url, unrunnable)
            XCTAssertTrue(built == "Intel" || built == "Apple Silicon", "got \(built)")
        }
    }

    @MainActor
    func testNoCandidatesReadsAsAbsent() {
        withCandidates([]) {
            XCTAssertNil(Launcher.freerdpURL())
            guard case .absent = Launcher.freerdpStatus else {
                return XCTFail("expected absent, got \(Launcher.freerdpStatus)")
            }
        }
    }

    @MainActor
    func testARunnableCandidateReadsAsUsable() throws {
        let runnable = try write(thin(ExecutableArchitecture.runnable.first!))
        withCandidates([runnable]) {
            guard case .usable(let url) = Launcher.freerdpStatus else {
                return XCTFail("expected usable, got \(Launcher.freerdpStatus)")
            }
            XCTAssertEqual(url, runnable)
        }
    }

    // MARK: Describing architectures

    func testDescribeNamesKnownArchitectures() {
        XCTAssertEqual(ExecutableArchitecture.describe([ExecutableArchitecture.cpuARM64]),
                       "Apple Silicon")
        XCTAssertEqual(ExecutableArchitecture.describe([ExecutableArchitecture.cpuX86_64]),
                       "Intel")
        XCTAssertEqual(ExecutableArchitecture.describe([ExecutableArchitecture.cpuX86_64,
                                                        ExecutableArchitecture.cpuARM64]),
                       "Intel and Apple Silicon")
    }

    func testDescribeFallsBackToTheRawType() {
        XCTAssertEqual(ExecutableArchitecture.describe([0x0100_0099]), "cpu type 16777369")
        XCTAssertEqual(ExecutableArchitecture.describe([]), "an unknown architecture")
    }
}
