import Foundation
import UserNotifications

enum NotificationKind: String {
    case offline = "notifyOffline"
    case backOnline = "notifyBackOnline"
    case ipChange = "notifyIPChange"

    var defaultsKey: String { rawValue }
}

final class Notifier {
    static let shared = Notifier()

    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func isEnabled(_ kind: NotificationKind) -> Bool {
        UserDefaults.standard.object(forKey: kind.defaultsKey) as? Bool ?? true
    }

    func post(_ kind: NotificationKind, title: String, body: String) {
        guard available, Self.isEnabled(kind) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
