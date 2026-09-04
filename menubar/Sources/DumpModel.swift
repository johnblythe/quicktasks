// DumpModel.swift -- `--dump-model` prints the computed menu model as JSON.
//
// This is the seam the tests drive. It runs the real Store and the real
// ordering and aggregation, so a test that points QT_DATA and QT_HUB at
// fixture directories is exercising the same code the menu draws from, in the
// same way tests/test_hub_feed.py drives the real `qt` script as a subprocess.
// It is also the read-only way to inspect live state without opening the menu.

import Foundation

enum DumpModel {
    static func run(args: [String]) -> Int32 {
        var limit = 12
        if let i = args.firstIndex(of: "--limit"), i + 1 < args.count, let n = Int(args[i + 1]) {
            limit = n
        }
        let config = StoreConfig.resolve(limit: limit)
        let model = Store.load(config: config)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func stamp(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

        let payload: [String: Any] = [
            "tasks_dir": config.tasksDir.path,
            "hub_jobs_dir": config.hubJobsDir?.path ?? NSNull(),
            "aggregate": aggregateJSON(model.aggregate),
            "headline": model.aggregate.headline,
            "badge": model.aggregate.badge,
            "refreshed_at": iso.string(from: model.refreshedAt),
            "warning": model.warning ?? NSNull(),
            "count": model.records.count,
            "records": model.records.map { r in
                [
                    "id": r.id,
                    "title": r.title,
                    "status": r.status.rawValue,
                    "detail": r.status.detail,
                    "origin": r.origin.rawValue,
                    "created": stamp(r.created),
                    "started": stamp(r.started),
                    "finished": stamp(r.finished),
                    "session_id": r.sessionId ?? NSNull(),
                    "denials": r.denialCount,
                    "can_resume": r.canResume,
                    "wants_resume": r.wantsResume,
                ] as [String: Any]
            },
        ]

        guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("could not serialise model\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }

    private static func aggregateJSON(_ a: Aggregate) -> [String: Any] {
        switch a {
        case .running(let n): return ["state": "running", "count": n]
        case .attention(let n): return ["state": "attention", "count": n]
        case .idle: return ["state": "idle", "count": 0]
        }
    }
}
