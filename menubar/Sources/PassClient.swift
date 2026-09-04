// PassClient.swift -- the only file in the widget that touches the network,
// and it only ever talks to loopback.
//
// Every call is synchronous and must be made off the main thread: the menu is
// a MenuBarExtra panel, and a semaphore wait on the main queue would freeze it
// mid-click. The timeouts are short for the same reason -- a poll that hangs
// for 30 seconds is indistinguishable from a Pass that is down, so it may as
// well give up in one and fall back to the files.
//
// No Origin header is set. serve.py's _origin_blocked() lets a request with no
// Origin through (browsers always send one cross-origin; CLIs never do), which
// is exactly the hole a native app is supposed to come in by.

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

        /// One line for the footer tooltip: where the widget is looking, and why.
        var describe: String {
            let shown = url?.absoluteString ?? ""
            switch source {
            case .env: return "\(shown) (QT_PASS_URL)"
            case .file: return "\(shown) (from \(file?.path ?? urlFileName))"
            case .standard: return "\(shown) (default port)"
            case .off: return "off: QT_PASS_URL is empty, reading the ledgers only"
            }
        }
    }

    /// Discovery order: QT_PASS_URL, then the hub checkout's `.pass-url`, then
    /// port 8811. An empty QT_PASS_URL disables the Pass feed entirely and pins
    /// the widget to the file ledgers, which is also how the tests keep the
    /// file-feed cases deterministic on a machine where the Pass is up.
    ///
    /// Only the configured hub's `.pass-url` is read -- `~/code/hub`'s when no
    /// hub is configured -- so the widget never discovers a Pass belonging to a
    /// checkout it was not pointed at.
    static func resolution(env: [String: String] = ProcessInfo.processInfo.environment,
                           hubDir: URL? = nil) -> Resolution {
        let file = urlFile(hubDir: hubDir)
        if let raw = env["QT_PASS_URL"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return Resolution(url: nil, source: .off, file: file,
                                  fileURL: nil, fileProblem: nil)
            }
            // An explicit override is taken as given: it is how a test points
            // the widget at an ephemeral port and how a second Pass gets used.
            return Resolution(url: URL(string: trimmed), source: .env, file: file,
                              fileURL: nil, fileProblem: nil)
        }
        switch read(file: file) {
        case .success(let url)?:
            return Resolution(url: url, source: .file, file: file,
                              fileURL: url.absoluteString, fileProblem: nil)
        case .failure(let problem)?:
            // A malformed or non-loopback file is reported and then ignored, so
            // a half-written file cannot take the feed down with it.
            return Resolution(url: URL(string: defaultURL), source: .standard, file: file,
                              fileURL: nil, fileProblem: problem.message)
        case nil:
            return Resolution(url: URL(string: defaultURL), source: .standard, file: file,
                              fileURL: nil, fileProblem: nil)
        }
    }

    static func resolve(env: [String: String] = ProcessInfo.processInfo.environment,
                        hubDir: URL? = nil) -> URL? {
        resolution(env: env, hubDir: hubDir).url
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
