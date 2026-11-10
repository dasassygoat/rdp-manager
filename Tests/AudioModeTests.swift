import XCTest

/// Where a session's sound comes out. The two RDP clients take the same three numbers but
/// disagree about what happens when nobody says, so both are pinned here.
@MainActor
final class AudioModeTests: StoreTestCase {
    private func machine(_ audio: AudioMode) -> Machine {
        var m = makeMachine("alpha")
        m.hostname = "alpha.local"
        m.lastIP = "192.168.1.5"
        m.audio = audio
        return m
    }

    // MARK: The numbers both clients take

    /// These are RDP's own values, not ours to choose: 0 redirects the sound to the
    /// client, 1 leaves it on the server, 2 plays it nowhere. Getting one wrong sends
    /// audio to the opposite machine, which no test above this level would notice.
    func testTheValuesAreTheOnesRDPDefines() {
        XCTAssertEqual(AudioMode.thisMac.rdpValue, 0)
        XCTAssertEqual(AudioMode.remote.rdpValue, 1)
        XCTAssertEqual(AudioMode.off.rdpValue, 2)
    }

    func testEveryModeIsOfferedAndNamed() {
        XCTAssertEqual(AudioMode.allCases.count, 3)
        for mode in AudioMode.allCases {
            XCTAssertFalse(mode.label.isEmpty, "\(mode) needs a label for the picker")
        }
    }

    // MARK: Reaching Windows App

    func testTheRDPFileCarriesTheChosenMode() {
        XCTAssertTrue(Launcher.rdpFileContents(for: machine(.remote))
            .contains("audiomode:i:1"))
        XCTAssertTrue(Launcher.rdpFileContents(for: machine(.thisMac))
            .contains("audiomode:i:0"))
        XCTAssertTrue(Launcher.rdpFileContents(for: machine(.off))
            .contains("audiomode:i:2"))
    }

    /// Windows App reads a .rdp file as CRLF-separated key lines; the setting has to be
    /// its own line or it is simply not seen.
    func testTheModeIsOnALineOfItsOwn() {
        let lines = Launcher.rdpFileContents(for: machine(.remote))
            .components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains("audiomode:i:1"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("audiomode:") }.count, 1,
                       "two audiomode lines would leave the winner to the parser")
    }

    // MARK: Reaching FreeRDP

    func testFreeRDPIsToldTheSameMode() {
        XCTAssertTrue(Launcher.freeRDPArguments(for: machine(.remote))
            .contains("/audio-mode:1"))
        XCTAssertTrue(Launcher.freeRDPArguments(for: machine(.thisMac))
            .contains("/audio-mode:0"))
        XCTAssertTrue(Launcher.freeRDPArguments(for: machine(.off))
            .contains("/audio-mode:2"))
    }

    /// Left unsaid, the two clients do opposite things — FreeRDP opens no audio channel
    /// and Windows App redirects to this Mac — so the argument has to always be passed,
    /// not only when it differs from some default.
    func testTheModeIsAlwaysPassedToFreeRDP() {
        for mode in AudioMode.allCases {
            let args = Launcher.freeRDPArguments(for: machine(mode))
            XCTAssertEqual(args.filter { $0.hasPrefix("/audio-mode:") }.count, 1,
                           "\(mode) should pass exactly one audio mode")
        }
    }

    // MARK: Stored per machine

    func testMachinesKeepTheirOwnSetting() throws {
        let store = makeStore()
        var quiet = makeMachine("quiet"); quiet.audio = .off
        var here = makeMachine("here"); here.audio = .thisMac
        store.add(quiet)
        store.add(here)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.machines.first { $0.name == "quiet" }?.audio, .off)
        XCTAssertEqual(reloaded.machines.first { $0.name == "here" }?.audio, .thisMac)
    }

    /// A machine list written before this setting existed — or by an older copy of the
    /// app on another Mac — has no such field, and must still load.
    func testAFileWithoutTheFieldStillLoads() throws {
        let json = """
        {"version":1,"machines":[{"id":"\(UUID().uuidString)","name":"legacy",
          "hostname":"legacy.local","kind":"windows","primary":"rdp"}]}
        """
        try Data(json.utf8).write(to: storeURL)
        let store = makeStore()
        let machine = try XCTUnwrap(store.machines.first)
        XCTAssertEqual(machine.name, "legacy")
        XCTAssertEqual(machine.audio, .remote, "the default is to leave sound where it is")
    }

    /// The default matters: it is what every machine already in the list gets.
    func testANewMachineLeavesSoundOnTheRemoteMachine() {
        XCTAssertEqual(Machine().audio, .remote)
        XCTAssertTrue(Launcher.rdpFileContents(for: makeMachine("fresh"))
            .contains("audiomode:i:1"))
    }
}
