import Foundation
import UIKit
import UserNotifications

/// Tracks whether iOS will actually deliver Nudgy's reminders, and explains the answer in plain
/// language.
///
/// This is split from `NotificationScheduler` because the two answer different questions.
/// The scheduler answers "is this reminder set?"; this answers "will a set reminder ever ring?".
/// Conflating them produces the worst possible failure for a reminder app: a screen full of
/// confidently-scheduled reminders that the system silently drops on the floor because the user
/// tapped "Don't Allow" on day one and forgot.
///
/// The copy here deliberately never blames the user and never nags. Denied is a legitimate choice;
/// our job is to say what it means and how to change it, once.
@MainActor
final class NotificationPermission: ObservableObject {

    /// Current system authorization. `.notDetermined` until the first `refresh()`.
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    /// Whether alerts specifically are enabled. A user can authorize notifications and then turn
    /// off banners, which looks identical to `.authorized` unless you check.
    @Published private(set) var alertsEnabled: Bool = false

    /// Whether Nudgy has asked during this install, so the UI can offer the prompt at a calm moment
    /// rather than on cold launch.
    @Published private(set) var hasRequested: Bool = false

    @Published private(set) var lastCheckedAt: Date?

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - Requesting

    /// Asks the system for permission, then refreshes.
    ///
    /// Requests `.alert`, `.sound`, and `.badge`. Not `.provisional`: a medication reminder that
    /// arrives silently in Notification Center, which is what provisional authorization means, is a
    /// medication reminder that does not work. Nudgy would rather be told no.
    @discardableResult
    func request() async -> UNAuthorizationStatus {
        hasRequested = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // A throw here means the system could not present the prompt at all. `refresh()` still
            // reports the truthful current status, which is what the UI renders.
        }
        await refresh()
        return status
    }

    /// Re-reads the system's settings. Call on `scenePhase == .active` — the user may have changed
    /// this in Settings while the app was backgrounded, which is the whole point of `openSettings()`.
    func refresh() async {
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        alertsEnabled = settings.alertSetting == .enabled
        lastCheckedAt = Date()
    }

    // MARK: - Derived state

    /// True when a scheduled reminder will actually reach the user.
    var deliversReminders: Bool {
        switch status {
        case .authorized, .ephemeral: return true
        case .provisional: return true  // delivered, but quietly — see `explanation`.
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    /// True when the only way forward is the Settings app, not another in-app prompt.
    ///
    /// iOS will not re-present the system prompt after a denial, so an in-app "Allow notifications"
    /// button in this state does nothing and reads as broken.
    var requiresSettingsTrip: Bool { status == .denied }

    /// Short line for the status strip.
    var headline: String {
        switch status {
        case .notDetermined: return "Reminders not set up yet"
        case .denied: return "Reminders are turned off"
        case .authorized: return alertsEnabled ? "Reminders on" : "Reminders on, banners off"
        case .provisional: return "Reminders arrive quietly"
        case .ephemeral: return "Reminders on for now"
        @unknown default: return "Reminder status unknown"
        }
    }

    /// The paragraph shown when the user asks what this means. Calm, specific, no scolding.
    var explanation: String {
        switch status {
        case .notDetermined:
            return """
            Nudgy hasn't asked to send you notifications yet. Approved reminders are delivered by \
            your phone alone — nothing is sent through a server, and no text message leaves this \
            device.
            """
        case .denied:
            return """
            Notifications are off for Nudgy, so approved reminders won't reach you. iOS only asks \
            once, so this has to be changed in Settings: open Settings › Notifications › Nudgy and \
            turn on Allow Notifications. Your reminders are still saved here and will start \
            arriving as soon as you do.
            """
        case .authorized:
            if alertsEnabled {
                return """
                Approved reminders will arrive as notifications from this phone. To keep them \
                private on the lock screen, Nudgy never puts a medication name or a clinic name in \
                the notification itself.
                """
            }
            return """
            Notifications are allowed, but banners are switched off, so reminders will only appear \
            in Notification Center rather than on screen. You can turn banners back on in Settings \
            › Notifications › Nudgy.
            """
        case .provisional:
            return """
            Reminders are being delivered quietly — they go straight to Notification Center without \
            a sound or a banner. For a medication or exercise reminder that's easy to miss. In \
            Settings › Notifications › Nudgy you can choose "Deliver Prominently".
            """
        case .ephemeral:
            return """
            Notifications are allowed for this temporary session only. Install Nudgy to keep \
            reminders running.
            """
        @unknown default:
            return """
            This version of iOS reports a notification setting Nudgy doesn't recognise. You can \
            check it in Settings › Notifications › Nudgy.
            """
        }
    }

    /// Label for the single call-to-action button, or nil when nothing needs doing.
    var actionTitle: String? {
        switch status {
        case .notDetermined: return "Turn on reminders"
        case .denied: return "Open Settings"
        case .provisional: return "Open Settings"
        case .authorized: return alertsEnabled ? nil : "Open Settings"
        case .ephemeral: return nil
        @unknown default: return nil
        }
    }

    /// Deep link to Nudgy's own page in Settings.
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
