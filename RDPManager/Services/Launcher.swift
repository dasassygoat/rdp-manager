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
    /// The person closed the sign-in prompt. Nothing to report.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noClient(let s): return s
        case .badAddress: return "The machine's address could not be turned into a URL."
        case .failed(let s): return s
        case .cancelled: return "Cancelled."
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

    /// Shared sign-ins live in the store, which this does not own, so it is a seam for the
    /// same reason. Only consulted for a machine that actually points at one.
    static var credentialSet: (UUID) -> CredentialSet? = { MachineStore.shared.credential($0) }

    /// Who to sign in as, and where the password for it is kept.
    struct Login: Equatable {
        var username = ""
        var domain = ""
        /// The Keychain account holding the password: the shared sign-in's id when the
        /// machine uses one, and otherwise the machine's own.
        var passwordKey: UUID
    }

    static func login(for machine: Machine) -> Login {
        if let id = machine.credentialID, let set = credentialSet(id) {
            return Login(username: set.username, domain: set.domain, passwordKey: set.id)
        }
        let own = machine.login
        return Login(username: own.username, domain: own.domain, passwordKey: machine.id)
    }

    static func hasSavedPassword(_ machine: Machine) -> Bool {
        !(savedPassword(login(for: machine).passwordKey) ?? "").isEmpty
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
            "use multimon:i:\(machine.multipleMonitors ? 1 : 0)",
            "session bpp:i:32",
            "audiomode:i:\(machine.audio.rdpValue)",
            "redirectclipboard:i:\(machine.shareClipboard ? 1 : 0)",
            "desktopscalefactor:i:\(machine.displayScale)",
            "authentication level:i:2",
            "prompt for credentials:i:0",
            "smart sizing:i:1",
            "dynamic resolution:i:1",
        ]
        let login = Self.login(for: machine)
        if !login.username.isEmpty { lines.append("username:s:\(login.username)") }
        if !login.domain.isEmpty { lines.append("domain:s:\(login.domain)") }
        if !machine.gateway.isEmpty {
            // 1 is "use these gateway settings"; 4 tells it to ask for the gateway's own
            // credentials rather than assuming the session's will do.
            lines.append("gatewayhostname:s:\(machine.gateway)")
            lines.append("gatewayusagemethod:i:1")
            lines.append("gatewaycredentialssource:i:4")
            lines.append("gatewayprofileusagemethod:i:1")
        }
        // No folder line: Windows App does not take one from a .rdp file it is handed, so
        // writing one would promise something that silently does not happen.
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

    /// Built apart from running it so the tests can check what gets passed. Uses the
    /// machine's own login and whatever password is saved for it.
    static func freeRDPInvocation(for machine: Machine) -> FreeRDPInvocation {
        let login = Self.login(for: machine)
        return freeRDPInvocation(for: machine, login: login, password: savedPassword(login.passwordKey))
    }

    /// The same, for a login and password decided by the caller: what the person just typed
    /// into the sign-in prompt when nothing was saved.
    static func freeRDPInvocation(for machine: Machine, login: Login, password: String?) -> FreeRDPInvocation {
        var args = [
            "/v:\(machine.connectHost):\(machine.rdpPort)",
            "/cert:ignore",
            "/dynamic-resolution",
            machine.shareClipboard ? "+clipboard" : "-clipboard",
            "/title:\(machine.name)",
            // Spelled out rather than left to the default, so the two clients agree:
            // unasked, FreeRDP opens no audio channel and Windows App redirects to here.
            "/audio-mode:\(machine.audio.rdpValue)",
        ]
        if machine.multipleMonitors { args.append("/multimon") }
        if !machine.gateway.isEmpty {
            // Username and domain but no password: a password here would be back in the
            // process arguments, which is what /from-stdin exists to avoid. FreeRDP asks
            // for the gateway's password itself when it needs one.
            var gateway = "g:\(machine.gateway)"
            if !login.username.isEmpty { gateway += ",u:\(login.username)" }
            if !login.domain.isEmpty { gateway += ",d:\(login.domain)" }
            args.append("/gateway:\(gateway)")
        }
        if machine.displayScale != 100 { args.append("/scale:\(machine.displayScale)") }
        if !machine.sharedFolder.isEmpty {
            // Named for what it is on the far side. The share only lasts the session.
            args.append("/drive:Mac,\(machine.sharedFolder)")
        }
        if !login.domain.isEmpty { args.append("/d:\(login.domain)") }
        if !login.username.isEmpty { args.append("/u:\(login.username)") }
        // Only with a username to go with it: the SDL client reads just the password from
        // stdin, so a password without a username would leave it asking for the username in
        // a prompt it cannot show (see rdpViaFreeRDP).
        if let password, !password.isEmpty, !login.username.isEmpty {
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
        // FreeRDP cannot ask for a password itself when started from here: its prompt needs
        // a terminal, and without one it gives up at once with ERRCONNECT_CONNECT_CANCELLED,
        // which looked like nothing happening at all. So the asking is done in this app.
        var login = Self.login(for: machine)
        var password = savedPassword(login.passwordKey) ?? ""
        if password.isEmpty {
            guard let typed = CredentialPrompt.ask(for: machine, login: login) else {
                throw LaunchError.cancelled
            }
            login = typed.login(passwordKey: login.passwordKey)
            password = typed.password
            if typed.remember {
                Keychain.setPassword(password, for: login.passwordKey)
                // The username is part of the machine record, so a different one typed here
                // is kept there too — unless the machine signs in with a shared set, whose
                // name is edited in Settings.
                if machine.credentialID == nil, typed.username != machine.username {
                    var updated = machine
                    updated.username = typed.username
                    updated.domain = ""
                    MachineStore.shared.update(updated)
                }
            }
        }
        let invocation = freeRDPInvocation(for: machine, login: login, password: password)
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

        // Everything FreeRDP prints is kept, because when a session fails to start the
        // client's own error dialog closes with the process, and that log is the only place
        // the reason survives. It is read on a background handler so a chatty session can
        // never fill the pipe and stall.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let collector = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        let started = Date()
        let logFile = sessionLogURL(for: machine)
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            collector.append(output.fileHandleForReading.readDataToEndOfFile())
            let log = collector.text
            let status = finished.terminationStatus
            let lifetime = Date().timeIntervalSince(started)
            // The whole run, kept on disk: when a session ends in a way the rules below
            // decide not to mention, this file is still there to say what happened.
            let record = """
            RDP Manager FreeRDP session log
            machine:   \(machine.name)
            started:   \(started.formatted(date: .numeric, time: .standard))
            command:   \(executable.path) \(invocation.arguments.joined(separator: " "))
            exit:      status \(status) after \(Int(lifetime.rounded())) s

            \(log)
            """
            try? FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? record.write(to: logFile, atomically: true, encoding: .utf8)
            Task { @MainActor in
                FreeRDPDiagnostics.report(machine: machine, status: status, lifetime: lifetime,
                                          log: log, logFile: logFile)
            }
        }

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

    /// One file per machine, rewritten on every FreeRDP run.
    static func sessionLogURL(for machine: Machine) -> URL {
        StoreLocation.defaultDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("freerdp-" + safeFileName(machine.name) + ".log")
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
        let login = Self.login(for: machine)
        if !login.username.isEmpty {
            components.user = login.username
            components.password = savedPassword(login.passwordKey)
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
        let user = Self.login(for: machine).username
        if !user.isEmpty { components.user = user }
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
        // The username only; the password is deliberately never written into the script.
        let user = Self.login(for: machine).username
        let target = user.isEmpty
            ? machine.connectHost
            : "\(user)@\(machine.connectHost)"
        var command = "exec ssh"
        if machine.sshPort != 22 { command += " -p \(machine.sshPort)" }
        // -J makes ssh open the session through the jump host, so the machine only has to
        // be reachable from there and not from here.
        if !machine.jumpHost.isEmpty {
            command += " -J " + shellQuoted(machine.jumpHost)
        }
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
        // The real subnet broadcast when this Mac shares a network with the machine, and the
        // /24 guess only when it does not.
        let directed = WakeOnLAN.directedBroadcast(for: machine.lastIP) ?? machine.broadcastAddress
        try WakeOnLAN.send(mac: machine.macAddress, directedBroadcast: directed)
    }
}

/// Thread-safe accumulator for a child process's output.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Turns how FreeRDP ended into something a person can act on, or into nothing when the
/// session simply ended.
@MainActor
enum FreeRDPDiagnostics {
    /// Whether an exit is worth an alert, and what to say. Pure so the tests can feed it
    /// real FreeRDP logs.
    nonisolated static func explanation(status: Int32, lifetime: TimeInterval, log: String,
                                        host: String) -> String? {
        guard status != 0 else { return nil }
        let text = log.lowercased()
        // FreeRDP's own password prompt needs a terminal; without one it cancels itself
        // within a second or two. The app asks for the password first so this should not
        // happen, but if it does it must not pass for the person cancelling.
        if text.contains("connect_cancelled") && lifetime < 5 {
            return "FreeRDP needed a password for \(host) and could not ask for one. Save a password for this machine with Edit, or enter it when the app asks."
        }
        // A session the user or the server ended on purpose.
        if text.contains("connect_cancelled") || text.contains("logoff_by_user")
            || text.contains("disconnect_by_user") || text.contains("disconnected by user")
            || text.contains("rpc_initiated_disconnect") {
            return nil
        }
        let failedToStart = text.contains("errconnect") || text.contains("authentication_failed")
            || text.contains("[error]") || text.contains("[warn]")
        // A session that ran for a while and then ended without a complaint is a normal end
        // (the client's exit code is not zero for those either). Anything shorter than a
        // minute that nobody ended on purpose is a session that did not happen.
        guard failedToStart || lifetime < 60 else { return nil }

        if text.contains("logon_failure") || text.contains("authentication_failed")
            || text.contains("authentication failure") || text.contains("wrong_password")
            || text.contains("no_credentials") {
            return "The username or password was rejected. Check them with Edit. For a domain-joined PC use DOMAIN\\user; for a local account on a Mac running Pro RDP use the macOS short name."
        }
        if text.contains("account_locked") { return "The account is locked out on the target machine." }
        if text.contains("password_expired") || text.contains("password_must_change") {
            return "The password has expired and must be changed on the target machine first."
        }
        if text.contains("account_disabled") { return "The account is disabled on the target machine." }
        if text.contains("dns_name_not_found") || text.contains("dns_error") || text.contains("name not found") {
            return "The hostname could not be resolved."
        }
        if text.contains("connection refused") || text.contains("transport_failed")
            || text.contains("connect_failed") || text.contains("timed out") || text.contains("unreachable")
            || text.contains("connection reset") {
            return "Nothing answered on \(host). Check that the machine is on, Remote Desktop is enabled, and the firewall allows that port."
        }
        if text.contains("security_nego") || text.contains("credssp") || text.contains("nla") {
            return "Security negotiation failed with \(host). The target may require Network Level Authentication with a domain account, or a different security level."
        }
        if text.contains("tls") || text.contains("ssl") {
            return "The TLS handshake with \(host) failed."
        }
        return "FreeRDP exited with code \(status) while connecting to \(host)."
    }

    static func report(machine: Machine, status: Int32, lifetime: TimeInterval, log: String,
                       logFile: URL? = nil) {
        let host = "\(machine.connectHost):\(machine.rdpPort)"
        guard let reason = explanation(status: status, lifetime: lifetime, log: log, host: host) else { return }
        let tail = log.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("password") }
            .suffix(6)
            .joined(separator: "\n")
        var message = reason
        if !tail.isEmpty { message += "\n\nFreeRDP output:\n" + tail }
        if let logFile { message += "\n\nFull log: \(logFile.path)" }
        AppAlerts.show("Could not connect to \(machine.name)", message)
    }
}

/// What the person typed into the sign-in prompt.
struct TypedCredentials: Equatable {
    var username: String
    var password: String
    var remember: Bool

    /// "DOMAIN\\user" becomes a domain and a user; "user@domain" is left for FreeRDP to split.
    nonisolated func login(passwordKey: UUID) -> Launcher.Login {
        if let slash = username.firstIndex(of: "\\") {
            return Launcher.Login(username: String(username[username.index(after: slash)...]),
                                  domain: String(username[..<slash]), passwordKey: passwordKey)
        }
        return Launcher.Login(username: username, domain: "", passwordKey: passwordKey)
    }
}

/// The sign-in sheet shown when a machine has no saved password.
@MainActor
enum CredentialPrompt {
    static func ask(for machine: Machine, login: Launcher.Login) -> TypedCredentials? {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(machine.name)"
        alert.informativeText = "No password is saved for this machine. Enter the account to use for the Remote Desktop session."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let prefilled = login.domain.isEmpty ? login.username : "\(login.domain)\\\(login.username)"
        let userField = NSTextField(string: prefilled)
        userField.placeholderString = "Username, or DOMAIN\\user"
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "Password"
        let remember = NSButton(checkboxWithTitle: "Remember in this Mac's Keychain", target: nil, action: nil)
        remember.state = .on

        let stack = NSStackView(views: [userField, passwordField, remember])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for field in [userField, passwordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 86)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = prefilled.isEmpty ? userField : passwordField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let username = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        guard !username.isEmpty, !password.isEmpty else { return nil }
        return TypedCredentials(username: username, password: password, remember: remember.state == .on)
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

    /// Returns true when the user picks `confirmTitle`.
    static func confirm(_ title: String, _ message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Whether to try the service port before handing off. Not when the session goes through
/// a gateway or jump host, since the machine then only has to be reachable from there.
nonisolated func shouldProbeBeforeConnecting(_ machine: Machine, via type: ConnectionType) -> Bool {
    switch type {
    case .web: return false
    case .rdp: return machine.gateway.isEmpty
    case .ssh: return machine.jumpHost.isEmpty
    case .vnc: return true
    }
}

/// Connect from the UI. The service port is tried first, so a machine that is off or has
/// the service disabled is reported here instead of by a client that fails out of sight.
@MainActor
func connect(_ machine: Machine, via type: ConnectionType) {
    Task { @MainActor in
        if shouldProbeBeforeConnecting(machine, via: type) {
            let port = machine.port(for: type)
            let reachable = await Prober.tcpOpen(host: machine.connectHost, port: port, timeout: 2)
            if !reachable {
                let proceed = AppAlerts.confirm(
                    "\(machine.name) is not answering on port \(port)",
                    "No response from \(machine.connectHost) on port \(port) (\(type.label)). The machine may be off, asleep, blocking the port, or the service may not be enabled.\n\nConnect anyway?",
                    confirmTitle: "Connect Anyway")
                if !proceed { return }
            }
        }
        do {
            try Launcher.connect(machine, via: type)
            // Only once it started. A session that could not launch is not one you were on.
            ConnectionLog.shared.record(machine, via: type)
        } catch LaunchError.cancelled {
            return
        } catch {
            AppAlerts.show("Could not connect to \(machine.name)", error.localizedDescription)
        }
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
