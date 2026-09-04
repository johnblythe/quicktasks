// PassStatus.swift -- parsing GET /status.json, and building the two POST
// bodies, as pure functions over Data and dictionaries.
//
// Kept free of URLSession and of AppKit on purpose: every wire-format decision
// in here is exercised by the test suite through `--dump-model`,
// `--dump-capture`, and `--dump-decision`, which is only possible because
// nothing in this file needs a network or a screen.
//
// The contract (hub/serve.py):
//
//   GET /status.json -> {"generated_at", "pass_url",
//                        "groups":[{"key","label","count","undone"}],
//                        "counts":{"running","verify","gate","blocked","failed"},
//                        "jobs":[{"item_id","title","state","status","started",
//                                 "elapsed_s","failed","blocked","session_id",
//                                 "resume_url","report","outputs"}],
//                        "needs_you":[{"item_id","title","state","reason"}]}
//   POST /capture    <- {"text","source"}  -> {"ok":true,"id":"cap-..."}
//   POST /save       <- {"saved_at","decisions":[{id,title,state,action,comment}]}
//
// `needs_you` carries no resume_url and no report, so its rows are joined onto
// `jobs` by item_id to pick up their affordances. A gate item has no job at
// all, which is why the reason has to be able to stand in as the row's status
// text on its own.
//
// Only `item_id` is actually dependable inside a jobs entry. The real payload
// omits `title`, `started`, `elapsed_s`, `failed`, `blocked`, and `session_id`
// from jobs that have nothing to say about them, so every field here is read
// leniently and every derived value has a fallback. `generated_at` arrives as
// UTC with six fractional digits and a `+00:00` offset.

import Foundation

struct PassStatus: Equatable {
    let generatedAt: Date?
    let passURL: String
    let groups: [PassGroup]
    let counts: [String: Int]
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
        var counts: [String: Int] = [:]
        for (k, v) in (obj["counts"] as? [String: Any] ?? [:]) {
            if let n = intValue(v) { counts[k] = n }
        }

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
                                  job: job,
                                  title: (entry["title"] as? String) ?? job?["title"] as? String,
                                  state: (entry["state"] as? String) ?? job?["state"] as? String,
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
                                  job: job,
                                  title: job?["title"] as? String,
                                  state: job?["state"] as? String,
                                  reason: NeedsReason.from(status: jobStatus(job)),
                                  generatedAt: generatedAt))
        }

        return .success(PassStatus(generatedAt: generatedAt,
                                   passURL: passURL,
                                   groups: groups,
                                   counts: counts,
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

    private static func record(itemID: String,
                               job: [String: Any]?,
                               title: String?,
                               state: String?,
                               reason: NeedsReason?,
                               generatedAt: Date?) -> TaskRecord {
        let status = jobStatus(job)
        let resumeURL = (job?["resume_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let started = Store.parseDate(job?["started"])
        let elapsed = doubleValue(job?["elapsed_s"])
        // The contract carries no `finished`, so a terminal row's end time is
        // reconstructed from started + elapsed_s. It only has to be accurate
        // enough to sort the row and to place it in today vs earlier.
        var finished: Date?
        if !status.isActive, status != .unknown, let start = started {
            finished = start.addingTimeInterval(elapsed ?? 0)
        }
        let outputs = (job?["outputs"] as? [Any])?.count ?? 0
        return TaskRecord(
            id: dedupKey(itemID: itemID, resumeURL: resumeURL),
            itemID: itemID,
            title: Store.titleFrom(title ?? itemID),
            status: status,
            state: state,
            reason: reason,
            origin: itemID.hasPrefix("qt-") ? .quicktask : .pass,
            created: started,
            started: started,
            finished: finished,
            sessionId: job?["session_id"] as? String,
            resumeURL: resumeURL,
            report: (job?["report"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            elapsedAtFetch: elapsed,
            // Only when the row brought no clock of its own. A row reported
            // live belongs to today; it just cannot say how old it is.
            feedStamp: started == nil ? generatedAt : nil,
            outputCount: outputs,
            error: job?["error"] as? String,
            denialCount: (job?["denials"] as? [Any])?.count ?? 0)
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
}

// MARK: - request bodies

/// The two POST bodies, built as plain dictionaries so a test can compare them
/// key by key without a live server.
enum PassPayload {
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
