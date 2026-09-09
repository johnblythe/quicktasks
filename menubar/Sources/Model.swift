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

/// Where an item came into The Pass from. Shown as a small glyph on the row,
/// because "who is asking" is most of what tells two similarly-titled rows
/// apart, and it is the one thing the title never says.
///
/// The list is the set of spokes that actually feed the ledger. Anything else
/// carries through as `.other` with its raw text kept for the tooltip: a spoke
/// added upstream should show as an unlabelled row, never be dropped and never
/// be guessed at.
enum ItemSource: String, Codable, CaseIterable {
    case slack
    case monologue
    case linear
    case github
    case gmail
    case capture
    case other

    init(raw: String?) {
        let key = (raw ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        // The Pass writes "pass" for its own captures and "menubar" for the
        // ones this widget posts; both arrived through the capture route.
        switch key {
        case "menubar", "pass", "capture": self = .capture
        default: self = ItemSource(rawValue: key) ?? .other
        }
    }

    /// SF Symbol for the row glyph. Deliberately generic shapes rather than
    /// brand marks, which are not in the system font and would need bundling.
    var symbol: String {
        switch self {
        case .slack: return "number.square"
        case .monologue: return "waveform"
        case .linear: return "square.stack.3d.up"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .gmail: return "envelope"
        case .capture: return "tray.and.arrow.down"
        case .other: return "circle.dotted"
        }
    }

    /// Word for the tooltip and for search to match on.
    var label: String {
        switch self {
        case .other: return "unknown source"
        default: return rawValue
        }
    }
}

/// One row of the suggestions section: something the Pass's suggestion engine
/// thinks lands on John, with its reasoning and how sure it is.
///
/// Not a TaskRecord. A suggestion has no job, no lane, and no status -- it is a
/// proposal, and the four things you can say to it (confirm, deny, go, snooze)
/// are a different vocabulary from a verdict on finished work. Modelling it as
/// a task record would have meant a record whose status, section, and actions
/// all had to be special-cased, which is how the two would drift.
struct Suggestion: Equatable {
    let itemID: String
    let title: String
    /// One line saying why the engine thinks this is John's. Shown under the
    /// title: a suggestion with no reasoning attached is one he has to
    /// reconstruct himself, which costs more than it saves.
    let rationale: String
    /// 0...1, clamped on parse. Drawn as a three-step pip rather than a
    /// percentage, because the engine's confidence is not precise enough to
    /// deserve two digits.
    let confidence: Double
    /// What the engine proposes doing: fire it, track it, or put it on today.
    let proposed: String
    let source: ItemSource
    /// Raw `source` string, kept for the tooltip when it is not one we know.
    let sourceRaw: String?
    /// Where the suggestion came from, for the title click.
    let sourceURL: String?
    let date: Date?

    init(itemID: String,
         title: String,
         rationale: String = "",
         confidence: Double = 0,
         proposed: String = "",
         source: ItemSource = .other,
         sourceRaw: String? = nil,
         sourceURL: String? = nil,
         date: Date? = nil) {
        self.itemID = itemID
        self.title = title
        self.rationale = rationale
        self.confidence = confidence
        self.proposed = proposed
        self.source = source
        self.sourceRaw = sourceRaw
        self.sourceURL = sourceURL
        self.date = date
    }

    /// Three steps, so the pip can be drawn as filled dots. The thresholds are
    /// coarse on purpose: the difference between 0.61 and 0.68 is not something
    /// the engine can defend, and drawing it would imply that it can.
    var confidenceStep: Int {
        if confidence >= 0.75 { return 3 }
        if confidence >= 0.45 { return 2 }
        return 1
    }

    var confidenceWord: String {
        switch confidenceStep {
        case 3: return "high confidence"
        case 2: return "medium confidence"
        default: return "low confidence"
        }
    }

    /// Header line for the section, in John's own words for it. Titled from the
    /// count so the section says what it holds before it is read.
    static func headline(_ n: Int) -> String {
        n == 1 ? "1 thing we think you need to do"
               : "\(n) things we think you need to do"
    }
}

/// A row's primary action, which is what return triggers on the highlighted
/// row and what clicking its title does.
enum RowAction: String, Codable {
    case resume  // quicktask://resume/<slug>
    case item    // the Pass's own deep link to the item
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
    /// Whether The Pass will accept a `POST /run` for this item: it has a
    /// prompt and is not already running or awaiting a verdict. Decided
    /// server-side (`/status.json`'s `can_run`) so the widget's Run-it button
    /// and the review page's own fire action cannot disagree. Always false for
    /// a file-feed row: the ledgers do not carry the item's prompt.
    let canRun: Bool
    /// Whether the hub will accept this item back into Verify via
    /// `POST /revive` (LD-224). Decided server-side (`/status.json`'s
    /// `revivable`), same reasoning as `canRun`: absent or false just hides
    /// the row's Revive button rather than offering one that 404s. Always
    /// false for a file-feed row, same as `canRun`.
    let revivable: Bool
    /// Which spoke the item came in from, for the row's glyph. `.other` when
    /// nothing said -- which is every quicktask, since a task fired from a
    /// terminal has no spoke behind it.
    let source: ItemSource
    /// The raw `source` string, kept when it is not one of the known spokes, so
    /// the tooltip can still name it.
    let sourceRaw: String?

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
         denialCount: Int = 0,
         canRun: Bool = false,
         revivable: Bool = false,
         source: ItemSource = .other,
         sourceRaw: String? = nil) {
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
        self.canRun = canRun
        self.revivable = revivable
        self.source = source
        self.sourceRaw = sourceRaw
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

    /// What return does on the highlighted row: reopen the session when there
    /// is one, otherwise open the item in The Pass. Deliberately never a
    /// verdict or a fire -- both of those ask first, and a keystroke that
    /// throws work away or spawns a job is not a keyboard shortcut anyone
    /// wants to discover by accident.
    var primaryAction: RowAction { canResume ? .resume : .item }

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
    /// `/status.json`'s `item_url_template`, for the title deep link. nil on a
    /// v1 payload or the file feed, where the title opens the Pass root.
    let itemURLTemplate: String?
    /// `/status.json`'s `counts`, carried whole rather than cherry-picked so a
    /// tally added upstream shows up in `--dump-model` without a code change.
    let counts: [String: Int]
    /// The Pass caps `jobs` at 200 and says so in `counts.truncated`. Surfaced
    /// as a footer hint, because a widget quietly showing a slice of the
    /// history is the kind of thing you only notice when it matters.
    let truncated: Bool
    /// What the Pass's suggestion engine thinks lands on John. Empty when it
    /// sent an empty list, which is different from not having sent one at all:
    /// see `suggestionsAvailable`.
    let suggestions: [Suggestion]
    /// Whether `/status.json` carried a `suggestions` key at all. The section
    /// hides itself entirely when it did not, so a Pass that has not shipped
    /// the engine yet shows no empty section and no zero count -- an absent
    /// feature has to look absent, not broken.
    let suggestionsAvailable: Bool
    /// Sections the settings window allows. A section switched off is dropped
    /// from `sections()` entirely rather than collapsed, so it takes its header
    /// and its count with it.
    let visibleSections: Set<String>
    /// Whether the most recent poll actually reached the Pass -- distinct from
    /// `source`, which stays `.pass` while a held-stale model is still being
    /// shown after a poll has started failing. False whenever the Pass was not
    /// even in play (the file feed, or a poll that has not run yet).
    let passReachable: Bool
    /// When the Pass first stopped answering, nil while it is reachable. Set
    /// on the first failed poll after a success (or a prior hold) and carried
    /// forward unchanged -- by a held `.pass` model and by the `.files` model
    /// the widget falls back to once the hold runs out -- so both "still
    /// holding" and "gave up, but the Pass is the reason" can tell how long
    /// it has actually been down.
    let passStaleSince: Date?
    /// The deadline the widget will keep showing a held Pass model past.
    /// Non-nil only while `source == .pass` and a poll is actively failing;
    /// nil once the model has fallen back to file feeds, or while the Pass is
    /// reachable and there is nothing to hold.
    let heldUntil: Date?

    init(records: [TaskRecord],
         aggregate: Aggregate,
         refreshedAt: Date,
         warning: String? = nil,
         source: FeedSource = .files,
         passURL: String = PassEndpoint.defaultURL,
         passError: String? = nil,
         groups: [PassGroup] = [],
         itemURLTemplate: String? = nil,
         counts: [String: Int] = [:],
         truncated: Bool = false,
         suggestions: [Suggestion] = [],
         suggestionsAvailable: Bool = false,
         visibleSections: Set<String> = Settings.allSectionKeys,
         passReachable: Bool = false,
         passStaleSince: Date? = nil,
         heldUntil: Date? = nil) {
        self.records = records
        self.aggregate = aggregate
        self.refreshedAt = refreshedAt
        self.warning = warning
        self.source = source
        self.passURL = passURL
        self.passError = passError
        self.groups = groups
        self.itemURLTemplate = itemURLTemplate
        self.counts = counts
        self.truncated = truncated
        self.suggestions = suggestions
        self.suggestionsAvailable = suggestionsAvailable
        self.visibleSections = visibleSections
        self.passReachable = passReachable
        self.passStaleSince = passStaleSince
        self.heldUntil = heldUntil
    }

    static func build(records: [TaskRecord],
                      now: Date = Date(),
                      warning: String? = nil,
                      source: FeedSource = .files,
                      passURL: String = PassEndpoint.defaultURL,
                      passError: String? = nil,
                      groups: [PassGroup] = [],
                      itemURLTemplate: String? = nil,
                      counts: [String: Int] = [:],
                      truncated: Bool = false,
                      suggestions: [Suggestion] = [],
                      suggestionsAvailable: Bool = false,
                      visibleSections: Set<String> = Settings.allSectionKeys,
                      passReachable: Bool = false,
                      passStaleSince: Date? = nil,
                      heldUntil: Date? = nil) -> MenuModel {
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
                         groups: groups,
                         itemURLTemplate: itemURLTemplate,
                         counts: counts,
                         truncated: truncated,
                         suggestions: suggestions,
                         suggestionsAvailable: suggestionsAvailable,
                         visibleSections: visibleSections,
                         passReachable: passReachable,
                         passStaleSince: passStaleSince,
                         heldUntil: heldUntil)
    }

    /// The header line MenuView draws and `--dump-model` reports as
    /// `"headline"`. Gets a suffix only once a held-stale Pass has actually
    /// given up and fallen back to the file ledgers -- `passStaleSince`
    /// survives that fallback specifically so this can tell "files because
    /// there is no Pass" apart from "files because the Pass went quiet".
    var headlineText: String {
        guard source == .files, passStaleSince != nil else { return aggregate.headline }
        return "\(aggregate.headline) \u{00B7} file feeds only, Pass down"
    }

    /// Rows grouped for display, in section order, empty sections dropped and
    /// sections switched off in the settings window left out.
    func sections(now: Date? = nil) -> [(section: Section, records: [TaskRecord])] {
        let when = now ?? refreshedAt
        var buckets: [Section: [TaskRecord]] = [:]
        for r in records { buckets[r.section(now: when), default: []].append(r) }
        return Section.allCases
            .sorted { $0.order < $1.order }
            .filter { visibleSections.contains($0.rawValue) }
            .compactMap { s in
                guard let rows = buckets[s], !rows.isEmpty else { return nil }
                return (s, rows)
            }
    }

    /// Whether the suggestions section should be drawn at all: the Pass has to
    /// have sent the key, and it has to have sent something in it.
    var showsSuggestions: Bool { suggestionsAvailable && !suggestions.isEmpty }

    /// The first few row titles, for under the header count. "6 tasks need
    /// you" on its own names nothing John can act on; the titles are the whole
    /// point of the widget being a list rather than a badge.
    ///
    /// Drawn from the needs-you rows when there are any, because those are the
    /// rows the count is counting, and from the top of the list otherwise.
    func headlinePreview(limit: Int = 3, now: Date? = nil) -> [String] {
        let when = now ?? refreshedAt
        let attention = records.filter { $0.effectiveReason != nil }
        let pool = attention.isEmpty
            ? records.filter { $0.section(now: when) == .running }
            : attention
        return (pool.isEmpty ? records : pool).prefix(limit).map { $0.title }
    }

    /// Copy of the model narrowed to a search query, aggregate and counts left
    /// alone. The header keeps saying how many rows need John while the list
    /// shows the ones he is looking for -- a filter that also retallied the
    /// header would make "6 tasks need you" mean "6 matching", which is not
    /// something anybody wants a search box to decide.
    func filtered(query: String) -> MenuModel {
        guard !RowFilter.terms(query).isEmpty else { return self }
        return MenuModel(records: RowFilter.apply(records, query: query),
                         aggregate: aggregate,
                         refreshedAt: refreshedAt,
                         warning: warning,
                         source: source,
                         passURL: passURL,
                         passError: passError,
                         groups: groups,
                         itemURLTemplate: itemURLTemplate,
                         counts: counts,
                         truncated: truncated,
                         suggestions: suggestions.filter {
                             RowFilter.matches($0, query: query)
                         },
                         suggestionsAvailable: suggestionsAvailable,
                         visibleSections: visibleSections,
                         passReachable: passReachable,
                         passStaleSince: passStaleSince,
                         heldUntil: heldUntil)
    }

    /// Rows in the order the menu draws them, with the collapsed sections'
    /// rows left out. This is the list the keyboard highlight walks, so it has
    /// to be the same list the eye walks.
    func visibleRecords(collapsed: Set<String>, now: Date? = nil) -> [TaskRecord] {
        sections(now: now)
            .filter { !collapsed.contains($0.section.rawValue) }
            .flatMap { $0.records }
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
                  groups: groups,
                  itemURLTemplate: itemURLTemplate,
                  counts: counts,
                  truncated: truncated,
                  suggestions: suggestions,
                  suggestionsAvailable: suggestionsAvailable,
                  visibleSections: visibleSections,
                  passReachable: passReachable,
                  passStaleSince: passStaleSince,
                  heldUntil: heldUntil)
    }
}

// MARK: - Quick search

/// Narrows the row list by a typed query. Pure, and separate from the view, so
/// the whole of the filter's behaviour can be checked without a display.
///
/// Matching is case- and diacritic-insensitive substring, across the four
/// things a row shows or carries: its title, its status text, why it needs
/// John, and which spoke it came from. Substring rather than prefix because a
/// row's title is a trimmed sentence and the memorable word is rarely the first
/// one ("atlas", not "look thru"). Every whitespace-separated term has to match
/// somewhere in the row, so a second word narrows rather than widens -- typing
/// "slack blocked" means both, which is the only reading that makes a filter
/// field worth having on a list this short.
///
/// The id is deliberately searchable too, and deliberately last in the
/// haystack: John does paste job slugs in, and a row whose title has been
/// trimmed to 60 characters is sometimes only findable that way.
enum RowFilter {
    static func matches(_ record: TaskRecord, query: String) -> Bool {
        let terms = self.terms(query)
        guard !terms.isEmpty else { return true }
        let haystack = self.haystack(record)
        return terms.allSatisfy { haystack.contains($0) }
    }

    static func matches(_ suggestion: Suggestion, query: String) -> Bool {
        let terms = self.terms(query)
        guard !terms.isEmpty else { return true }
        let haystack = fold([
            suggestion.title,
            suggestion.rationale,
            suggestion.proposed,
            suggestion.source.label,
            suggestion.sourceRaw ?? "",
            suggestion.itemID,
        ].joined(separator: "\u{1F}"))
        return terms.allSatisfy { haystack.contains($0) }
    }

    static func apply(_ records: [TaskRecord], query: String) -> [TaskRecord] {
        guard !terms(query).isEmpty else { return records }
        return records.filter { matches($0, query: query) }
    }

    /// What one row is searched over. `detail` rather than the raw status so
    /// the words on screen are the words that match: the row says "Timed out",
    /// and typing that has to find it.
    static func haystack(_ record: TaskRecord) -> String {
        fold([
            record.title,
            record.detail,
            record.status.detail,
            record.effectiveReason?.detail ?? "",
            record.effectiveReason?.rawValue ?? "",
            record.state ?? "",
            record.source.label,
            record.sourceRaw ?? "",
            record.origin.rawValue,
            record.id,
            record.itemID ?? "",
        ].joined(separator: "\u{1F}"))
    }

    /// Whitespace-separated, folded, empties dropped. A query of only spaces
    /// is no query at all rather than one nothing can match.
    static func terms(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

// MARK: - Keyboard highlight

/// Where the up/down highlight lands. Pure, and separate from the view, so the
/// whole of the keyboard's behaviour can be tested without a display.
///
/// Rules, deliberately few: down from nothing highlights the first row, up from
/// nothing highlights the last, and the ends do not wrap -- a held arrow key
/// stopping at the end of the list is easier to follow than one that teleports.
/// A highlight on a row that has since left the feed is dropped rather than
/// remapped, because the row under the cursor changing identity between polls
/// is how you fire the wrong thing.
enum KeyboardNav {
    /// The id the highlight moves to. `delta` is +1 for down, -1 for up.
    static func move(ids: [String], from current: String?, delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta < 0 ? ids.last : ids.first
        }
        let next = index + delta
        guard next >= 0, next < ids.count else { return current }
        return ids[next]
    }

    /// The highlight after a refresh: kept when its row is still visible,
    /// dropped when it is not.
    static func survivor(ids: [String], current: String?) -> String? {
        guard let current, ids.contains(current) else { return nil }
        return current
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
