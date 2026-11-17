// Notifier.swift -- macOS notifications for outcomes that happen while
// neither the dropdown nor the summon panel is on screen. Behind the
// Settings toggle "Notify me when the dropdown is closed" (default on) for
// the widget's own discoveries (poll transitions); inbox notices dropped by
// qt/hub (see NotifyInbox.swift) are producer-initiated banners and post
// regardless of that toggle -- they replace the Python paths' own
// osascript/terminal-notifier banners, which never knew the toggle existed.
//
// Q6 (asks, slice 2) adds the banner that carries the answer: the hub's
// bell drops a v2 payload (NotifyInbox.swift) naming the ask, and the
// notice it becomes gets its own category per bell kind -- ask.answer,
// ask.failed, ask.blocked, ask.question, ask.receipt, ask.reminder -- with
// the actions that answer in place: text-input follow-ups and answers,
// Copy, Open, Try again / Change it…, Allow once / Always allow / Skip.
// Only the sounding kinds (failed, blocked, question, reminder) may set
// `sound`, and sound is what buys the time-sensitive interruption level;
// a quiet answer is a passive banner. Every ask action routes through the
// one pure `AskNoticeRoute` so the delegate, StatusController, and the
// `--ask-notice` seam cannot drift apart.
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
        // Q6: one category per bell kind (plan 1.8), so the banner's
        // buttons are the ones that answer carries.
        case askAnswer = "ask.answer"
        case askFailed = "ask.failed"
        case askBlocked = "ask.blocked"
        case askQuestion = "ask.question"
        case askReceipt = "ask.receipt"
        case askReminder = "ask.reminder"
    }

    /// Action identifiers, shared by category registration and the delegate.
    enum Action: String {
        case resume = "QT_RESUME"
        case allow = "QT_ALLOW"
        case openPass = "QT_OPEN_PASS"
        // Q6: ask banner actions. `copy` and `open` are client-only (no
        // route, section 1.2); every other one is a 1.6 move the
        // controller POSTs through AskClient.
        case askFollowUp = "QT_ASK_FOLLOW_UP"          // text input -> follow_up
        case askAnswer = "QT_ASK_ANSWER"               // text input -> follow_up
        case askCopy = "QT_ASK_COPY"
        case askOpen = "QT_ASK_OPEN"
        case askRetry = "QT_ASK_RETRY"
        case askRetryChanges = "QT_ASK_RETRY_CHANGES"  // text input -> retry_with_changes
        case askAllowOnce = "QT_ASK_ALLOW_ONCE"
        case askAllowAlways = "QT_ASK_ALLOW_ALWAYS"
        case askSkip = "QT_ASK_SKIP"
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
    /// Q6: this banner may interrupt -- a sound plus the time-sensitive
    /// interruption level. Only the sounding kinds ever set it (the bell
    /// decides; toNotice enforces the ceiling), so an answer or a receipt
    /// is always a passive banner that waits to be noticed.
    var sound: Bool = false
    /// Q6: the ask this banner is about, when it is an ask banner (a v2
    /// bell payload). Carries the click-through: a click reveals the ask's
    /// row and posts `seen`, and every action POSTs its move to this id.
    var askID: String? = nil
}

/// One ask banner action as the plan words it: the identifier, the button
/// title, and whether the button opens a text input. The table is the one
/// source both the category registration and the `--ask-notice` seam read,
/// so what a test prints is what Notification Center shows.
struct AskBannerAction: Equatable {
    let action: Notice.Action
    let title: String
    let textInput: Bool
}

/// The ask categories' action lists in banner order (Q6). Fixed by the
/// plan: answer = Follow up… (text input), Copy, Open; failed = Try again,
/// Change it… (text input), Open; blocked = Allow once, Always allow, Skip
/// that step; question = Answer… (text input); receipt and reminder carry
/// no actions.
enum AskNotice {
    static let actions: [Notice.Category: [AskBannerAction]] = [
        .askAnswer: [
            AskBannerAction(action: .askFollowUp, title: "Follow up\u{2026}", textInput: true),
            AskBannerAction(action: .askCopy, title: "Copy", textInput: false),
            AskBannerAction(action: .askOpen, title: "Open", textInput: false),
        ],
        .askFailed: [
            AskBannerAction(action: .askRetry, title: "Try again", textInput: false),
            AskBannerAction(action: .askRetryChanges, title: "Change it\u{2026}", textInput: true),
            AskBannerAction(action: .askOpen, title: "Open", textInput: false),
        ],
        .askBlocked: [
            AskBannerAction(action: .askAllowOnce, title: "Allow once", textInput: false),
            AskBannerAction(action: .askAllowAlways, title: "Always allow", textInput: false),
            AskBannerAction(action: .askSkip, title: "Skip that step", textInput: false),
        ],
        .askQuestion: [
            AskBannerAction(action: .askAnswer, title: "Answer\u{2026}", textInput: true),
        ],
        .askReceipt: [],
        .askReminder: [],
    ]
}

/// What tapping an ask banner (or clicking it) becomes -- pure, so the
/// delegate, StatusController, and the `--ask-notice` seam all route the
/// same action the same way. `.move` is a 1.6 move with its JSON body (the
/// typed text for the text-input actions); `.copy` and `.open` are
/// client-only; `.click` is the banner's own click-through (reveal the row,
/// post `seen`).
enum AskNoticeRoute: Equatable {
    case click(id: String)
    case move(id: String, move: String, body: [String: String])
    case copy(text: String)
    case open(url: String)
    case none

    /// `actionID` is the UNNotificationResponse's actionIdentifier (the
    /// default-action identifier maps to `.click`). `askID` nil or empty
    /// means the banner was not an ask banner: `.none`.
    static func route(actionID: String,
                      askID: String?,
                      typedText: String,
                      body: String?,
                      url: String?) -> AskNoticeRoute {
        guard let askID, !askID.isEmpty else { return .none }
        func move(_ name: String, _ body: [String: String] = [:]) -> AskNoticeRoute {
            .move(id: askID, move: name, body: body)
        }
        switch actionID {
        case Notice.Action.askFollowUp.rawValue:
            return move("follow_up", ["text": typedText])
        case Notice.Action.askAnswer.rawValue:
            return move("follow_up", ["text": typedText])
        case Notice.Action.askRetryChanges.rawValue:
            return move("retry_with_changes", ["prompt": typedText])
        case Notice.Action.askRetry.rawValue:
            return move("retry")
        case Notice.Action.askAllowOnce.rawValue:
            return move("allow_once")
        case Notice.Action.askAllowAlways.rawValue:
            return move("allow_always")
        case Notice.Action.askSkip.rawValue:
            return move("skip")
        case Notice.Action.askCopy.rawValue:
            return .copy(text: body ?? "")
        case Notice.Action.askOpen.rawValue:
            return url.map { .open(url: $0) } ?? .none
        case UNNotificationDefaultActionIdentifier:
            return .click(id: askID)
        default:
            return .none
        }
    }
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
    /// An ask banner's action or click, as the pure AskNoticeRoute that
    /// describes it (Q6). StatusController wires this to handleAskRoute:
    /// move POSTs through AskClient, the copy, the open, and the
    /// reveal-and-seen click. The delegate stays transport-only -- the
    /// same rule the Python producers follow, kept: producers describe
    /// *what happened*, the app decides how a click is carried out.
    var onAskRoute: ((AskNoticeRoute) -> Void)?

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
        var categories: [UNNotificationCategory] = [
            UNNotificationCategory(identifier: Notice.Category.blocked.rawValue,
                                   actions: [resume, allow, openPass], intentIdentifiers: []),
            UNNotificationCategory(identifier: Notice.Category.blockedNoAllow.rawValue,
                                   actions: [resume, openPass], intentIdentifiers: []),
            UNNotificationCategory(identifier: Notice.Category.outcome.rawValue,
                                   actions: [openPass], intentIdentifiers: []),
        ]
        // The ask categories (Q6), built from the one table the seam also
        // reads, so a registered banner and a printed one cannot drift.
        // The text-input actions are UNTextInputNotificationAction: the
        // system's own inline reply box, whose text rides the response.
        for (category, actions) in AskNotice.actions {
            let registered = actions.map { action -> UNNotificationAction in
                if action.textInput {
                    return UNTextInputNotificationAction(
                        identifier: action.action.rawValue,
                        title: action.title, options: [],
                        textInputButtonTitle: action.title,
                        textInputPlaceholder: "Type your reply")
                }
                return UNNotificationAction(identifier: action.action.rawValue,
                                            title: action.title, options: [])
            }
            categories.append(UNNotificationCategory(identifier: category.rawValue,
                                                     actions: registered,
                                                     intentIdentifiers: []))
        }
        center.setNotificationCategories(Set(categories))
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
        if notice.sound {
            // Sound is what the bell buys for the sounding kinds only
            // (1.8); with it comes the interruption level, so a failure
            // can break through Focus while an answer waits its turn.
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        }
        var info: [String: Any] = ["category": notice.category.rawValue]
        if let resumeURL = notice.resumeURL { info["resumeURL"] = resumeURL }
        if let passURL = notice.passURL { info["passURL"] = passURL }
        if let taskID = notice.taskID { info["taskID"] = taskID }
        if !notice.allowTools.isEmpty { info["allowTools"] = notice.allowTools }
        if let askID = notice.askID { info["askID"] = askID }
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
            // Ask banners route first (Q6): every action, and the plain
            // click itself, becomes one AskNoticeRoute off the same pure
            // table the seam prints. A dismissal or an unknown identifier
            // routes to .none and stops here.
            if let askID = info["askID"] as? String {
                let typed = (response as? UNTextInputNotificationResponse)?.userText ?? ""
                let route = AskNoticeRoute.route(
                    actionID: response.actionIdentifier,
                    askID: askID,
                    typedText: typed,
                    body: response.notification.request.content.body,
                    url: info["passURL"] as? String)
                if case .none = route { break }
                DispatchQueue.main.async { [weak self] in self?.onAskRoute?(route) }
                completionHandler()
                return
            }
            // Only the actual banner click routes anywhere; a dismissal
            // (or any future system identifier) must not pop the panel
            // open (2026-11-03 review).
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier
            else { break }
            // A notice that names its task opens the panel focused on that
            // row (the 2026-11-03 deep link). Without one, the older
            // fallbacks: a blocked notice resumes, a URL opens, anything
            // else just shows the panel.
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
