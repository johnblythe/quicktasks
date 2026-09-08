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
        return [
            "mode": "run",
            "text": stripped,
            "dir": resolved.url.path,
            "dir_source": resolved.source,
            "argv": ["--in", resolved.url.path, stripped],
        ]
    }
}

/// The chip's recency menu: distinct `run_cwd` values off the qt ledger,
/// most-recently-created task first, capped. A fixture ledger with entries
/// missing `run_cwd` (a task filed before this field existed) is skipped
/// rather than shown as a blank row.
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
