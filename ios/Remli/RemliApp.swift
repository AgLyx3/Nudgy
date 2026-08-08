import SwiftUI
import UserNotifications

@main
struct RemliApp: App {
    @StateObject private var session = RemliSession()
    @StateObject private var responder = NotificationResponder()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(session)
                .task {
                    responder.session = session
                    UNUserNotificationCenter.current().delegate = responder
                    await session.start()
                }
        }
    }
}

/// Receives taps on notification actions and hands them to the session.
///
/// Kept separate from `RemliSession` because `UNUserNotificationCenterDelegate` requires an
/// NSObject, and the session should not have to be one.
final class NotificationResponder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    weak var session: RemliSession?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let reminderID = userInfo[NotificationScheduler.reminderIDKey] as? String
        let actionID = response.actionIdentifier

        Task { @MainActor in
            if let reminderID {
                await session?.handleNotificationAction(actionID, reminderID: reminderID)
            }
            completionHandler()
        }
    }

    /// Reminders are worth seeing even with the app open — otherwise a dose due while someone is
    /// reading their card passes silently.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
