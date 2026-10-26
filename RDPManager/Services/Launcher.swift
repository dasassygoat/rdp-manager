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

    static func rdpFileURL(for machine: Machine) -> URL {
        let safe = machine.name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return MachineStore.defaultDirectory
            .appendingPathComponent("rdp", isDirectory: true)
            .appendingPathComponent(String(safe) + ".rdp")
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
        var components = URLComponents()
        components.scheme = "ssh"
        components.host = machine.connectHost
        components.port = machine.sshPort
        if !machine.username.isEmpty { components.user = machine.username }
        guard let url = components.url else { throw LaunchError.badAddress }
        NSWorkspace.shared.open(url)
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
