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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
