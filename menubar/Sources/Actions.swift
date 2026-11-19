// Actions.swift -- everything the widget can do: fire a task, capture to The
// Pass, resume a run, open a report, open the Pass, and post a verdict.
//
// A menu-bar app launched by launchd or as a login item inherits almost no
// PATH, so every binary is resolved explicitly rather than trusted to be
// findable. The only network calls are the loopback ones in PassClient; this
// file shells out and opens URLs.

import Foundation
import AppKit

enum Actions {
    /// The Pass, as served by hub/serve.py.
    static let passURL = URL(string: PassEndpoint.defaultURL + "/")!

    /// Locates the `qt` script. install.sh symlinks it to ~/.local/bin/qt,
    /// which is the first place checked; QT_BIN overrides for a dev checkout.
    static func qtBinary(env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let override = env["QT_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/qt"),
            home.appendingPathComponent("code/quicktasks/qt"),
            URL(fileURLWithPath: "/opt/homebrew/bin/qt"),
            URL(fileURLWithPath: "/usr/local/bin/qt"),
        ]
        // A qt sitting next to the built app, for a checkout-local install.
        let bundleNeighbour = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("qt")
        candidates.append(bundleNeighbour)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Queues a task the same way raycast/quick-task.sh does: `qt --in <dir>
    /// [-m <model>] <prompt>`. `--in` is what makes qt trust the directory the
    /// task actually meant to run in rather than wherever the widget's own
    /// process happens to have as its cwd; `dir` comes from `FireResolve`,
    /// which is also where the widget's own `--in`/`@`-prefix parsing and the
    /// directory chip's precedence live. `model` is the model chip's choice
    /// (`FireResolve.FireModel.resolve`), nil at Default -- it rides the fire
    /// as `qt -m <name>`, one fire, never persisted by this side.
    /// `origin` is qt's source-of-truth for which surface fired it
    /// (LD-224): "widget" for the dropdown, "summon" for the hotkey panel
    /// -- the two call sites this widget has.
    @discardableResult
    static func fire(prompt: String, in dir: URL, model: String? = nil,
                     origin: String) -> Result<Void, Problem> {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("nothing to fire") }
        guard let qt = qtBinary() else {
            return .failure("qt not found; run install.sh")
        }
        let p = Process()
        p.executableURL = qt
        var arguments = ["--in", dir.path]
        if let model { arguments += ["-m", model] }
        arguments.append(text)
        p.arguments = arguments
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["QT_ORIGIN"] = origin
        p.environment = env
        // qt detaches the run itself, so this returns as soon as it is queued.
        do {
            try p.run()
        } catch {
            return .failure("could not run qt: \(error.localizedDescription)")
        }
        return .success(())
    }

    /// Reopens a run in John's preferred terminal. The quicktask:// handler
    /// installed by `qt install-handler` is the same path Slack resume links
    /// take, so this shares its terminal choice and cmux behaviour. Falls back
    /// to invoking qt directly when the handler is not registered.
    @discardableResult
    static func resume(id: String) -> Result<Void, Problem> {
        guard !id.isEmpty else { return .failure("no task id") }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        if let url = URL(string: "quicktask://resume/\(encoded)"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return .success(())
        }
        guard let qt = qtBinary() else {
            return .failure("no quicktask:// handler and no qt binary; run qt install-handler")
        }
        let p = Process()
        p.executableURL = qt
        p.arguments = ["_resume-launch", id]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            try p.run()
        } catch {
            return .failure("could not run qt resume: \(error.localizedDescription)")
        }
        return .success(())
    }

    /// Reopens a run, preferring the resume URL The Pass handed over so the
    /// widget follows the server's idea of the slug rather than deriving it.
    @discardableResult
    static func resume(record: TaskRecord) -> Result<Void, Problem> {
        if let raw = record.resumeURL, !raw.isEmpty, let url = URL(string: raw) {
            if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                return .success(())
            }
            // No handler registered: fall through to the qt path with the slug
            // out of the URL, which is the same id `qt resume` takes.
            if let slug = PassStatus.resumeSlug(raw), !slug.isEmpty {
                return resume(id: slug)
            }
        }
        return resume(id: record.id)
    }

    /// The task's RESULT.md on disk, opened in the default viewer -- the
    /// same artifact `qt open <id>` opens (2026-11-03: "I can't access the
    /// actual info"). The hub mirror is the durable copy, so the glob runs
    /// against the hub's jobs dir by item id (jobs/<item-id>-<ts>/), newest
    /// first. A failure here is not dead-end: callers fall back to the
    /// report/Pass page.
    @discardableResult
    static func openResult(record: TaskRecord, hubJobsDir: URL?) -> Result<Void, Problem> {
        guard let dir = hubJobsDir else { return .failure("no hub jobs dir configured") }
        let prefix = (record.itemID ?? record.id) + "-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return .failure("cannot read \(dir.path)")
        }
        for name in names.filter({ $0.hasPrefix(prefix) }).sorted().reversed() {
            let result = dir.appendingPathComponent(name)
                .appendingPathComponent("output").appendingPathComponent("RESULT.md")
            if FileManager.default.fileExists(atPath: result.path) {
                NSWorkspace.shared.open(result)
                return .success(())
            }
        }
        return .failure("no RESULT.md on disk for \(record.id)")
    }

    /// Copy-to-clipboard for the peek panel's result text.
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - The Pass

    static func openPass(_ base: String = PassEndpoint.defaultURL) {
        NSWorkspace.shared.open(URL(string: base) ?? passURL)
    }

    /// The Pass's deep link to one item, from `/status.json`'s
    /// `item_url_template` (`http://127.0.0.1:<port>/?item={item_id}`) with the
    /// id substituted. serve.py reads that query parameter and build() scrolls
    /// the item into view, so the title now lands on the row rather than on the
    /// top of the page.
    ///
    /// Falls back to the Pass root when there is no template (a v1 payload, or
    /// the file feed) or no item id (a freshly fired quicktask The Pass has not
    /// heard about yet), because opening the page is still better than a dead
    /// click.
    static func itemURL(template: String?, base: String, itemID: String?) -> URL? {
        guard let template, !template.isEmpty,
              let itemID, !itemID.isEmpty,
              template.contains(idPlaceholder) else {
            return URL(string: base) ?? passURL
        }
        // RFC 3986 unreserved only, not .urlQueryAllowed: the id goes in as a
        // query *value*, so an "&" in it has to be escaped rather than end the
        // parameter. Ids are normally slugs; captures are the ones that are not.
        let unreserved = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        let encoded = itemID.addingPercentEncoding(
            withAllowedCharacters: unreserved) ?? itemID
        let filled = template.replacingOccurrences(of: idPlaceholder, with: encoded)
        // A template that came back unusable is not worth a dead click either.
        return URL(string: filled) ?? URL(string: base) ?? passURL
    }

    /// The token serve.py leaves in `item_url_template`.
    static let idPlaceholder = "{item_id}"

    @discardableResult
    static func openItem(template: String?, base: String, itemID: String?) -> Result<Void, Problem> {
        guard let url = itemURL(template: template, base: base, itemID: itemID) else {
            return .failure("no link for this row")
        }
        NSWorkspace.shared.open(url)
        return .success(())
    }

    /// Fires an item's own kickoff prompt as a headless job, through The Pass
    /// rather than through qt: the prompt lives in the ledger, not in the
    /// widget, and `POST /run` is the route that already knows how to spawn it
    /// under the three-slot limit. Returns the job slug it started.
    static func run(record: TaskRecord, base: URL) -> Result<String, Problem> {
        guard let itemID = record.itemID, !itemID.isEmpty else {
            return .failure("row has no Pass item id")
        }
        return PassClient(base: base).run(id: itemID)
    }

    /// Sends a delivered row back to Verify, through `POST /revive`. Only
    /// offered when the row's `revivable` flag says the hub will accept it
    /// (LD-224); a 404 from an older hub with no such route just reads as a
    /// plain action error, same as any other failure here.
    static func revive(record: TaskRecord, base: URL) -> Result<String, Problem> {
        guard let itemID = record.itemID, !itemID.isEmpty else {
            return .failure("row has no Pass item id")
        }
        return PassClient(base: base).revive(id: itemID)
    }

    /// Joins /status.json's root-relative `report` path onto its `pass_url`.
    /// The report is served over http because a file:// link is dead from an
    /// http:// page, and serve.py sandboxes the response.
    static func reportURL(base: String, report: String) -> URL? {
        guard !report.isEmpty else { return nil }
        guard let root = URL(string: base) else { return nil }
        if let absolute = URL(string: report), absolute.scheme != nil { return absolute }
        return URL(string: report, relativeTo: root)?.absoluteURL
    }

    @discardableResult
    static func openReport(base: String, report: String?) -> Result<Void, Problem> {
        guard let report, let url = reportURL(base: base, report: report) else {
            return .failure("no report on this row")
        }
        NSWorkspace.shared.open(url)
        return .success(())
    }

    /// Sends the quick-fire text to The Pass as a gate item instead of running
    /// it. Returns the id the Pass assigned, for the flash message.
    static func capture(text: String, base: URL) -> Result<String, Problem> {
        PassClient(base: base).capture(text: text)
    }

    // MARK: - asks: yours, find, desk (Q11)

    /// `GET /asks/search?q=` (contract 1.6, H11): every ask ever -- done and
    /// archived included, unlike the list -- whose words, answer, or title
    /// match the query. Refusals and transport failures come back as plain
    /// Problems; an empty query is not a request at all.
    static func searchAsks(base: URL, query: String) -> Result<[AskSearchHit], Problem> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .success([]) }
        var parts = URLComponents(url: base.appendingPathComponent("asks/search"),
                                  resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = parts?.url else { return .failure("bad search URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        switch AskClient.send(request, timeout: 8) {
        case .success(let reply):
            return AskSearchHit.decode(reply.data)
        case .failure(let failure):
            // A refusal that carried the hub's own message shows that
            // message -- "search is off" -- never "HTTP 500: {…}".
            if let obj = (try? JSONSerialization.jsonObject(with: failure.body)) as? [String: Any],
               let message = obj["message"] as? String, !message.isEmpty {
                return .failure(Problem(message))
            }
            return .failure(failure.code == 404
                            ? Problem("this Pass has no ask search")
                            : failure.problem)
        }
    }

    /// The body POST /asks carries for mode "remind" (contract 1.6, H12):
    /// the same shape askFirst sends -- text, mode, door, the directory a
    /// Run-now fire of the same words would use -- plus the reminder time.
    static func remindBody(text: String, dir: URL?, remindAt: Date) -> [String: Any] {
        var body: [String: Any] = [
            "text": text,
            "mode": "remind",
            // Section 1.3's door table: menubar (widget or summon) -> typed.
            "door": "typed",
        ]
        if let dir { body["dir"] = dir.path }
        body["remind_at"] = isoStamp(remindAt)
        return body
    }

    /// ⌥⏎ Remind me instead: `POST /asks {mode: "remind"}` -- the typed
    /// words become a todo of John's with a reminder time, not a run. Every
    /// refusal comes back as a MoveResult so the hub's own message is what
    /// shows ("creating an ask is not built yet", on a hub that has not
    /// shipped H12) -- never a dead button, and no /capture fallback: a
    /// silently captured item is not a reminder.
    static func remind(text: String, dir: URL?, remindAt: Date, base: URL) -> MoveResult {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return .transportFailure("nothing to ask") }
        guard let body = try? JSONSerialization.data(
                withJSONObject: remindBody(text: stripped, dir: dir, remindAt: remindAt)) else {
            return .transportFailure("the ask body is not JSON")
        }
        var request = URLRequest(url: base.appendingPathComponent("asks"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 8
        switch AskClient.send(request, timeout: 8) {
        case .success(let reply):
            return MoveResult.parse(status: reply.code, data: reply.data)
        case .failure(let failure) where failure.code == 0:
            return .transportFailure(failure.problem.message)
        case .failure(let failure):
            return MoveResult.parse(status: failure.code, data: failure.body)
        }
    }

    /// The `remind` move on an existing ask (contract 1.6: `at|null`) -- the
    /// knob a yours row carries. `at` nil clears the reminder.
    static func remindMove(id: String, at: Date?, base: URL) -> MoveResult {
        AskClient(base: base).post(id: id, move: "remind",
                                   body: ["at": at.map(Self.isoStamp) ?? NSNull()])
    }

    /// The one ISO 8601 shape the hub speaks for `remind_at` (and every
    /// other stamp): internet date-time, local offset, no sub-second drift.
    static func isoStamp(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        // Local offset, the shape every stamp in the contract carries
        // ("2026-11-17T09:45:12-05:00"). ISO8601DateFormatter's own default
        // is GMT, which would hand the hub a time five hours off the clock
        // the reminder is meant for.
        f.timeZone = .current
        return f
    }()

    /// ⌘D's target: the hub's desk (H9) lives at base + /desk, on the same
    /// base every ask read and write uses.
    static func deskURL(base: URL) -> URL {
        base.appendingPathComponent("desk")
    }

    // MARK: - asks (Q12)

    /// What one Ask-me-first send came back as: which of the two routes took
    /// it, and the id that route assigned.
    enum AskFirstOutcome: Equatable {
        /// POST /asks answered (201): the ask the hub created, waiting for
        /// John's go.
        case posted(askID: String?)
        /// This hub has not built POST /asks yet -- a 501 (the move table's
        /// "registered but not built" answer creation gives today) or a 404
        /// (a hub that predates the route) -- and today's /capture To-Pass
        /// path took it instead, exactly as the plan's fallback says.
        case fellBack(capturedID: String?)

        /// One word for the seam and the outcome queue: which route took it.
        var route: String {
            if case .posted = self { return "asks" }
            return "capture"
        }

        /// The id the route that took it assigned -- the ask POST /asks
        /// created, or the item /capture filed.
        var id: String? {
            switch self {
            case .posted(let askID): return askID
            case .fellBack(let capturedID): return capturedID
            }
        }
    }

    /// ⌘⏎ Ask me first: `POST /asks {text, mode: "ask_first", door, dir}`
    /// (contract 1.6). The text arrives already stripped of its `--in`/`@`
    /// prefix and `dir` is the directory that prefix (or the chip) resolved
    /// to -- the same directory a Run-now fire of the same words would use,
    /// which is the whole point of sending it along.
    ///
    /// On 501/404 the send falls back to today's `/capture` To-Pass path
    /// with the raw, unstripped text -- To Pass has always ignored the
    /// prefix, and the fallback is meant to be byte-for-byte the old mode,
    /// not a near copy of it. Any other refusal is a real failure and is
    /// reported as one rather than retried against /capture, the same line
    /// `decide`'s own 404-only fallback draws.
    static func askFirst(text: String, rawText: String, dir: URL?, model: String? = nil,
                         base: URL) -> Result<AskFirstOutcome, Problem> {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return .failure("nothing to ask") }
        guard let body = try? JSONSerialization.data(
                withJSONObject: FireResolve.askFirstBody(text: stripped, dir: dir,
                                                         model: model)) else {
            return .failure("the ask body is not JSON")
        }
        var request = URLRequest(url: base.appendingPathComponent("asks"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 8
        // AskClient's transport, not PassClient's: a refusal's status code is
        // the thing this caller branches on, and PassClient's throws it away.
        switch AskClient.send(request, timeout: 8) {
        case .success(let reply):
            let obj = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
            let id = (obj?["ask"] as? [String: Any])?["id"] as? String
            return .success(.posted(askID: id))
        case .failure(let failure) where failure.code == 501 || failure.code == 404:
            switch PassClient(base: base).capture(text: rawText) {
            case .failure(let problem): return .failure(problem)
            case .success(let capturedID): return .success(.fellBack(capturedID: capturedID))
            }
        case .failure(let failure):
            return .failure(failure.problem)
        }
    }

    /// The receipt's Undo, first half: `qt stop <tid>` -- kill the run, mark
    /// the task "Stopped by you". Waits for exit because stop is a quick,
    /// bounded verb and the drop that follows wants to know it took (a drop
    /// against a still-running ask is a 409 the hub is right to send). Only
    /// ever called off the main thread.
    @discardableResult
    static func stopQtTask(askID: String) -> Result<Void, Problem> {
        let tid = AskReceipt.qtTaskID(forAskID: askID)
        guard !tid.isEmpty else { return .failure("no task id to stop") }
        guard let qt = qtBinary() else {
            return .failure("qt not found; run install.sh")
        }
        let p = Process()
        p.executableURL = qt
        p.arguments = ["stop", tid]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return .failure("could not run qt stop: \(error.localizedDescription)")
        }
        return .success(())
    }

    /// Posts one verdict for a verify row, in the same shape the review page's
    /// Save button posts. Any decision already sitting unreconciled in
    /// hub/decisions.json rides along, because serve.py overwrites that file
    /// wholesale and a one-row post would otherwise drop John's saved review.
    static func decide(record: TaskRecord,
                       action: String,
                       comment: String = "",
                       base: URL,
                       hubDir: URL?) -> Result<Void, Problem> {
        PassClient(base: base).decide(record: record,
                                      action: action,
                                      comment: comment,
                                      pending: PassPayload.pendingDecisions(hubDir: hubDir))
    }

    /// One of confirm / deny / go / snooze on a suggestion, through
    /// `POST /decide`, falling back to `POST /save` on a Pass that has not
    /// shipped the route yet.
    ///
    /// The fallback is the old wholesale save, so it still has to carry every
    /// unreconciled decision along -- that is exactly the hazard `/decide`
    /// exists to remove, and until the route lands the widget cannot pretend it
    /// already has. It also has to translate the verb: `/save` knows accept /
    /// redo / reject and nothing else, so a suggestion's four answers map onto
    /// the two that mean the same thing there, and the other two are refused
    /// rather than mistranslated. "This Pass cannot snooze yet" is honest;
    /// posting "accept" for a snooze would file the wrong decision.
    static func decideSuggestion(id: String,
                                 title: String,
                                 action: String,
                                 base: URL,
                                 hubDir: URL?) -> Result<String, Problem> {
        let outcome = PassClient(base: base).decide(id: id, action: action) {
            guard let legacy = legacyVerdict(for: action) else {
                return .failure("this Pass is too old to \(action) a suggestion")
            }
            return PassClient(base: base).decide(
                record: TaskRecord(id: id, itemID: id, title: title,
                                   status: .unknown, state: "suggest", origin: .pass),
                action: legacy,
                pending: PassPayload.pendingDecisions(hubDir: hubDir))
        }
        return outcome.map { how in
            let verb = ["confirm": "Confirmed", "deny": "Denied",
                        "go": "Fired", "snooze": "Snoozed"][action] ?? "Done"
            // Says which route took it. "Confirmed (old Pass)" is the same
            // outcome for John and a different one for anyone wondering why a
            // decision landed on top of somebody else's.
            return how == .fellBackToSave ? "\(verb) (old Pass)" : verb
        }
    }

    /// How a suggestion's answer reads to a Pass that only has `/save`.
    /// Confirm and deny have honest equivalents there; go and snooze do not,
    /// and are refused rather than approximated.
    static func legacyVerdict(for action: String) -> String? {
        switch action {
        case "confirm": return "accept"
        case "deny": return "reject"
        default: return nil
        }
    }
}

// MARK: - search hits (Q11)

/// One `GET /asks/search` result: a full ask row -- the same shape every
/// other list serves, so a found ask renders as a row with its own moves and
/// opens at its one address -- plus where the query matched and a snippet of
/// the matching text. Tolerant row by row: one bad hit never costs the rest.
struct AskSearchHit: Equatable, Identifiable {
    let ask: Ask
    let match: String?
    let snippet: String?

    var id: String { ask.id }

    /// Where the query hit, as a person reads it. The hub's own word kept
    /// verbatim when it is not one of the three the contract names.
    var matchLabel: String? {
        switch match {
        case "words": return "in the words"
        case "answer": return "in the answer"
        case "title": return "in the title"
        case nil: return nil
        default: return "in the \(match ?? "")"
        }
    }

    static func decode(_ data: Data) -> Result<[AskSearchHit], Problem> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawHits = obj["asks"] as? [Any] else {
            return .failure("/asks/search did not return a list of asks")
        }
        var hits: [AskSearchHit] = []
        for raw in rawHits {
            guard let row = raw as? [String: Any],
                  JSONSerialization.isValidJSONObject(row),
                  let bytes = try? JSONSerialization.data(withJSONObject: row),
                  let ask = try? JSONDecoder().decode(Ask.self, from: bytes) else { continue }
            hits.append(AskSearchHit(ask: ask,
                                     match: row["match"] as? String,
                                     snippet: row["snippet"] as? String))
        }
        return .success(hits)
    }
}

// MARK: - reminder times (Q11)

/// The time a reminder fires at, read from the few shapes a person types
/// into the ⌥⏎ picker -- "3:30", "3p", "15:30", "in 2h", "tonight",
/// "tomorrow 9a". Pure, so the picker, the view, and the `--ask-remind` seam
/// all read one parser and cannot disagree about what a time means.
///
/// A time of day lands on its next occurrence (3:30 already past today is
/// tomorrow's 3:30); a bare hour without an am/pm marker is taken as the
/// 24-hour clock, so "9a"/"9p" are how an ambiguous hour says which it
/// meant. `nil` from a non-empty spec means unreadable; an *empty* spec is
/// nil too, and the caller decides what that defaults to.
enum RemindTime {
    /// Whether a spec means "clear the reminder" rather than "set one".
    static func isClear(_ raw: String) -> Bool {
        let spec = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["none", "clear", "off", "never"].contains(spec)
    }

    static func parse(_ raw: String, now: Date) -> Date? {
        let spec = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !spec.isEmpty, !isClear(spec) else { return nil }
        if let relative = relative(spec, now: now) { return relative }
        if spec == "tonight" { return date(hour: 18, minute: 0, onOrAfter: now) }
        if spec == "tomorrow" { return date(hour: 9, minute: 0, onOrAfter: now, dayOffset: 1) }
        if spec.hasPrefix("tomorrow ") {
            guard let time = clockTime(String(spec.dropFirst("tomorrow ".count))) else { return nil }
            return date(hour: time.hour, minute: time.minute, onOrAfter: now, dayOffset: 1)
        }
        guard let time = clockTime(spec) else { return nil }
        return date(hour: time.hour, minute: time.minute, onOrAfter: now)
    }

    /// The picker's display shape, fixed locale so a test reads what the
    /// menu will draw whatever the machine is set to.
    static func text(for date: Date) -> String {
        Self.display.string(from: date)
    }

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    /// "in 2h" / "45m" / "in 1 hour" / "in 30 minutes": now plus the span.
    /// Unit words count as much as their letters -- a person types the word
    /// the placeholder shows.
    private static func relative(_ spec: String, now: Date) -> Date? {
        var text = spec
        if text.hasPrefix("in ") { text = String(text.dropFirst(3)) }
        text = text.replacingOccurrences(of: " ", with: "")
        let unitWords: [(String, String)] = [
            ("hours", "h"), ("hour", "h"), ("hrs", "h"), ("hr", "h"),
            ("minutes", "m"), ("minute", "m"), ("mins", "m"), ("min", "m"),
            ("days", "d"), ("day", "d"),
        ]
        for (word, letter) in unitWords where text.hasSuffix(word) {
            text = String(text.dropLast(word.count)) + letter
            break
        }
        guard let unit = text.last, "hmd".contains(unit),
              let span = Double(text.dropLast()), span > 0, span <= 24 * 30 else { return nil }
        let seconds: TimeInterval
        switch unit {
        case "h": seconds = span * 3600
        case "m": seconds = span * 60
        default: seconds = span * 86400
        }
        return now.addingTimeInterval(seconds)
    }

    /// "9", "9a", "9p", "9am", "9:30", "9:30p", "9:30 pm", "15:30".
    private static func clockTime(_ spec: String) -> (hour: Int, minute: Int)? {
        var text = spec.replacingOccurrences(of: " ", with: "").lowercased()
        var pm: Bool?
        if text.hasSuffix("pm") { pm = true; text = String(text.dropLast(2)) }
        else if text.hasSuffix("am") { pm = false; text = String(text.dropLast(2)) }
        else if text.hasSuffix("p") { pm = true; text = String(text.dropLast()) }
        else if text.hasSuffix("a") { pm = false; text = String(text.dropLast()) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard minute >= 0, minute < 60 else { return nil }
        if pm != nil {
            guard hour >= 1, hour <= 12 else { return nil }
            return (hour % 12 + (pm! ? 12 : 0), minute)
        }
        guard hour >= 0, hour <= 23 else { return nil }
        return (hour, minute)
    }

    /// A time of day on today's date (or `dayOffset` days out), rolled to
    /// tomorrow when today's has already passed.
    private static func date(hour: Int, minute: Int, onOrAfter now: Date,
                             dayOffset: Int = 0) -> Date? {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        guard let at = calendar.date(from: comps) else { return nil }
        if at <= now { return calendar.date(byAdding: .day, value: 1, to: at) }
        return at
    }
}
