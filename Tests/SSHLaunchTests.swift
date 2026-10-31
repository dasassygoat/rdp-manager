import XCTest

/// Covers the script handed to a chosen terminal. A terminal only opens an SSH session if
/// the command inside is right, and a hostname or username is user input, so quoting is
/// what keeps it from running as shell code.
@MainActor
final class SSHLaunchTests: StoreTestCase {
    private func machine(host: String, user: String = "", port: Int = 22, name: String = "alpha") -> Machine {
        var m = makeMachine(name)
        m.hostname = host
        m.username = user
        m.sshPort = port
        return m
    }

    func testCommandUsesHostAloneWithoutAUsername() {
        XCTAssertEqual(Launcher.sshCommand(for: machine(host: "nas.local")),
                       "exec ssh 'nas.local'")
    }

    func testCommandIncludesTheUsername() {
        XCTAssertEqual(Launcher.sshCommand(for: machine(host: "nas.local", user: "admin")),
                       "exec ssh 'admin@nas.local'")
    }

    func testDefaultPortIsLeftOut() {
        XCTAssertFalse(Launcher.sshCommand(for: machine(host: "nas.local", port: 22)).contains("-p"))
    }

    func testNonDefaultPortIsPassed() {
        XCTAssertEqual(Launcher.sshCommand(for: machine(host: "nas.local", port: 2222)),
                       "exec ssh -p 2222 'nas.local'")
    }

    func testResolvedAddressIsPreferredOverTheHostname() {
        var m = machine(host: "nas.local", user: "admin")
        m.lastIP = "192.168.1.9"
        XCTAssertEqual(Launcher.sshCommand(for: m), "exec ssh 'admin@192.168.1.9'")
    }

    func testAwkwardCharactersCannotEscapeTheQuotes() {
        let hostile = Launcher.sshCommand(for: machine(host: "h; rm -rf ~", user: "a'b"))
        XCTAssertEqual(hostile, "exec ssh 'a'\\''b@h; rm -rf ~'")
        XCTAssertFalse(hostile.hasSuffix("rm -rf ~"), "the command must stay inside quotes")
    }

    func testQuotingSurvivesARoundTripThroughTheShell() throws {
        // The real check: ask bash what the script would pass to ssh.
        let m = machine(host: "h o s t", user: "a'b")
        let script = Launcher.sshScript(for: m)
            .replacingOccurrences(of: "exec ssh", with: "printf '%s\\n'")
        let file = directory.appendingPathComponent("probe.command")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines),
                       "a'b@h o s t")
    }

    func testScriptIsAnExecutableBashScript() {
        let script = Launcher.sshScript(for: machine(host: "nas.local"))
        XCTAssertTrue(script.hasPrefix("#!/bin/bash\n"))
        XCTAssertTrue(script.hasSuffix("\n"), "a trailing newline keeps shells happy")
        XCTAssertTrue(script.contains("exec ssh 'nas.local'"))
    }

    func testScriptHoldsNoPassword() {
        var m = machine(host: "nas.local", user: "admin")
        m.id = UUID()
        let script = Launcher.sshScript(for: m)
        XCTAssertFalse(script.lowercased().contains("password"))
        XCTAssertFalse(script.contains("sshpass"))
    }

    func testScriptPathIsNamedAfterTheMachineAndIsSafe() {
        let url = Launcher.sshScriptURL(for: machine(host: "h", name: "Shop PC / 2"))
        XCTAssertEqual(url.lastPathComponent, "Shop_PC___2.command")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "ssh")
    }

    func testFileNameSanitiserKeepsOnlySafeCharacters() {
        XCTAssertEqual(Launcher.safeFileName("a-b_c1"), "a-b_c1")
        XCTAssertEqual(Launcher.safeFileName("../../etc/passwd"), "______etc_passwd")
        XCTAssertFalse(Launcher.safeFileName("../../etc/passwd").contains("/"),
                       "a machine name must not be able to steer the path")
    }

    // MARK: - Terminal preference

    func testRegisteredDefaultPrefersWarpWhenInstalled() throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: TerminalPreference.defaultsKey)
        TerminalPreference.registerDefaults()

        if TerminalPreference.url(forBundleID: TerminalPreference.preferredBundleID) != nil {
            XCTAssertEqual(TerminalPreference.selectedBundleID, TerminalPreference.preferredBundleID)
        } else {
            XCTAssertTrue(TerminalPreference.selectedBundleID.isEmpty,
                          "without Warp installed the system ssh:// handler stays in charge")
        }
    }

    func testAnExplicitChoiceOverridesTheRegisteredDefault() {
        let defaults = UserDefaults.standard
        TerminalPreference.registerDefaults()
        defaults.set("com.apple.Terminal", forKey: TerminalPreference.defaultsKey)
        defer { defaults.removeObject(forKey: TerminalPreference.defaultsKey) }

        XCTAssertEqual(TerminalPreference.selectedBundleID, "com.apple.Terminal")
    }

    func testChoosingTheSystemDefaultOverridesWarp() {
        let defaults = UserDefaults.standard
        TerminalPreference.registerDefaults()
        defaults.set("", forKey: TerminalPreference.defaultsKey)
        defer { defaults.removeObject(forKey: TerminalPreference.defaultsKey) }

        XCTAssertTrue(TerminalPreference.selectedBundleID.isEmpty,
                      "picking System default must beat the registered preference")
    }

    func testTerminalIsRecognisedAsRunningShellScripts() throws {
        guard let terminal = TerminalPreference.url(forBundleID: "com.apple.Terminal") else {
            throw XCTSkip("Terminal.app is not installed")
        }
        XCTAssertTrue(TerminalPreference.runsShellScripts(at: terminal),
                      "Terminal declares the Shell role, which is what the SSH path relies on")
    }

    func testAnAppThatOnlyEditsFilesIsRejected() throws {
        guard let textEdit = TerminalPreference.url(forBundleID: "com.apple.TextEdit") else {
            throw XCTSkip("TextEdit is not installed")
        }
        XCTAssertFalse(TerminalPreference.runsShellScripts(at: textEdit),
                       "an editor would show the script instead of running it")
    }

    func testAnUninstalledBundleIDHasNoURL() {
        XCTAssertNil(TerminalPreference.url(forBundleID: "com.example.not.installed"))
        XCTAssertNil(TerminalPreference.url(forBundleID: ""))
    }
}
