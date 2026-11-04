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
    let pass_url: String?
    let denied_tools: [String]?
    let ts: String?
    let source: String?

    /// The rich notice this payload becomes. Pure and seam-tested; the
    /// watcher and the dump seam both go through here so a banner can never
    /// drift from what the test asserted.
    func toNotice(uuid: String = UUID().uuidString) -> Notice {
        let tid = task_id
        let resume = resume_url ?? tid.map { "quicktask://resume/\($0)" }
        switch kind {
        case "blocked":
            let tools = denied_tools ?? []
            return Notice(id: "inbox-\(tid ?? uuid)-blocked",
                          title: title, subtitle: subtitle, body: body,
                          category: tools.isEmpty ? .blockedNoAllow : .blocked,
                          resumeURL: resume, passURL: pass_url, taskID: tid,
                          allowTools: tools)
        case "failed", "timeout":
            return Notice(id: "inbox-\(tid ?? uuid)-failed",
                          title: title, subtitle: subtitle, body: body,
                          category: .outcome, passURL: pass_url, taskID: tid)
        case "done":
            return Notice(id: "inbox-\(tid ?? uuid)-done",
                          title: title, subtitle: subtitle, body: body,
                          category: .outcome, passURL: pass_url, taskID: tid)
        default:
            // info/unknown: plain banner, but keep the URL so a click still
            // lands somewhere useful (Slack permalink, Pass page).
            return Notice(id: "inbox-\(tid ?? uuid)",
                          title: title, subtitle: subtitle, body: body,
                          category: .plain, passURL: pass_url, taskID: tid)
        }
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
    static func add(_ tools: [String],
                    env: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        let url = fileURL(env: env)
        let fm = FileManager.default
        var allow: [String] = []
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
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let payload = try? JSONSerialization.data(withJSONObject: ["allow": allow],
                                                  options: [.prettyPrinted, .sortedKeys])
        // Atomic write: tmp + rename, so a guard reading mid-write never
        // sees a torn file. replaceItemAt only works over an existing file,
        // so a first-time write falls back to remove+move.
        let tmp = url.appendingPathExtension("tmp")
        try? payload?.write(to: tmp)
        if (try? fm.replaceItemAt(url, withItemAt: tmp)) ?? nil == nil {
            try? fm.removeItem(at: url)
            try? fm.moveItem(at: tmp, to: url)
        }
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
        return added
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
        src.setEventHandler { [weak self] in self?.sweep() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() { source?.cancel(); source = nil }

    /// Decodes every *.json in the inbox, delivers it, and removes it.
    /// Producers write atomically (tmp + rename), so a decode failure means
    /// a genuinely malformed file: it is renamed to .bad once rather than
    /// retried forever. Safe to call from any queue; callbacks hop to main.
    func sweep() {
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
            try? fm.removeItem(at: url)
            DispatchQueue.main.async { self.onNotice(notice) }
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
        case .plain: actions = []
        }
        let out: [String: Any] = [
            "id": n.id, "title": n.title,
            "subtitle": n.subtitle ?? NSNull(), "body": n.body ?? NSNull(),
            "category": n.category.rawValue, "actions": actions,
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
