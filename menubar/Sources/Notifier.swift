// Notifier.swift -- macOS notifications for outcomes that happen while
// neither the dropdown nor the summon panel is on screen. Behind the
// Settings toggle "Notify me when the dropdown is closed" (default on) for
// the widget's own discoveries (poll transitions); inbox notices dropped by
// qt/hub (see NotifyInbox.swift) are producer-initiated banners and post
// regardless of that toggle -- they replace the Python paths' own
// osascript/terminal-notifier banners, which never knew the toggle existed.
//
// Everything posts through this one protocol so a test can inject a
// recorder and prove what *would* have gone to Notification Center without
// ever touching the real thing -- required reading for anyone tempted to
// call UNUserNotificationCenter directly from StatusController, which would
// make every notification-gating test either flaky or unrunnable in CI.

import AppKit
import Foundation
import UserNotifications

/// One rich, actionable notification. `id` doubles as the
/// UNNotificationRequest identifier, so re-posting the same id replaces the
/// banner in place instead of stacking. The 2026-10-28 upgrade from
/// title/body strings to this struct is what lets a "Job needs you" banner
/// carry Resume / Always allow / Open in Pass buttons under the app's own
/// bundle identity -- the end of osascript banners that open Script Editor.
struct Notice {
    enum Category: String {
        case plain                     // no actions
        case blocked = "QT_BLOCKED"    // Resume / Always allow / Open in Pass
        case blockedNoAllow = "QT_BLOCKED_NOALLOW" // Resume / Open in Pass
        case outcome = "QT_OUTCOME"    // Open in Pass
    }

    /// Action identifiers, shared by category registration and the delegate.
    enum Action: String {
        case resume = "QT_RESUME"
        case allow = "QT_ALLOW"
        case openPass = "QT_OPEN_PASS"
    }

    let id: String
    let title: String
    var subtitle: String? = nil
    var body: String? = nil
    var category: Category = .plain
    /// quicktask://resume/<id>; the Resume action's target.
    var resumeURL: String? = nil
    /// Pass job page or Slack permalink; the "Open in Pass" action target.
    var passURL: String? = nil
    /// The task/row this notice is about. A banner click with a taskID
    /// opens the summon panel with that row highlighted and expanded
    /// (2026-11-03: "I get the notification, I look in QuickTask, I read
    /// it right there") -- Resume stays available as the explicit action.
    var taskID: String? = nil
    /// Denied tool names an "Always allow" tap would whitelist. Empty means
    /// the caller had no denial detail (poll-detected blocks), and the
    /// category should be .blockedNoAllow so no dead button shows.
    var allowTools: [String] = []
}

protocol Notifier: AnyObject {
    /// Requests authorization. Callers are expected to call this only on an
    /// off -> on transition of the Settings toggle (StatusController.apply)
    /// and once at launch if the toggle is already on (StatusController.init)
    /// -- the real center already no-ops once a decision has been made, but
    /// callers should not rely on that for the "asked exactly once" guarantee
    /// the tests check, since a RecordingNotifier counts every raw call.
    /// (Inbox notices call it lazily too -- see StatusController.handleInbox
    /// -- which is safe for the same no-op reason and unreachable from tests,
    /// since the inbox watcher only exists beside a SystemNotifier.)
    func requestAuthorizationIfNeeded()
    /// Posts one local notification.
    func post(_ notice: Notice)
}

extension Notifier {
    /// The pre-Notice shape, kept so health transitions and settings
    /// confirmations (and their tests) never had to learn about categories.
    func post(title: String, body: String?) {
        post(Notice(id: UUID().uuidString, title: title, body: body))
    }
}

/// The real thing, used everywhere outside tests and snapshots. Also the
/// notification center's delegate, so a click can show the dropdown --
/// StatusController wires `onClicked` to whatever "show the dropdown if
/// achievable" ends up meaning for a MenuBarExtra(.window). Action taps
/// (Resume / Always allow / Open in Pass) are routed here too, from the
/// notice's own userInfo, so the Python producers only ever describe *what*
/// happened and never how a click is carried out.
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    var onClicked: (() -> Void)?
    /// Banner click on a notice that names a task: StatusController wires
    /// this to revealRecord (open the panel, highlight + expand the row).
    var onOpenRecord: ((String) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let resume = UNNotificationAction(identifier: Notice.Action.resume.rawValue,
                                          title: "Resume in Terminal", options: [])
        let allow = UNNotificationAction(identifier: Notice.Action.allow.rawValue,
                                         title: "Always Allow Tool", options: [])
        let openPass = UNNotificationAction(identifier: Notice.Action.openPass.rawValue,
                                            title: "Open in Pass", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Notice.Category.blocked.rawValue,
                                   actions: [resume, allow, openPass], intentIdentifiers: []),
            UNNotificationCategory(identifier: Notice.Category.blockedNoAllow.rawValue,
                                   actions: [resume, openPass], intentIdentifiers: []),
            UNNotificationCategory(identifier: Notice.Category.outcome.rawValue,
                                   actions: [openPass], intentIdentifiers: []),
        ])
    }

    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func post(title: String, body: String?) {
        post(Notice(id: UUID().uuidString, title: title, body: body))
    }

    func post(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = notice.subtitle { content.subtitle = subtitle }
        if let body = notice.body { content.body = body }
        if notice.category != .plain {
            content.categoryIdentifier = notice.category.rawValue
        }
        var info: [String: Any] = ["category": notice.category.rawValue]
        if let resumeURL = notice.resumeURL { info["resumeURL"] = resumeURL }
        if let passURL = notice.passURL { info["passURL"] = passURL }
        if let taskID = notice.taskID { info["taskID"] = taskID }
        if !notice.allowTools.isEmpty { info["allowTools"] = notice.allowTools }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: notice.id,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func openResume(_ info: [AnyHashable: Any]) {
        guard let raw = info["resumeURL"] as? String, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPass(_ info: [AnyHashable: Any]) {
        guard let raw = info["passURL"] as? String, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func allowTools(_ info: [AnyHashable: Any]) {
        let tools = (info["allowTools"] as? [String]) ?? []
        guard !tools.isEmpty else { return }
        let added = AlwaysAllow.add(tools)
        post(Notice(id: "allow-\(UUID().uuidString)",
                    title: added > 0 ? "Allowlist updated" : "Already allowed",
                    body: "\(tools.joined(separator: ", ")) -- future headless runs won't block on these reads."))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let category = Notice.Category(rawValue: info["category"] as? String ?? "") ?? .plain
        switch response.actionIdentifier {
        case Notice.Action.resume.rawValue:
            openResume(info)
        case Notice.Action.allow.rawValue:
            allowTools(info)
        case Notice.Action.openPass.rawValue:
            openPass(info)
        default:
            // Banner click: a notice that names its task opens the panel
            // focused on that row (the 2026-11-03 deep link). Without one,
            // the older fallbacks: a blocked notice resumes, a URL opens,
            // anything else just shows the panel.
            if let tid = info["taskID"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onOpenRecord?(tid) }
            } else if (category == .blocked || category == .blockedNoAllow),
                      info["resumeURL"] is String {
                openResume(info)
            } else if info["passURL"] is String {
                openPass(info)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onClicked?() }
            }
        }
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
    /// Kept in the pre-Notice shape: existing seams and tests read this.
    private(set) var posted: [Posted] = []
    /// The full notices, for anything that wants categories/actions.
    private(set) var notices: [Notice] = []

    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func post(_ notice: Notice) {
        notices.append(notice)
        posted.append(Posted(title: notice.title, body: notice.body))
    }
}
