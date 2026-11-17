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
//   --ask-fire <text> [--ask-mode run|ask_first] [--ask-panel] (Q12)
//       [--ask-undo] [--ask-aged <seconds>]
//       The ask field's fire, really performed: Run now spawns qt through
//       the same Actions.fire the field uses (point QT_BIN at a stub and
//       read what it was invoked with); Ask me first really POSTs /asks
//       through Actions.askFirst, falling back to /capture on a 501/404
//       exactly as the field does. Prints the receipt the field leaves
//       (the plan's fixed line, its undo window), and --ask-undo performs
//       the receipt's Undo: resolve the fired ask off the board, qt stop,
//       POST drop. --ask-aged backdates the receipt so an expired undo can
//       be proven. --dump-fire/--dump-keys still describe the *fallback*
//       (capture) leg of the second mode -- this seam describes both legs.
//
//   --ask-again [<id-substring>] (Q12)
//       The Ask-again list: GET /asks.json?place=done through the same
//       AskClient the field's own fetch uses, newest first. With a
//       substring, also the walkthrough of clicking that row: the words
//       that land in the field, and the fire they would make in either
//       mode (FireResolve.describe, the same pure call the field runs).
//
// Entry (App.swift) dispatches on `--dump-model` today and does not know these
// flags, so a test invokes them next to it (`--dump-model --ask-dump-model`);
// DumpModel.run hands any `--ask-*` argument to `AskSeams.run`. Since Q6,
// Entry also routes any `--ask-*` argument directly, so both spellings work.

import Foundation

enum AskSeams {
    static func run(args: [String]) -> Int32 {
        if args.contains("--ask-notice") { return askNotice(args: args) }
        if args.contains("--ask-fire") { return fireField(args: args) }
        if args.contains("--ask-again") { return askAgain(args: args) }
        if args.contains("--ask-dump-model") { return dumpModel(args: args) }
        if args.contains("--ask-dump-rows") { return dumpRows(args: args) }
        if args.contains("--ask-dump-thread") { return dumpThread(args: args) }
        if args.contains("--ask-press") { return press(args: args) }
        if args.contains("--ask-post") { return post(args: args) }
        return fail("unknown --ask-* seam: \(args.filter { $0.hasPrefix("--ask-") }.joined(separator: " "))")
    }

    // MARK: --ask-fire (Q12)

    /// The ask field's fire, really performed, with the receipt it leaves
    /// and (asked for) the receipt's Undo. Every step is the same call the
    /// live field makes -- Actions.fire / Actions.askFirst for the send,
    /// AskReceipt for the landing, Actions.stopQtTask + AskClient.post for
    /// the undo -- so a test pins the field's behaviour, not a copy of it.
    private static func fireField(args: [String]) -> Int32 {
        // The text is allowed to start with `--in`/`@` -- that is the
        // fire's own directory prefix -- so the guard rejects only this
        // seam's own flags, not every leading dash.
        let ownFlags: Set<String> = ["--ask-mode", "--ask-panel", "--ask-undo", "--ask-aged"]
        guard let i = args.firstIndex(of: "--ask-fire"), i + 1 < args.count,
              !ownFlags.contains(args[i + 1]) else {
            return fail("--ask-fire needs some text")
        }
        let raw = args[i + 1]
        let mode = value(args, "--ask-mode") ?? "run"
        let isPanel = args.contains("--ask-panel")
        let config = StoreConfig.resolve()
        var out: [String: Any] = [
            "text": raw,
            "mode": mode,
            "panel": isPanel,
        ]
        let (prefixDir, stripped) = FireResolve.parsePrefix(raw)
        let resolved = FireResolve.runDirectory(prefixDir: prefixDir, settings: config.settings)
        out["dir"] = resolved.url.path
        out["dir_source"] = resolved.source

        func receiptJSON(_ receipt: AskReceipt, undoable: Bool) -> [String: Any] {
            [
                "kind": receipt.kind.rawValue,
                "line": receipt.line,
                "words": receipt.words,
                "ask_id": receipt.askID ?? NSNull(),
                "undo_window_s": Int(AskReceipt.undoWindow),
                "undoable": undoable,
            ] as [String: Any]
        }

        switch mode {
        case "run":
            switch Actions.fire(prompt: stripped, in: resolved.url,
                                origin: isPanel ? "summon" : "widget").map({ stripped }) {
            case .failure(let problem):
                out["ok"] = false
                out["error"] = problem.message
                _ = emit(out)
                return 1
            case .success:
                let aged = value(args, "--ask-aged").flatMap { Double($0) } ?? 0
                let receipt = AskReceipt(kind: .runNow, words: stripped,
                                         firedAt: Date().addingTimeInterval(-aged), askID: nil)
                out["ok"] = true
                out["receipt"] = receiptJSON(receipt, undoable: receipt.undoable(now: Date()))
                if args.contains("--ask-undo") {
                    out["undo"] = undoJSON(receipt: receipt, config: config)
                }
            }
        case "ask_first":
            guard let base = config.passURL else {
                return fail("the Pass feed is off (QT_PASS_URL is empty)")
            }
            switch Actions.askFirst(text: stripped, rawText: raw, dir: resolved.url, base: base) {
            case .failure(let problem):
                out["ok"] = false
                out["error"] = problem.message
                _ = emit(out)
                return 1
            case .success(let outcome):
                out["ok"] = true
                out["route"] = outcome.route
                switch outcome {
                case .posted(let id):
                    let aged = value(args, "--ask-aged").flatMap { Double($0) } ?? 0
                    let receipt = AskReceipt(kind: .askFirst, words: stripped,
                                             firedAt: Date().addingTimeInterval(-aged), askID: id)
                    out["ask_id"] = id ?? NSNull()
                    out["receipt"] = receiptJSON(receipt, undoable: receipt.undoable(now: Date()))
                    if args.contains("--ask-undo") {
                        out["undo"] = undoJSON(receipt: receipt, config: config)
                    }
                case .fellBack(let captured):
                    out["captured_id"] = captured ?? NSNull()
                    // The fallback leg's landing is today's To-Pass outcome,
                    // computed by the same describe the live field runs.
                    let (state, _) = FireFieldOutcome.describe(
                        result: .success(captured ?? ""), toPass: true,
                        displayText: raw, isPanel: isPanel)
                    if case .success(let text) = state {
                        out["fallback_line"] = text
                    } else {
                        out["fallback_line"] = NSNull()
                    }
                }
            }
        default:
            return fail("--ask-mode must be run or ask_first")
        }
        return emit(out)
    }

    /// The receipt's Undo, performed exactly as the field's Undo button
    /// does: resolve the fired ask off a real board read, `qt stop` when the
    /// ask is still running or queued, then the `drop` move. A receipt past
    /// its window refuses, the way the button disappears.
    private static func undoJSON(receipt: AskReceipt, config: StoreConfig) -> [String: Any] {
        let now = Date()
        guard receipt.undoable(now: now) else {
            return ["ok": false, "expired": true,
                    "window_s": Int(AskReceipt.undoWindow)] as [String: Any]
        }
        let board = AskBoard.build(feed: Feed.loadAsks(config: config, now: now))
        let asks = board.rows.map(\.ask)
        guard let id = receipt.askID ?? AskReceipt.resolveAskID(in: asks, words: receipt.words) else {
            return ["ok": false,
                    "error": "the fired ask is not on the board to stop"] as [String: Any]
        }
        var out: [String: Any] = [
            "ok": true,
            "id": id,
            "qt_task_id": AskReceipt.qtTaskID(forAskID: id),
            "stopped": false,
        ] as [String: Any]
        if let row = board.row(id: id),
           row.ask.state == .working || row.ask.state == .heard {
            switch Actions.stopQtTask(askID: id) {
            case .success: out["stopped"] = true
            case .failure(let problem):
                out["ok"] = false
                out["stop_error"] = problem.message
            }
        }
        if let base = config.passURL {
            let result = AskClient(base: base).post(id: id, move: "drop")
            out["dropped"] = result.ok
            out["drop_message"] = result.message
            if !result.ok { out["ok"] = false }
        } else {
            out["dropped"] = NSNull()
        }
        return out
    }

    // MARK: --ask-again (Q12)

    /// The Ask-again list: the hub's own done pages, newest first, through
    /// the same AskClient call the field's fetch makes; with a substring,
    /// the walkthrough of clicking that row -- the words that land in the
    /// field, and the fire they would make in either mode.
    private static func askAgain(args: [String]) -> Int32 {
        let config = StoreConfig.resolve()
        guard let base = config.passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        var needle: String?
        if let i = args.firstIndex(of: "--ask-again"), i + 1 < args.count,
           !args[i + 1].hasPrefix("--") {
            needle = args[i + 1]
        }
        var out: [String: Any] = [:]
        switch AskClient(base: base).list(place: "done", limit: 8) {
        case .failure(let failure):
            out["ok"] = false
            out["error"] = failure.problem.message
            _ = emit(out)
            return 1
        case .success(.unchanged(let rev)):
            // The list call carries no since_rev, so this is a hub speaking
            // ahead of the contract; say so rather than pretend.
            out["ok"] = false
            out["error"] = "the hub answered unchanged for rev \(rev ?? "?")"
            _ = emit(out)
            return 1
        case .success(.list(let list)):
            out["ok"] = true
            out["count"] = list.asks.count
            out["recent"] = list.asks.map { ask in
                ["id": ask.id, "title": ask.title, "words": ask.words] as [String: Any]
            }
            if let needle {
                guard let pick = list.asks.first(where: { $0.id.contains(needle) }) else {
                    return fail("no recent ask id contains \"\(needle)\"")
                }
                // The click's own two steps, as the view runs them: the
                // words land in the field (empty words would leave the
                // field alone), then a fire of those words resolves through
                // the same FireResolve.describe every fire describes by.
                let words = pick.words.trimmingCharacters(in: .whitespacesAndNewlines)
                out["picked"] = [
                    "id": pick.id,
                    "draft": words.isEmpty ? NSNull() : words,
                    "run": words.isEmpty ? NSNull()
                        : FireResolve.describe(text: words, toPass: false,
                                               settings: config.settings),
                    "ask_first_fallback": words.isEmpty ? NSNull()
                        : FireResolve.describe(text: words, toPass: true,
                                               settings: config.settings),
                ] as [String: Any]
            }
        }
        return emit(out)
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
            // Q12: the failed row's reason, plus `lines` -- the sub-lines the
            // row draws under its title, in draw order, so "rendered" is a
            // fact about the row the view draws rather than a field it
            // merely carries. Keep in sync with AskRowView's body.
            "reason": row.reasonLine ?? NSNull(),
            "lines": rowLines(row),
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

    /// The sub-lines one ask row draws under its title, in the order the
    /// row draws them: the live line, the failed reason, the last-attempt
    /// facts, the move line's slot (nothing here -- it is transient), and
    /// a question's own words. AskRowView's body is the other copy of this
    /// order; the view's comment says the same.
    private static func rowLines(_ row: AskRowModel) -> [String] {
        var lines: [String] = []
        if let now = row.nowLine { lines.append(now) }
        if let reason = row.reasonLine { lines.append(reason) }
        if let attempt = row.lastAttempt { lines.append(attempt) }
        if let question = row.ask.question, !question.isEmpty, row.ask.state == .question {
            lines.append(question)
        }
        return lines
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
