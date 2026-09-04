// PassStatus.swift -- parsing GET /status.json, and building the two POST
// bodies, as pure functions over Data and dictionaries.
//
// Kept free of URLSession and of AppKit on purpose: every wire-format decision
// in here is exercised by the test suite through `--dump-model`,
// `--dump-capture`, and `--dump-decision`, which is only possible because
// nothing in this file needs a network or a screen.
//
// The contract (hub/serve.py, /status.json v2):
//
//   GET /status.json -> {"generated_at", "pass_url", "item_url_template",
//                        "groups":[{"key","label","count","undone"}],
//                        "counts":{"running","verify","gate","blocked","failed",
//                                  "done_today","total_jobs","truncated"},
//                        "jobs":[{"item_id","title","state","status","started",
//                                 "elapsed_s","failed","blocked","session_id",
//                                 "resume_url","report","outputs",
//                                 "finished","error","denials","can_run"}],
//                        "needs_you":[{"item_id","title","state","reason",
//                                      "resume_url","report","session_id",
//                                      "started","can_run"}]}
//   POST /capture    <- {"text","source"}  -> {"ok":true,"id":"cap-..."}
//   POST /run        <- {"id"}             -> {"ok":true,"job":"<slug>"}, or 409
//   POST /save       <- {"saved_at","decisions":[{id,title,state,action,comment}]}
//
// v2 made `needs_you` self-sufficient: it now carries its own resume_url,
// report, session_id, started, and can_run, so a gate item with no job at all
// still arrives with a real timestamp (its ledger date) and a fireable flag.
// The join onto `jobs` by item_id is still done, and still matters -- only the
// job side carries elapsed_s, outputs, error, and the denial count -- so each
// field is taken from the needs_you entry first and from the job second.
//
// Everything v2 added is read as optional. A v1 payload (no finished, no
// denials, no can_run, no item_url_template) still parses: `finished` falls
// back to started + elapsed_s, `denials` reads either an int or the old array,
// the deep link falls back to pass_url, and a row with no `started` at all
// falls back to `generated_at` for ordering only. Titles are now always sent,
// but an empty one still falls back to the item id rather than rendering a
// blank row. `generated_at` and `finished` arrive as UTC with six fractional
// digits and a `+00:00` offset.

import Foundation

struct PassStatus: Equatable {
    let generatedAt: Date?
    let passURL: String
    /// `http://127.0.0.1:<port>/?item={item_id}` -- the deep link a row title
    /// opens, with `{item_id}` substituted. nil on a v1 payload, where the
    /// title falls back to opening the Pass root.
    let itemURLTemplate: String?
    let groups: [PassGroup]
    let counts: [String: Int]
    /// counts.truncated: the Pass caps `jobs` at 200 and says so. Carried
    /// separately from `counts` because it is a flag, not a tally.
    let truncated: Bool
    let records: [TaskRecord]

    /// Parses a /status.json body. Returns .failure only when the payload is
    /// not usable at all; missing optional keys inside a row are tolerated,
    /// because a widget that blanks out on one unexpected null is worse than a
    /// widget showing a row with less detail on it.
    static func decode(_ data: Data, fallbackURL: String) -> Result<PassStatus, Problem> {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else {
            return .failure("status.json is not a JSON object")
        }
        // A response that parses but carries neither list is almost certainly
        // some other server on the port, not an empty Pass.
        guard obj["jobs"] != nil || obj["needs_you"] != nil || obj["counts"] != nil else {
            return .failure("status.json has no jobs/needs_you/counts")
        }

        let passURL = (obj["pass_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackURL
        let itemURLTemplate = (obj["item_url_template"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        // Parsed up front because it stands in for a missing `started`. The
        // real payload leaves `started` and `elapsed_s` off jobs that have no
        // meaningful ones, and a row with no timestamp at all would sort last
        // inside its section and fall into Earlier rather than Done today.
        let generatedAt = Store.parseDate(obj["generated_at"])
        let groups = (obj["groups"] as? [[String: Any]] ?? []).compactMap { g -> PassGroup? in
            guard let key = g["key"] as? String, !key.isEmpty else { return nil }
            return PassGroup(key: key,
                             label: (g["label"] as? String) ?? key,
                             count: intValue(g["count"]) ?? 0,
                             undone: intValue(g["undone"]) ?? 0)
        }
        let countsIn = obj["counts"] as? [String: Any] ?? [:]
        var counts: [String: Int] = [:]
        // `truncated` is a JSON bool sitting in the same object as the tallies.
        // Left out of the int dictionary so nothing reads it as "1 truncated".
        for (k, v) in countsIn where k != "truncated" {
            if let n = intValue(v) { counts[k] = n }
        }
        let truncated = boolValue(countsIn["truncated"]) ?? false

        // 1. Index the jobs by item id, so needs_you can borrow their fields.
        var jobs: [String: [String: Any]] = [:]
        var jobOrder: [String] = []
        for job in obj["jobs"] as? [[String: Any]] ?? [] {
            guard let itemID = job["item_id"] as? String, !itemID.isEmpty else { continue }
            if jobs[itemID] == nil { jobOrder.append(itemID) }
            jobs[itemID] = job
        }

        // 2. needs_you first, so its reason is what lands on the shared row.
        var records: [TaskRecord] = []
        var claimed = Set<String>()
        for entry in obj["needs_you"] as? [[String: Any]] ?? [] {
            guard let itemID = entry["item_id"] as? String, !itemID.isEmpty else { continue }
            guard !claimed.contains(itemID) else { continue }
            claimed.insert(itemID)
            let job = jobs[itemID]
            let reason = NeedsReason(rawValue: ((entry["reason"] as? String) ?? "").lowercased())
            records.append(record(itemID: itemID,
                                  entry: entry,
                                  job: job,
                                  reason: reason ?? NeedsReason.from(
                                      status: jobStatus(job)) ?? .gate,
                                  generatedAt: generatedAt))
        }

        // 3. Every remaining job. A job the Pass did not list under needs_you
        //    but which is blocked or failed still gets a reason, so the widget
        //    never shows a dead run in the quiet tail.
        for itemID in jobOrder where !claimed.contains(itemID) {
            let job = jobs[itemID]
            records.append(record(itemID: itemID,
                                  entry: nil,
                                  job: job,
                                  reason: NeedsReason.from(status: jobStatus(job)),
                                  generatedAt: generatedAt))
        }

        return .success(PassStatus(generatedAt: generatedAt,
                                   passURL: passURL,
                                   itemURLTemplate: itemURLTemplate,
                                   groups: groups,
                                   counts: counts,
                                   truncated: truncated,
                                   records: records))
    }

    // MARK: - one row

    private static func jobStatus(_ job: [String: Any]?) -> TaskStatus {
        guard let job else { return .unknown }
        // The booleans are the Pass's own verdict on the job and outrank the
        // status string, which can still read "done" on a run that failed.
        if job["failed"] as? Bool == true { return .failed }
        if job["blocked"] as? Bool == true { return .blocked }
        return TaskStatus(raw: job["status"] as? String)
    }

    /// One row, built from a needs_you entry, its matching jobs entry, or both.
    /// v2 sends most fields on both sides, so each one is taken from the
    /// needs_you entry first (it is the row's own view of itself) and from the
    /// job second (it is the only side that has elapsed_s, outputs, error, and
    /// denials).
    private static func record(itemID: String,
                               entry: [String: Any]?,
                               job: [String: Any]?,
                               reason: NeedsReason?,
                               generatedAt: Date?) -> TaskRecord {
        let status = jobStatus(job)
        // A JSON null arrives as NSNull, which is present but says nothing --
        // it has to read as absent, or an explicit null on the needs_you side
        // would hide a real value on the job side.
        func field(_ key: String) -> Any? {
            if let value = entry?[key], !(value is NSNull) { return value }
            if let value = job?[key], !(value is NSNull) { return value }
            return nil
        }
        func text(_ key: String) -> String? {
            (field(key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let resumeURL = text("resume_url")
        let started = Store.parseDate(field("started"))
        let elapsed = doubleValue(job?["elapsed_s"])
        // v2 sends `finished` for every terminal job, which is what decides
        // Done today. A v1 payload has none, so a terminal row's end time
        // falls back to started + elapsed_s -- accurate enough to sort the row
        // and to place it in today vs earlier, which is all it is used for.
        var finished = Store.parseDate(job?["finished"])
        if finished == nil, !status.isActive, status != .unknown, let start = started {
            finished = start.addingTimeInterval(elapsed ?? 0)
        }
        let outputs = (job?["outputs"] as? [Any])?.count ?? 0
        // v2 sends a count; v1 sent the array itself.
        let denials = intValue(job?["denials"])
            ?? (job?["denials"] as? [Any])?.count ?? 0
        return TaskRecord(
            id: dedupKey(itemID: itemID, resumeURL: resumeURL),
            itemID: itemID,
            // v2 always sends a title. An empty one still falls back to the id,
            // because a blank row is worse than an ugly one.
            title: Store.titleFrom(text("title") ?? itemID),
            status: status,
            state: text("state"),
            reason: reason,
            origin: itemID.hasPrefix("qt-") ? .quicktask : .pass,
            created: started,
            started: started,
            finished: finished,
            sessionId: text("session_id"),
            resumeURL: resumeURL,
            report: text("report"),
            elapsedAtFetch: elapsed,
            // Only when the row brought no clock of its own. A row reported
            // live belongs to today; it just cannot say how old it is.
            feedStamp: started == nil ? generatedAt : nil,
            outputCount: outputs,
            error: text("error"),
            denialCount: denials,
            // Whether the Pass will accept a POST /run for this item: it has a
            // prompt and is not already running or awaiting a verdict. Same
            // rule the review page's own canRun() applies, computed server-side
            // so the widget and the page cannot drift.
            canRun: boolValue(field("can_run")) ?? false)
    }

    /// The id every feed agrees on, so a Pass row and a qt-ledger row for the
    /// same run collapse instead of showing twice. Same rule as
    /// Store.resumeID: the resume slug when the Pass hands one over, else the
    /// item id with the "qt-" prefix that qt's _feed_hub() added stripped off.
    static func dedupKey(itemID: String, resumeURL: String?) -> String {
        if let slug = resumeSlug(resumeURL), !slug.isEmpty { return slug }
        if itemID.hasPrefix("qt-") { return String(itemID.dropFirst(3)) }
        return itemID
    }

    /// `quicktask://resume/<slug>` -> `<slug>`, percent-decoded.
    static func resumeSlug(_ url: String?) -> String? {
        guard let url, let parsed = URL(string: url), parsed.scheme == "quicktask" else {
            return nil
        }
        let slug = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let raw = slug.isEmpty ? (parsed.host ?? "") : slug
        return raw.removingPercentEncoding ?? raw
    }

    // MARK: - lenient scalars

    /// JSON numbers arrive as NSNumber, but a writer that renders a count as a
    /// string should not blank the field out.
    static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// JSON true/false arrives as an NSNumber, and a hand-written payload or a
    /// future writer could send the string form. Anything else reads as absent
    /// rather than as false, so a caller's own default wins.
    static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - request bodies

/// The three POST bodies, built as plain dictionaries so a test can compare
/// them key by key without a live server.
enum PassPayload {
    /// POST /run. Fires the item's own kickoff prompt as a headless job, the
    /// same thing the review page's fire action posts. One key, so the body is
    /// trivial -- but it goes through the same seam as the other two, so a test
    /// can pin it without a live server.
    static func run(id: String) -> Result<[String: Any], Problem> {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("no item id to run") }
        return .success(["id": trimmed])
    }

    /// The only actions the widget will ever post. serve.py validates nothing,
    /// so this is the only thing standing between a typo and a junk row in
    /// decisions.json.
    static let verdictActions: Set<String> = ["accept", "redo", "reject"]

    static let captureSource = "menubar"

    /// What POST /capture rejects with a 400. Enforced here as well so the
    /// widget can say what is wrong in its own words instead of surfacing an
    /// HTTP status, and so a paste of a whole document never leaves the app.
    static let captureLimit = 4000

    /// POST /capture. Creates a gate item ("needs your go") in The Pass.
    static func capture(text: String, source: String = captureSource) -> Result<[String: Any], Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("nothing to capture") }
        guard trimmed.count <= captureLimit else {
            return .failure("too long to capture: \(trimmed.count) characters, limit is \(captureLimit)")
        }
        return .success(["text": trimmed, "source": source])
    }

    /// POST /save. Same shape the review page posts: a `saved_at` stamp and a
    /// list of decisions, each echoing the item's id, title, and state back
    /// with an action and a comment.
    ///
    /// `pending` is any decision already sitting unreconciled in
    /// hub/decisions.json for a *different* item. serve.py overwrites that file
    /// wholesale on every save, so a one-row post from the menu bar would
    /// otherwise discard a review John saved in the browser and has not run
    /// reconcile.py over yet. Carrying them along is the only way to post a
    /// single decision without losing his.
    static func decisions(id: String,
                          title: String,
                          state: String,
                          action: String,
                          comment: String = "",
                          savedAt: Date = Date(),
                          pending: [[String: Any]] = []) -> Result<[String: Any], Problem> {
        guard !id.isEmpty else { return .failure("no item id") }
        guard verdictActions.contains(action) else {
            return .failure("\(action) is not one of accept/redo/reject")
        }
        let mine: [String: Any] = [
            "id": id,
            "title": title,
            "state": state.isEmpty ? "verify" : state,
            "action": action,
            "comment": comment,
        ]
        let carried = pending.filter { ($0["id"] as? String) != id }
        return .success([
            "saved_at": isoStamp(savedAt),
            "decisions": carried + [mine],
        ])
    }

    /// Decisions still waiting in hub/decisions.json. Empty when the file is
    /// missing, unreadable, or already reset by reconcile.py.
    static func pendingDecisions(hubDir: URL?) -> [[String: Any]] {
        guard let hubDir else { return [] }
        let file = hubDir.appendingPathComponent("decisions.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["decisions"] as? [[String: Any]] else {
            return []
        }
        return list.filter { ($0["id"] as? String)?.isEmpty == false }
    }

    /// `new Date().toISOString()`, which is what the review page sends.
    static func isoStamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func encode(_ body: [String: Any]) -> Result<Data, Problem> {
        guard let data = try? JSONSerialization.data(withJSONObject: body,
                                                     options: [.sortedKeys]) else {
            return .failure("could not serialise request body")
        }
        return .success(data)
    }
}
