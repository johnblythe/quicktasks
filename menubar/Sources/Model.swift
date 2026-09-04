// Model.swift -- status vocabulary, one task record, and the menu model.
//
// The vocabulary is the union of what the writers actually emit: qt's
// run_task() writes queued/running/done/failed/blocked/timeout, hub's
// runner.py writes running/done/failed/blocked, and The Pass's /status.json
// adds an item-level `state` (verify, gate) for work that has no job status at
// all. Anything else is carried through as .unknown rather than guessed at, so
// a new status added upstream shows as a gray row instead of silently reading
// as done.

import Foundation

/// A human-readable failure. Exists so the reading and acting code can return
/// `Result<_, Problem>` and write `.failure("what went wrong")` inline, while
/// still satisfying Result's requirement that the failure type be an Error.
struct Problem: Error, ExpressibleByStringInterpolation, CustomStringConvertible {
    let message: String

    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { self.message = value }
    init(stringInterpolation: DefaultStringInterpolation) {
        self.message = String(stringInterpolation: stringInterpolation)
    }

    var description: String { message }
}

enum TaskStatus: String, Codable, CaseIterable {
    case running
    case queued
    case blocked
    case failed
    case timeout
    case done
    case unknown

    init(raw: String?) {
        self = TaskStatus(rawValue: (raw ?? "").lowercased()) ?? .unknown
    }

    /// Needs John's attention: a denied permission or an outright failure.
    var isAttention: Bool { self == .blocked || self == .failed || self == .timeout }

    /// In flight, so the aggregate dot should read as busy.
    var isActive: Bool { self == .running || self == .queued }

    /// Short right-hand detail text, mirroring the reference design's
    /// "Investigating" / "Monitoring" column.
    var detail: String {
        switch self {
        case .running: return "Running"
        case .queued: return "Queued"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        case .timeout: return "Timed out"
        case .done: return "Done"
        case .unknown: return "Unknown"
        }
    }
}

/// Why a row is in the "Needs you" section. Mirrors /status.json's
/// `needs_you[].reason` exactly, which is the whole vocabulary of ways the loop
/// can stall on John: a finished job awaiting his verdict, an item the router
/// held for his go-ahead, a run stopped on a denied permission, a run that
/// died. File-sourced rows derive the last two from their status, so the
/// section means the same thing whichever feed is live.
enum NeedsReason: String, Codable, CaseIterable {
    case verify
    case gate
    case blocked
    case failed

    /// Right-hand status text for the row. The Pass hands us a reason and no
    /// job status for gate items, so the reason *is* the status text.
    var detail: String {
        switch self {
        case .verify: return "Verify"
        case .gate: return "Needs go"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        }
    }

    /// Order inside the section. Verify leads because a verdict is the cheapest
    /// action John can take and the one holding a finished job's result.
    var rank: Int {
        switch self {
        case .verify: return 0
        case .gate: return 1
        case .blocked: return 2
        case .failed: return 3
        }
    }

    /// What a status-only row (the file feed) means in Needs-you terms.
    static func from(status: TaskStatus) -> NeedsReason? {
        switch status {
        case .blocked: return .blocked
        case .failed, .timeout: return .failed
        default: return nil
        }
    }
}

/// Which ledger a record came from. Both writers mirror into each other's
/// store when a run finishes, so this is about provenance, not location.
enum Origin: String, Codable {
    case quicktask  // fired with `qt <prompt>`
    case pass       // fired from The Pass (hub run-job.sh / runner.py)
}

/// Which feed produced the model. Shown in the footer, because "all quiet" and
/// "I cannot see The Pass" must never look the same.
enum FeedSource: String, Codable {
    case pass   // GET /status.json answered
    case files  // read the two ledgers off disk
}

/// One collapsible section of the dropdown. Running and Needs-you match the
/// reference design; Done-today is the reference's quiet tail. `earlier` is the
/// overflow the reference does not have: finished runs from previous days still
/// have to go somewhere, and dropping them would lose the history v1 showed.
enum Section: String, Codable, CaseIterable {
    case running
    case needsYou = "needs_you"
    case doneToday = "done_today"
    case earlier

    var label: String {
        switch self {
        case .running: return "Running"
        case .needsYou: return "Needs you"
        case .doneToday: return "Done today"
        case .earlier: return "Earlier"
        }
    }

    var order: Int {
        switch self {
        case .running: return 0
        case .needsYou: return 1
        case .doneToday: return 2
        case .earlier: return 3
        }
    }

    /// Only the tail section starts collapsed. The two sections that carry
    /// actions must be open the moment the menu opens, or the widget has
    /// buried the thing it exists to surface.
    var collapsedByDefault: Bool { self == .earlier }
}

struct TaskRecord: Codable, Equatable {
    /// Canonical identity, and the dedup key across every feed. Also the exact
    /// argument `qt resume` takes and the slug in `quicktask://resume/<id>`,
    /// which is what makes one-click resume work for every origin without a
    /// lookup table.
    let id: String
    /// The Pass's item id, when this row came from (or matched) a Pass item.
    /// Distinct from `id`: the decisions payload and the report URL are both
    /// keyed by item id, while resume is keyed by `id`.
    let itemID: String?
    let title: String
    let status: TaskStatus
    /// The Pass's item-level state ("verify", "gate", "running", "today"...).
    /// Needed verbatim because POST /save echoes it back in each decision.
    let state: String?
    let reason: NeedsReason?
    let origin: Origin
    let created: Date?
    let started: Date?
    let finished: Date?
    let sessionId: String?
    /// `quicktask://resume/<slug>` as handed over by The Pass. nil for file
    /// rows, which derive the same URL from `id`.
    let resumeURL: String?
    /// Root-relative path to a rendered report, e.g.
    /// `/job/<item_id>/output/report.html`. nil when the job wrote none.
    let report: String?
    /// Seconds elapsed as of the fetch, for in-flight rows whose `started`
    /// did not parse. The live ticker adds the drift since.
    let elapsedAtFetch: Double?
    /// When the feed generated this view, set only for a row that carries no
    /// timestamp of its own. It orders the row and places it in today, but it
    /// never dates it: "Needs go - 2s" on an item held for a week would be a
    /// lie, and one that resets on every poll.
    let feedStamp: Date?
    let outputCount: Int
    let error: String?
    let denialCount: Int

    init(id: String,
         itemID: String? = nil,
         title: String,
         status: TaskStatus,
         state: String? = nil,
         reason: NeedsReason? = nil,
         origin: Origin,
         created: Date? = nil,
         started: Date? = nil,
         finished: Date? = nil,
         sessionId: String? = nil,
         resumeURL: String? = nil,
         report: String? = nil,
         elapsedAtFetch: Double? = nil,
         feedStamp: Date? = nil,
         outputCount: Int = 0,
         error: String? = nil,
         denialCount: Int = 0) {
        self.id = id
        self.itemID = itemID
        self.title = title
        self.status = status
        self.state = state
        self.reason = reason
        self.origin = origin
        self.created = created
        self.started = started
        self.finished = finished
        self.sessionId = sessionId
        self.resumeURL = resumeURL
        self.report = report
        self.elapsedAtFetch = elapsedAtFetch
        self.feedStamp = feedStamp
        self.outputCount = outputCount
        self.error = error
        self.denialCount = denialCount
    }

    /// Newest timestamp the row actually carries. Drives the age text, so it
    /// must never include a stamp the feed supplied on the row's behalf.
    var activity: Date? { finished ?? started ?? created }

    /// What orders the row and decides today vs earlier. Falls back to the
    /// feed's own clock for a row with no timestamps, because sorting those
    /// last and burying them in Earlier is worse than dating them roughly.
    var sortStamp: Date? { activity ?? feedStamp }

    /// A run is only reopenable if something handed back a session to resume:
    /// a session id from either ledger, or a resume URL from The Pass.
    var canResume: Bool { (sessionId?.isEmpty == false) || (resumeURL?.isEmpty == false) }

    /// The rows the ticket wants one click away from being reopened.
    var wantsResume: Bool { canResume && (reason != nil || status.isAttention) }

    /// Whether this row takes accept / redo / reject.
    ///
    /// Keyed off the item's `state`, not its reason, because that is what the
    /// review page keys its own action vocabulary off: template.html's ACTIONS
    /// map gives `verify` exactly accept / redo / reject. The distinction is
    /// load-bearing for a job that died in the verify lane, which The Pass
    /// reports as `state: "verify"` with `reason: "failed"` -- the row reads
    /// "Failed", and a verdict is still the action it needs.
    var canDecide: Bool {
        state?.lowercased() == "verify" && (itemID?.isEmpty == false)
    }

    var hasReport: Bool { report?.isEmpty == false }

    /// Right-hand status text. A Pass reason outranks the job status, because a
    /// finished job awaiting a verdict reads "Verify", not "Done". A blocked
    /// file row keeps its own word, which is more specific than the reason
    /// ("Timed out" rather than "Failed").
    var detail: String { reason?.detail ?? status.detail }

    /// The reason this row needs John, whether The Pass said so or the status
    /// implies it. This is what puts a blocked run from the file feed in the
    /// same section as a blocked run from /status.json.
    var effectiveReason: NeedsReason? { reason ?? NeedsReason.from(status: status) }

    /// Which section the row belongs to. `now` decides only today-vs-earlier.
    func section(now: Date, calendar: Calendar = .current) -> Section {
        if effectiveReason != nil { return .needsYou }
        if status.isActive { return .running }
        if let end = finished, calendar.isDate(end, inSameDayAs: now) { return .doneToday }
        if finished == nil, let seen = sortStamp, calendar.isDate(seen, inSameDayAs: now) {
            return .doneToday
        }
        return .earlier
    }

    /// Seconds this run has been in flight, ticking off the wall clock rather
    /// than off the feed, so an open menu counts up between polls.
    func liveElapsed(fetchedAt: Date, now: Date) -> TimeInterval? {
        guard status.isActive else { return nil }
        if let start = started { return max(0, now.timeIntervalSince(start)) }
        if let base = elapsedAtFetch { return max(0, base + now.timeIntervalSince(fetchedAt)) }
        return nil
    }
}

/// What the menu-bar icon shows. `running` wins over `attention` because an
/// in-flight run is the thing most likely to change in the next few seconds.
enum Aggregate: Equatable {
    case running(Int)
    case attention(Int)
    case idle

    static func of(_ records: [TaskRecord]) -> Aggregate {
        let running = records.filter { $0.status.isActive && $0.effectiveReason == nil }.count
        if running > 0 { return .running(running) }
        let attention = records.filter { $0.effectiveReason != nil }.count
        if attention > 0 { return .attention(attention) }
        return .idle
    }

    /// Header line, in the voice of the reference design's
    /// "Degraded -- worth a look" / "All Systems Operational".
    var headline: String {
        switch self {
        case .running(let n): return n == 1 ? "1 task running" : "\(n) tasks running"
        case .attention(let n): return n == 1 ? "1 task needs you" : "\(n) tasks need you"
        case .idle: return "All quiet"
        }
    }

    /// Text drawn next to the menu-bar dot. Empty when idle so the icon stays
    /// a bare dot and does not jitter the menu bar's layout while nothing runs.
    var badge: String {
        switch self {
        case .running(let n): return String(n)
        case .attention(let n): return String(n)
        case .idle: return ""
        }
    }
}

/// One of The Pass's own groups, carried through from /status.json for the
/// header tooltip and for `--dump-model`. The dropdown's sections are computed
/// from the rows instead, so the widget groups the same way whichever feed is
/// live.
struct PassGroup: Equatable {
    let key: String
    let label: String
    let count: Int
    let undone: Int
}

struct MenuModel: Equatable {
    let records: [TaskRecord]
    let aggregate: Aggregate
    let refreshedAt: Date
    /// Non-nil when a ledger could not be read, surfaced as a menu row rather
    /// than swallowed -- an unreadable ledger looks identical to "all quiet"
    /// otherwise, which is the one failure that would mislead John.
    let warning: String?
    let source: FeedSource
    /// Base URL of The Pass, from /status.json when it answered and from the
    /// configured default when it did not. Report links hang off this.
    let passURL: String
    /// Why the Pass feed was not used, for the footer tooltip. nil when it was.
    let passError: String?
    let groups: [PassGroup]

    init(records: [TaskRecord],
         aggregate: Aggregate,
         refreshedAt: Date,
         warning: String? = nil,
         source: FeedSource = .files,
         passURL: String = PassEndpoint.defaultURL,
         passError: String? = nil,
         groups: [PassGroup] = []) {
        self.records = records
        self.aggregate = aggregate
        self.refreshedAt = refreshedAt
        self.warning = warning
        self.source = source
        self.passURL = passURL
        self.passError = passError
        self.groups = groups
    }

    static func build(records: [TaskRecord],
                      now: Date = Date(),
                      warning: String? = nil,
                      source: FeedSource = .files,
                      passURL: String = PassEndpoint.defaultURL,
                      passError: String? = nil,
                      groups: [PassGroup] = []) -> MenuModel {
        let ordered = records.sorted { lhs, rhs in
            // Sections first, then reason inside Needs-you, then
            // newest-activity. Attention rows have to pin above the merely
            // finished ones: they are the rows with an action on them, and a
            // blocked task ten rows down behind a scroll is not one click away.
            let ls = lhs.section(now: now).order, rs = rhs.section(now: now).order
            if ls != rs { return ls < rs }
            let lr = lhs.effectiveReason?.rank ?? -1, rr = rhs.effectiveReason?.rank ?? -1
            if lr != rr { return lr < rr }
            let l = lhs.sortStamp ?? .distantPast
            let r = rhs.sortStamp ?? .distantPast
            if l != r { return l > r }
            return lhs.id < rhs.id
        }
        return MenuModel(records: ordered,
                         aggregate: .of(ordered),
                         refreshedAt: now,
                         warning: warning,
                         source: source,
                         passURL: passURL,
                         passError: passError,
                         groups: groups)
    }

    /// Rows grouped for display, in section order, empty sections dropped.
    func sections(now: Date? = nil) -> [(section: Section, records: [TaskRecord])] {
        let when = now ?? refreshedAt
        var buckets: [Section: [TaskRecord]] = [:]
        for r in records { buckets[r.section(now: when), default: []].append(r) }
        return Section.allCases
            .sorted { $0.order < $1.order }
            .compactMap { s in
                guard let rows = buckets[s], !rows.isEmpty else { return nil }
                return (s, rows)
            }
    }

    /// Copy of the model with a shorter row list, preserving the aggregate.
    /// Trimming happens after ordering, so the newest and the acting rows live.
    func trimmed(to limit: Int) -> MenuModel {
        MenuModel(records: Array(records.prefix(limit)),
                  aggregate: aggregate,
                  refreshedAt: refreshedAt,
                  warning: warning,
                  source: source,
                  passURL: passURL,
                  passError: passError,
                  groups: groups)
    }
}

// MARK: - Relative age, for the right-hand column

/// Matches qt's own `age()` helper so the widget and `qt list` agree.
func shortAge(from date: Date, to now: Date = Date()) -> String {
    let s = Int(max(0, now.timeIntervalSince(date)))
    for (unit, div) in [("d", 86400), ("h", 3600), ("m", 60)] where s >= div {
        return "\(s / div)\(unit)"
    }
    return "\(s)s"
}

/// Stopwatch text for an in-flight row: m:ss under an hour, h:mm:ss over it.
/// Counts seconds, unlike shortAge, because that is the point of showing it.
func stopwatch(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
