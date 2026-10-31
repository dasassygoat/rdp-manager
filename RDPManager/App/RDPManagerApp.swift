import SwiftUI
import UserNotifications

@main
struct RDPManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MachineStore.shared
    @StateObject private var monitor = Monitor.shared

    var body: some Scene {
        WindowGroup(id: "main") {
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
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Status") { monitor.refreshNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Install Command Line Tool…") { installCommandLineTool() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(monitor)
        }

        MenuBarExtra("RDP Manager", systemImage: "rectangle.connected.to.line.below") {
            MenuBarView()
                .environmentObject(store)
        }
    }
}

extension Notification.Name {
    static let newMachineRequested = Notification.Name("newMachineRequested")
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
