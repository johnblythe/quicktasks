// AskSeams.swift -- the `--ask-*` CLI seams the tests drive.
//
// Same idea as DumpModel's seams: the real Feed, the real client, the real
// decode, printed as JSON, so a test asserts on what the widget would show
// without a display or a live hub. Later ask units add their own `--ask-*`
// seams to this file.
//
//   --ask-dump-model [--ask-since-rev <rev>]
//       The ask feed Feed.loadAsks produces: source (asks|status|files), rev,
//       counts, every row (re-encoded, plus a `gray` flag for unknown states),
//       and on the status path the legacy model's source and ids.
//   --ask-dump-thread <id> [--ask-updated-at <stamp>] [--ask-repeat <n>]
//       GET /asks/<id>.json through the thread cache, n times (default 1), so a
//       test can prove the second fetch made no request.
//   --ask-post <id> <move> [json]
//       The real POST /asks/<id>/<move>; prints the MoveResult. Exit 0 when the
//       move took, 1 when it did not (a 409 is an answer, not a crash).
//   --ask-dump-rows [--ask-expand <id-substring>] [--ask-done <id-substring>] [--ask-undo]
//       The ask menu the rows draw (Q3): source, badge (the hub's counts.badge,
//       verbatim), the sections in plan order with every row's detail,
//       affordances, move buttons (Q9, from the hub's own moves list), and the
//       legacy ids when this hub predates the ask API. --ask-expand runs the
//       row's expand plan (thread fetch + seen for an unseen row); --ask-done
//       posts done and prints the undo line the row shows, and --ask-undo
//       spends the returned token right after.
//   --ask-press <id-substring> <key> [--ask-text <text>] [--ask-in-field] [--ask-undo] (Q9)
//       The key walkthrough: the same AskKeys.target the root handler runs,
//       then the same POST the resolved button would make. A text move posts
//       the words its field opens with (the original words, for a redo) when
//       no --ask-text overrides them. --ask-in-field proves the inert case:
//       a field with focus owns every key, nothing resolves, nothing posts.
//
//   --ask-notice <payload.json> [--ask-action <id>] [--ask-text <text>] (Q6)
//       One bell payload (v2 or v1) as the notice it becomes: category,
//       sound, the actions in banner order, and the POST each action routes
//       to -- the same InboxNotice.toNotice and AskNoticeRoute the watcher
//       and the delegate run, printed instead of posted. --ask-action (with
//       --ask-text for a text input) really performs that action's POST
//       through AskClient, so a test can prove the typed text reached
//       /asks/<id>/<move>. The `dedupe` block replays the notice's
//       suppressions through a real JobTransitionTracker to prove the poll
//       that later sees the same landing stays silent.
//
// Entry (App.swift) dispatches on `--dump-model` today and does not know these
// flags, so a test invokes them next to it (`--dump-model --ask-dump-model`);
// DumpModel.run hands any `--ask-*` argument to `AskSeams.run`. Since Q6,
// Entry also routes any `--ask-*` argument directly, so both spellings work.

import Foundation

enum AskSeams {
    static func run(args: [String]) -> Int32 {
        if args.contains("--ask-notice") { return askNotice(args: args) }
        if args.contains("--ask-dump-model") { return dumpModel(args: args) }
        if args.contains("--ask-dump-rows") { return dumpRows(args: args) }
        if args.contains("--ask-dump-thread") { return dumpThread(args: args) }
        if args.contains("--ask-press") { return press(args: args) }
        if args.contains("--ask-post") { return post(args: args) }
        return fail("unknown --ask-* seam: \(args.filter { $0.hasPrefix("--ask-") }.joined(separator: " "))")
    }

    // MARK: --ask-notice (Q6)

    /// One bell payload as the notice it becomes, plus each action's routed
    /// POST, the once-per-ask dedupe proof, and (with `--ask-action`) the
    /// real POST an action tap would make.
    private static func askNotice(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--ask-notice"), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else {
            return fail("--ask-notice needs a payload file")
        }
        let path = args[i + 1]
        guard let data = FileManager.default.contents(atPath: path),
              let payload = try? JSONDecoder().decode(InboxNotice.self, from: data) else {
            return fail("could not decode \(path) as an inbox notice")
        }
        let notice = payload.toNotice(uuid: "SEAM")
        let typed = value(args, "--ask-text") ?? ""
        let askID = payload.ask_id ?? payload.task_id

        var out: [String: Any] = [
            "v": payload.v ?? NSNull(),
            "v2": payload.isV2,
            "kind": payload.kind ?? NSNull(),
            "category": notice.category.rawValue,
            "sound": notice.sound,
            "title": notice.title,
            "body": notice.body ?? NSNull(),
            "ask_id": payload.ask_id ?? NSNull(),
            "task_id": payload.task_id ?? NSNull(),
            "open_url": notice.passURL ?? NSNull(),
            "moves": payload.moves ?? NSNull(),
            "notice_id": notice.id,
        ]
        var actionEntries: [[String: Any]] = []
        if let banners = AskNotice.actions[notice.category] {
            // An ask category: every banner action with the POST it routes
            // to, so the printout and Notification Center cannot drift.
            actionEntries = banners.map { banner in
                var entry: [String: Any] = [
                    "id": banner.action.rawValue,
                    "title": banner.title,
                    "text_input": banner.textInput,
                ]
                let route = AskNoticeRoute.route(actionID: banner.action.rawValue,
                                                 askID: askID,
                                                 typedText: typed,
                                                 body: payload.body,
                                                 url: notice.passURL)
                switch route {
                case .move(_, let move, let body):
                    entry["post"] = ["move": move, "body": body] as [String: Any]
                case .copy:
                    entry["copy"] = true
                case .open:
                    entry["open"] = true
                case .click, .none:
                    break
                }
                return entry
            }
        } else {
            // A legacy category: today's buttons, titles only -- they are
            // the old deep links (resume / allowlist / open), not moves.
            let legacyTitles: [String]
            switch notice.category {
            case .blocked: legacyTitles = ["Resume in Terminal", "Always Allow Tool", "Open in Pass"]
            case .blockedNoAllow: legacyTitles = ["Resume in Terminal", "Open in Pass"]
            case .outcome: legacyTitles = ["Open in Pass"]
            default: legacyTitles = []
            }
            actionEntries = legacyTitles.map { ["title": $0, "text_input": false] as [String: Any] }
        }
        out["actions"] = actionEntries
        out["dedupe"] = dedupeJSON(payload)

        if let actionID = value(args, "--ask-action") {
            let route = AskNoticeRoute.route(actionID: actionID, askID: askID,
                                             typedText: typed, body: payload.body,
                                             url: notice.passURL)
            guard case .move(let id, let move, let body) = route else {
                return fail("--ask-action \(actionID) is not a move on this notice")
            }
            guard let base = StoreConfig.resolve().passURL else {
                return fail("the Pass feed is off (QT_PASS_URL is empty)")
            }
            let result = AskClient(base: base).post(id: id, move: move, body: body)
            out["action_post"] = [
                "action": actionID,
                "id": id,
                "move": move,
                "body": body,
                "ok": result.ok,
                "status": result.status,
                "kind": result.kind.rawValue,
                "message": result.message,
            ] as [String: Any]
        }
        return emit(out)
    }

    /// The no-duplicate guarantee as data (Q6): a real JobTransitionTracker
    /// shown the ask running, then the notice's suppressions applied --
    /// exactly what handleInbox does -- then the landing poll, versus the
    /// same two polls with no notice in between. `fired_after_notice` 0
    /// with `fired_without_notice` 1 is "poll-detected fallback notices
    /// suppressed when an inbox v2 notice for the same ask_id arrived".
    private static func dedupeJSON(_ payload: InboxNotice) -> [String: Any] {
        let suppressions = payload.suppressions()
        let landedID = payload.task_id
            ?? payload.ask_id.map { $0.hasPrefix("qt-") ? String($0.dropFirst(3)) : $0 }
            ?? "seam"
        let landed: TaskStatus
        switch payload.kind {
        case "answer", "done": landed = .done
        case "failed", "timeout": landed = .failed
        case "blocked": landed = .blocked
        default: landed = .unknown   // question/receipt/reminder/info: no legacy transition fires
        }
        func record(_ status: TaskStatus) -> TaskRecord {
            TaskRecord(id: landedID, itemID: payload.ask_id ?? landedID,
                       title: payload.title, status: status,
                       state: nil, origin: .pass)
        }
        let tracker = JobTransitionTracker()
        _ = tracker.detect(fresh: [record(.running)])
        for s in suppressions { tracker.suppress(id: s.id, status: s.status) }
        let afterNotice = tracker.detect(fresh: [record(landed)])
        let control = JobTransitionTracker()
        _ = control.detect(fresh: [record(.running)])
        let withoutNotice = control.detect(fresh: [record(landed)])
        return [
            "suppressed_ids": suppressions.map(\.id),
            "landed_status": landed.rawValue,
            "fired_after_notice": afterNotice.count,
            "fired_without_notice": withoutNotice.count,
        ] as [String: Any]
    }

    // MARK: --ask-dump-model

    private static func dumpModel(args: [String]) -> Int32 {
        let limit = value(args, "--limit").flatMap { Int($0) }
        let config = StoreConfig.resolve(limit: limit)
        let now = Date()

        // A prior poll that held `rev`, so `since_rev` goes on the wire and an
        // `{unchanged: true}` answer has something to hand back.
        var previous: AskFeed?
        if let rev = value(args, "--ask-since-rev") {
            previous = AskFeed(source: .asks, asks: [], counts: AskCounts(), rev: rev,
                               generatedAt: nil, passURL: nil, passError: nil, model: nil)
        }
        let feed = Feed.loadAsks(config: config, now: now, previous: previous)

        var payload: [String: Any] = [
            "source": feed.source.rawValue,
            "rev": feed.rev ?? NSNull(),
            "generated_at": feed.generatedAt ?? NSNull(),
            "unchanged": feed.unchanged,
            "pass_url": feed.passURL ?? NSNull(),
            "pass_error": feed.passError ?? NSNull(),
            "counts": countsJSON(feed.counts),
            "count": feed.asks.count,
            "ids": feed.asks.map { $0.id },
            "asks": feed.asks.map(rowJSON),
        ]
        if let model = feed.model {
            payload["status_model"] = [
                "source": model.source.rawValue,
                "count": model.records.count,
                "ids": model.records.map { $0.id },
                "badge": model.aggregate.badge,
            ] as [String: Any]
        } else {
            payload["status_model"] = NSNull()
        }
        return emit(payload)
    }

    // MARK: --ask-dump-thread

    private static func dumpThread(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--ask-dump-thread"), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else {
            return fail("--ask-dump-thread needs an ask id")
        }
        let id = args[i + 1]
        guard let base = StoreConfig.resolve().passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        let repeats = max(1, value(args, "--ask-repeat").flatMap { Int($0) } ?? 1)
        let stamp = value(args, "--ask-updated-at")
        let cache = AskThreadCache()
        let client = AskClient(base: base)
        var last: Result<AskThread, AskFailure> = .failure(.problem("no fetch ran"))
        for _ in 0..<repeats { last = client.thread(id: id, updatedAt: stamp, cache: cache) }
        switch last {
        case .failure(let failure):
            _ = emit(["ok": false, "not_found": failure == .notFound,
                      "error": failure.problem.message])
            return 1
        case .success(let thread):
            return emit(["ok": true,
                         "ask": rowJSON(thread.ask),
                         "answer_text": thread.answerText,
                         "answer_truncated": thread.answerTruncated,
                         "timeline": thread.timeline.map { ["at": $0.at ?? NSNull(), "text": $0.text] as [String: Any] },
                         "runs": thread.runs.map(runJSON),
                         "cached": cache.count])
        }
    }

    // MARK: --ask-dump-rows

    /// The ask menu as data (Q3): the same `AskBoard` the rows draw, plus the
    /// optional expand/done walkthroughs so a test can prove what a row *does*
    /// without a display -- the plan and the wording come from the same pure
    /// code the view runs.
    private static func dumpRows(args: [String]) -> Int32 {
        let config = StoreConfig.resolve()
        let feed = Feed.loadAsks(config: config)
        let board = AskBoard.build(feed: feed)

        var payload: [String: Any] = [
            "source": feed.source.rawValue,
            "speaks_asks": board.speaksAsks,
            "badge": board.badge,
            "headline": board.headline,
            "counts": countsJSON(feed.counts),
            "footer": board.speaksAsks ? AskFooter.stub : NSNull(),
            "sections": board.sections.map { entry in
                [
                    "key": entry.section.rawValue,
                    "label": entry.section.label,
                    "count": entry.rows.count,
                    "ids": entry.rows.map { $0.id },
                    "rows": entry.rows.map(rowModelJSON),
                ] as [String: Any]
            },
        ]
        // The legacy side, so a hub that predates the ask API can be proven
        // to keep its rows rather than blanking the menu.
        if let legacy = board.legacy {
            payload["legacy_source"] = legacy.source.rawValue
            payload["legacy_ids"] = legacy.records.map { $0.id }
        } else {
            payload["legacy_source"] = NSNull()
            payload["legacy_ids"] = NSNull()
        }

        if let needle = value(args, "--ask-expand") {
            guard let row = board.row(matching: needle) else {
                return fail("no ask id contains \"\(needle)\"")
            }
            payload["expanded"] = expandJSON(row: row, feed: feed, config: config)
        }
        if let needle = value(args, "--ask-done") {
            guard let row = board.row(matching: needle) else {
                return fail("no ask id contains \"\(needle)\"")
            }
            payload["done"] = doneJSON(row: row, args: args, config: config)
        }
        return emit(payload)
    }

    /// The expand walkthrough: the same `AskExpand.plan` the row runs, then
    /// the same I/O in the same order (thread first, `seen` only once the
    /// answer is in hand).
    private static func expandJSON(row: AskRowModel,
                                   feed: AskFeed,
                                   config: StoreConfig) -> [String: Any] {
        let plan = AskExpand.plan(ask: row.ask, source: feed.source)
        var out: [String: Any] = [
            "id": row.id,
            "post_seen": plan.postSeen,
        ]
        guard plan.fetchThread, let base = config.passURL else {
            // The file fallback: no thread endpoint, so the peek shows the
            // excerpt and nothing is posted anywhere.
            out["from_thread"] = false
            out["answer_text"] = row.ask.answerExcerpt ?? NSNull()
            return out
        }
        let client = AskClient(base: base)
        switch client.thread(id: row.id, updatedAt: row.ask.updatedAt) {
        case .failure(let failure):
            out["from_thread"] = false
            out["error"] = failure.problem.message
            out["answer_text"] = row.ask.answerExcerpt ?? NSNull()
        case .success(let thread):
            out["from_thread"] = true
            out["answer_text"] = thread.answerText
            out["answer_truncated"] = thread.answerTruncated
            if plan.postSeen {
                let seen = client.post(id: row.id, move: "seen")
                out["seen_posted"] = true
                out["seen_ok"] = seen.ok
            } else {
                out["seen_posted"] = false
            }
        }
        return out
    }

    /// The done walkthrough: the real POST, the exact line the row draws
    /// (`AskMoveLine`), and -- with `--ask-undo` -- the Z keystroke's own
    /// POST spending the returned token.
    private static func doneJSON(row: AskRowModel,
                                 args: [String],
                                 config: StoreConfig) -> [String: Any] {
        guard let base = config.passURL else {
            return ["id": row.id, "error": "the Pass feed is off (QT_PASS_URL is empty)"]
        }
        let client = AskClient(base: base)
        let result = client.post(id: row.id, move: "done")
        var out: [String: Any] = [
            "id": row.id,
            "ok": result.ok,
            "kind": result.kind.rawValue,
            "message": result.message,
            "line": AskMoveLine.done(result),
            "undo_token": result.undo?.token ?? NSNull(),
        ]
        if args.contains("--ask-undo"), let token = result.undo?.token {
            let undone = client.post(id: row.id, move: "undo", body: ["token": token])
            out["undo"] = [
                "ok": undone.ok,
                "message": undone.message,
                "line": AskMoveLine.undo(undone),
            ] as [String: Any]
        }
        return out
    }

    /// One row as the seam reports it: exactly the fields the view derives,
    /// nothing the view does not read.
    private static func rowModelJSON(_ row: AskRowModel) -> [String: Any] {
        [
            "id": row.id,
            "title": row.title,
            "state": row.ask.state.raw,
            "gray": row.gray,
            "detail": row.detail,
            "age": row.ageText ?? NSNull(),
            "now_line": row.nowLine ?? NSNull(),
            "unseen": row.ask.unseen,
            "open_url": row.ask.url ?? NSNull(),
            "open_enabled": row.openEnabled,
            "can_done": row.canDone,
            "can_expand": true,
            // Q9: the row's move buttons, from the hub's own moves list, and
            // the two state-specific extras the row draws around them.
            "buttons": row.moveButtons.map { buttonJSON($0, ask: row.ask) },
            "last_attempt": row.lastAttempt ?? NSNull(),
            "answer_field": row.answersInline,
        ] as [String: Any]
    }

    /// One move button as the seam reports it: what it does, its key, and
    /// for a text move the body key and the words its field opens with.
    private static func buttonJSON(_ button: AskMoveButton, ask: Ask) -> [String: Any] {
        var out: [String: Any] = [
            "title": button.title,
            "key": button.key ?? NSNull(),
            "inline": button.inline,
            "text_input": false,
        ]
        switch button.act {
        case .post(let move):
            out["move"] = move
        case .text(let move, _):
            out["move"] = move
            out["text_input"] = true
            out["body_key"] = AskRowMoves.bodyKey(for: move)
            out["prefill"] = AskRowMoves.prefill(for: ask, move: move) ?? ""
        case .copyAnswer:
            out["client"] = "copy"
        case .openThread:
            out["client"] = "open"
        }
        return out
    }

    // MARK: --ask-press (Q9)

    /// The key walkthrough: resolve one bare key against a row the way the
    /// root handler does (`AskKeys.target`), then perform it the way its
    /// button does. A plain move POSTs `{}`; a text move POSTs its body key
    /// with the words the field would carry (the prefill, unless --ask-text
    /// overrides), and posts nothing when those words are empty -- an empty
    /// follow-up is a slip of the return key, not a move. --ask-in-field
    /// proves the keys go inert while a field has focus: nothing resolves,
    /// nothing posts. --ask-undo spends the token right after, the way Z
    /// does. Client-only buttons (copy, open) report themselves without
    /// posting anything anywhere.
    private static func press(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--ask-press"), i + 2 < args.count,
              !args[i + 1].hasPrefix("--") else {
            return fail("--ask-press needs <id-substring> <key>")
        }
        let needle = args[i + 1]
        let key = args[i + 2]
        let config = StoreConfig.resolve()
        let feed = Feed.loadAsks(config: config)
        let board = AskBoard.build(feed: feed)
        guard let row = board.row(matching: needle) else {
            return fail("no ask id contains \"\(needle)\"")
        }
        let inField = args.contains("--ask-in-field")
        var out: [String: Any] = [
            "id": row.id,
            "key": key,
            "in_field": inField,
            "state": row.ask.state.raw,
        ]
        guard let button = AskKeys.target(ask: row.ask, key: key, fieldHasFocus: inField) else {
            // Nothing resolved: a key this row does not carry, or a field
            // that owns the keystroke. Either way, nothing posts.
            out["pressed"] = NSNull()
            out["posted"] = false
            return emit(out)
        }
        out["pressed"] = ["title": button.title, "move": button.move ?? NSNull()] as [String: Any]
        switch button.act {
        case .copyAnswer, .openThread:
            out["client"] = button.act == .copyAnswer ? "copy" : "open"
            out["posted"] = false
            return emit(out)
        case .post(let move):
            guard let base = config.passURL else {
                return fail("the Pass feed is off (QT_PASS_URL is empty)")
            }
            let result = AskClient(base: base).post(id: row.id, move: move)
            out["posted"] = true
            out["move"] = move
            return emit(pressOutcome(row: row, move: move, result: result,
                                     args: args, base: base, out: out))
        case .text(let move, _):
            let bodyKey = AskRowMoves.bodyKey(for: move)
            let prefill = AskRowMoves.prefill(for: row.ask, move: move) ?? ""
            out["move"] = move
            out["text_input"] = true
            out["body_key"] = bodyKey
            out["prefill"] = prefill
            let typed = value(args, "--ask-text") ?? prefill
            guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                out["posted"] = false
                out["needs_text"] = true
                return emit(out)
            }
            guard let base = config.passURL else {
                return fail("the Pass feed is off (QT_PASS_URL is empty)")
            }
            let result = AskClient(base: base).post(id: row.id, move: move,
                                                    body: [bodyKey: typed])
            out["posted"] = true
            out["sent_text"] = typed
            return emit(pressOutcome(row: row, move: move, result: result,
                                     args: args, base: base, out: out))
        }
    }

    /// What a press's POST came back as, in the same words the row draws:
    /// the line (`AskMoveLine`), the token Z spends, and --ask-undo's own
    /// POST when it was asked for and there is a token to spend.
    private static func pressOutcome(row: AskRowModel, move: String, result: MoveResult,
                                     args: [String], base: URL,
                                     out: [String: Any]) -> [String: Any] {
        var out = out
        out["ok"] = result.ok
        out["kind"] = result.kind.rawValue
        out["message"] = result.message
        out["line"] = AskMoveLine.line(move: move, result: result)
        out["undo_token"] = result.undo?.token ?? NSNull()
        if args.contains("--ask-undo"), let token = result.undo?.token {
            let undone = AskClient(base: base).post(id: row.id, move: "undo",
                                                    body: ["token": token])
            out["undo"] = ["ok": undone.ok, "line": AskMoveLine.undo(undone)] as [String: Any]
        }
        return out
    }

    // MARK: --ask-post

    private static func post(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--ask-post"), i + 2 < args.count else {
            return fail("--ask-post needs <id> <move> [json]")
        }
        let id = args[i + 1]
        let move = args[i + 2]
        var body: [String: Any] = [:]
        if i + 3 < args.count, !args[i + 3].hasPrefix("--") {
            guard let parsed = (try? JSONSerialization.jsonObject(
                    with: Data(args[i + 3].utf8))) as? [String: Any] else {
                return fail("the move body is not a JSON object")
            }
            body = parsed
        }
        guard let base = StoreConfig.resolve().passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        let result = AskClient(base: base).post(id: id, move: move, body: body)
        var out: [String: Any] = [
            "ok": result.ok,
            "status": result.status,
            "kind": result.kind.rawValue,
            "message": result.message,
            "state": result.state ?? NSNull(),
            "moves": result.moves ?? NSNull(),
        ]
        out["ask"] = result.ask.map(rowJSON) ?? NSNull()
        out["undo"] = result.undo.map {
            ["token": $0.token, "expires_at": $0.expiresAt ?? NSNull()] as [String: Any]
        } ?? NSNull()
        _ = emit(out)
        return result.ok ? 0 : 1
    }

    // MARK: JSON

    static func rowJSON(_ ask: Ask) -> [String: Any] {
        var obj: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(ask),
           let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj = decoded
        }
        obj["gray"] = ask.state.isGray
        obj["counts_toward_badge"] = ask.countsTowardBadge
        return obj
    }

    private static func runJSON(_ run: AskRun) -> [String: Any] {
        var obj: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(run),
           let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj = decoded
        }
        obj["event_count"] = run.eventCount
        return obj
    }

    private static func countsJSON(_ c: AskCounts) -> [String: Any] {
        ["badge": c.badge, "needs": c.needs, "working": c.working,
         "done": c.done, "yours": c.yours, "unseen": c.unseen]
    }

    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func emit(_ payload: [String: Any]) -> Int32 {
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return fail("could not serialise payload")
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }
}
