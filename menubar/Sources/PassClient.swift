// PassClient.swift -- the only file in the widget that touches the network,
// and it only ever talks to loopback.
//
// Every call is synchronous and must be made off the main thread: the menu is
// a MenuBarExtra panel, and a semaphore wait on the main queue would freeze it
// mid-click. The timeouts are short for the same reason -- a poll that hangs
// for 30 seconds is indistinguishable from a Pass that is down, so it may as
// well give up in one and fall back to the files.
//
// No Origin header is set, with one exception: restart() sends the Pass's own
// origin, because /restart is gated the same way and a native app has no
// other loopback origin to offer that the gate would accept. Everywhere else,
// serve.py's _origin_blocked() lets a request with no Origin through
// (browsers always send one cross-origin; CLIs never do), which is exactly
// the hole a native app is supposed to come in by.

import Foundation

enum PassEndpoint {
    /// Where hub/serve.py listens by default. It walks PORT..PORT+9 looking for
    /// a free one, so a Pass that lost 8811 to something else answers on 8812 --
    /// which is why it writes its real base URL to `.pass-url` on bind and
    /// removes the file on shutdown, and why that file is consulted before this.
    static let defaultURL = "http://127.0.0.1:8811"

    /// The hub checkout consulted for `.pass-url` when no hub dir is configured.
    static let defaultHubDir = "~/code/hub"

    static let urlFileName = ".pass-url"

    /// Hosts a discovered URL is allowed to name. The widget only ever talks to
    /// loopback, and a file on disk is the one thing that could point it
    /// somewhere else without anyone asking.
    static let allowedHosts: Set<String> = ["127.0.0.1", "localhost"]

    /// How the base URL was decided. Shown in the footer tooltip, because "the
    /// Pass is not answering" reads very differently depending on whether the
    /// widget guessed 8811 or read a live URL off disk.
    enum Source: String {
        case env                    // QT_PASS_URL
        case setting                // the settings window's Pass URL field
        case file                   // <hub>/.pass-url, written by serve.py on bind
        case standard = "default"   // port 8811
        case off                    // QT_PASS_URL="", the file ledgers only
    }

    struct Resolution {
        let url: URL?
        let source: Source
        /// The `.pass-url` path consulted, whether or not it existed.
        let file: URL?
        /// What the file held, when it held a usable URL.
        let fileURL: String?
        /// Why the file was ignored. nil when it was used or was simply absent.
        let fileProblem: String?
        /// Why the settings window's Pass URL was ignored. nil when it was used
        /// or was never set. Surfaced in the settings window next to the field,
        /// so a typed-in URL that is refused says so where it was typed.
        let settingProblem: String?
        /// Set only when a probed `.pass-url` target did not answer and the
        /// default port was used instead. nil the rest of the time, including
        /// when probing never ran at all.
        let fallback: String?

        init(url: URL?,
             source: Source,
             file: URL?,
             fileURL: String?,
             fileProblem: String?,
             settingProblem: String? = nil,
             fallback: String? = nil) {
            self.url = url
            self.source = source
            self.file = file
            self.fileURL = fileURL
            self.fileProblem = fileProblem
            self.settingProblem = settingProblem
            self.fallback = fallback
        }

        /// One line for the footer tooltip: where the widget is looking, and why.
        var describe: String {
            let shown = url?.absoluteString ?? ""
            switch source {
            case .env: return "\(shown) (QT_PASS_URL)"
            case .setting: return "\(shown) (set in Settings)"
            case .file: return "\(shown) (from \(file?.path ?? urlFileName))"
            case .standard: return "\(shown) (default port)"
            case .off: return "off: QT_PASS_URL is empty, reading the ledgers only"
            }
        }
    }

    /// Discovery order: QT_PASS_URL, then the settings window's Pass URL, then
    /// the hub checkout's `.pass-url`, then port 8811. An empty QT_PASS_URL
    /// disables the Pass feed entirely and pins the widget to the file ledgers,
    /// which is also how the tests keep the file-feed cases deterministic on a
    /// machine where the Pass is up.
    ///
    /// The environment stays ahead of the setting on purpose: QT_PASS_URL is
    /// how a test points the widget at an ephemeral port, and a stored
    /// preference that could shadow it would make the widget's behaviour depend
    /// on which of two places was written last.
    ///
    /// Only the configured hub's `.pass-url` is read -- `~/code/hub`'s when no
    /// hub is configured -- so the widget never discovers a Pass belonging to a
    /// checkout it was not pointed at.
    /// `probe` gates a live reachability check on a `.file`-sourced result --
    /// off by default, so most callers still make no request at all. See
    /// `reachable(_:timeout:)`.
    static func resolution(env: [String: String] = ProcessInfo.processInfo.environment,
                           hubDir: URL? = nil,
                           settings: Settings = .load(),
                           probe: Bool = false) -> Resolution {
        let file = urlFile(hubDir: hubDir)
        if let raw = env["QT_PASS_URL"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return Resolution(url: nil, source: .off, file: file,
                                  fileURL: nil, fileProblem: nil)
            }
            // An explicit override is taken as given: it is how a test points
            // the widget at an ephemeral port and how a second Pass gets used.
            // Never probed -- QT_PASS_URL is authoritative and does not fall
            // back even to a dead port.
            return Resolution(url: URL(string: trimmed), source: .env, file: file,
                              fileURL: nil, fileProblem: nil)
        }
        // A refused override is reported and then stepped over, the same way a
        // bad `.pass-url` is: a typo in a settings field should cost the user
        // an explanation, not the whole feed.
        var settingProblem: String?
        switch settings.validatedPassURL() {
        case .success(let url)?:
            return Resolution(url: url, source: .setting, file: file,
                              fileURL: nil, fileProblem: nil)
        case .failure(let problem)?:
            settingProblem = problem.message
        case nil:
            break
        }
        switch read(file: file) {
        case .success(let url)?:
            if probe, !reachable(url) {
                // The file said something, but nothing answers there -- the
                // Pass that wrote it is gone, and polling a dead port forever
                // is worse than falling back to the port a fresh serve.py
                // would have bound. The raw file contents are still kept in
                // `fileURL` so Settings can show what was found.
                return Resolution(url: URL(string: defaultURL), source: .standard, file: file,
                                  fileURL: url.absoluteString, fileProblem: nil,
                                  settingProblem: settingProblem,
                                  fallback: "8811 (pass-url target unreachable)")
            }
            return Resolution(url: url, source: .file, file: file,
                              fileURL: url.absoluteString, fileProblem: nil,
                              settingProblem: settingProblem)
        case .failure(let problem)?:
            // A malformed or non-loopback file is reported and then ignored, so
            // a half-written file cannot take the feed down with it.
            return Resolution(url: URL(string: defaultURL), source: .standard, file: file,
                              fileURL: nil, fileProblem: problem.message,
                              settingProblem: settingProblem)
        case nil:
            return Resolution(url: URL(string: defaultURL), source: .standard, file: file,
                              fileURL: nil, fileProblem: nil,
                              settingProblem: settingProblem)
        }
    }

    static func resolve(env: [String: String] = ProcessInfo.processInfo.environment,
                        hubDir: URL? = nil,
                        settings: Settings = .load(),
                        probe: Bool = false) -> URL? {
        resolution(env: env, hubDir: hubDir, settings: settings, probe: probe).url
    }

    /// Whether a discovered `.pass-url` target is worth trusting: reuses
    /// `status()` rather than a bespoke probe, since a target that answers
    /// with something that is not Pass JSON is exactly as useless as one that
    /// does not answer at all. Timeout is short -- this runs inline in
    /// discovery, so it costs a poll or a `--dump-endpoint` call at most one
    /// extra second, not the ~1.5s `PassClient.status()` allows a live feed.
    static func reachable(_ url: URL, timeout: TimeInterval = 1.0) -> Bool {
        switch PassClient(base: url, statusTimeout: timeout).status() {
        case .success: return true
        case .failure: return false
        }
    }

    static func urlFile(hubDir: URL?) -> URL {
        let hub = hubDir ?? URL(fileURLWithPath: (defaultHubDir as NSString).expandingTildeInPath)
        return hub.appendingPathComponent(urlFileName)
    }

    /// nil when the file is not there (the Pass is down, or never wrote one),
    /// which is the normal state and not a problem. A failure means the file
    /// exists and says something unusable.
    static func read(file: URL) -> Result<URL, Problem>? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure("\(urlFileName) is empty") }
        return validate(raw)
    }

    /// A discovered URL has to be http on loopback. Anything else is refused:
    /// this is a file the widget reads without being told to, so it does not
    /// get to choose the host.
    static func validate(_ raw: String) -> Result<URL, Problem> {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return .failure("\(urlFileName) is not a URL: \(String(raw.prefix(60)))")
        }
        guard scheme == "http" else {
            return .failure("\(urlFileName) is not http: \(String(raw.prefix(60)))")
        }
        guard let host = url.host, allowedHosts.contains(host.lowercased()) else {
            return .failure("\(urlFileName) is not loopback: \(String(raw.prefix(60)))")
        }
        return .success(url)
    }
}

struct PassClient {
    let base: URL
    /// Poll budget. One second is generous for loopback and short enough that
    /// a wedged server costs the widget one skipped refresh, not a stall.
    var statusTimeout: TimeInterval = 1.5
    /// Acting on a row is a deliberate click, so it gets longer: /save writes
    /// two files and appends a calibration row before it answers.
    var actionTimeout: TimeInterval = 8

    // MARK: - reads

    func status() -> Result<PassStatus, Problem> {
        var request = URLRequest(url: base.appendingPathComponent("status.json"))
        request.timeoutInterval = statusTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        switch send(request, timeout: statusTimeout) {
        case .failure(let failure):
            return .failure(failure.problem)
        case .success(let data):
            return PassStatus.decode(data, fallbackURL: base.absoluteString)
        }
    }

    // MARK: - writes

    /// POST /capture -> the new gate item's id.
    func capture(text: String) -> Result<String, Problem> {
        switch PassPayload.capture(text: text) {
        case .failure(let problem): return .failure(problem)
        case .success(let body):
            switch post(path: "capture", body: body) {
            case .failure(let failure): return .failure(failure.problem)
            case .success(let data):
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let id = obj?["id"] as? String, !id.isEmpty { return .success(id) }
                // A 200 with no id still means the item landed; the flash
                // message just cannot name it.
                return .success("")
            }
        }
    }

    /// POST /run -> the job slug The Pass started. A 409 is the expected
    /// refusal, not a fault: the item is already running, or all three job
    /// slots are busy.
    func run(id: String) -> Result<String, Problem> {
        switch PassPayload.run(id: id) {
        case .failure(let problem): return .failure(problem)
        case .success(let body):
            switch post(path: "run", body: body) {
            case .failure(let failure):
                return .failure(failure.code == 409
                                ? Self.refusal(failure.detail)
                                : failure.problem)
            case .success(let data):
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                return .success((obj?["job"] as? String) ?? "")
            }
        }
    }

    /// A 409 body in the widget's own words. serve.py sends "already running"
    /// or "max concurrent jobs running" as plain text; both mean "nothing was
    /// fired", which is the only part that has to fit in a menu header.
    static func refusal(_ body: String) -> Problem {
        let text = body.lowercased()
        if text.contains("already running") { return "Already running" }
        if text.contains("max concurrent") { return "Job slots full, not fired" }
        return body.isEmpty ? "the Pass would not start it"
                            : "Not fired: \(String(body.prefix(80)))"
    }

    /// POST /save with one verdict, carrying any unreconciled decisions along.
    func decide(record: TaskRecord,
                action: String,
                comment: String = "",
                pending: [[String: Any]] = []) -> Result<Void, Problem> {
        guard let itemID = record.itemID, !itemID.isEmpty else {
            return .failure("row has no Pass item id")
        }
        let built = PassPayload.decisions(id: itemID,
                                          title: record.title,
                                          state: record.state ?? "verify",
                                          action: action,
                                          comment: comment,
                                          pending: pending)
        switch built {
        case .failure(let problem): return .failure(problem)
        case .success(let body):
            return post(path: "save", body: body)
                .map { _ in () }
                .mapError { $0.problem }
        }
    }

    /// POST /decide with one decision, falling back to POST /save when the
    /// Pass has not shipped the route yet.
    ///
    /// `/decide` is additive and single-item: it merges one decision into
    /// `decisions.json` without touching the others, so unlike `/save` there is
    /// nothing to carry along. `/save` overwrites the file wholesale, which is
    /// why the old path has to drag every unreconciled decision through every
    /// one-row post. Once `/decide` answers, that carry-forward stops -- it is
    /// the whole reason the route exists.
    ///
    /// Feature-detected per call rather than cached: the Pass gets restarted
    /// under the widget often enough (that is why `.pass-url` is re-read every
    /// poll) that a "no /decide here" answer learned at launch would outlive
    /// the build that gave it. A 404 or a 405 both mean the route is not there;
    /// anything else is a real failure and is reported as one rather than
    /// quietly retried against `/save`, which would turn one refused decision
    /// into a wholesale overwrite.
    func decide(id: String,
                action: String,
                comment: String = "",
                fallback: () -> Result<Void, Problem>) -> Result<DecideOutcome, Problem> {
        switch PassPayload.decide(id: id, action: action, comment: comment) {
        case .failure(let problem): return .failure(problem)
        case .success(let body):
            switch post(path: "decide", body: body) {
            case .success:
                return .success(.decided)
            case .failure(let failure) where failure.code == 404 || failure.code == 405:
                return fallback().map { .fellBackToSave }
            case .failure(let failure):
                return .failure(failure.problem)
            }
        }
    }

    /// Which route actually took the decision. Worth reporting rather than
    /// swallowing: "it worked, the old way" and "it worked" are the same
    /// outcome for the user and different ones for anyone debugging why a
    /// decision landed on top of somebody else's.
    enum DecideOutcome: String {
        case decided            // POST /decide took it
        case fellBackToSave = "save"   // no /decide on this Pass; POST /save did
    }

    // MARK: - restart

    /// The exact request `restart()` sends, without sending it. `--dump-restart`
    /// prints this so a test can pin the Origin header without a live Pass.
    struct RestartRequest {
        let method: String
        let path: String
        let headers: [String: String]
    }

    static func restartRequest(base: URL) -> RestartRequest {
        RestartRequest(method: "POST", path: "restart",
                       headers: ["Origin": originHeader(for: base)])
    }

    /// `scheme://host:port` for `base`, with no path -- the one Origin header
    /// this file ever sends. /restart is gated the same way every other
    /// state-changing POST is, but a native app asking a process to restart
    /// itself is worth being deliberate about, and the value the gate accepts
    /// is the Pass's own origin, not the absence this file otherwise relies on.
    private static func originHeader(for base: URL) -> String {
        guard let host = base.host else { return base.absoluteString }
        let scheme = base.scheme ?? "http"
        if let port = base.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// What POST /restart answered. `supervised` is the whole reason to ask:
    /// a launchd-managed Pass (KeepAlive) comes back on its own within
    /// seconds; a hand-started one just stops.
    struct RestartOutcome {
        let supervised: Bool
    }

    /// Why POST /restart did not succeed. A dedicated type rather than a bare
    /// `Problem`, because 404 and 403 each drive a different follow-up in
    /// SettingsView (predates: leave the button enabled and say so; refused:
    /// report the Origin block) and a caller should not have to sniff a
    /// message string to tell them apart.
    enum RestartFailure: Error {
        case predates            // 404: this Pass has no /restart route yet
        case refused(String)     // 403: the Origin gate said no
        case other(Problem)

        var problem: Problem {
            switch self {
            case .predates:
                return "This Pass predates POST /restart; update the hub"
            case .refused(let detail):
                return "The Pass refused the restart (Origin blocked): \(detail)"
            case .other(let p):
                return p
            }
        }
    }

    /// POST /restart, no body. The process exits about half a second after
    /// answering, so a `.success` here describes what is about to happen, not
    /// what has already happened.
    func restart() -> Result<RestartOutcome, RestartFailure> {
        var request = URLRequest(url: base.appendingPathComponent("restart"))
        request.httpMethod = "POST"
        request.setValue(Self.originHeader(for: base), forHTTPHeaderField: "Origin")
        request.timeoutInterval = actionTimeout
        switch send(request, timeout: actionTimeout) {
        case .success(let data):
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let supervised = (obj?["supervised"] as? Bool) ?? false
            return .success(RestartOutcome(supervised: supervised))
        case .failure(let failure):
            switch failure.code {
            case 404:
                return .failure(.predates)
            case 403:
                return .failure(.refused(failure.detail.isEmpty ? "no reason given" : failure.detail))
            default:
                return .failure(.other(failure.problem))
            }
        }
    }

    // MARK: - transport

    /// A round trip that did not return 2xx. `code` is 0 for a transport
    /// failure, so a caller that cares about one specific status (POST /run's
    /// 409) can tell it apart from "the Pass is not there" without parsing a
    /// message.
    struct HTTPFailure: Error {
        let code: Int
        /// The response body, trimmed. Empty for a transport failure.
        let detail: String
        let problem: Problem
    }

    private func post(path: String, body: [String: Any]) -> Result<Data, HTTPFailure> {
        switch PassPayload.encode(body) {
        case .failure(let problem):
            return .failure(HTTPFailure(code: 0, detail: "", problem: problem))
        case .success(let data):
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            request.timeoutInterval = actionTimeout
            return send(request, timeout: actionTimeout)
        }
    }

    /// Blocking round trip. The completion handler runs on URLSession's own
    /// queue, so the semaphore is only ever waited on by the caller's
    /// background thread.
    private func send(_ request: URLRequest, timeout: TimeInterval) -> Result<Data, HTTPFailure> {
        var outcome: Result<Data, HTTPFailure> = .failure(
            HTTPFailure(code: 0, detail: "", problem: "no response"))
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                outcome = .failure(HTTPFailure(code: 0, detail: "",
                                               problem: "\(Self.describe(error))"))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = .failure(HTTPFailure(
                    code: code,
                    detail: trimmed,
                    problem: trimmed.isEmpty
                        ? "the Pass answered HTTP \(code)"
                        : "HTTP \(code): \(String(trimmed.prefix(120)))"))
                return
            }
            outcome = .success(data ?? Data())
        }
        task.resume()
        // A hard ceiling on top of URLSession's own timeout, so a stall inside
        // the session cannot outlive the poll interval by much.
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return .failure(HTTPFailure(code: 0, detail: "",
                                        problem: "the Pass did not answer in \(Int(timeout))s"))
        }
        return outcome
    }

    /// "Could not connect to the server." is the message John needs in a
    /// footer tooltip; the rest of NSError's description is noise.
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "the Pass is not answering"
            case NSURLErrorTimedOut:
                return "the Pass timed out"
            case NSURLErrorNetworkConnectionLost:
                return "the connection dropped"
            default: break
            }
        }
        return ns.localizedDescription
    }
}
