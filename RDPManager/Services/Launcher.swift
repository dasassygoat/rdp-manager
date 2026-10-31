import AppKit
import Foundation

enum RDPClientPreference: String, CaseIterable, Identifiable {
    case auto, windowsApp, freerdp

    static let defaultsKey = "rdpClient"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Windows App, then FreeRDP"
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
    static func freerdpURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/freerdp/bin/sdl-freerdp")
        let candidates = [
            bundled,
            URL(fileURLWithPath: "/opt/homebrew/bin/sdl-freerdp"),
            URL(fileURLWithPath: "/usr/local/bin/sdl-freerdp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
            if let windowsApp {
                try rdpViaWindowsApp(machine, app: windowsApp)
            } else if let freerdp {
                try rdpViaFreeRDP(machine, executable: freerdp)
            } else {
                throw LaunchError.noClient(missingWindowsApp + "\n\n" + missingFreeRDP)
            }
        }
    }

    private static let missingWindowsApp =
        "Windows App is not installed. Get it free from the Mac App Store (search for \"Windows App\")."
    private static let missingFreeRDP =
        "FreeRDP was not found in the app bundle or at /opt/homebrew/bin/sdl-freerdp (install with: brew install freerdp)."

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

    private static func rdpViaWindowsApp(_ machine: Machine, app: URL) throws {
        var lines = [
            "full address:s:\(machine.connectHost):\(machine.rdpPort)",
            "screen mode id:i:2",
            "use multimon:i:0",
            "session bpp:i:32",
            "audiomode:i:0",
            "redirectclipboard:i:1",
            "authentication level:i:2",
            "prompt for credentials:i:0",
            "smart sizing:i:1",
            "dynamic resolution:i:1",
        ]
        if !machine.username.isEmpty { lines.append("username:s:\(machine.username)") }
        let file = rdpFileURL(for: machine)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\r\n").write(to: file, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in AppAlerts.show("Could not open Windows App", error.localizedDescription) }
            }
        }
    }

    private static func rdpViaFreeRDP(_ machine: Machine, executable: URL) throws {
        var args = [
            "/v:\(machine.connectHost):\(machine.rdpPort)",
            "/cert:ignore",
            "/dynamic-resolution",
            "+clipboard",
            "/title:\(machine.name)",
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
        if let password = Keychain.password(for: machine.id) {
            args.append("/p:\(password)")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        do {
            try process.run()
        } catch {
            throw LaunchError.failed("FreeRDP failed to start: \(error.localizedDescription)")
        }
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
