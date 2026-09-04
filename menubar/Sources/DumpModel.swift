// DumpModel.swift -- the CLI seams the tests drive.
//
// `--dump-model` runs the real Feed (Pass first, files second), the real
// merge, and the real ordering, then prints the result as JSON. A test that
// points QT_DATA, QT_HUB, and QT_PASS_URL at fixtures is exercising the same
// code the menu draws from, in the same way tests/test_hub_feed.py drives the
// real `qt` script as a subprocess. It is also the read-only way to inspect
// live state without opening the menu.
//
// `--dump-capture` and `--dump-decision` print the two POST bodies without
// sending them. Payload construction is the part of an HTTP client most worth
// pinning down and the part least worth a live server to test, so it is a pure
// function with its own seam.

import Foundation

enum DumpModel {
    static func run(args: [String]) -> Int32 {
        var limit = 12
        if let i = args.firstIndex(of: "--limit"), i + 1 < args.count, let n = Int(args[i + 1]) {
            limit = n
        }
        let config = StoreConfig.resolve(limit: limit)
        let now = Date()
        let model = Feed.load(config: config, now: now)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func stamp(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

        let payload: [String: Any] = [
            "tasks_dir": config.tasksDir.path,
            "hub_jobs_dir": config.hubJobsDir?.path ?? NSNull(),
            "source": model.source.rawValue,
            "pass_url": model.passURL,
            "pass_reachable": model.source == .pass,
            "pass_error": model.passError ?? NSNull(),
            "login_item": LoginItem.isEnabled(),
            "aggregate": aggregateJSON(model.aggregate),
            "headline": model.aggregate.headline,
            "badge": model.aggregate.badge,
            "refreshed_at": iso.string(from: model.refreshedAt),
            "warning": model.warning ?? NSNull(),
            "count": model.records.count,
            "groups": model.groups.map { g in
                ["key": g.key, "label": g.label, "count": g.count, "undone": g.undone]
                    as [String: Any]
            },
            "sections": model.sections(now: now).map { entry in
                [
                    "key": entry.section.rawValue,
                    "label": entry.section.label,
                    "count": entry.records.count,
                    "collapsed_by_default": entry.section.collapsedByDefault,
                    "ids": entry.records.map { $0.id },
                ] as [String: Any]
            },
            "records": model.records.map { r in
                [
                    "id": r.id,
                    "item_id": r.itemID ?? NSNull(),
                    "title": r.title,
                    "status": r.status.rawValue,
                    "state": r.state ?? NSNull(),
                    "reason": r.reason?.rawValue ?? NSNull(),
                    "detail": r.detail,
                    "section": r.section(now: now).rawValue,
                    "origin": r.origin.rawValue,
                    "created": stamp(r.created),
                    "started": stamp(r.started),
                    "finished": stamp(r.finished),
                    "session_id": r.sessionId ?? NSNull(),
                    "resume_url": r.resumeURL ?? NSNull(),
                    "report": r.report ?? NSNull(),
                    "report_url": r.report.flatMap {
                        Actions.reportURL(base: model.passURL, report: $0)?.absoluteString
                    } ?? NSNull(),
                    "elapsed_s": r.elapsedAtFetch ?? NSNull(),
                    "feed_stamp": stamp(r.feedStamp),
                    "outputs": r.outputCount,
                    "denials": r.denialCount,
                    "can_resume": r.canResume,
                    "wants_resume": r.wantsResume,
                    "can_decide": r.canDecide,
                ] as [String: Any]
            },
        ]

        return emit(payload)
    }

    /// `--dump-capture <text>` and
    /// `--dump-decision <item-id> <action> [comment]`.
    static func runPayload(args: [String]) -> Int32 {
        if let i = args.firstIndex(of: "--dump-capture") {
            guard i + 1 < args.count else { return fail("--dump-capture needs some text") }
            switch PassPayload.capture(text: args[i + 1]) {
            case .failure(let problem): return fail(problem.message)
            case .success(let body): return emit(body)
            }
        }

        guard let i = args.firstIndex(of: "--dump-decision") else {
            return fail("no payload requested")
        }
        guard i + 2 < args.count else {
            return fail("--dump-decision needs an item id and an action")
        }
        let id = args[i + 1]
        let action = args[i + 2]
        let comment = i + 3 < args.count && !args[i + 3].hasPrefix("--") ? args[i + 3] : ""
        let config = StoreConfig.resolve()
        // The row is looked up in the live feed so the dumped body carries the
        // same title and state the widget would post. A row that is not there
        // still dumps, with the id the caller gave and "verify" as the state.
        let record = Feed.load(config: config).records.first { $0.itemID == id || $0.id == id }
        let built = PassPayload.decisions(
            id: record?.itemID ?? id,
            title: record?.title ?? "",
            state: record?.state ?? "verify",
            action: action,
            comment: comment,
            pending: PassPayload.pendingDecisions(hubDir: config.hubDir))
        switch built {
        case .failure(let problem): return fail(problem.message)
        case .success(let body): return emit(body)
        }
    }

    // MARK: - output

    private static func emit(_ payload: [String: Any]) -> Int32 {
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]) else {
            return fail("could not serialise payload")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func aggregateJSON(_ a: Aggregate) -> [String: Any] {
        switch a {
        case .running(let n): return ["state": "running", "count": n]
        case .attention(let n): return ["state": "attention", "count": n]
        case .idle: return ["state": "idle", "count": 0]
        }
    }
}
