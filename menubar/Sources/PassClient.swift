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
    /// Where hub/serve.py listens. It walks PORT..PORT+9 looking for a free
    /// one, so a Pass that lost 8811 to something else answers on 8812 and the
    /// widget will report it unreachable until QT_PASS_URL says otherwise.
    static let defaultURL = "http://127.0.0.1:8811"

    /// nil disables the Pass feed entirely and pins the widget to the file
    /// ledgers. Set QT_PASS_URL="" for that, which is also how the tests keep
    /// the file-feed cases deterministic on a machine where the Pass is up.
    static func resolve(env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let raw = env["QT_PASS_URL"] else { return URL(string: defaultURL) }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return URL(string: trimmed)
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
        case .failure(let problem):
            return .failure(problem)
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
            return post(path: "capture", body: body).flatMap { data in
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if let id = obj?["id"] as? String, !id.isEmpty { return .success(id) }
                // A 200 with no id still means the item landed; the flash
                // message just cannot name it.
                return .success("")
            }
        }
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
        case .success(let body): return post(path: "save", body: body).map { _ in () }
        }
    }

    // MARK: - transport

    private func post(path: String, body: [String: Any]) -> Result<Data, Problem> {
        switch PassPayload.encode(body) {
        case .failure(let problem): return .failure(problem)
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
    private func send(_ request: URLRequest, timeout: TimeInterval) -> Result<Data, Problem> {
        var outcome: Result<Data, Problem> = .failure("no response")
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                outcome = .failure("\(Self.describe(error))")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = .failure(trimmed.isEmpty
                    ? "the Pass answered HTTP \(code)"
                    : "HTTP \(code): \(String(trimmed.prefix(120)))")
                return
            }
            outcome = .success(data ?? Data())
        }
        task.resume()
        // A hard ceiling on top of URLSession's own timeout, so a stall inside
        // the session cannot outlive the poll interval by much.
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return .failure("the Pass did not answer in \(Int(timeout))s")
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
