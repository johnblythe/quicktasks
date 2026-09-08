// DumpModel.swift -- the CLI seams the tests drive.
//
// `--dump-model` runs the real Feed (Pass first, files second), the real
// merge, and the real ordering, then prints the result as JSON. A test that
// points QT_DATA, QT_HUB, and QT_PASS_URL at fixtures is exercising the same
// code the menu draws from, in the same way tests/test_hub_feed.py drives the
// real `qt` script as a subprocess. It is also the read-only way to inspect
// live state without opening the menu.
//
// `--dump-capture`, `--dump-decision`, and `--dump-run` print the three POST
// bodies without sending them. Payload construction is the part of an HTTP
// client most worth pinning down and the part least worth a live server to
// test, so it is a pure function with its own seam.
//
// `--dump-endpoint` prints where the widget would look for The Pass and why.
// A `.file`-sourced result is probed exactly the way a live poll probes it --
// one loopback GET, to catch a `.pass-url` left behind by a Pass that has
// since died -- so this is no longer request-free for that one case; every
// other source (env, setting, no file, default) still makes none.
//
// `--dump-keys` walks the keyboard highlight over the visible rows, so the
// whole of the keyboard's behaviour can be checked without a display.
//
// `--post-run` and `--post-restart` are the seams that really post: `--post-run`
// fires an item through `POST /run`, and `--post-restart` fires `POST /restart`,
// both against whatever QT_PASS_URL points at, which in the tests is a
// loopback fixture server. `--post-run` exists because a 409 (already
// running, or all three job slots busy) is an expected answer that has to be
// shown in the widget's own words; `--post-restart` exists because
// `supervised` is a real fact about the target process that only a real
// round trip can report. `--dump-restart` is the request-free sibling, for
// pinning the Origin header without a live Pass.

import Foundation

enum DumpModel {
    static func run(args: [String]) -> Int32 {
        // No --limit means the settings window's row limit, the same number the
        // running widget uses. An explicit one wins, so the seam stays
        // deterministic whatever is stored.
        let limit = value(args, "--limit").flatMap { Int($0) }
        let config = StoreConfig.resolve(limit: limit)
        let now = Date()
        let loaded = Feed.load(config: config, now: now)
        // `--search` runs the same filter the search field runs, over the same
        // model, so the seam tests the filter rather than a copy of it.
        let query = value(args, "--search") ?? ""
        let model = loaded.filtered(query: query)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func stamp(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

        let payload: [String: Any] = [
            "tasks_dir": config.tasksDir.path,
            "hub_jobs_dir": config.hubJobsDir?.path ?? NSNull(),
            "source": model.source.rawValue,
            "pass_url": model.passURL,
            "pass_url_source": config.pass.source.rawValue,
            "pass_reachable": model.source == .pass,
            "pass_error": model.passError ?? NSNull(),
            "item_url_template": model.itemURLTemplate ?? NSNull(),
            "counts": model.counts,
            "truncated": model.truncated,
            "login_item": LoginItem.isEnabled(),
            "search": query,
            // Whether the payload carried a `suggestions` key at all, which is
            // what decides if the section is drawn. Distinct from the list
            // being empty: a Pass without the engine sends no key.
            "suggestions_available": model.suggestionsAvailable,
            "shows_suggestions": model.showsSuggestions,
            "suggestions": model.suggestions.map { s in
                [
                    "item_id": s.itemID,
                    "title": s.title,
                    "rationale": s.rationale,
                    "confidence": s.confidence,
                    "confidence_step": s.confidenceStep,
                    "proposed": s.proposed,
                    "source": s.source.rawValue,
                    "source_raw": s.sourceRaw ?? NSNull(),
                    "source_url": s.sourceURL ?? NSNull(),
                    "date": stamp(s.date),
                ] as [String: Any]
            },
            "suggestions_headline": Suggestion.headline(model.suggestions.count),
            "headline_preview": model.headlinePreview(limit: 3, now: now),
            "visible_sections": Array(model.visibleSections).sorted(),
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
            // What the keyboard highlight walks, as a freshly opened menu would
            // show it: default collapse rather than whatever is remembered in
            // UserDefaults, so the seam is deterministic.
            "visible_ids": defaultVisibleIDs(model, now: now),
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
                    "error": r.error ?? NSNull(),
                    "can_resume": r.canResume,
                    "wants_resume": r.wantsResume,
                    "can_decide": r.canDecide,
                    "can_run": r.canRun,
                    "source_app": r.source.rawValue,
                    "source_raw": r.sourceRaw ?? NSNull(),
                    "source_symbol": r.source.symbol,
                    "primary_action": r.primaryAction.rawValue,
                    "item_url": Actions.itemURL(template: model.itemURLTemplate,
                                                base: model.passURL,
                                                itemID: r.itemID ?? r.id)?
                        .absoluteString ?? NSNull(),
                ] as [String: Any]
            },
        ]

        return emit(payload)
    }

    private static func defaultVisibleIDs(_ model: MenuModel, now: Date) -> [String] {
        let collapsed = Set(Section.allCases.filter { $0.collapsedByDefault }.map { $0.rawValue })
        return model.visibleRecords(collapsed: collapsed, now: now).map { $0.id }
    }

    /// `--dump-settings`: the stored settings and what the widget resolved out
    /// of them. Read-only, and the seam the settings-persistence tests drive:
    /// writing a preference and reading it back through the real resolution
    /// order is the only way to check that QT_PASS_URL still wins.
    static func runSettings() -> Int32 {
        let settings = Settings.load()
        let config = StoreConfig.resolve()
        return emit([
            "pass_url_override": settings.passURLOverride ?? NSNull(),
            "hub_dir_override": settings.hubDirOverride ?? NSNull(),
            "poll_interval": settings.pollInterval,
            "row_limit": settings.rowLimit,
            "visible_sections": Array(settings.visibleSections).sorted(),
            // What the overrides actually resolved to, which is the question
            // the settings window exists to answer.
            "resolved_pass_url": config.passURL?.absoluteString ?? NSNull(),
            "resolved_pass_source": config.pass.source.rawValue,
            "resolved_hub_dir": config.hubDir?.path ?? NSNull(),
            "resolved_limit": config.limit,
            "setting_problem": config.pass.settingProblem ?? NSNull(),
            "describe": config.pass.describe,
            // POST /restart exists now (LD-201). Unlike /decide there is no
            // per-Pass feature detection to report here -- the button is
            // simply on, and a test can pin that.
            "restart_available": true,
        ])
    }

    /// `--dump-decide <id> <action> [comment]`: the POST /decide body, built
    /// and printed without being sent.
    static func runDecidePayload(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--dump-decide"), i + 2 < args.count else {
            return fail("--dump-decide needs an item id and an action")
        }
        let comment = i + 3 < args.count && !args[i + 3].hasPrefix("--") ? args[i + 3] : ""
        switch PassPayload.decide(id: args[i + 1], action: args[i + 2], comment: comment) {
        case .failure(let problem): return fail(problem.message)
        case .success(let body): return emit(body)
        }
    }

    /// `--post-decide <id> <action> [comment]`: the real round trip, against
    /// whatever QT_PASS_URL points at. Prints which route took the decision,
    /// which is the whole point of the seam: a Pass without /decide has to fall
    /// back to /save, and "it worked" is not enough to tell those apart.
    static func runPostDecide(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--post-decide"), i + 2 < args.count else {
            return fail("--post-decide needs an item id and an action")
        }
        let id = args[i + 1]
        let action = args[i + 2]
        let config = StoreConfig.resolve()
        guard let base = config.passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        // Asks the client directly rather than through Actions, so the outcome
        // comes back as the route that took it rather than as flash wording.
        let outcome = PassClient(base: base).decide(id: id, action: action) {
            guard let legacy = Actions.legacyVerdict(for: action) else {
                return .failure("this Pass is too old to \(action) a suggestion")
            }
            return PassClient(base: base).decide(
                record: TaskRecord(id: id, itemID: id, title: "",
                                   status: .unknown, state: "suggest", origin: .pass),
                action: legacy,
                pending: PassPayload.pendingDecisions(hubDir: config.hubDir))
        }
        switch outcome {
        case .success(let how):
            return emit(["ok": true, "route": how.rawValue,
                         "fell_back": how == .fellBackToSave])
        case .failure(let problem):
            _ = emit(["ok": false, "error": problem.message])
            return 1
        }
    }

    /// `--dump-search <query>`: what the filter matches, and the haystack it
    /// matched over. Separate from `--dump-model --search` because a filter
    /// that returns the wrong rows and a filter that reads the wrong fields
    /// are different bugs, and only one of them is visible in the row list.
    static func runSearch(args: [String]) -> Int32 {
        guard let query = value(args, "--dump-search") else {
            return fail("--dump-search needs a query")
        }
        let config = StoreConfig.resolve()
        let now = Date()
        let model = Feed.load(config: config, now: now)
        let filtered = model.filtered(query: query)
        return emit([
            "query": query,
            "terms": RowFilter.terms(query),
            "matched_ids": filtered.records.map { $0.id },
            "matched_count": filtered.records.count,
            "total_count": model.records.count,
            "matched_suggestions": filtered.suggestions.map { $0.itemID },
            // The aggregate is deliberately untouched by the filter: the header
            // keeps counting the feed while the list shows the matches.
            "headline": filtered.aggregate.headline,
            "sections": filtered.sections(now: now).map { entry in
                ["key": entry.section.rawValue, "count": entry.records.count] as [String: Any]
            },
            "haystacks": Dictionary(uniqueKeysWithValues: model.records.map {
                ($0.id, RowFilter.haystack($0))
            }),
        ])
    }

    /// The value after a flag, or nil when the flag is absent or last.
    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--dump-endpoint`: where the widget would look for The Pass, and how it
    /// decided. Probes a `.file`-sourced result the same way the running
    /// widget does, so this makes a request exactly when a live poll would --
    /// a `.pass-url` that names an unreachable target reports the fallback it
    /// actually used, rather than the stale value nothing is listening on.
    static func runEndpoint() -> Int32 {
        let config = StoreConfig.resolve(probeDiscovery: true)
        let pass = config.pass
        return emit([
            "pass_url": pass.url?.absoluteString ?? NSNull(),
            "source": pass.source.rawValue,
            "file": pass.file?.path ?? NSNull(),
            "file_url": pass.fileURL ?? NSNull(),
            "file_problem": pass.fileProblem ?? NSNull(),
            "fallback": pass.fallback ?? NSNull(),
            "hub_dir": config.hubDir?.path ?? NSNull(),
            "describe": pass.describe,
        ])
    }

    /// `--dump-restart`: the exact request `restart()` would send -- method,
    /// path, and the Origin header the gate requires -- without sending it.
    static func runDumpRestart() -> Int32 {
        let config = StoreConfig.resolve()
        guard let base = config.passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        let request = PassClient.restartRequest(base: base)
        return emit([
            "method": request.method,
            "path": request.path,
            "headers": request.headers,
        ])
    }

    /// `--post-restart`: really POSTs /restart against whatever QT_PASS_URL
    /// points at, and prints the outcome. `supervised` is what SettingsView's
    /// confirm-sheet flow branches on: launchd brings a supervised Pass back
    /// within seconds, a hand-started one just stays down.
    static func runPostRestart() -> Int32 {
        let config = StoreConfig.resolve()
        guard let base = config.passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        switch PassClient(base: base).restart() {
        case .success(let outcome):
            return emit(["ok": true, "restarting": true, "supervised": outcome.supervised])
        case .failure(let failure):
            _ = emit(["ok": false, "error": failure.problem.message])
            return 1
        }
    }

    /// `--dump-keys down,down,up`: the highlight's landing place after a key
    /// sequence, over the same visible rows a freshly opened menu would show.
    /// Anything but `up`/`down`/`escape`/`tab`/`cmd-1`/`cmd-2`/`cmd-return` is
    /// refused rather than ignored, so a typo in a test is not a silent pass.
    ///
    /// `tab`, `cmd-1`, `cmd-2`, and `cmd-return` walk quick-fire's mode toggle
    /// exactly the way MenuView's own hidden buttons do (`toggleMode`,
    /// `selectMode`, `fireOtherMode`): `tab` flips Run now/To Pass, `cmd-1`/
    /// `cmd-2` select one directly, and `cmd-return` fires with the *other*
    /// mode once without moving the toggle -- `mode` in the payload is where
    /// the toggle actually landed, `fired` is what that one-shot fire
    /// resolved to (nil unless `cmd-return` appeared). `--mode pass` seeds the
    /// toggle before the sequence runs; `--draft` seeds the text a
    /// `cmd-return` fires, defaulting to a non-empty placeholder so a bare
    /// `cmd-return` never fails on "nothing to fire".
    static func runKeys(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--dump-keys"), i + 1 < args.count else {
            return fail("--dump-keys needs a comma-separated key sequence")
        }
        let config = StoreConfig.resolve()
        let now = Date()
        let model = Feed.load(config: config, now: now)
        let ids = defaultVisibleIDs(model, now: now)
        var highlight: String?
        var keys: [String] = []
        var toPass = value(args, "--mode") == "pass"
        let draft = value(args, "--draft") ?? "sample text"
        var fired: [String: Any]?
        for key in args[i + 1].split(separator: ",") {
            let name = key.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            switch name {
            case "down": highlight = KeyboardNav.move(ids: ids, from: highlight, delta: 1)
            case "up": highlight = KeyboardNav.move(ids: ids, from: highlight, delta: -1)
            case "escape": highlight = nil
            case "tab": toPass.toggle()
            case "cmd-1": toPass = false
            case "cmd-2": toPass = true
            case "cmd-return":
                fired = FireResolve.describe(text: draft, toPass: !toPass, settings: config.settings)
            default:
                return fail("unknown key: \(name) (down, up, escape, tab, cmd-1, cmd-2, cmd-return)")
            }
            keys.append(name)
        }
        let row = model.records.first { $0.id == highlight }
        return emit([
            "keys": keys,
            "visible_ids": ids,
            "highlight": highlight ?? NSNull(),
            "primary_action": row?.primaryAction.rawValue ?? NSNull(),
            "primary_url": row.flatMap { r -> String? in
                switch r.primaryAction {
                case .resume: return r.resumeURL ?? "quicktask://resume/\(r.id)"
                case .item: return Actions.itemURL(template: model.itemURLTemplate,
                                                   base: model.passURL,
                                                   itemID: r.itemID ?? r.id)?.absoluteString
                }
            } ?? NSNull(),
            "mode": toPass ? "pass" : "run",
            "fired": fired ?? NSNull(),
        ])
    }

    /// `--dump-fire <text> [--mode run|pass]`: the resolved argv for a Run-now
    /// fire, or the `/capture` body for To Pass -- whichever `send()` would
    /// actually do, without doing it. Delegates to `FireResolve.describe`, the
    /// same function the live quick-fire field and the `cmd-return` case of
    /// `--dump-keys` call, so this seam and the widget can never describe a
    /// fire two different ways.
    static func runFire(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--dump-fire"), i + 1 < args.count else {
            return fail("--dump-fire needs some text")
        }
        let text = args[i + 1]
        let toPass = value(args, "--mode") == "pass"
        let config = StoreConfig.resolve()
        return emit(FireResolve.describe(text: text, toPass: toPass, settings: config.settings))
    }

    /// `--dump-hotkey`: the registered summon shortcut -- key code, modifiers,
    /// and its display string -- and whether RegisterEventHotKey actually
    /// took it. Registers and immediately unregisters its own `GlobalHotkey`
    /// rather than touching a real running widget's: this process is not the
    /// widget, and holding two live registrations at once is exactly the
    /// ownership problem `register`'s own unregister-then-try-again dance
    /// exists to avoid.
    static func runHotkey() -> Int32 {
        let combo = Settings.load().hotkeyCombo
        let hotkey = GlobalHotkey {}
        let registered = hotkey.register(combo)
        hotkey.unregister()
        return emit([
            "configured": combo != nil,
            "key_code": combo.map { Int($0.keyCode) } ?? NSNull(),
            "modifiers": combo.map { Int($0.modifiers) } ?? NSNull(),
            "display": combo?.displayString ?? NSNull(),
            "registered": registered,
        ])
    }

    /// `--dump-recent-dirs`: the directory chip's own recency list -- distinct
    /// `run_cwd` values off the qt ledger, most recent first, capped at 8.
    /// Reads QT_DATA/tasks exactly the way `RecentDirs.load` and the live chip
    /// do, so a fixture ledger under QT_DATA is what a test points this at.
    static func runRecentDirs() -> Int32 {
        let config = StoreConfig.resolve()
        let dirs = RecentDirs.load(tasksDir: config.tasksDir)
        return emit(["dirs": dirs, "count": dirs.count])
    }

    /// `--post-run <item-id>`: the real POST, against whatever QT_PASS_URL
    /// points at. Prints the outcome as JSON and exits non-zero when The Pass
    /// refused, so the 409 wording is checkable end to end.
    static func runPost(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--post-run"), i + 1 < args.count else {
            return fail("--post-run needs an item id")
        }
        let config = StoreConfig.resolve()
        guard let base = config.passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        switch PassClient(base: base).run(id: args[i + 1]) {
        case .success(let slug):
            return emit(["ok": true, "job": slug])
        case .failure(let problem):
            _ = emit(["ok": false, "error": problem.message])
            return 1
        }
    }

    /// `--dump-capture <text>`, `--dump-run <item-id>`, and
    /// `--dump-decision <item-id> <action> [comment]`.
    static func runPayload(args: [String]) -> Int32 {
        if let i = args.firstIndex(of: "--dump-capture") {
            guard i + 1 < args.count else { return fail("--dump-capture needs some text") }
            switch PassPayload.capture(text: args[i + 1]) {
            case .failure(let problem): return fail(problem.message)
            case .success(let body): return emit(body)
            }
        }

        if let i = args.firstIndex(of: "--dump-run") {
            guard i + 1 < args.count else { return fail("--dump-run needs an item id") }
            switch PassPayload.run(id: args[i + 1]) {
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
