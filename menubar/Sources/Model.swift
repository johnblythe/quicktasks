// Model.swift -- status vocabulary, one task record, and the menu model.
//
// The vocabulary is the union of what the two writers actually emit:
// qt's run_task() writes queued/running/done/failed/blocked/timeout, and
// hub's runner.py writes running/done/failed/blocked. Anything else is
// carried through as .unknown rather than guessed at, so a new status
// added upstream shows as a gray row instead of silently reading as done.

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

/// Which ledger a record came from. Both writers mirror into each other's
/// store when a run finishes, so this is about provenance, not location.
enum Origin: String, Codable {
    case quicktask  // fired with `qt <prompt>`
    case pass       // fired from The Pass (hub run-job.sh / runner.py)
}

struct TaskRecord: Codable, Equatable {
    /// Canonical identity. Also the exact argument `qt resume` takes and the
    /// slug in `quicktask://resume/<id>`, which is what makes one-click
    /// resume work for both origins without a lookup table.
    let id: String
    let title: String
    let status: TaskStatus
    let origin: Origin
    let created: Date?
    let started: Date?
    let finished: Date?
    let sessionId: String?
    let error: String?
    let denialCount: Int

    /// Newest timestamp on the record, used for ordering the dropdown.
    var activity: Date? { finished ?? started ?? created }

    /// A run is only reopenable if claude handed back a session to resume.
    var canResume: Bool { (sessionId?.isEmpty == false) }

    /// Blocked runs are the ones the ticket wants one click away.
    var wantsResume: Bool { canResume && status.isAttention }
}

/// What the menu-bar icon shows. `running` wins over `attention` because an
/// in-flight run is the thing most likely to change in the next few seconds.
enum Aggregate: Equatable {
    case running(Int)
    case attention(Int)
    case idle

    static func of(_ records: [TaskRecord]) -> Aggregate {
        let running = records.filter { $0.status.isActive }.count
        if running > 0 { return .running(running) }
        let attention = records.filter { $0.status.isAttention }.count
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

/// Sort band: in-flight, then needs-you, then everything finished cleanly.
private func band(_ r: TaskRecord) -> Int {
    if r.status.isActive { return 0 }
    if r.status.isAttention { return 1 }
    return 2
}

struct MenuModel: Equatable {
    let records: [TaskRecord]
    let aggregate: Aggregate
    let refreshedAt: Date
    /// Non-nil when a ledger could not be read, surfaced as a menu row rather
    /// than swallowed -- an unreadable ledger looks identical to "all quiet"
    /// otherwise, which is the one failure that would mislead John.
    let warning: String?

    static func build(records: [TaskRecord], now: Date = Date(), warning: String? = nil) -> MenuModel {
        let ordered = records.sorted { lhs, rhs in
            // Three bands, then newest-activity within each. Attention rows
            // have to pin above the merely-finished ones: they are the rows
            // with a resume click on them, and a blocked task ten rows down
            // behind a scroll is not one click away from being resumed.
            let lb = band(lhs), rb = band(rhs)
            if lb != rb { return lb < rb }
            let l = lhs.activity ?? .distantPast
            let r = rhs.activity ?? .distantPast
            if l != r { return l > r }
            return lhs.id < rhs.id
        }
        return MenuModel(records: ordered,
                         aggregate: .of(ordered),
                         refreshedAt: now,
                         warning: warning)
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
