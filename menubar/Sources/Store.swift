// Store.swift -- reads task state off disk. No network, no serve.py dependency.
//
// Two ledgers hold the truth, and they mirror into each other on completion:
//
//   ~/.quicktasks/tasks/<id>.json      qt's ledger. Hub jobs are copied in
//                                      here by hub/run-job.sh when they
//                                      finish, tagged "source": "pass".
//   <hub>/jobs/<slug>/job.json         hub's ledger. qt tasks are copied in
//                                      here by qt's _feed_hub() when they
//                                      finish, with item_id "qt-<task id>".
//
// Reading only the qt ledger would miss a Pass job while it is still running,
// which is exactly the state the widget exists to show, so both are read and
// deduplicated. The dedup key is the id `qt resume` accepts:
//
//   qt task            -> its own id
//   hub job "qt-<t>"   -> t            (collapses onto the qt ledger row)
//   hub job otherwise  -> its dir name (collapses onto the mirrored "pass" row)
//
// serve.py is deliberately not used: it exposes only GET / (full HTML),
// /search, and /job/<item_id>, so there is no aggregate JSON route to poll,
// and reading files means the widget still works when The Pass is not running.

import Foundation

struct StoreConfig {
    let tasksDir: URL
    /// The hub checkout itself, for the files that are not under jobs/ --
    /// decisions.json, which has to be preserved across a one-row POST /save.
    let hubDir: URL?
    /// nil when the hub feed is off, matching qt's resolve_hub_dir(): QT_HUB
    /// overrides config.json's "hub_dir", and unset means off.
    let hubJobsDir: URL?
    /// Base URL of The Pass, or nil when the HTTP feed is switched off with
    /// QT_PASS_URL="" and only the file ledgers should be read.
    let passURL: URL?
    let limit: Int

    static func resolve(env: [String: String] = ProcessInfo.processInfo.environment,
                        limit: Int = 12) -> StoreConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let qtData = env["QT_DATA"].map { URL(fileURLWithPath: expand($0)) }
            ?? home.appendingPathComponent(".quicktasks")

        var hub = env["QT_HUB"].flatMap { $0.isEmpty ? nil : expand($0) }
        if hub == nil {
            let cfg = qtData.appendingPathComponent("config.json")
            if let data = try? Data(contentsOf: cfg),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dir = obj["hub_dir"] as? String, !dir.isEmpty {
                hub = expand(dir)
            }
        }
        let hubURL = hub.map { URL(fileURLWithPath: $0) }
        return StoreConfig(
            tasksDir: qtData.appendingPathComponent("tasks"),
            hubDir: hubURL,
            hubJobsDir: hubURL?.appendingPathComponent("jobs"),
            passURL: PassEndpoint.resolve(env: env),
            limit: limit)
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

enum Store {
    /// Reads both ledgers and returns the deduplicated, ordered menu model.
    static func load(config: StoreConfig, now: Date = Date()) -> MenuModel {
        var byID: [String: TaskRecord] = [:]
        var problems: [String] = []

        // qt ledger first, so a live hub job read second can overwrite the
        // stale mirrored copy of itself.
        switch readQuicktasks(config.tasksDir) {
        case .success(let records):
            for r in records { byID[r.id] = r }
        case .failure(let message):
            problems.append(message.message)
        }

        if let jobs = config.hubJobsDir {
            switch readHubJobs(jobs) {
            case .success(let records):
                for r in records {
                    // Prefer whichever copy of the run is further along. A
                    // finished qt-ledger row beats a job.json still marked
                    // running (and vice versa) because the two are written at
                    // different moments and either can be the stale one.
                    if let existing = byID[r.id], rank(existing) >= rank(r) { continue }
                    byID[r.id] = r
                }
            case .failure(let message):
                problems.append(message.message)
            }
        }

        // Trim after ordering so the newest and the acting rows survive.
        return MenuModel.build(
            records: Array(byID.values),
            now: now,
            warning: problems.isEmpty ? nil : problems.joined(separator: " · "),
            source: .files,
            passURL: config.passURL?.absoluteString ?? PassEndpoint.defaultURL
        ).trimmed(to: config.limit)
    }

    /// Terminal states outrank in-flight ones: a run that has a finished
    /// timestamp is later news than one that does not.
    static func rank(_ r: TaskRecord) -> Int {
        if r.finished != nil { return 2 }
        if r.status.isActive { return 1 }
        return 0
    }

    // MARK: - qt ledger

    static func readQuicktasks(_ dir: URL) -> Result<[TaskRecord], Problem> {
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return .success([])  // qt not installed yet is not an error
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return .failure("cannot read \(dir.path)")
        }
        var out: [TaskRecord] = []
        for name in names where name.hasSuffix(".json") {
            guard let obj = readJSONObject(dir.appendingPathComponent(name)) else { continue }
            guard let id = obj["id"] as? String, !id.isEmpty else { continue }
            let prompt = (obj["prompt"] as? String) ?? ""
            out.append(TaskRecord(
                id: id,
                title: titleFrom(prompt.isEmpty ? id : prompt),
                status: TaskStatus(raw: obj["status"] as? String),
                origin: (obj["source"] as? String) == "pass" ? .pass : .quicktask,
                created: parseDate(obj["created"]),
                started: parseDate(obj["started"]),
                finished: parseDate(obj["finished"]),
                sessionId: obj["session_id"] as? String,
                error: obj["result"] as? String,
                denialCount: (obj["denials"] as? [Any])?.count ?? 0))
        }
        return .success(out)
    }

    // MARK: - hub ledger

    static func readHubJobs(_ dir: URL) -> Result<[TaskRecord], Problem> {
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return .success([])  // hub feed configured but not populated yet
        }
        guard let slugs = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return .failure("cannot read \(dir.path)")
        }
        var out: [TaskRecord] = []
        for slug in slugs {
            let jobFile = dir.appendingPathComponent(slug).appendingPathComponent("job.json")
            guard let obj = readJSONObject(jobFile) else { continue }
            let itemID = (obj["item_id"] as? String) ?? ""
            let title = (obj["title"] as? String) ?? slug
            out.append(TaskRecord(
                id: resumeID(jobSlug: slug, itemID: itemID),
                // Carried even though the file feed cannot post a decision:
                // it is the id every Pass route is keyed by, and the file
                // already knows it.
                itemID: itemID.isEmpty ? nil : itemID,
                title: titleFrom(title),
                status: TaskStatus(raw: obj["status"] as? String),
                origin: itemID.hasPrefix("qt-") ? .quicktask : .pass,
                created: parseDate(obj["started"]),
                started: parseDate(obj["started"]),
                finished: parseDate(obj["finished"]),
                sessionId: obj["session_id"] as? String,
                error: obj["error"] as? String,
                denialCount: (obj["denials"] as? [Any])?.count ?? 0))
        }
        return .success(out)
    }

    /// The id `qt resume` accepts for a hub job. hub/run-job.sh registers the
    /// job's *directory name* as a quicktask id, and qt's _feed_hub() writes
    /// item_id "qt-<task id>" for runs that started life as quicktasks, so a
    /// "qt-" prefix means the original task id is the resume target.
    static func resumeID(jobSlug: String, itemID: String) -> String {
        if itemID.hasPrefix("qt-") { return String(itemID.dropFirst(3)) }
        return jobSlug
    }

    // MARK: - helpers

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One line, trimmed to something that fits a menu row. Matches the
    /// 60-char budget hub's _hub_title() already uses for job titles.
    static func titleFrom(_ raw: String) -> String {
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= 60 { return flat }
        return String(flat.prefix(59)) + "\u{2026}"
    }

    /// Both ledgers write `datetime.isoformat(timespec="seconds")`, i.e. local
    /// time with no zone. Zoned and fractional forms are accepted too so a
    /// future writer switching to UTC does not blank out every timestamp.
    static func parseDate(_ value: Any?) -> Date? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else {
            return nil
        }
        let iso = ISO8601DateFormatter()
        for options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] as [ISO8601DateFormatter.Options] {
            iso.formatOptions = options
            if let d = iso.date(from: s) { return d }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let d = local.date(from: s) { return d }
        }
        return nil
    }
}
