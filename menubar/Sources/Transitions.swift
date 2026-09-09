// Transitions.swift -- pure functions that turn "the model just changed"
// into "here is what a person would call that change". Kept apart from
// StatusController so the detection logic can be driven by a CLI seam with
// two plain fixtures and no feed, no timer, and no notifier -- the same
// reason MenuModel.build and Aggregate.of are free functions rather than
// methods on the controller.

import Foundation

/// live -> held-stale -> files-only and back, matching MenuModel.headlineText's
/// own rule for what counts as each state (see IconHealth.of in
/// MenuBarIcon.swift, which the dot, the tooltip, and the footer's freshness
/// line all read off of so none of the three can disagree).
enum HealthTransition: Equatable {
    case wentStale      // normal -> held-stale: Pass stopped answering, holding the last poll
    case wentFilesOnly  // (normal or held-stale) -> files-only: the hold window ran out
    case recovered      // (held-stale or files-only) -> normal: Pass answered again

    static func detect(previous: MenuModel, fresh: MenuModel) -> HealthTransition? {
        let before = IconHealth.of(source: previous.source,
                                   passReachable: previous.passReachable,
                                   passStaleSince: previous.passStaleSince)
        let after = IconHealth.of(source: fresh.source,
                                  passReachable: fresh.passReachable,
                                  passStaleSince: fresh.passStaleSince)
        guard before != after else { return nil }
        switch (before, after) {
        case (.normal, .heldStale): return .wentStale
        case (.normal, .filesOnly), (.heldStale, .filesOnly): return .wentFilesOnly
        case (.heldStale, .normal), (.filesOnly, .normal): return .recovered
        // .filesOnly <-> .heldStale directly does not occur: Store.load never
        // reports passReachable == false while source == .files. Nothing to
        // name, so nothing is reported.
        default: return nil
        }
    }

    /// What goes in the outcome queue and, when notify-worthy, the
    /// notification title/body. Kept together so the banner and the system
    /// notification for the same transition never drift apart in wording.
    var outcome: (title: String, detail: String?) {
        switch self {
        case .wentStale:
            return ("Pass isn't answering", "Holding the last update.")
        case .wentFilesOnly:
            return ("Pass is down", "Showing file feeds until it answers again.")
        case .recovered:
            return ("Pass is back", nil)
        }
    }
}

/// A row that crossed into done, failed/timed-out, or blocked between two
/// polls. Compared by id against the *previous* poll's rows, deliberately
/// excluding any row with no previous entry at all: a cold launch has no
/// real "previous" to diff against, and treating every already-finished job
/// on disk as a fresh transition would fire a notification storm the first
/// time the widget ever starts.
enum JobTransition: Equatable {
    case finished(title: String)
    case failed(title: String)
    case blocked(title: String)

    var outcomeTitle: String {
        switch self {
        case .finished(let title): return "Job finished: \(title)"
        case .failed(let title): return "Job failed: \(title)"
        case .blocked(let title): return "Job needs you: \(title)"
        }
    }

    static func detect(previous: [TaskRecord], fresh: [TaskRecord]) -> [JobTransition] {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        var out: [JobTransition] = []
        for row in fresh {
            guard let prior = before[row.id], prior.status != row.status else { continue }
            switch row.status {
            case .done: out.append(.finished(title: row.title))
            case .failed, .timeout: out.append(.failed(title: row.title))
            case .blocked: out.append(.blocked(title: row.title))
            case .running, .queued, .unknown: continue
            }
        }
        return out
    }
}

/// LD-201 v9: cross-poll job-transition tracking, replacing JobTransition's
/// pairwise-only comparison (this poll's rows against the *immediately
/// preceding* poll's rows, nothing further back) with a persistent
/// last-known-status map. A job missing from one poll's records -- a
/// ledger-read race, or any other one-poll-only blip -- is simply left
/// untouched rather than read as "no prior data, nothing to diff": its
/// eventual reappearance still compares against the status it actually had
/// last time it was seen, not against nothing. Additionally dedupes by the
/// combination of job id and landed-on status, so the same finished/failed/
/// blocked verdict can never fire twice for one job no matter how it got
/// there. A class, not a stateless function, because that memory has to
/// survive across every `refresh()` for the controller's whole run.
final class JobTransitionTracker {
    private var lastStatus: [String: TaskStatus] = [:]
    private var fired: Set<String> = []

    /// Call once per poll, in poll order, with that poll's full row list.
    /// The first call ever made (a cold launch, or this tracker's first use
    /// in a test) reports nothing: every row is being seen for the first
    /// time, so there is no real "previous" to diff against -- the same
    /// rule JobTransition.detect itself follows, just extended across more
    /// than one poll's gap.
    func detect(fresh: [TaskRecord]) -> [JobTransition] {
        var out: [JobTransition] = []
        for row in fresh {
            let prior = lastStatus[row.id]
            lastStatus[row.id] = row.status
            guard let prior, prior != row.status else { continue }
            let key = "\(row.id)#\(row.status.rawValue)"
            guard !fired.contains(key) else { continue }
            switch row.status {
            case .done: out.append(.finished(title: row.title))
            case .failed, .timeout: out.append(.failed(title: row.title))
            case .blocked: out.append(.blocked(title: row.title))
            case .running, .queued, .unknown: continue
            }
            fired.insert(key)
        }
        return out
    }
}

/// LD-201 v9: turns raw health-icon transitions (see HealthTransition above)
/// into episodes, so a Pass that answers slow under load -- one skipped
/// poll, a few seconds late, nowhere near actually down -- never earns a
/// notification. v8 posted on every wentStale/wentFilesOnly/recovered
/// transition unconditionally; overnight, ordinary load-induced blips read
/// as a "Pass isn't answering" / "Pass is back" pair every few minutes even
/// though the Pass server itself never restarted. This tracker instead
/// treats one continuous run of not-normal polls as a single episode, and
/// only tells the notifier about the episode once it has either run long
/// enough to be real or given up on Pass entirely (gone files-only) -- see
/// `process` below. A class, not a stateless function, so its bookkeeping
/// (`episodeStarted`, `notifiedDown`, `lastPairAt`) survives across every
/// `refresh()` the same way `Feed.held`'s own `passStaleSince` does.
final class HealthEpisodeTracker {
    /// An episode has to run this long before its "down" notification is
    /// worth interrupting John for. Comfortably longer than
    /// PassClient.statusTimeout (8s) plus a couple of skipped 5-second
    /// polls, so an ordinary slow-under-load stretch never crosses it by
    /// accident, while a real outage is still caught well before the old
    /// 90-second hold window would have fallen back to file feeds anyway.
    static let healthNotifyAfter: TimeInterval = 45
    /// However often one outage flaps between heldStale and filesOnly, or
    /// however soon a second outage follows the first, at most one down/
    /// back notification pair reaches the notifier in any ten-minute span.
    /// Anchored to the last pair actually sent (not to when the blocked
    /// episode started), so one long outage does not earn a second pair
    /// simply because ten minutes passed since it began.
    static let notifyRateLimit: TimeInterval = 600

    /// When the outage in progress started, nil while Pass reads as normal.
    private(set) var episodeStarted: Date?
    /// Whether the current episode has already decided its down/back pair's
    /// fate (fired the notification, or been rate-limited into silence) --
    /// checked so a long outage's later polls, and its eventual recovery,
    /// know not to re-decide.
    private(set) var notifiedDown = false
    /// The last time a down/back pair actually reached the notifier, nil
    /// until the first one does.
    private(set) var lastPairAt: Date?
    /// Whether *this* episode's pair was allowed past the rate limit --
    /// meaningless until `notifiedDown` is true, and read again at recovery
    /// so "Pass is back" mirrors whatever "Pass isn't answering" (or "Pass
    /// is down") actually did, rather than running its own, second rate
    /// check against a `lastPairAt` that its own down half may have just set.
    private var pairAllowed = false

    /// What one poll's health is worth reporting, if anything. `notify`
    /// says whether it should also reach the system notifier; `seen` says
    /// whether it should land in the outcome queue already marked read --
    /// true only for a blip that resolved before ever crossing the
    /// threshold, which is history the moment it is recorded, not news.
    struct Result {
        let kind: Outcome.Kind
        let title: String
        let detail: String?
        let notify: Bool
        let seen: Bool

        static func blip(seconds: TimeInterval) -> Result {
            Result(kind: .info, title: "Pass blipped for \(Int(seconds))s",
                  detail: nil, notify: false, seen: true)
        }
    }

    /// Call once per poll, in poll order, with the exact `now` used to
    /// build `fresh`. A nil `previous` (a cold launch, or a test seam's
    /// first step) reports nothing, matching every other "no real
    /// previous" rule in this file -- there is nothing yet to call an
    /// episode's start.
    func process(previous: MenuModel?, fresh: MenuModel, now: Date) -> Result? {
        guard previous != nil else { return nil }
        let after = IconHealth.of(source: fresh.source,
                                  passReachable: fresh.passReachable,
                                  passStaleSince: fresh.passStaleSince)
        switch after {
        case .normal: return recovered(now: now)
        case .heldStale: return down(now: now, filesOnly: false)
        case .filesOnly: return down(now: now, filesOnly: true)
        }
    }

    /// A poll that read as heldStale or filesOnly. Starts the episode's
    /// clock on the first such poll, then reports at most once per episode:
    /// once `notifiedDown` flips true here, every later poll in the same
    /// episode (however much further it degrades) returns nil, on purpose
    /// -- the episode already told John once, and the point of episodes
    /// over raw transitions is that it should not tell him again for the
    /// same outage.
    private func down(now: Date, filesOnly: Bool) -> Result? {
        let started = episodeStarted ?? now
        episodeStarted = started
        guard !notifiedDown else { return nil }
        let elapsed = now.timeIntervalSince(started)
        // Files-only forces the decision even under healthNotifyAfter: it
        // already implies the 90-second hold window ran out in real use, so
        // this only actually fires early under a test's shortened hold
        // window -- see Feed.pollFailed's holdWindow override.
        guard elapsed >= Self.healthNotifyAfter || filesOnly else { return nil }
        notifiedDown = true
        pairAllowed = lastPairAt.map { now.timeIntervalSince($0) >= Self.notifyRateLimit } ?? true
        if pairAllowed { lastPairAt = now }
        let (title, detail) = filesOnly
            ? ("Pass is down", "Showing file feeds until it answers again.")
            : ("Pass isn't answering", "Holding the last update.")
        return Result(kind: .info, title: title, detail: detail,
                      notify: pairAllowed, seen: false)
    }

    /// A poll that read as normal. Ends whatever episode was in progress --
    /// nil if there was none, meaning Pass was already normal and this is a
    /// no-op poll, reported as nothing.
    private func recovered(now: Date) -> Result? {
        guard let started = episodeStarted else { return nil }
        let wasNotified = notifiedDown
        let allowed = pairAllowed
        episodeStarted = nil
        notifiedDown = false
        pairAllowed = false
        guard wasNotified else {
            return .blip(seconds: now.timeIntervalSince(started))
        }
        return Result(kind: .ok, title: "Pass is back", detail: nil,
                      notify: allowed, seen: false)
    }
}
