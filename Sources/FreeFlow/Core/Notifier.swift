import Foundation
import UserNotifications
import AppKit

/// User notifications with a fallback to the Flow Bar for apps without notification entitlements.
enum Notifier {
    static var granted = false

    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            granted = ok
        }
    }

    static func notify(_ title: String, _ body: String = "", identifier: String? = nil) {
        if granted {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: identifier ?? UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        DispatchQueue.main.async {
            FlowBarController.shared.flash(message: body.isEmpty ? title : "\(title): \(body)")
        }
    }
}
