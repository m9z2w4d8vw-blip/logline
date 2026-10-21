import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = NotificationDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Notifier.registerCategories()
        BackgroundScheduler.register()
        AppModel.shared.didFinishLaunching()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppModel.shared.willTerminate()
    }
}

/// Kept apart from AppDelegate so it stays nonisolated. UserNotifications calls it on its own queue.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let itemID = info["itemID"] as? String
        let link = info["link"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            AppModel.shared.handleNotificationResponse(itemID: itemID, link: link, action: action)
        }
        completionHandler()
    }
}
