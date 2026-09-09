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
