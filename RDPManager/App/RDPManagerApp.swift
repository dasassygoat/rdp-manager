import SwiftUI
import UserNotifications

@main
struct RDPManagerApp: App {
    static let mainWindowID = "main"
    static let updateWindowID = "update"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MachineStore.shared
    @StateObject private var monitor = Monitor.shared

    var body: some Scene {
        // A single window rather than a group: the app has one machine list, and
        // reopening it has to bring the existing window back rather than add a second.
        Window("RDP Manager", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(store)
                .environmentObject(monitor)
                .frame(minWidth: 860, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Machine…") {
                    NotificationCenter.default.post(name: .newMachineRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Find Machines on This Network…") {
                    NotificationCenter.default.post(name: .discoveryRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Status") { monitor.refreshNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // The first nine machines in list order, so the shortcut for a given machine
            // stays the same between launches.
            CommandMenu("Connect") {
                ForEach(Array(store.machines.prefix(9).enumerated()), id: \.element.id) { index, machine in
                    Button("\(machine.name) (\(machine.primary.label))") {
                        connect(machine, via: machine.primary)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                if store.machines.isEmpty {
                    Button("No Machines Yet") {}.disabled(true)
                }
            }
            UpdateCommands()
        }

        // The update answer lives in a window of its own rather than a sheet on the main
        // one. This app keeps running after its last window is closed, and a sheet has
        // nowhere to appear in that state: the check would finish and show nothing.
        Window("Software Update", id: Self.updateWindowID) {
            UpdateWindowView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(monitor)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            // A view rather than a system image name, so the count of offline machines can
            // appear beside it. A menu bar app whose icon never changes is only a menu.
            MenuBarView.Icon(store: store)
        }
    }
}

/// The menu items that need a window to report into.
///
/// Separate from `RDPManagerApp` only because `openWindow` comes from the environment,
/// which an `App` cannot read but a `Commands` can. Checking for updates with every
/// window closed used to find the update and then show nothing, because the sheet it
/// raises belongs to the main window.
struct UpdateCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                let openWindow = self.openWindow
                Updater.shared.prepareToPresent = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: RDPManagerApp.updateWindowID)
                }
                Updater.shared.check(userInitiated: true)
            }
            Button("Install Command Line Tool…") { installCommandLineTool() }
        }
    }
}

extension Notification.Name {
    static let newMachineRequested = Notification.Name("newMachineRequested")
    static let discoveryRequested = Notification.Name("discoveryRequested")
}

/// Links `rdpm` into /usr/local/bin and says what happened, since a menu item that reports
/// nothing leaves no way to tell a success from a silent failure.
@MainActor
func installCommandLineTool() {
    do {
        let destination = try CommandLineTool.install()
        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .contains(Substring(destination.deletingLastPathComponent().path))
        AppAlerts.show(
            "rdpm installed",
            "\(destination.path) now points into RDP Manager.app, so replacing the app "
            + "updates the command too.\n\nTry: rdpm list"
            + (onPath ? "" : "\n\nNote: \(destination.deletingLastPathComponent().path) "
               + "is not on this shell's PATH."))
    } catch CommandLineTool.Failure.cancelled {
        return
    } catch {
        AppAlerts.show("Could not install rdpm", error.localizedDescription)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TerminalPreference.registerDefaults()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            Notifier.shared.requestAuthorization()
        }
        Monitor.shared.start()
        Updater.shared.checkInBackground()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `rdpm connect` arrives here.
    ///
    /// The command knows the machine list but not how a session is launched — the client
    /// preference, the Keychain, the shared sign-ins and which client can be handed a
    /// password all live in the app. So it sends an id and the app does the rest.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "rdpm", url.host == "connect" else { continue }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            guard let raw = query.first(where: { $0.name == "machine" })?.value,
                  let id = UUID(uuidString: raw),
                  let machine = MachineStore.shared.machine(id) else { continue }
            let requested = query.first(where: { $0.name == "with" })?.value
                .flatMap(ConnectionType.init(rawValue:))
            connect(machine, via: requested ?? machine.primary)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
