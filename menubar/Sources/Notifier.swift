// Notifier.swift -- macOS notifications for outcomes that happen while
// neither the dropdown nor the summon panel is on screen. Behind the
// Settings toggle "Notify me when the dropdown is closed" (default on).
//
// Everything posts through this one protocol so a test can inject a
// recorder and prove what *would* have gone to Notification Center without
// ever touching the real thing -- required reading for anyone tempted to
// call UNUserNotificationCenter directly from StatusController, which would
// make every notification-gating test either flaky or unrunnable in CI.

import Foundation
import UserNotifications

protocol Notifier: AnyObject {
    /// Requests authorization. Callers are expected to call this only on an
    /// off -> on transition of the Settings toggle (StatusController.apply)
    /// and once at launch if the toggle is already on (StatusController.init)
    /// -- the real center already no-ops once a decision has been made, but
    /// callers should not rely on that for the "asked exactly once" guarantee
    /// the tests check, since a RecordingNotifier counts every raw call.
    func requestAuthorizationIfNeeded()
    /// Posts one local notification. `body` is the outcome's detail, if any.
    func post(title: String, body: String?)
}

/// The real thing, used everywhere outside tests and snapshots. Also the
/// notification center's delegate, so a click can show the dropdown --
/// StatusController wires `onClicked` to whatever "show the dropdown if
/// achievable" ends up meaning for a MenuBarExtra(.window).
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    var onClicked: (() -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func post(title: String, body: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in self?.onClicked?() }
        completionHandler()
    }
}

/// The test double. Never touches Notification Center -- not even a stub
/// framework call -- so nothing real is ever sent from the sandbox. Records
/// every call in order, with no idempotency of its own: the "authorization
/// requested exactly once" guarantee is a property of the *call sites*
/// (StatusController.init / .apply), and this recorder exists to prove that
/// property rather than to enforce it itself.
final class RecordingNotifier: Notifier {
    struct Posted: Equatable {
        let title: String
        let body: String?
    }

    private(set) var authorizationRequests = 0
    private(set) var posted: [Posted] = []

    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func post(title: String, body: String?) { posted.append(Posted(title: title, body: body)) }
}
