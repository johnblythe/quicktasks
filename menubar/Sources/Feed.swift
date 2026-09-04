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
    static func load(config: StoreConfig,
                     now: Date = Date(),
                     client: PassClient? = nil) -> MenuModel {
        guard let passURL = config.passURL else {
            return Store.load(config: config, now: now)
        }
        let pass = client ?? PassClient(base: passURL)
        switch pass.status() {
        case .failure(let problem):
            let files = Store.load(config: config, now: now)
            return MenuModel(records: files.records,
                             aggregate: files.aggregate,
                             refreshedAt: files.refreshedAt,
                             warning: files.warning,
                             source: .files,
                             passURL: passURL.absoluteString,
                             passError: problem.message,
                             groups: [])
        case .success(let status):
            return merge(status: status, config: config, now: now)
        }
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
            truncated: status.truncated
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
            canRun: pass.canRun)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
