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
import AppKit

enum DumpModel {
    static func run(args: [String]) -> Int32 {
        // `--poll-sequence` replaces the rest of this function with a replay
        // of several simulated polls in one process, so a test can drive the
        // hold-timer lifecycle deterministically. See `runPollSequence`.
        if let sequence = value(args, "--poll-sequence") {
            return runPollSequence(sequence, args: args)
        }
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
            "pass_reachable": model.passReachable,
            "pass_stale_since": stamp(model.passStaleSince),
            "held_until": stamp(model.heldUntil),
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
            "headline": model.headlineText,
            "badge": model.aggregate.badge,
            "icon_state": IconHealth.of(source: model.source,
                                       passReachable: model.passReachable,
                                       passStaleSince: model.passStaleSince).rawValue,
            "freshness": FreshnessLine.text(for: model, now: now),
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
                    "revivable": r.revivable,
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
        // Probed, like the live poll, so `rejected` is populated the same
        // way it would be for a real settings window rather than reading
        // nil just because this seam skipped the probe.
        let config = StoreConfig.resolve(probeDiscovery: true)
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
            // A probed `.pass-url` that named a different hub than this
            // widget is configured for -- surfaced in the settings window so
            // "no Pass" and "found one, but it's not mine" don't read alike.
            "rejected": config.pass.rejected ?? NSNull(),
            "notify_when_hidden": settings.notifyWhenHidden,
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
            "headline": filtered.headlineText,
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
            "rejected": pass.rejected ?? NSNull(),
            "hub_dir": config.hubDir?.path ?? NSNull(),
            "describe": pass.describe,
        ])
    }

    /// `--dump-model --poll-sequence ok,fail,fail,...`: replays a run of polls
    /// through the real `Feed.load`/`held` pipeline inside one process,
    /// carrying the hold-timer state (`previous`) from one simulated poll to
    /// the next exactly the way `StatusController.refresh()` does. `ok`
    /// steps make the same real request a live poll would, against whatever
    /// `config.passURL` is (a test's own fixture); `fail` steps skip the
    /// network call entirely and inject a synthetic timeout, so a test can
    /// drive the whole "good poll, Pass goes quiet, held stale, hold runs
    /// out, falls back to files, Pass recovers, snaps back" lifecycle in one
    /// deterministic invocation instead of eighteen real 5-second polls.
    /// `--poll-interval-seconds` (default: the settings window's own default)
    /// is how far the simulated clock advances between steps.
    private static func runPollSequence(_ raw: String, args: [String]) -> Int32 {
        let steps = raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !steps.isEmpty, steps.allSatisfy({ $0 == "ok" || $0 == "fail" }) else {
            return fail("--poll-sequence wants a comma-separated list of ok/fail steps")
        }
        let interval = value(args, "--poll-interval-seconds").flatMap(Double.init)
            ?? Settings.defaultPollInterval
        let limit = value(args, "--limit").flatMap { Int($0) }
        let config = StoreConfig.resolve(limit: limit)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func stamp(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

        var now = Date()
        var previous: MenuModel?
        var results: [[String: Any]] = []
        for (i, step) in steps.enumerated() {
            let model: MenuModel
            if step == "ok" {
                model = Feed.load(config: config, now: now, previous: previous)
            } else {
                model = Feed.pollFailed(config: config, now: now, previous: previous,
                                        problem: Problem("simulated poll failure"))
            }
            results.append([
                "step": i,
                "outcome": step,
                "at": iso.string(from: now),
                "source": model.source.rawValue,
                "pass_reachable": model.passReachable,
                "pass_stale_since": stamp(model.passStaleSince),
                "held_until": stamp(model.heldUntil),
                "headline": model.headlineText,
                "record_count": model.records.count,
                // LD-201 v8: the same two functions the dot, its tooltip, and
                // the footer read off of, so the hold-timer lifecycle this
                // seam already drives can prove the dot/freshness states
                // (held-stale, files-only) without a live server to flip.
                "icon_state": IconHealth.of(source: model.source,
                                           passReachable: model.passReachable,
                                           passStaleSince: model.passStaleSince).rawValue,
                "freshness": FreshnessLine.text(for: model, now: now),
            ])
            previous = model
            now = now.addingTimeInterval(interval)
        }
        return emit(["poll_sequence": results])
    }

    /// `--dump-notifications <seq> [--poll-interval-seconds <s>]
    /// [--hold-window-seconds <s>]`: LD-201 v9. Replays the same
    /// comma-separated ok/fail vocabulary --poll-sequence does, through the
    /// same Feed.load/Feed.pollFailed pipeline and simulated clock, but also
    /// drives a standalone HealthEpisodeTracker and JobTransitionTracker --
    /// not a real StatusController, which always ticks on the real wall
    /// clock and a real 5-second Timer, incompatible with proving a
    /// 45-second-or-more gate and a ten-minute rate limit inside one fast,
    /// deterministic run. `previous` and the two trackers all carry state
    /// forward step to step exactly the way StatusController's own `model`/
    /// `healthTracker`/`jobTracker` do across real polls.
    ///
    /// `--hold-window-seconds` overrides Feed.holdWindow for this seam's
    /// `fail` steps only (real polls are untouched), so a test can reach
    /// files-only in a handful of simulated seconds instead of the real 90
    /// -- proving the down notification fires on that transition even when
    /// it lands under HealthEpisodeTracker.healthNotifyAfter (45s).
    ///
    /// Per-step fields mirror --poll-sequence's (source, pass_reachable,
    /// pass_stale_since, held_until, headline, record_count, icon_state,
    /// freshness) plus this seam's own bookkeeping: `episode_started`,
    /// `notified_down`, `last_pair_at` (HealthEpisodeTracker's state right
    /// after this step, the three fields the brief asks this seam to
    /// surface), `health_outcome` (nil, or what this step's health poll
    /// reported), and `job_outcomes` (titles any job transitions fired this
    /// step). The top-level payload additionally rolls those per-step
    /// outcomes up into `outcomes` (every health Result, in step order --
    /// what would have reached the persistent queue) and `notified` (every
    /// health Result with `notify: true`, plus every job transition, in the
    /// same {title, body} shape --dump-outcomes already uses).
    static func runNotifications(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--dump-notifications"), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else {
            return fail("--dump-notifications needs a comma-separated list of ok/fail steps")
        }
        let steps = args[i + 1].split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !steps.isEmpty, steps.allSatisfy({ $0 == "ok" || $0 == "fail" }) else {
            return fail("--dump-notifications wants a comma-separated list of ok/fail steps")
        }
        let interval = value(args, "--poll-interval-seconds").flatMap(Double.init)
            ?? Settings.defaultPollInterval
        let holdWindow = value(args, "--hold-window-seconds").flatMap(Double.init)
            ?? Feed.holdWindow
        let limit = value(args, "--limit").flatMap { Int($0) }
        let config = StoreConfig.resolve(limit: limit)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func stamp(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

        var now = Date()
        var previous: MenuModel?
        let healthTracker = HealthEpisodeTracker()
        let jobTracker = JobTransitionTracker()
        var results: [[String: Any]] = []
        var outcomes: [[String: Any]] = []
        var notified: [[String: Any]] = []

        for (i, step) in steps.enumerated() {
            let model: MenuModel
            if step == "ok" {
                model = Feed.load(config: config, now: now, previous: previous)
            } else {
                model = Feed.pollFailed(config: config, now: now, previous: previous,
                                        problem: Problem("simulated poll failure"),
                                        holdWindow: holdWindow)
            }

            let healthResult = healthTracker.process(previous: previous, fresh: model, now: now)
            if let healthResult {
                outcomes.append([
                    "kind": healthResult.kind.rawValue,
                    "title": healthResult.title,
                    "detail": healthResult.detail ?? NSNull(),
                    "seen": healthResult.seen,
                ])
                if healthResult.notify {
                    notified.append(["title": healthResult.title,
                                     "body": healthResult.detail ?? NSNull()])
                }
            }
            let jobOutcomes = jobTracker.detect(fresh: model.records)
            for job in jobOutcomes {
                notified.append(["title": job.outcomeTitle, "body": NSNull()])
            }

            results.append([
                "step": i,
                "outcome": step,
                "at": iso.string(from: now),
                "source": model.source.rawValue,
                "pass_reachable": model.passReachable,
                "pass_stale_since": stamp(model.passStaleSince),
                "held_until": stamp(model.heldUntil),
                "headline": model.headlineText,
                "record_count": model.records.count,
                "icon_state": IconHealth.of(source: model.source,
                                           passReachable: model.passReachable,
                                           passStaleSince: model.passStaleSince).rawValue,
                "freshness": FreshnessLine.text(for: model, now: now),
                "episode_started": stamp(healthTracker.episodeStarted),
                "notified_down": healthTracker.notifiedDown,
                "last_pair_at": stamp(healthTracker.lastPairAt),
                "health_outcome": healthResult.map { r -> [String: Any] in
                    [
                        "kind": r.kind.rawValue,
                        "title": r.title,
                        "detail": r.detail ?? NSNull(),
                        "notify": r.notify,
                        "seen": r.seen,
                    ]
                } ?? NSNull(),
                "job_outcomes": jobOutcomes.map { $0.outcomeTitle },
            ])

            previous = model
            now = now.addingTimeInterval(interval)
        }

        return emit([
            "notifications": results,
            "outcomes": outcomes,
            "notified": notified,
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

    /// `--dump-summon <sequence>`: drives the real, non-Carbon half of the
    /// hotkey path -- `toggleHotkeyPanel`/`hideHotkeyPanel` on a real,
    /// headless `StatusController` -- and reads back what a live \u{2325}Q
    /// actually left on screen. `--dump-hotkey` only checks whether
    /// RegisterEventHotKey took the combo; this is the seam for whether
    /// summoning it focuses anything, which is the bug LD-201 v7 exists to
    /// fix: a panel `showHotkeyPanel` caches and reuses only ever runs its
    /// view's one-shot `.onAppear` once, so every summon after the first
    /// used to land no focus at all.
    ///
    /// Tokens, comma-separated: `summon` (one \u{2325}Q -- `toggleHotkeyPanel`,
    /// which shows the panel or hides it if already showing, exactly like a
    /// second real press) and `escape` (`hideHotkeyPanel` directly -- what
    /// the panel's own Escape does once draft/search/highlight are already
    /// empty, which they are in a freshly summoned one). Each token is
    /// followed by a short real run-loop spin so the async focus dance
    /// (`DispatchQueue.main.async`, then +50ms) has actually landed before
    /// the next token or the final read.
    ///
    /// `first_responder_is_field` reads `NSWindow.firstResponder is NSText`
    /// rather than anything SwiftUI-private: a freshly summoned panel has
    /// exactly one focusable control, so that is what actually distinguishes
    /// "focus landed" from "the window is merely key."
    static func runSummon(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--dump-summon"), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else {
            return fail("--dump-summon needs a comma-separated token sequence (summon, escape)")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = StatusController(interval: 3600, activatesGlobalHotkey: false)

        func settle(_ seconds: TimeInterval = 0.3) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        var seen: [String] = []
        for token in args[i + 1].split(separator: ",") {
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            switch name {
            case "summon":
                controller.toggleHotkeyPanel()
                settle()
            case "escape":
                controller.hideHotkeyPanel()
                settle(0.1)
            default:
                return fail("unknown token: \(name) (summon, escape)")
            }
            seen.append(name)
        }

        let panel = controller.summonPanel
        let isField = panel?.firstResponder is NSText
        return emit([
            "tokens": seen,
            "panel_visible": panel?.isVisible ?? false,
            "is_key": panel?.isKeyWindow ?? false,
            "first_responder_is_field": isField,
            "focused_field": isField ? "quick_fire" : NSNull(),
            "mode": controller.fireToPass ? "pass" : "run",
        ])
    }

    /// `--dump-outcomes <sequence> [--seen-after <seconds>]`: drives the real
    /// producers LD-201 v8 wired to `post`/`notifyIfHidden` -- the login-item
    /// toggle, a Restart Pass verdict, Settings Apply, a manual poll, and the
    /// dropdown/panel visibility gate itself -- on a headless, real
    /// `StatusController`, then reads back the persistent outcome queue and
    /// the injected notifier's state. `activatesGlobalHotkey: false` (below)
    /// always resolves to a `RecordingNotifier` -- see `StatusController.init`
    /// -- so nothing this seam does can ever reach the real Notification
    /// Center, exactly like `--dump-summon` never reaches Carbon's real
    /// global hotkey table.
    ///
    /// Tokens, comma-separated:
    ///   show / hide              dropdownDidAppear / dropdownDidDisappear
    ///   panel-show / panel-hide  toggleHotkeyPanel / hideHotkeyPanel
    ///   mark-seen                scheduleMarkOutcomesSeen(after: --seen-after,
    ///                            default 2) -- settles past it automatically
    ///   login-on / login-off     setLoginItem(true/false) -- pair with
    ///                            QT_MENUBAR_LOGINITEM_FORCE_OK or
    ///                            QT_MENUBAR_LOGINITEM_FORCE_FAIL so nothing
    ///                            real is ever touched
    ///   restart                  restartPass -- pair with an explicit
    ///                            QT_PASS_URL (a fixture or a dead loopback
    ///                            port), the same discipline every other
    ///                            restart/fire test in this file already
    ///                            follows, since an unset QT_PASS_URL falls
    ///                            back to the real default
    ///   apply                    apply(settings) unchanged, to re-commit
    ///   apply-notify-on/-off     apply(settings) with notifyWhenHidden
    ///                            flipped first
    ///   refresh                  refresh() -- a real Feed.load/Store.load
    ///                            against whatever QT_DATA/QT_HUB/QT_PASS_URL
    ///                            point at
    ///   post-ok/-error/-info     post(kind:, title: "Test outcome") -- no
    ///                            notify
    ///   notify-ok/-error         post(kind:, title: "Test notify",
    ///                            notify: true)
    ///   dismiss-newest           dismissOutcome(outcomes.first's id)
    static func runOutcomes(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--dump-outcomes"), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else {
            return fail("--dump-outcomes needs a comma-separated token sequence")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let controller = StatusController(interval: 3600, activatesGlobalHotkey: false)
        let seenAfter = value(args, "--seen-after").flatMap(Double.init) ?? 2

        func settle(_ seconds: TimeInterval = 0.3) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        var seen: [String] = []
        for token in args[i + 1].split(separator: ",") {
            let name = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            switch name {
            case "show": controller.dropdownDidAppear()
            case "hide": controller.dropdownDidDisappear()
            case "panel-show": controller.toggleHotkeyPanel(); settle()
            case "panel-hide": controller.hideHotkeyPanel(); settle(0.1)
            case "mark-seen":
                controller.scheduleMarkOutcomesSeen(after: seenAfter)
                settle(seenAfter + 0.3)
            // 0.8s rather than the bare 0.3s default: both hop to a
            // background queue and back (LoginItem.set / PassClient.restart)
            // before posting their outcome, and under the load a full test
            // suite run puts on the machine 0.3s was occasionally not enough,
            // making these two tokens flaky in exactly that circumstance.
            case "login-on": controller.setLoginItem(true) { _ in }; settle(0.8)
            case "login-off": controller.setLoginItem(false) { _ in }; settle(0.8)
            case "restart": controller.restartPass { _ in }; settle(0.8)
            case "apply": controller.apply(controller.settings); settle(0.1)
            case "apply-notify-on":
                var s = controller.settings
                s.notifyWhenHidden = true
                controller.apply(s)
                settle(0.1)
            case "apply-notify-off":
                var s = controller.settings
                s.notifyWhenHidden = false
                controller.apply(s)
                settle(0.1)
            case "refresh": controller.refresh(); settle(0.5)
            case "post-ok": controller.post(kind: .ok, title: "Test outcome"); settle(0.05)
            case "post-error": controller.post(kind: .error, title: "Test outcome"); settle(0.05)
            case "post-info": controller.post(kind: .info, title: "Test outcome"); settle(0.05)
            case "notify-ok":
                controller.post(kind: .ok, title: "Test notify", notify: true); settle(0.05)
            case "notify-error":
                controller.post(kind: .error, title: "Test notify", notify: true); settle(0.05)
            case "dismiss-newest":
                if let id = controller.outcomes.first?.id { controller.dismissOutcome(id) }
                settle(0.05)
            default:
                return fail("unknown token: \(name)")
            }
            seen.append(name)
        }

        let recorder = controller.notifier as? RecordingNotifier
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return emit([
            "tokens": seen,
            "login_item": controller.loginItem,
            "notify_when_hidden": controller.settings.notifyWhenHidden,
            "dropdown_visible": controller.dropdownVisible,
            "panel_visible": controller.summonPanel?.isVisible ?? false,
            "outcomes": controller.outcomes.map { o in
                [
                    "id": o.id,
                    "kind": o.kind.rawValue,
                    "title": o.title,
                    "detail": o.detail ?? NSNull(),
                    "seen": o.seen,
                    "at": iso.string(from: o.at),
                ] as [String: Any]
            },
            "notified": (recorder?.posted ?? []).map { p in
                ["title": p.title, "body": p.body ?? NSNull()] as [String: Any]
            },
            "authorization_requests": recorder?.authorizationRequests ?? 0,
        ])
    }

    /// `--dump-fire-outcome <text> [--mode run|pass] [--panel]`: really
    /// performs the fire -- `Actions.fire`/`Actions.capture` against
    /// whatever QT_BIN/QT_PASS_URL the environment points at -- and reports
    /// the exact state and panel-hide decision MenuView's own quick-fire
    /// field lands on, both computed by `FireFieldOutcome.describe`: the one
    /// place that logic lives, so this seam and the live field can never
    /// disagree. Exists because `--dump-fire` only describes what a fire
    /// *would* send, not what the field shows once one actually lands or
    /// fails.
    ///
    /// `--panel` reports as the standalone summon panel would (a success
    /// closes it); omitted, reports as the real dropdown would (a fire never
    /// closes that).
    static func runFireOutcome(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--dump-fire-outcome"), i + 1 < args.count else {
            return fail("--dump-fire-outcome needs some text")
        }
        let text = args[i + 1]
        let toPass = value(args, "--mode") == "pass"
        let isPanel = args.contains("--panel")
        let config = StoreConfig.resolve()

        let result: Result<String, Problem>
        let displayText: String
        if toPass {
            let base = config.passURL ?? Actions.passURL
            result = Actions.capture(text: text, base: base)
            displayText = text
        } else {
            let (prefixDir, stripped) = FireResolve.parsePrefix(text)
            let resolved = FireResolve.runDirectory(prefixDir: prefixDir, settings: config.settings)
            result = Actions.fire(prompt: stripped, in: resolved.url,
                                  origin: isPanel ? "summon" : "widget").map { "" }
            displayText = stripped
        }
        let (state, hidesPanel) = FireFieldOutcome.describe(
            result: result, toPass: toPass, displayText: displayText, isPanel: isPanel)
        let (kind, message): (String, String) = {
            switch state {
            case .idle: return ("idle", "")
            case .firing: return ("firing", "")
            case .success(let text): return ("success", text)
            case .failure(let text): return ("failure", text)
            }
        }()
        return emit([
            "state": kind,
            "message": message,
            "hides_panel": hidesPanel,
            "is_error": kind == "failure",
        ])
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

    /// `--post-revive <item-id>`: the real POST to `/revive`, against
    /// whatever QT_PASS_URL points at. Mirrors `runPost` above exactly --
    /// same shape, no special-cased status code, since a revive that 404s
    /// (an old hub, or an item that already moved on) is just a normal
    /// action error rather than something the widget should call out.
    static func runPostRevive(args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--post-revive"), i + 1 < args.count else {
            return fail("--post-revive needs an item id")
        }
        let config = StoreConfig.resolve()
        guard let base = config.passURL else {
            return fail("the Pass feed is off (QT_PASS_URL is empty)")
        }
        switch PassClient(base: base).revive(id: args[i + 1]) {
        case .success(let revivedID):
            return emit(["ok": true, "id": revivedID])
        case .failure(let problem):
            _ = emit(["ok": false, "error": problem.message])
            return 1
        }
    }

    /// `--dump-capture <text>`, `--dump-run <item-id>`,
    /// `--dump-revive <item-id>`, and
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

        if let i = args.firstIndex(of: "--dump-revive") {
            guard i + 1 < args.count else { return fail("--dump-revive needs an item id") }
            switch PassPayload.revive(id: args[i + 1]) {
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
