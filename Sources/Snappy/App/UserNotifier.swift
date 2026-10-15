import AppKit
import UserNotifications

/// Posts banner notifications (e.g. OCR results). Requests notification
/// permission on first use. Falls back to logging when running unbundled
/// (`swift run`), where UserNotifications is unavailable and would crash.
final class UserNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // @unchecked Sendable: the class holds no state; delegate callbacks may
    // arrive on arbitrary queues.
    static let shared = UserNotifier()

    /// When previews are hidden (System Settings → Notifications), macOS still
    /// shows the title — "Text Copied" — but not the recognized text.
    private static let categoryIdentifier = "snappy.result"

    /// - Parameters:
    ///   - identifier: a banner with the same identifier *replaces* the
    ///     previous one, so repeated results don't pile up in Notification
    ///     Center (HIG Notifications › Best practices).
    ///   - alertIfUndelivered: when the banner can't be shown (notifications
    ///     denied or set to None, or unbundled), play the system alert sound —
    ///     which "Flash the screen when an alert sound occurs" turns into a
    ///     visual flash — and ask VoiceOver to announce the banner, so a result
    ///     the person needs to know about is never silent.
    func post(_ banner: BannerText, identifier: String = UUID().uuidString, alertIfUndelivered: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("[Snappy] %@ — %@", banner.title, banner.body)
            if alertIfUndelivered { Self.alertUndelivered(banner) }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: [.hiddenPreviewsShowTitle]
            ),
        ])
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                if alertIfUndelivered { Self.alertUndelivered(banner) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = banner.title
            content.body = banner.body
            content.categoryIdentifier = Self.categoryIdentifier
            let center = UNUserNotificationCenter.current()
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                if error != nil, alertIfUndelivered { Self.alertUndelivered(banner) }
            }
            guard alertIfUndelivered else { return }
            center.getNotificationSettings { settings in
                if settings.alertStyle == .none { Self.alertUndelivered(banner) }
            }
        }
    }

    private static func alertUndelivered(_ banner: BannerText) {
        Task { @MainActor in
            NSSound.beep()
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "\(banner.title). \(banner.body)",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }

    // Show banners even while Snappy is the active app (the capture flow
    // activates us, and by default macOS suppresses a frontmost app's banners).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
