// Feed.swift -- picks where the model comes from, and merges when both have
// something to say.
//
// The Pass is preferred because it is the only source that knows about the
// half of the loop the files do not: an item held at a gate has no job and no
// ledger row, and a finished job awaiting a verdict looks identical to a
// finished job that is done. When /status.json does not answer, the widget
// falls back to the v1 file model and says so in the footer.
//
// Even in Pass mode the qt ledger is still read. A task fired with `qt` (or
// with this widget's own quick-fire) does not reach The Pass until it
// finishes, and "I just fired that and it is not in the list" is exactly the
// moment the widget loses trust. The hub jobs/ directory is *not* read in Pass
// mode: /status.json already covers it, and reading both would mean two
// answers for the same run.

import Foundation

enum Feed {
    /// How long a Pass that stops answering keeps showing its last successful
    /// model before the widget gives up and falls back to the file ledgers.
    /// Long enough to ride out one wedged poll (the Pass server is
    /// single-threaded and does stall) or a restart without the header
    /// flapping between two different counts every 5 seconds; short enough
    /// that a Pass that is actually down for a while still says so.
    static let holdWindow: TimeInterval = 90

    /// `previous` is the model this same feed returned last poll -- the
    /// widget's own memory of "the last thing that actually worked", not
    /// anything re-derived here. Nil on the very first poll, and whenever a
    /// caller (a one-shot `--dump-*` seam) has nothing to carry forward;
    /// either way a failure then falls straight to the files, same as before
    /// the hold existed.
    static func load(config: StoreConfig,
                     now: Date = Date(),
                     previous: MenuModel? = nil,
                     client: PassClient? = nil) -> MenuModel {
        guard let passURL = config.passURL else {
            return Store.load(config: config, now: now)
        }
        let pass = client ?? PassClient(base: passURL)
        switch pass.status() {
        case .failure(let problem):
            return held(problem: problem, config: config, now: now,
                       previous: previous, passURL: passURL)
        case .success(let status):
            return merge(status: status, config: config, now: now)
        }
    }

    /// What a failed poll shows: the last successful Pass model, unchanged,
    /// for up to `holdWindow` seconds past the *first* failure in a run of
    /// them -- so the count on screen never alternates between a Pass number
    /// and a file-feed number from one 5-second poll to the next. Falls back
    /// to the file ledgers once the window runs out, and marks the fallback
    /// so the headline can say the Pass is the reason.
    private static func held(problem: Problem,
                             config: StoreConfig,
                             now: Date,
                             previous: MenuModel?,
                             passURL: URL,
                             holdWindow: TimeInterval = Feed.holdWindow) -> MenuModel {
        if let previous, previous.source == .pass {
            // `previous` is either the last live poll (passStaleSince nil --
            // this is the first failure) or itself already a held model
            // (passStaleSince set -- carry the *original* failure time
            // forward rather than resetting the clock on every subsequent
            // failed poll).
            let staleSince = previous.passStaleSince ?? now
            let deadline = previous.heldUntil ?? staleSince.addingTimeInterval(holdWindow)
            if now < deadline {
                return MenuModel(records: previous.records,
                                 aggregate: previous.aggregate,
                                 refreshedAt: previous.refreshedAt,
                                 warning: previous.warning,
                                 source: .pass,
                                 passURL: passURL.absoluteString,
                                 passError: problem.message,
                                 groups: previous.groups,
                                 itemURLTemplate: previous.itemURLTemplate,
                                 counts: previous.counts,
                                 truncated: previous.truncated,
                                 suggestions: previous.suggestions,
                                 suggestionsAvailable: previous.suggestionsAvailable,
                                 visibleSections: config.settings.visibleSections,
                                 passReachable: false,
                                 passStaleSince: staleSince,
                                 heldUntil: deadline)
            }
            // The window ran out and the Pass is still not answering: give up
            // and show the files, but keep `passStaleSince` so the headline
            // can say file feeds are standing in for a Pass that went down,
            // not that no Pass was ever configured.
            let files = Store.load(config: config, now: now)
            return MenuModel(records: files.records,
                             aggregate: files.aggregate,
                             refreshedAt: files.refreshedAt,
                             warning: files.warning,
                             source: .files,
                             passURL: passURL.absoluteString,
                             passError: problem.message,
                             groups: [],
                             visibleSections: config.settings.visibleSections,
                             passReachable: false,
                             passStaleSince: staleSince)
        }
        if let previous, previous.source == .files, let staleSince = previous.passStaleSince {
            // Already gave up on a Pass that went down and still is not
            // answering. Once the fallback above fires once, `previous.source`
            // is `.files` forever after, so without this branch every
            // following failed poll would fall into the "never had a Pass"
            // case below and silently drop `passStaleSince` -- erasing the
            // "Pass down" suffix from the headline on the very next poll
            // after the fallback happened. Keep saying why.
            let files = Store.load(config: config, now: now)
            return MenuModel(records: files.records,
                             aggregate: files.aggregate,
                             refreshedAt: files.refreshedAt,
                             warning: files.warning,
                             source: .files,
                             passURL: passURL.absoluteString,
                             passError: problem.message,
                             groups: [],
                             visibleSections: config.settings.visibleSections,
                             passReachable: false,
                             passStaleSince: staleSince)
        }
        // Nothing successful to hold onto, ever -- straight to the files,
        // same as every poll before this feature existed.
        let files = Store.load(config: config, now: now)
        return MenuModel(records: files.records,
                         aggregate: files.aggregate,
                         refreshedAt: files.refreshedAt,
                         warning: files.warning,
                         source: .files,
                         passURL: passURL.absoluteString,
                         passError: problem.message,
                         groups: [],
                         // No Pass, no suggestions: the engine lives there,
                         // and the ledgers have never heard of it.
                         visibleSections: config.settings.visibleSections,
                         passReachable: false)
    }

    /// Test-only entry point for `--dump-model --poll-sequence`: runs exactly
    /// the failure path `load()` runs when a poll times out, without making
    /// any network call, so a test can simulate "the Pass did not answer"
    /// deterministically rather than depending on a fixture actually being
    /// unreachable. `problem` is never shown; it only becomes `passError`.
    /// `holdWindow` is a second test-only override, on top of the seam's own
    /// deterministic clock: it lets `--dump-notifications` manufacture a
    /// files-only fallback inside a few simulated seconds, to prove the
    /// health-episode notification fires on that transition even when it
    /// lands well under `HealthEpisodeTracker.healthNotifyAfter` -- real
    /// polls always use the real `Feed.holdWindow` (90s), unchanged.
    static func pollFailed(config: StoreConfig,
                           now: Date,
                           previous: MenuModel?,
                           problem: Problem,
                           holdWindow: TimeInterval = Feed.holdWindow) -> MenuModel {
        guard let passURL = config.passURL else {
            return Store.load(config: config, now: now)
        }
        return held(problem: problem, config: config, now: now,
                   previous: previous, passURL: passURL, holdWindow: holdWindow)
    }

    /// Pass rows, with the qt ledger folded in on the shared dedup key.
    static func merge(status: PassStatus,
                      config: StoreConfig,
                      now: Date = Date()) -> MenuModel {
        var byID: [String: TaskRecord] = [:]
        var problems: [String] = []

        switch Store.readQuicktasks(config.tasksDir) {
        case .success(let records):
            for r in records { byID[r.id] = r }
        case .failure(let message):
            problems.append(message.message)
        }

        for row in status.records {
            if let existing = byID[row.id] {
                byID[row.id] = combine(pass: row, ledger: existing)
            } else {
                byID[row.id] = row
            }
        }

        return MenuModel.build(
            records: Array(byID.values),
            now: now,
            warning: problems.isEmpty ? nil : problems.joined(separator: " · "),
            source: .pass,
            passURL: status.passURL,
            passError: nil,
            groups: status.groups,
            itemURLTemplate: status.itemURLTemplate,
            counts: status.counts,
            truncated: status.truncated,
            suggestions: status.suggestions,
            suggestionsAvailable: status.suggestionsAvailable,
            visibleSections: config.settings.visibleSections,
            // A poll that got this far reached the Pass; nothing to hold,
            // whether or not the last one did.
            passReachable: true
        ).trimmed(to: config.limit)
    }

    /// One run seen twice. The Pass row wins on identity and affordances -- it
    /// is the only one that has an item id, a reason, and a report -- but the
    /// ledger wins on status when it is further along, because the two are
    /// written at different moments and either can be the stale one.
    static func combine(pass: TaskRecord, ledger: TaskRecord) -> TaskRecord {
        let ledgerIsLater = Store.rank(ledger) > Store.rank(pass)
        let status = ledgerIsLater ? ledger.status : pass.status
        // A verdict still pending outranks a status change: a job whose ledger
        // row says done is exactly the job The Pass is asking about.
        let reason = pass.reason ?? NeedsReason.from(status: status)
        return TaskRecord(
            id: pass.id,
            itemID: pass.itemID,
            title: pass.title.isEmpty ? ledger.title : pass.title,
            status: status,
            state: pass.state,
            reason: reason,
            origin: pass.origin,
            created: pass.created ?? ledger.created,
            started: pass.started ?? ledger.started,
            finished: ledgerIsLater ? (ledger.finished ?? pass.finished)
                                    : (pass.finished ?? ledger.finished),
            sessionId: nonEmpty(pass.sessionId) ?? ledger.sessionId,
            resumeURL: pass.resumeURL,
            report: pass.report,
            elapsedAtFetch: pass.elapsedAtFetch,
            feedStamp: pass.feedStamp ?? ledger.feedStamp,
            outputCount: pass.outputCount,
            error: nonEmpty(pass.error) ?? ledger.error,
            denialCount: max(pass.denialCount, ledger.denialCount),
            // Only The Pass knows whether an item can be fired: the rule needs
            // the item's prompt and its lane, neither of which is in a ledger.
            canRun: pass.canRun,
            // Only The Pass knows whether an item is revivable, same
            // reasoning as canRun just above: a ledger row has no such
            // concept, so the Pass side always wins.
            revivable: pass.revivable,
            // Only the Pass tags a row with the spoke it came from; a ledger
            // row's own "source" says which of the two writers mirrored it,
            // which is a different question and is already `origin`.
            source: pass.source,
            sourceRaw: pass.sourceRaw)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Asks

/// Where a poll's asks came from.
///
///   asks    GET /asks.json answered; the hub derived everything.
///   status  this hub has no ask API (404); `model` is the /status.json feed,
///           exactly as `Feed.load` has always produced it, and `asks` is empty.
///   files   no Pass answered (or none is configured); `asks` is the qt ledger
///           mapped locally, with no unseen and no moves.
struct AskFeed {
    enum Source: String {
        case asks
        case status
        case files
    }

    let source: Source
    let asks: [Ask]
    let counts: AskCounts
    let rev: String?
    let generatedAt: String?
    /// The Pass base URL in use, nil when the HTTP feed is off.
    let passURL: String?
    /// Why the Pass was not used, when it was not.
    let passError: String?
    /// The legacy menu model: present only on the `status` path.
    let model: MenuModel?
    /// True when this value is the previous poll returned as-is because the
    /// hub said `{unchanged: true}` for its `rev`.
    var unchanged: Bool = false
}

extension Feed {
    /// The ask feed. Prefers `/asks.json`; a 404 hands off to the unchanged
    /// `/status.json` path; a Pass that does not answer falls back to the qt
    /// ledger. `previous` is the last poll this feed returned: when it came
    /// from the ask API its `rev` rides along as `since_rev`.
    static func loadAsks(config: StoreConfig,
                         now: Date = Date(),
                         previous: AskFeed? = nil,
                         client: AskClient? = nil,
                         passClient: PassClient? = nil) -> AskFeed {
        guard let passURL = config.passURL else {
            return fileAsks(config: config, now: now, passURL: nil, error: nil)
        }
        let asks = client ?? AskClient(base: passURL)
        let sinceRev = (previous?.source == .asks) ? previous?.rev : nil

        switch asks.list(sinceRev: sinceRev) {
        case .success(.list(let list)):
            return AskFeed(source: .asks, asks: list.asks, counts: list.counts,
                           rev: list.rev, generatedAt: list.generatedAt,
                           passURL: passURL.absoluteString, passError: nil, model: nil)

        case .success(.unchanged(let rev)):
            if var same = previous, same.source == .asks, rev == nil || rev == same.rev {
                same.unchanged = true
                return same
            }
            // Told "unchanged" about a rev we are not holding: ask for it all.
            if case .success(.list(let list)) = asks.list() {
                return AskFeed(source: .asks, asks: list.asks, counts: list.counts,
                               rev: list.rev, generatedAt: list.generatedAt,
                               passURL: passURL.absoluteString, passError: nil, model: nil)
            }
            return fileAsks(config: config, now: now, passURL: passURL.absoluteString,
                            error: "the Pass answered unchanged for a rev we do not hold")

        case .failure(.notFound):
            // An older hub: today's path, untouched.
            let model = Feed.load(config: config, now: now, previous: previous?.model,
                                  client: passClient)
            if model.source == .pass {
                return AskFeed(source: .status, asks: [], counts: AskCounts(),
                               rev: nil, generatedAt: nil,
                               passURL: passURL.absoluteString, passError: nil, model: model)
            }
            return fileAsks(config: config, now: now, passURL: passURL.absoluteString,
                            error: model.passError)

        case .failure(.problem(let problem)):
            return fileAsks(config: config, now: now, passURL: passURL.absoluteString,
                            error: problem.message)
        }
    }

    /// Test-only: the failure path without a network call, mirroring
    /// `pollFailed`.
    static func asksPollFailed(config: StoreConfig, now: Date, problem: Problem) -> AskFeed {
        fileAsks(config: config, now: now, passURL: config.passURL?.absoluteString,
                 error: problem.message)
    }

    private static func fileAsks(config: StoreConfig, now: Date,
                                 passURL: String?, error: String?) -> AskFeed {
        let hubBase = passURL
        let asks = AskLedger.asks(tasksDir: config.tasksDir, hubBase: hubBase)
        let trimmed = Array(asks.prefix(max(config.limit, 0)))
        return AskFeed(source: .files, asks: trimmed, counts: AskCounts.compute(trimmed),
                       rev: nil, generatedAt: nil, passURL: passURL,
                       passError: error, model: nil)
    }
}

/// The qt ledger read as asks, for the poll where no Pass answers.
///
/// Rule 2 of section 1.3 and nothing more: each task becomes `qt-<tid>`, the
/// status maps to a state, and the rest is read straight off the record. It
/// knows nothing the files do not: no unseen (so nothing is "new for you"), no
/// sidecar overrides, and no moves, because every move goes through the hub
/// and the hub is the thing that is down.
enum AskLedger {
    /// qt status -> ask state. Anything unrecognised reads as `heard` rather
    /// than inventing a verdict about a run nobody can see.
    static func state(forStatus raw: String?) -> AskState {
        switch raw {
        case "queued": return .heard
        case "running": return .working
        case "question": return .question
        case "blocked": return .blocked
        case "failed", "timeout", "stopped": return .failed
        case "done": return .answer
        case "dropped": return .done
        default: return .heard
        }
    }

    /// qt `origin` -> ask `door`.
    static func door(forOrigin raw: String?) -> String {
        switch raw {
        case "qt": return "cli"
        case "raycast": return "raycast"
        default: return "typed"   // summon, widget, and anything new
        }
    }

    static func asks(tasksDir: URL, hubBase: String?) -> [Ask] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tasksDir.path) else {
            return []
        }
        var rows: [(Date, Ask)] = []
        for name in names where name.hasSuffix(".json") {
            let file = tasksDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ask = ask(from: obj, hubBase: hubBase) else { continue }
            rows.append((sortKey(obj), ask))
        }
        // Newest first, like every other list in the widget.
        return rows.sorted { $0.0 > $1.0 }.map { $0.1 }
    }

    private static func sortKey(_ obj: [String: Any]) -> Date {
        for key in ["finished", "started", "created"] {
            if let d = Store.parseDate(obj[key]) { return d }
        }
        return .distantPast
    }

    static func ask(from obj: [String: Any], hubBase: String?) -> Ask? {
        guard let tid = obj["id"] as? String, !tid.isEmpty else { return nil }
        // Rule 1: a bridge record mirrors a hub job the hub already counts.
        if (obj["source"] as? String) == "pass" { return nil }

        let status = obj["status"] as? String
        let state = state(forStatus: status)
        let prompt = (obj["prompt"] as? String) ?? ""
        let label = (obj["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (label?.isEmpty == false) ? label! : Store.titleFrom(prompt.isEmpty ? tid : prompt)
        let result = ((obj["result"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let created = Store.parseDate(obj["created"])
        let started = Store.parseDate(obj["started"])
        let finished = Store.parseDate(obj["finished"])
        let updated = finished ?? started ?? created

        var elapsed: Double?
        if let s = started, let f = finished { elapsed = max(0, f.timeIntervalSince(s)) }
        let resumes = (obj["resumes"] as? [Any])?.count ?? 0
        var facts = AskFacts(elapsedS: elapsed,
                             costUsd: (obj["cost_usd"] as? NSNumber)?.doubleValue,
                             model: obj["model"] as? String,
                             runDir: (obj["run_cwd"] as? String) ?? (obj["invoked_from"] as? String),
                             runs: 1 + resumes,
                             sessionId: obj["session_id"] as? String)
        if (obj["cost_usd"] as? NSNumber) == nil { facts.costUsd = nil }

        var reason: String?
        var excerpt: String?
        var question: String?
        switch state {
        case .failed, .blocked:
            reason = result.isEmpty ? nil : AskText.plain(result, limit: 200)
        case .answer:
            excerpt = result.isEmpty ? nil : AskText.plain(result, limit: 600)
        case .question:
            question = ((obj["question"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                .map { AskText.plain($0, limit: 600) }
        default:
            break
        }
        let denials = (obj["denials"] as? [[String: Any]]) ?? []
        let blockedTools = denials.compactMap { $0["tool_name"] as? String ?? $0["tool"] as? String }

        let id = "qt-\(tid)"
        return Ask(id: id,
                   kind: "agent",
                   title: title,
                   words: prompt,
                   state: state,
                   unseen: false,
                   door: door(forOrigin: obj["origin"] as? String),
                   ledger: "qt",
                   ref: tid,
                   itemID: id,
                   createdAt: iso(created),
                   updatedAt: iso(updated),
                   finishedAt: iso(finished),
                   reason: reason,
                   question: question,
                   blockedTools: blockedTools,
                   answerExcerpt: excerpt,
                   facts: facts,
                   moves: [],
                   filed: status == "dropped" ? "dropped" : nil,
                   url: hubBase.map { $0.hasSuffix("/") ? "\($0)ask/\(id)" : "\($0)/ask/\(id)" })
    }

    /// ISO 8601 with the local offset, the form the contract promises. qt's
    /// own stamps are naive local time; this is the `_parse_ts` rule.
    static func iso(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }
}

enum AskText {
    /// Markdown flattened to plain text and cut to `limit` characters, the
    /// shape `answer_excerpt` has (section 1.4). Not a markdown parser: it
    /// strips the marks that read badly in a menu row and collapses space.
    static func plain(_ markdown: String, limit: Int) -> String {
        var s = markdown
        let rules: [(String, String)] = [
            ("```[a-zA-Z0-9_+-]*", ""),            // fence lines
            ("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),  // links and images keep their text
            ("(?m)^\\s{0,3}#{1,6}\\s*", ""),        // headings
            ("(?m)^\\s*>\\s?", ""),                 // quotes
            ("(?m)^\\s*[-*+]\\s+", ""),             // bullets
            ("[*_`~]+", ""),                        // emphasis and code marks
            ("\\s+", " "),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= limit { return s }
        return String(s.prefix(max(limit - 1, 0))) + "\u{2026}"
    }
}
