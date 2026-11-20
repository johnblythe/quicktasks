// FireResolve.swift -- where a Run-now fire's `--in <dir>` comes from, and
// the recent-directory list the chip's menu shows.
//
// The precedence is a typed `--in`/`@` prefix (one-shot, never persisted),
// then QT_MENUBAR_FIRE_DIR, then the directory chip's last choice (persisted
// in Settings), then $HOME. That mirrors Settings.swift's own rule for every
// other override -- the environment always wins, because QT_MENUBAR_FIRE_DIR
// is how a test (or a second, deliberately scoped install) points quick-fire
// somewhere without touching what is stored in UserDefaults.
//
// Kept as pure functions so `--dump-fire` and the \u{2318}-Return one-shot
// "fire with the other mode" (driven from `--dump-keys`) exercise the exact
// resolution the live chip and field use, rather than a restatement of it.

import Foundation

enum FireResolve {
    /// A directory chosen for one fire, and the reason: `"prefix"` (a typed
    /// `--in`/`@`), `"env"` (QT_MENUBAR_FIRE_DIR), `"chip"` (the last one
    /// picked from the chip's menu, persisted in Settings), or `"default"`
    /// ($HOME, nothing else said otherwise).
    struct Directory {
        let url: URL
        let source: String
    }

    /// Splits a typed `--in <dir> <rest>` or `@<dir> <rest>` prefix off the
    /// front of quick-fire's text -- the same convention qt's own CLI parses,
    /// and the one raycast/quick-task.sh mirrors as `--in <dir>`. Returns the
    /// raw (unexpanded) dir string and the text with the prefix stripped; when
    /// there is no recognised prefix, `dir` is nil and `text` is unchanged.
    static func parsePrefix(_ text: String) -> (dir: String?, text: String) {
        func split(_ body: Substring) -> (String, String)? {
            guard let space = body.firstIndex(of: " ") else { return nil }
            let dir = String(body[..<space])
            guard !dir.isEmpty else { return nil }
            let rest = body[body.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            return (dir, rest)
        }
        if text.hasPrefix("--in "), let (dir, rest) = split(text.dropFirst(5)) {
            return (dir, rest)
        }
        if text.hasPrefix("@"), let (dir, rest) = split(text.dropFirst(1)) {
            return (dir, rest)
        }
        return (nil, text)
    }

    /// A directory string, tilde-expanded and checked, or nil when it does not
    /// name a real directory. The one standard a typed prefix and the chip's
    /// stored path are both held to.
    static func valid(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    /// The chip's own directory when nothing typed overrides it: env, then
    /// the persisted chip choice, then $HOME. This is what the chip displays
    /// and what a fire with no prefix actually uses.
    static func chipDirectory(env: [String: String] = ProcessInfo.processInfo.environment,
                              settings: Settings) -> Directory {
        if let url = valid(env["QT_MENUBAR_FIRE_DIR"]) {
            return Directory(url: url, source: "env")
        }
        if let url = valid(settings.fireDirOverride) {
            return Directory(url: url, source: "chip")
        }
        return Directory(url: FileManager.default.homeDirectoryForCurrentUser, source: "default")
    }

    /// The directory one Run-now fire actually uses. A typed prefix wins when
    /// it names a real directory; an invalid or missing one falls through to
    /// the chip rather than failing the fire outright, so a typo in `--in`
    /// cannot eat the rest of the prompt as an error.
    static func runDirectory(prefixDir: String?,
                             env: [String: String] = ProcessInfo.processInfo.environment,
                             settings: Settings) -> Directory {
        if let url = valid(prefixDir) {
            return Directory(url: url, source: "prefix")
        }
        return chipDirectory(env: env, settings: settings)
    }

    /// The body the Ask-me-first mode POSTs to `/asks` (Q12, contract 1.6):
    /// the stripped text, the mode, the door this widget always is, and the
    /// directory a Run-now fire of the same words would have used -- the
    /// prefix is parsed and stripped here rather than ignored, because
    /// `dir` *is* a field this body has.
    ///
    /// `describe(text:toPass:)` below keeps describing the *fallback* leg
    /// (the `/capture` body an older hub takes) because that is what
    /// `--dump-fire`/`--dump-keys` have always printed and what the
    /// ask-first flow falls back to; this function and the `--ask-fire` seam
    /// describe the POST /asks leg.
    static func askFirstBody(text: String, dir: URL?, model: String? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "text": text,
            "mode": "ask_first",
            // Section 1.3's door table: menubar (widget or summon) -> typed.
            "door": "typed",
        ]
        if let dir { body["dir"] = dir.path }
        if let model { body["model"] = model }
        return body
    }

    /// The model chip's menu (2026-11-19): the short names qt's Fireworks
    /// routing expands (see qt's fireworks_model), plus the one Anthropic
    /// reference that deliberately does NOT route -- `sonnet[1m]` keeps a
    /// single run on the ambient Claude login even with the provider
    /// configured. `Default` is the absence of a choice: the fire carries
    /// no -m at all and qt's own config (provider + model) decides.
    enum FireModel: CaseIterable {
        case glm53
        case glm53Flash
        case kimiK31Pro
        case sonnet

        /// What rides the fire: a short Fireworks name, or the Anthropic
        /// reference that opts this one run out of the provider.
        var name: String {
            switch self {
            case .glm53: return "glm-5p3"
            case .glm53Flash: return "glm-5p3-flash"
            case .kimiK31Pro: return "kimi-k3.1-pro"
            case .sonnet: return "sonnet[1m]"
            }
        }

        /// The chip's own label, and the menu's.
        var label: String {
            switch self {
            case .glm53: return "GLM 5.3"
            case .glm53Flash: return "GLM 5.3 Flash"
            case .kimiK31Pro: return "Kimi K3.1 Pro"
            case .sonnet: return "Sonnet (Anthropic)"
            }
        }

        var help: String {
            self == .sonnet
                ? "This one fire stays on your Claude login (no Fireworks routing)."
                : "This one fire runs on Fireworks: \(name)."
        }

        /// The chosen model for a fire, nil when the chip is at Default.
        /// An unknown stored value (a name a newer build knew) reads as
        /// Default rather than firing a -m qt cannot expand.
        static func resolve(_ raw: String?) -> FireModel? {
            guard let raw else { return nil }
            return allCases.first { $0.name == raw }
        }
    }

    /// The full resolved outcome of one fire, as JSON: what `--dump-fire`
    /// prints directly, and what a \u{2318}-Return one-shot fire inside
    /// `--dump-keys` appends to `fired`. Kept as one function so both seams,
    /// and MenuView's real send(), describe a fire exactly the same way.
    ///
    /// To Pass ignores the directory outright, prefix and all: the raw text
    /// goes to `/capture` unstripped, because `--in`/`@` is a Run-now-only
    /// convention the capture body has no field for.
    static func describe(text raw: String, toPass: Bool,
                         env: [String: String] = ProcessInfo.processInfo.environment,
                         settings: Settings) -> [String: Any] {
        if toPass {
            switch PassPayload.capture(text: raw) {
            case .failure(let problem):
                return ["mode": "pass", "error": problem.message]
            case .success(var body):
                body["mode"] = "pass"
                return body
            }
        }
        let (prefixDir, stripped) = parsePrefix(raw)
        let resolved = runDirectory(prefixDir: prefixDir, env: env, settings: settings)
        let model = FireModel.resolve(settings.fireModelOverride)?.name
        var argv = ["--in", resolved.url.path]
        if let model { argv += ["-m", model] }
        argv.append(stripped)
        var out: [String: Any] = [
            "mode": "run",
            "text": stripped,
            "dir": resolved.url.path,
            "dir_source": resolved.source,
            "argv": argv,
        ]
        if let model { out["model"] = model }
        return out
    }
}

/// Q12: the receipt a successful fire from the ask field leaves behind, and
/// the undo it carries. One struct for both modes because they are one
/// gesture -- the plan's fixed words for Run now, an honest cousin for Ask me
/// first -- and one undo: stop the run if one is live (`qt stop`), then file
/// the ask away (the `drop` move).
///
/// Kept pure, next to FireResolve, so the live field and the `--ask-fire`
/// seam land the exact same receipt and spend the exact same undo.
struct AskReceipt: Equatable {
    enum Kind: String {
        case runNow = "run"
        case askFirst = "ask_first"
    }

    let kind: Kind
    /// The stripped text that was fired -- for Run now, the words the new
    /// ask will carry, and what Undo matches the fired ask by.
    let words: String
    let firedAt: Date
    /// The ask id, when the fire already knows it (Ask me first: POST /asks
    /// answered with the ask it created). Run now fires qt locally and knows
    /// no id, so Undo resolves it from the board at click time.
    let askID: String?

    /// `asks.undo_window_s`, the hub's default. The client does not read the
    /// config; the receipt simply stops offering Undo after the same window
    /// the hub's own undo tokens live for, so the two never disagree by much.
    static let undoWindow: TimeInterval = 600

    /// The plan's fixed receipt for Run now (the spec's "Asking" mockup).
    static let runNowLine = "Got it. Running. The answer will come to you here."
    /// Ask me first creates a gate item, not a run -- the receipt says what
    /// actually happens instead of borrowing Run now's "Running".
    static let askFirstLine = "Got it. It waits for your OK."

    var line: String { kind == .runNow ? Self.runNowLine : Self.askFirstLine }

    func undoable(now: Date) -> Bool {
        let age = now.timeIntervalSince(firedAt)
        return age >= 0 && age < Self.undoWindow
    }

    /// The ask this receipt's Undo acts on: the newest board row whose words
    /// (or title) are the fired text and which is still queued or running.
    /// A finished ask has nothing worth stopping, and a mismatched one is
    /// somebody else's fire. The receipt's own window bounds all of this;
    /// the match itself stays deliberately loose about time because the hub's
    /// `created_at` and the client's clock are not one clock.
    static func resolveAskID(in asks: [Ask], words: String) -> String? {
        let fired = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !fired.isEmpty else { return nil }
        var best: (id: String, at: Date)?
        for ask in asks where ask.state == .working || ask.state == .heard {
            let said = ask.words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let titled = ask.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard said == fired || titled == fired else { continue }
            let at = ask.createdDate ?? ask.updatedDate ?? .distantPast
            if best == nil || at > best!.at { best = (ask.id, at) }
        }
        return best?.id
    }

    /// The qt task id an ask id names: the ask is `qt-<tid>`, the task
    /// `qt stop` takes is `<tid>`.
    static func qtTaskID(forAskID id: String) -> String {
        id.hasPrefix("qt-") ? String(id.dropFirst(3)) : id
    }
}

/// The chip's recency menu: distinct `run_cwd` values off the qt ledger,
/// most-recently-created task first, capped. A fixture ledger with entries
/// missing `run_cwd` (a task filed before this field existed) is skipped
/// rather than shown as a blank row.
///
/// Opens and JSON-parses every file under `tasksDir` -- cheap once, not
/// cheap called from a view body. Call this from `StatusController.refresh()`
/// (which already runs off the main thread and already reruns after a
/// successful fire) and read the cached `StatusController.recentDirs` from
/// the view; do not call `load` directly from `FireDirectoryChip.body` or
/// any other `body` again -- that was the typing-lag bug (every keystroke
/// re-scanned and re-parsed every task file on the main thread).
enum RecentDirs {
    static func load(tasksDir: URL, cap: Int = 8) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tasksDir.path) else {
            return []
        }
        struct Entry { let dir: String; let created: Date }
        var entries: [Entry] = []
        for name in names where name.hasSuffix(".json") {
            let url = tasksDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dir = obj["run_cwd"] as? String, !dir.isEmpty else { continue }
            let created = Store.parseDate(obj["created"]) ?? .distantPast
            entries.append(Entry(dir: dir, created: created))
        }
        entries.sort { $0.created > $1.created }
        var seen = Set<String>()
        var out: [String] = []
        for e in entries {
            guard !seen.contains(e.dir) else { continue }
            seen.insert(e.dir)
            out.append(e.dir)
            if out.count == cap { break }
        }
        return out
    }
}
