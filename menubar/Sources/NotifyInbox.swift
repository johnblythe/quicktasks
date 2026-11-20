// NotifyInbox.swift -- the file-drop inbox that makes this app the
// notification authority for the whole quicktask/hub stack.
//
// qt's notify(), hub's local_notify, and hub runner's quick-profile notices
// all used to fire their own osascript/terminal-notifier banners, which is
// how "click a notification, get Script Editor" happened (2026-10-28). Now
// each of them drops one JSON file into $QT_DATA/notify-inbox/ (atomically:
// tmp + rename), this watcher picks it up within a heartbeat, and the banner
// goes out under this app's bundle identity with real action buttons.
//
// The JSON contract (all fields optional except title):
//
//   {"title": "...", "subtitle": "...", "body": "...",
//    "kind": "blocked" | "failed" | "timeout" | "done" | "info",
//    "task_id": "261028-075052-send-me-a",
//    "resume_url": "quicktask://resume/<id>",   // derived from task_id if absent
//    "pass_url": "http://127.0.0.1:8811/job/qt-<id>",
//    "denied_tools": ["mcp__claude_ai_Slack__slack_search_users"],
//    "ts": "...", "source": "qt|hub-local-notify|hub-runner"}
//
// Q6 adds the v2 payload the hub's bell writes (plan 1.8) -- v1 keys all
// still present, so an older build keeps posting, and this build keeps the
// v1 categories for v1 payloads:
//
//   {"v": 2, "kind": "answer", "ask_id": "qt-...", "task_id": "...",
//    "title": "...", "body": "...", "sound": false,
//    "url": "http://127.0.0.1:8811/ask/qt-...", "denied_tools": [],
//    "moves": ["follow_up", "copy", "open"], "ts": "...", "source": "hub-bell"}
//
// A v2 payload maps kind -> one of the ask.* categories (Notifier.swift):
// answer/failed/blocked/question carry the actions that answer in place,
// receipt and reminder are plain informative banners. `sound` is honored
// only for the sounding kinds (failed, blocked, question, reminder) -- the
// bell decides, the client enforces the ceiling, so a quiet answer stays
// passive whatever the payload claims.
//
// --dump-inbox-notice <file.json> is the CLI seam: it decodes one payload
// and prints the Notice it would post as JSON, so tests pin the mapping
// without a display or a real Notification Center.

import AppKit
import Foundation

struct InboxNotice: Codable {
    let title: String
    let subtitle: String?
    let body: String?
    let kind: String?
    let task_id: String?
    let resume_url: String?
    /// The click-through target. Neutral key since 2026-11-03 (review):
    /// half the producers pass a Slack permalink, not a Pass page.
    /// pass_url is the one-version-old name, read so a drop written by an
    /// older qt/hub still lands somewhere.
    let url: String?
    let pass_url: String?
    let denied_tools: [String]?
    let ts: String?
    let source: String?
    // Q6: the v2 bell payload (plan 1.8). All optional: a v1 drop from an
    // older producer decodes with every one of them absent.
    let v: Int?
    let ask_id: String?
    let sound: Bool?
    let moves: [String]?

    private var openURL: String? { url ?? pass_url }

    /// A bell (v2) payload rather than a producer's v1 drop. `v >= 2` is
    /// the honest signal; ask_id or one of the kinds v1 never had are the
    /// tolerant readings, so a bell that ever omits `v` still maps right.
    var isV2: Bool {
        if let v, v >= 2 { return true }
        if ask_id != nil { return true }
        return ["answer", "question", "receipt", "reminder"].contains(kind ?? "")
    }

    /// What handleInbox tells the job tracker to mark already handled, so
    /// the poll that later observes the same landing does not banner twice
    /// on top of the producer's own (Q6: "poll-detected fallback notices
    /// suppressed when an inbox v2 notice for the same ask_id/run
    /// arrived"). The tracker keys rows by their dedup id -- for a qt ask
    /// that is the bare tid (the "qt-" prefix hub item ids carry is
    /// stripped by PassStatus.dedupKey), for a hub item the item id, which
    /// is the ask id verbatim -- so every spelling is suppressed.
    struct Suppression: Equatable {
        let id: String
        let status: TaskStatus
    }

    func suppressions() -> [Suppression] {
        if isV2 {
            let statuses: [TaskStatus]
            switch kind {
            case "answer": statuses = [.done]
            // A timed-out run lands as .timeout on the legacy row; the
            // bell calls both "failed", so both keys are claimed.
            case "failed": statuses = [.failed, .timeout]
            case "blocked": statuses = [.blocked]
            // question / receipt / reminder have no legacy-row transition
            // that could double them.
            default: return []
            }
            var ids = [ask_id, task_id].compactMap { $0 }
            if let askID = ask_id, askID.hasPrefix("qt-") {
                ids.append(String(askID.dropFirst(3)))
            }
            var out: [Suppression] = []
            for status in statuses {
                for id in ids where !out.contains(where: { $0.id == id && $0.status == status }) {
                    out.append(Suppression(id: id, status: status))
                }
            }
            return out
        }
        // v1: today's mapping, unchanged (plus the timeout twin for the
        // same reason as above).
        guard let tid = task_id else { return [] }
        switch kind {
        case "blocked": return [Suppression(id: tid, status: .blocked)]
        case "failed": return [Suppression(id: tid, status: .failed),
                               Suppression(id: tid, status: .timeout)]
        case "timeout": return [Suppression(id: tid, status: .timeout),
                                Suppression(id: tid, status: .failed)]
        case "done": return [Suppression(id: tid, status: .done)]
        default: return []
        }
    }

    /// The rich notice this payload becomes. Pure and seam-tested; the
    /// watcher and the dump seam both go through here so a banner can never
    /// drift from what the test asserted.
    func toNotice(uuid: String = UUID().uuidString) -> Notice {
        if isV2 { return askNotice(uuid: uuid) }
        let tid = task_id
        let resume = resume_url ?? tid.map { "quicktask://resume/\($0)" }
        switch kind {
        case "blocked":
            let tools = denied_tools ?? []
            return Notice(id: "inbox-\(tid ?? uuid)-blocked",
                          title: title, subtitle: subtitle, body: body,
                          category: tools.isEmpty ? .blockedNoAllow : .blocked,
                          resumeURL: resume, passURL: openURL, taskID: tid,
                          allowTools: tools)
        case "failed", "timeout":
            return Notice(id: "inbox-\(tid ?? uuid)-failed",
                          title: title, subtitle: subtitle, body: body,
                          category: .outcome, passURL: openURL, taskID: tid)
        case "done":
            return Notice(id: "inbox-\(tid ?? uuid)-done",
                          title: title, subtitle: subtitle, body: body,
                          category: .outcome, passURL: openURL, taskID: tid)
        default:
            // info/unknown: plain banner, but keep the URL so a click still
            // lands somewhere useful (Slack permalink, Pass page).
            return Notice(id: "inbox-\(tid ?? uuid)",
                          title: title, subtitle: subtitle, body: body,
                          category: .plain, passURL: openURL, taskID: tid)
        }
    }

    /// The v2 mapping: one ask.* category per bell kind, the ask's one
    /// address as the click-through, and sound only when the bell set it
    /// *and* the kind may interrupt.
    private func askNotice(uuid: String) -> Notice {
        let askID = ask_id ?? task_id
        let category: Notice.Category
        switch kind {
        case "answer": category = .askAnswer
        case "failed": category = .askFailed
        case "blocked": category = .askBlocked
        case "question": category = .askQuestion
        case "receipt": category = .askReceipt
        case "reminder": category = .askReminder
        default: category = .plain
        }
        let maySound = ["failed", "blocked", "question", "reminder"].contains(kind ?? "")
        let id = askID ?? uuid
        return Notice(id: "ask-\(id)-\(kind ?? "notice")",
                      title: title, subtitle: subtitle, body: body,
                      category: category,
                      passURL: openURL,
                      allowTools: denied_tools ?? [],
                      sound: maySound && (sound ?? false),
                      askID: askID)
    }
}

/// Writes the user allowlist the "Always Allow Tool" action feeds. Both
/// guards (qt-guard.py, hub/guard.py) consult this file before denying, and
/// `qt allow <tool>` writes it by hand -- this is the same JSON they read:
/// {"allow": ["mcp__...", ...]}. Send-like tools are refused by the guards
/// themselves, so a fat-fingered allow here can never whitelist a write.
enum AlwaysAllow {
    static func fileURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit = env["QT_ALLOW_FILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        let data = env["QT_DATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".quicktasks")
        return data.appendingPathComponent("allow.json")
    }

    /// Adds tools to the allowlist, atomically. Returns how many were new.
    /// Read-modify-write with one retry on a concurrent mtime change (a tap
    /// racing `qt allow` must not silently drop the other's tools -- the
    /// action is user-trust-bearing, 2026-11-03 review).
    static func add(_ tools: [String],
                    env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        let url = fileURL(env: env)
        let fm = FileManager.default
        var allow: [String] = []
        for attempt in 0..<2 {
            let mtimeBefore = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let data = fm.contents(atPath: url.path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let existing = obj["allow"] as? [String] {
                allow = existing
            }
            var added = 0
            for tool in tools where !allow.contains(tool) {
                allow.append(tool)
                added += 1
            }
            guard added > 0 else { return 0 }
            let mtimeAfter = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if attempt == 0, mtimeAfter != mtimeBefore { continue }  // raced; reread once
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            let payload = try? JSONSerialization.data(withJSONObject: ["allow": allow],
                                                      options: [.prettyPrinted, .sortedKeys])
            // Atomic write: tmp + rename, so a guard reading mid-write never
            // sees a torn file. replaceItemAt only works over an existing
            // file, so a first-time write falls back to remove+move.
            let tmp = url.appendingPathExtension("tmp")
            try? payload?.write(to: tmp)
            if (try? fm.replaceItemAt(url, withItemAt: tmp)) ?? nil == nil {
                try? fm.removeItem(at: url)
                try? fm.moveItem(at: tmp, to: url)
            }
            if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
            return added
        }
        return 0  // unreachable (attempt 1 never re-races), but the compiler needs it
    }
}

/// Watches the inbox directory and hands each decoded notice to a callback.
/// A DispatchSource vnode watch gives near-instant pickup; StatusController
/// also calls sweep() on every poll, because a vnode event can be missed if
/// the directory itself was replaced between watches.
final class InboxWatcher {
    /// $QT_DATA/notify-inbox, defaulting to ~/.quicktasks/notify-inbox --
    /// the same QT_DATA resolution qt itself uses.
    static func defaultDir(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = env["QT_DATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".quicktasks")
        return base.appendingPathComponent("notify-inbox")
    }

    private let dir: URL
    private let onNotice: (InboxNotice) -> Void
    private let queue = DispatchQueue(label: "com.quicktasks.notify-inbox")
    private var source: DispatchSourceFileSystemObject?

    init(dir: URL, onNotice: @escaping (InboxNotice) -> Void) {
        self.dir = dir
        self.onNotice = onNotice
    }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sweep()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .rename],
                                                            queue: queue)
        src.setEventHandler { [weak self] in self?._sweep() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() { source?.cancel(); source = nil }

    /// Public sweep entry: always hops onto the watcher queue, so a
    /// poll-driven sweep (main thread) and a vnode-event sweep can never
    /// run concurrently -- before this, both could decode the same file
    /// and deliver it twice (2026-11-03 review).
    func sweep() {
        queue.async { self._sweep() }
    }

    /// Decodes every *.json in the inbox, delivers it, then removes it.
    /// Producers write atomically (tmp + rename), so a decode failure means
    /// a genuinely malformed file: it is renamed to .bad once rather than
    /// retried forever. The file is removed only AFTER delivery hops to
    /// main, accepting at-least-once redelivery on a mid-window crash over
    /// a silently consumed notice. Runs only on the watcher queue.
    private func _sweep() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in files.sorted() where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = fm.contents(atPath: url.path),
                  let notice = try? JSONDecoder().decode(InboxNotice.self, from: data) else {
                let bad = url.appendingPathExtension("bad")
                try? fm.removeItem(at: bad)
                try? fm.moveItem(at: url, to: bad)
                continue
            }
            DispatchQueue.main.async {
                self.onNotice(notice)
                try? fm.removeItem(at: url)
            }
        }
        // Housekeeping: a crashed producer's *.json.tmp never becomes a
        // notice; sweep it once it is clearly stale (10 minutes).
        let stale = Date().addingTimeInterval(-600)
        for name in files where name.hasSuffix(".tmp") {
            let url = dir.appendingPathComponent(name)
            if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, mtime < stale {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// CLI seam: decode one payload file and print the Notice it would post.
    static func runDumpInboxNotice(path: String) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
            return 2
        }
        guard let inbox = try? JSONDecoder().decode(InboxNotice.self, from: data) else {
            FileHandle.standardError.write(Data("could not decode \(path) as an inbox notice\n".utf8))
            return 2
        }
        let n = inbox.toNotice(uuid: "SEAM")
        var actions: [String] = []
        switch n.category {
        case .blocked: actions = ["Resume in Terminal", "Always Allow Tool", "Open in Pass"]
        case .blockedNoAllow: actions = ["Resume in Terminal", "Open in Pass"]
        case .outcome: actions = ["Open in Pass"]
        case .askAnswer, .askFailed, .askBlocked, .askQuestion, .askReceipt, .askReminder:
            actions = (AskNotice.actions[n.category] ?? []).map(\.title)
        case .plain: actions = []
        }
        let out: [String: Any] = [
            "id": n.id, "title": n.title,
            "subtitle": n.subtitle ?? NSNull(), "body": n.body ?? NSNull(),
            "category": n.category.rawValue, "actions": actions,
            "sound": n.sound,
            "ask_id": n.askID ?? NSNull(),
            "resume_url": n.resumeURL ?? NSNull(), "pass_url": n.passURL ?? NSNull(),
            "task_id": n.taskID ?? NSNull(),
            "allow_tools": n.allowTools,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: out,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        return 0
    }
}
