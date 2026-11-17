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
//
// Entry (App.swift) dispatches on `--dump-model` today and does not know these
// flags, so a test invokes them next to it (`--dump-model --ask-dump-model`);
// DumpModel.run hands any `--ask-*` argument to `AskSeams.run`. Once App.swift
// routes `--ask-*` itself the companion flag stops being needed.

import Foundation

enum AskSeams {
    static func run(args: [String]) -> Int32 {
        if args.contains("--ask-dump-model") { return dumpModel(args: args) }
        if args.contains("--ask-dump-thread") { return dumpThread(args: args) }
        if args.contains("--ask-post") { return post(args: args) }
        return fail("unknown --ask-* seam: \(args.filter { $0.hasPrefix("--ask-") }.joined(separator: " "))")
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
