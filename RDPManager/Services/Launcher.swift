import AppKit
import Foundation

enum RDPClientPreference: String, CaseIterable, Identifiable {
    case auto, windowsApp, freerdp

    static let defaultsKey = "rdpClient"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Best available for each machine"
        case .windowsApp: return "Windows App only"
        case .freerdp: return "FreeRDP only"
        }
    }
}

/// Which app opens an SSH session. An empty selection means the system handler for
/// `ssh://`, which is Terminal unless the user changed it.
///
/// Terminals cannot be reached through `ssh://` unless they register for that scheme, and
/// most (Warp included) register only their own. What they do declare is a document type
/// with the `Shell` role, meaning they run a script rather than display it, so a chosen
/// terminal is handed a small `.command` file instead.
enum TerminalPreference {
    static let defaultsKey = "sshTerminalBundleID"

    /// Offered in Settings when installed. Any other app can be picked by hand.
    static let known: [(name: String, bundleID: String)] = [
        ("Terminal", "com.apple.Terminal"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("Alacritty", "org.alacritty"),
        ("Hyper", "co.zeit.hyper"),
    ]

    /// Preferred out of the box when installed. Registering it (rather than reading it as a
    /// fallback) keeps the Settings picker and the launch path showing the same thing, and
    /// an explicit choice in Settings still wins.
    static let preferredBundleID = "dev.warp.Warp-Stable"

    static func registerDefaults() {
        let fallback = url(forBundleID: preferredBundleID) != nil ? preferredBundleID : ""
        UserDefaults.standard.register(defaults: [defaultsKey: fallback])
    }

    static var selectedBundleID: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    static func url(forBundleID id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    /// The installed entries of `known`, for the Settings picker.
    static func installed() -> [(name: String, bundleID: String)] {
        known.filter { url(forBundleID: $0.bundleID) != nil }
    }

    static func name(forBundleID id: String) -> String? {
        if let known = known.first(where: { $0.bundleID == id }) { return known.name }
        guard let url = url(forBundleID: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// True when the app declares a document type it runs rather than opens for editing.
    /// Without this a `.command` file would be shown in a text editor, not executed.
    static func runsShellScripts(at url: URL) -> Bool {
        guard let types = Bundle(url: url)?.infoDictionary?["CFBundleDocumentTypes"]
                as? [[String: Any]] else { return false }
        return types.contains { ($0["CFBundleTypeRole"] as? String) == "Shell" }
    }
}

enum LaunchError: LocalizedError {
    case noClient(String)
    case badAddress
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noClient(let s): return s
        case .badAddress: return "The machine's address could not be turned into a URL."
        case .failed(let s): return s
        }
    }
}

/// Hands a machine off to the right client application.
@MainActor
enum Launcher {
    static let windowsAppBundleIDs = ["com.microsoft.rdc.macos"]
    static let windowsAppStoreURL = URL(string: "https://apps.apple.com/app/id1295203466")!

    static func windowsAppURL() -> URL? {
        for id in windowsAppBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// The bundled FreeRDP client first, then a Homebrew install.
    static var defaultFreeRDPCandidates: [URL] {
        [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/freerdp/bin/sdl-freerdp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/sdl-freerdp"),
            URL(fileURLWithPath: "/usr/local/bin/sdl-freerdp"),
        ]
    }

    /// Set by tests, which need candidates that do not depend on what the machine running
    /// them happens to have installed — in particular a binary for the architecture this
    /// Mac is not, which no real install would provide.
    static var freerdpCandidateOverride: [URL]?

    static var freerdpCandidates: [URL] {
        freerdpCandidateOverride ?? defaultFreeRDPCandidates
    }

    /// Only a binary this Mac can actually start counts. The bundled FreeRDP carries the
    /// architecture of the Mac that packaged it, so on an Intel Mac it is present and
    /// executable yet cannot run; skipping it here lets `.auto` fall through to Windows App
    /// instead of surfacing "Bad CPU type in executable".
    static func freerdpURL() -> URL? {
        freerdpCandidates.first { ExecutableArchitecture.canRun(fileAt: $0) }
    }

    /// Present but unrunnable is worth telling apart from absent, in Settings and in the
    /// alert: the two have different remedies.
    enum FreeRDPStatus {
        case usable(URL)
        case wrongArchitecture(URL, builtFor: String)
        case absent
    }

    static var freerdpStatus: FreeRDPStatus {
        if let url = freerdpURL() { return .usable(url) }
        guard let present = freerdpCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { return .absent }
        return .wrongArchitecture(present, builtFor: ExecutableArchitecture.describe(
            ExecutableArchitecture.architectures(ofFileAt: present)))
    }

    static var rdpPreference: RDPClientPreference {
        RDPClientPreference(rawValue: UserDefaults.standard.string(forKey: RDPClientPreference.defaultsKey) ?? "") ?? .auto
    }

    static func connect(_ machine: Machine, via type: ConnectionType) throws {
        switch type {
        case .rdp: try rdp(machine)
        case .vnc: try vnc(machine)
        case .ssh: try ssh(machine)
        case .web: try web(machine)
        }
    }

    // MARK: RDP

    enum RDPRoute: Equatable { case windowsApp, freerdp }

    /// Looked up through a property so the routing tests can say what is saved without a
    /// real Keychain item for a machine that does not exist.
    static var savedPassword: (UUID) -> String? = { Keychain.password(for: $0) }

    static func hasSavedPassword(_ machine: Machine) -> Bool {
        !(savedPassword(machine.id) ?? "").isEmpty
    }

    /// Which client `.auto` picks. A saved password decides it, because only FreeRDP can
    /// be handed one: a .rdp file carries a password in `password 51:b:`, which is a
    /// Windows DPAPI blob, and the Mac build of Windows App has no code for that field at
    /// all. So however the file is written, Windows App asks for the password again every
    /// time — which is what made saved passwords look like they were never remembered.
    /// Windows App does remember credentials, but only for connections created inside it,
    /// not for a file it is handed.
    nonisolated static func autoRoute(hasWindowsApp: Bool, hasFreeRDP: Bool,
                                      hasSavedPassword: Bool) -> RDPRoute? {
        if hasSavedPassword, hasFreeRDP { return .freerdp }
        if hasWindowsApp { return .windowsApp }
        if hasFreeRDP { return .freerdp }
        return nil
    }

    static func rdp(_ machine: Machine) throws {
        let windowsApp = windowsAppURL()
        let freerdp = freerdpURL()
        switch rdpPreference {
        case .windowsApp:
            guard let windowsApp else { throw LaunchError.noClient(missingWindowsApp) }
            try rdpViaWindowsApp(machine, app: windowsApp)
        case .freerdp:
            guard let freerdp else { throw LaunchError.noClient(missingFreeRDP) }
            try rdpViaFreeRDP(machine, executable: freerdp)
        case .auto:
            switch autoRoute(hasWindowsApp: windowsApp != nil, hasFreeRDP: freerdp != nil,
                             hasSavedPassword: hasSavedPassword(machine)) {
            case .freerdp:
                guard let freerdp else { throw LaunchError.noClient(missingFreeRDP) }
                try rdpViaFreeRDP(machine, executable: freerdp)
            case .windowsApp:
                guard let windowsApp else { throw LaunchError.noClient(missingWindowsApp) }
                try rdpViaWindowsApp(machine, app: windowsApp)
            case nil:
                throw LaunchError.noClient(missingWindowsApp + "\n\n" + missingFreeRDP)
            }
        }
    }

    private static let missingWindowsApp =
        "Windows App is not installed. Get it free from the Mac App Store (search for \"Windows App\")."
    /// Separates the two reasons FreeRDP is unavailable, because "not found" is wrong and
    /// unactionable when the binary is right there but built for another architecture.
    private static var missingFreeRDP: String {
        switch freerdpStatus {
        case .wrongArchitecture(let url, let built):
            return "The FreeRDP at \(url.path) is built for \(built) and cannot run on this "
                + "Mac. Use Windows App instead, or install a native build with: "
                + "brew install freerdp."
        case .usable, .absent:
            return "FreeRDP was not found in the app bundle or at /opt/homebrew/bin/sdl-freerdp (install with: brew install freerdp)."
        }
    }

    /// Machine names become filenames, so anything that is not a letter, digit, dash or
    /// underscore is replaced.
    static func safeFileName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    static func rdpFileURL(for machine: Machine) -> URL {
        MachineStore.defaultDirectory
            .appendingPathComponent("rdp", isDirectory: true)
            .appendingPathComponent(safeFileName(machine.name) + ".rdp")
    }

    /// The .rdp file handed to Windows App. Separate from writing it so the tests can read
    /// what a machine turns into without launching anything.
    static func rdpFileContents(for machine: Machine) -> String {
        var lines = [
            "full address:s:\(machine.connectHost):\(machine.rdpPort)",
            "screen mode id:i:2",
            "use multimon:i:0",
            "session bpp:i:32",
            "audiomode:i:\(machine.audio.rdpValue)",
            "redirectclipboard:i:1",
            "authentication level:i:2",
            "prompt for credentials:i:0",
            "smart sizing:i:1",
            "dynamic resolution:i:1",
        ]
        if !machine.username.isEmpty { lines.append("username:s:\(machine.username)") }
        return lines.joined(separator: "\r\n")
    }

    private static func rdpViaWindowsApp(_ machine: Machine, app: URL) throws {
        let file = rdpFileURL(for: machine)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rdpFileContents(for: machine).write(to: file, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in AppAlerts.show("Could not open Windows App", error.localizedDescription) }
            }
        }
    }

    /// Everything FreeRDP is given for a machine: its command line, and whatever has to
    /// reach it down standard input instead.
    ///
    /// The password used to be `/p:` on the command line, where it stayed in the process
    /// arguments for as long as the session lasted — `ps` shows those to anything else
    /// running as this user, so a saved password was readable by any other program on the
    /// Mac. `/from-stdin` has FreeRDP ask for what it was not given on standard input,
    /// which is a pipe between the two processes and appears nowhere else.
    struct FreeRDPInvocation: Equatable {
        var arguments: [String]
        /// Fed to the process's standard input, in the order FreeRDP asks for it. Nil when
        /// there is nothing to hand over and the command line says everything.
        var standardInput: String?
    }

    /// Built apart from running it so the tests can check what gets passed.
    static func freeRDPInvocation(for machine: Machine) -> FreeRDPInvocation {
        var args = [
            "/v:\(machine.connectHost):\(machine.rdpPort)",
            "/cert:ignore",
            "/dynamic-resolution",
            "+clipboard",
            "/title:\(machine.name)",
            // Spelled out rather than left to the default, so the two clients agree:
            // unasked, FreeRDP opens no audio channel and Windows App redirects to here.
            "/audio-mode:\(machine.audio.rdpValue)",
        ]
        if !machine.username.isEmpty {
            let user = machine.username
            if let backslash = user.firstIndex(of: "\\") {
                args.append("/d:\(user[..<backslash])")
                args.append("/u:\(user[user.index(after: backslash)...])")
            } else {
                args.append("/u:\(user)")
            }
        }
        // Only with a username to go with it. FreeRDP asks on stdin for each thing it is
        // missing, in the order username, domain, password, so sending a password while the
        // username is also absent would answer the wrong question with it. A saved password
        // and no username is a half-filled machine either way: FreeRDP asks for both in its
        // own window, as it did before any password was saved.
        if let password = savedPassword(machine.id), !password.isEmpty,
           !machine.username.isEmpty {
            args.append("/from-stdin")
            return FreeRDPInvocation(arguments: args, standardInput: password + "\n")
        }
        return FreeRDPInvocation(arguments: args, standardInput: nil)
    }

    /// Just the command line. Kept because most callers and tests only care about that, and
    /// because it is the half that is safe to log.
    static func freeRDPArguments(for machine: Machine) -> [String] {
        freeRDPInvocation(for: machine).arguments
    }

    private static func rdpViaFreeRDP(_ machine: Machine, executable: URL) throws {
        let invocation = freeRDPInvocation(for: machine)
        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        if let modules = opensslModulesDirectory(forExecutableAt: executable) {
            var environment = ProcessInfo.processInfo.environment
            environment["OPENSSL_MODULES"] = modules.path
            process.environment = environment
        }

        // The pipe has to be in place before the process starts, or FreeRDP reads this
        // app's own standard input — which, launched from the Finder, is /dev/null, and the
        // session would fail as though the password were wrong.
        let input = invocation.standardInput.map { _ in Pipe() }
        if let input { process.standardInput = input }

        do {
            try process.run()
        } catch {
            throw LaunchError.failed("FreeRDP failed to start: \(error.localizedDescription)")
        }

        if let input, let credentials = invocation.standardInput {
            // Written after the fork so a password longer than the pipe buffer cannot
            // deadlock, and closed straight after so FreeRDP sees the end of it and does not
            // sit waiting for a second line.
            try? input.fileHandleForWriting.write(contentsOf: Data(credentials.utf8))
            try? input.fileHandleForWriting.close()
        }
    }

    /// Where the bundled FreeRDP's OpenSSL should look for its provider modules.
    ///
    /// OpenSSL finds providers through a directory compiled into libcrypto, which points
    /// at the Homebrew keg on whichever Mac built the bundle — a path that is wrong once
    /// the library is copied into the app and absent entirely on anyone else's Mac. The
    /// provider that matters is the legacy one, because it is the only source of MD4;
    /// without MD4 there is no NTLM, and NLA then fails with SEC_E_NO_CREDENTIALS no
    /// matter how correct the password is. That is a saved password looking ignored.
    ///
    /// Returns nil when there is no bundled copy — a FreeRDP installed by Homebrew finds
    /// its own providers, and pointing it at a directory that does not exist would break
    /// the one case that currently works.
    nonisolated static func opensslModulesDirectory(
        forExecutableAt url: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let directory = url
            .deletingLastPathComponent()    // …/freerdp/bin
            .deletingLastPathComponent()    // …/freerdp
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("ossl-modules", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory
    }

    // MARK: VNC / SSH / Web

    static func vnc(_ machine: Machine) throws {
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = machine.connectHost
        components.port = machine.vncPort
        if !machine.username.isEmpty {
            components.user = machine.username
            components.password = Keychain.password(for: machine.id)
        }
        guard let url = components.url else { throw LaunchError.badAddress }
        NSWorkspace.shared.open(url)
    }

    static func ssh(_ machine: Machine) throws {
        let id = TerminalPreference.selectedBundleID
        guard !id.isEmpty else { return try sshViaURLScheme(machine) }
        guard let app = TerminalPreference.url(forBundleID: id) else {
            throw LaunchError.noClient(
                "The terminal chosen in Settings → Connections is no longer installed. "
                + "Pick another one, or choose the system default.")
        }
        guard TerminalPreference.runsShellScripts(at: app) else {
            let name = TerminalPreference.name(forBundleID: id) ?? app.lastPathComponent
            throw LaunchError.noClient(
                "\(name) does not run shell scripts, so it cannot be handed an SSH command. "
                + "Choose a different terminal in Settings → Connections.")
        }
        try sshViaTerminalApp(machine, app: app)
    }

    private static func sshViaURLScheme(_ machine: Machine) throws {
        var components = URLComponents()
        components.scheme = "ssh"
        components.host = machine.connectHost
        components.port = machine.sshPort
        if !machine.username.isEmpty { components.user = machine.username }
        guard let url = components.url else { throw LaunchError.badAddress }
        NSWorkspace.shared.open(url)
    }

    static func sshScriptURL(for machine: Machine) -> URL {
        MachineStore.defaultDirectory
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent(safeFileName(machine.name) + ".command")
    }

    /// Single-quoted for the shell, so a hostname or username with surprising characters
    /// cannot run as part of the command.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func sshCommand(for machine: Machine) -> String {
        let target = machine.username.isEmpty
            ? machine.connectHost
            : "\(machine.username)@\(machine.connectHost)"
        var command = "exec ssh"
        if machine.sshPort != 22 { command += " -p \(machine.sshPort)" }
        return command + " " + shellQuoted(target)
    }

    static func sshScript(for machine: Machine) -> String {
        """
        #!/bin/bash
        # Written by RDP Manager so your chosen terminal opens this SSH session.
        # Rewritten on every connection; safe to delete.
        \(sshCommand(for: machine))
        """ + "\n"
    }

    /// Terminals that declare the `Shell` document role run an executable script handed to
    /// them, which is how an SSH session lands in a specific terminal rather than whichever
    /// app happens to own `ssh://`.
    private static func sshViaTerminalApp(_ machine: Machine, app: URL) throws {
        let file = sshScriptURL(for: machine)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sshScript(for: machine).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            throw LaunchError.failed("Could not write the SSH command: \(error.localizedDescription)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor in
                    AppAlerts.show("Could not open \(app.lastPathComponent)", error.localizedDescription)
                }
            }
        }
    }

    static func web(_ machine: Machine) throws {
        guard let url = machine.webTarget else { throw LaunchError.badAddress }
        NSWorkspace.shared.open(url)
    }

    static func wake(_ machine: Machine) throws {
        try WakeOnLAN.send(mac: machine.macAddress, directedBroadcast: machine.broadcastAddress)
    }
}

@MainActor
enum AppAlerts {
    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
func connect(_ machine: Machine, via type: ConnectionType) {
    do {
        try Launcher.connect(machine, via: type)
    } catch {
        AppAlerts.show("Could not connect to \(machine.name)", error.localizedDescription)
    }
}

@MainActor
func wake(_ machine: Machine) {
    do {
        try Launcher.wake(machine)
    } catch {
        AppAlerts.show("Could not wake \(machine.name)", error.localizedDescription)
    }
}
