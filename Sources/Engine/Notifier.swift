import Foundation
import UserNotifications

enum Notifier {
    static let categoryID = "logline.activity"
    static let openActionID = "logline.open"
    static let watchdogID = "logline.watchdog"

    static func registerCategories() {
        let open = UNNotificationAction(identifier: openActionID, title: "Open in Letterboxd", options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID, actions: [open], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.shared.add("Notification permission request failed: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    static func post(item: ActivityItem, accountName: String, username: String, prefs: Preferences,
                     badge: Int, timeSensitive: Bool, identifier: String? = nil) async {
        let parts = NotificationText.parts(for: item, accountName: accountName, hideSpoilers: prefs.hideSpoilers)
        let content = UNMutableNotificationContent()
        content.title = parts.title
        if !parts.subtitle.isEmpty {
            content.subtitle = parts.subtitle
        }
        content.body = parts.body
        content.sound = .default
        content.badge = NSNumber(value: badge)
        content.threadIdentifier = "account." + username
        content.categoryIdentifier = categoryID
        content.userInfo = ["itemID": item.id, "link": item.link ?? ""]
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
        }
        if prefs.attachImages, let image = item.imageURL, let attachment = await attachment(from: image) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: identifier ?? item.id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.shared.add("Couldn't post an alert: \(error.localizedDescription)", level: .error)
        }
    }

    /// One notification for a burst, so five watchlist additions don't arrive as five buzzes.
    static func postDigest(items: [ActivityItem], accountName: String, username: String, badge: Int, timeSensitive: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = accountName
        content.subtitle = "\(items.count) new on Letterboxd"
        content.body = items.suffix(6).reversed().map { NotificationText.line(for: $0) }.joined(separator: "\n")
        content.sound = .default
        content.badge = NSNumber(value: badge)
        content.threadIdentifier = "account." + username
        content.categoryIdentifier = categoryID
        if let newest = items.last {
            content.userInfo = ["itemID": newest.id, "link": newest.link ?? ""]
        }
        if timeSensitive {
            content.interruptionLevel = .timeSensitive
        }
        let identifier = "digest.\(username).\(Int(Date().timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.shared.add("Couldn't post a digest: \(error.localizedDescription)", level: .error)
        }
    }

    /// Pushed further into the future on every Instant-mode check. If checks stop, it fires.
    static func scheduleWatchdog(after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Logline stopped watching"
        content.body = "Instant mode hasn't checked in for a while, so new activity could be missed. Open Logline to start it again."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: watchdogID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    static func cancelWatchdog() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [watchdogID])
    }

    private static func attachment(from urlString: String) async -> UNNotificationAttachment? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        let data = result.0
        guard let http = result.1 as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("poster-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "poster", url: file, options: nil)
        } catch {
            return nil
        }
    }
}
