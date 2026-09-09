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
