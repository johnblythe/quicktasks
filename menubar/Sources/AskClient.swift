// AskClient.swift -- the loopback client for the ask API (section 1.6).
//
// Same rules as PassClient: loopback only, synchronous, and every call must be
// made off the main thread (a semaphore wait on the main queue would freeze the
// menu mid-click). It has its own transport rather than borrowing PassClient's
// because it needs what PassClient's throws away: the status code and the JSON
// body of a refusal. A 409 carries `{ok:false, message, state, moves}` and the
// menu has to show that message, not "HTTP 409".
//
//   list(...)    GET  /asks.json?place=&state=&limit=&since_rev=
//   thread(...)  GET  /asks/<id>.json         cached per id + updated_at
//   post(...)    POST /asks/<id>/<move>       -> MoveResult
//
// No Origin header is sent, for the reason PassClient.swift gives.

import Foundation

/// Why a read did not produce asks. 404 is its own case because it is the
/// signal that this hub predates the ask API and `/status.json` is the feed.
enum AskFailure: Error, Equatable {
    case notFound
    case problem(Problem)

    static func == (a: AskFailure, b: AskFailure) -> Bool {
        switch (a, b) {
        case (.notFound, .notFound): return true
        case (.problem(let x), .problem(let y)): return x.message == y.message
        default: return false
        }
    }

    var problem: Problem {
        switch self {
        case .notFound: return "this Pass has no ask API"
        case .problem(let p): return p
        }
    }
}

/// An undo handle from a move that can be taken back.
struct AskUndo: Equatable {
    let token: String
    let expiresAt: String?
}

/// The answer to `POST /asks/<id>/<move>`. Carries every outcome rather than
/// only success, because 409, 501 and 503 are expected answers the menu has to
/// say in words (the move is not allowed now, not built yet, ledger busy).
struct MoveResult: Equatable {
    /// HTTP status. 0 for a transport failure (nothing answered).
    let status: Int
    let ok: Bool
    /// The hub's own message, or a transport description when status is 0.
    let message: String
    /// The ask after the move, when the hub sent it.
    let ask: Ask?
    let undo: AskUndo?
    /// 409 only: the state the ask is actually in, and the moves it has now.
    let state: String?
    let moves: [String]?

    enum Kind: String {
        case ok
        case unknownAsk = "unknown_ask"    // 404
        case notAllowed = "not_allowed"    // 409
        case notBuilt = "not_built"        // 501
        case busy                          // 503
        case failed                        // anything else, including no answer
    }

    var kind: Kind {
        if ok { return .ok }
        switch status {
        case 404: return .unknownAsk
        case 409: return .notAllowed
        case 501: return .notBuilt
        case 503: return .busy
        default: return .failed
        }
    }

    static func transportFailure(_ message: String) -> MoveResult {
        MoveResult(status: 0, ok: false, message: message, ask: nil,
                   undo: nil, state: nil, moves: nil)
    }

    /// Reads a response body. Tolerant for the same reason `Ask` is: a hub that
    /// answers a 2xx with an odd shape still did the move.
    static func parse(status: Int, data: Data) -> MoveResult {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let success = (200..<300).contains(status)
        let declaredOK = obj?["ok"] as? Bool
        let ok = success && declaredOK != false
        var message = (obj?["message"] as? String) ?? ""
        if message.isEmpty && !ok {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            message = text.isEmpty ? "the Pass answered HTTP \(status)" : String(text.prefix(160))
        }
        var ask: Ask?
        if let raw = obj?["ask"], JSONSerialization.isValidJSONObject(raw),
           let bytes = try? JSONSerialization.data(withJSONObject: raw) {
            ask = try? JSONDecoder().decode(Ask.self, from: bytes)
        }
        var undo: AskUndo?
        if let u = obj?["undo"] as? [String: Any], let token = u["token"] as? String, !token.isEmpty {
            undo = AskUndo(token: token, expiresAt: u["expires_at"] as? String)
        }
        return MoveResult(status: status, ok: ok, message: message, ask: ask, undo: undo,
                          state: obj?["state"] as? String,
                          moves: obj?["moves"] as? [String])
    }
}

/// Threads fetched so far, keyed by ask id and valid for one `updated_at`.
/// A list poll that sees the same `updated_at` reuses the thread; a newer one
/// refetches. Lock-guarded because the menu reads it from the main thread and
/// fetches fill it from a background one.
final class AskThreadCache {
    static let shared = AskThreadCache()

    private let lock = NSLock()
    private var entries: [String: (stamp: String, thread: AskThread)] = [:]

    func get(id: String, stamp: String) -> AskThread? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = entries[id], hit.stamp == stamp else { return nil }
        return hit.thread
    }

    func put(id: String, stamp: String, thread: AskThread) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = (stamp, thread)
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = nil
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}

struct AskClient {
    let base: URL
    var readTimeout: TimeInterval = 8
    /// A move is a deliberate click; same budget PassClient gives actions.
    var actionTimeout: TimeInterval = 8

    /// Ask ids are `^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$` (section 1.1). Checked
    /// before any request so a bad id never becomes a path.
    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 160 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return id.first.map { $0.isLetter || $0.isNumber } ?? false
    }

    // MARK: - reads

    /// `GET /asks.json`. `place` and `state` are optional filters; the hub's
    /// default excludes `done`. `sinceRev` makes an unchanged hub answer with a
    /// two-field body instead of the whole list.
    func list(place: String? = nil,
              state: String? = nil,
              limit: Int = 200,
              sinceRev: String? = nil) -> Result<AskListReply, AskFailure> {
        var parts = URLComponents(url: base.appendingPathComponent("asks.json"),
                                  resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if let place, !place.isEmpty { items.append(URLQueryItem(name: "place", value: place)) }
        if let state, !state.isEmpty { items.append(URLQueryItem(name: "state", value: state)) }
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        if let sinceRev, !sinceRev.isEmpty {
            items.append(URLQueryItem(name: "since_rev", value: sinceRev))
        }
        parts?.queryItems = items
        guard let url = parts?.url else { return .failure(.problem("bad asks URL")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = readTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        switch Self.send(request, timeout: readTimeout) {
        case .failure(let failure):
            return .failure(failure.code == 404 ? .notFound : .problem(failure.problem))
        case .success(let reply):
            switch AskList.decode(reply.data) {
            case .success(let parsed): return .success(parsed)
            case .failure(let problem): return .failure(.problem(problem))
            }
        }
    }

    /// `GET /asks/<id>.json`, through the cache. `updatedAt` is the row's
    /// `updated_at` as the list reported it; a hit on the same stamp makes no
    /// request. Blocking: call off the main thread, or use `threadAsync`.
    func thread(id: String,
                updatedAt: String? = nil,
                cache: AskThreadCache = .shared) -> Result<AskThread, AskFailure> {
        guard Self.isValidID(id) else { return .failure(.problem("not an ask id: \(id.prefix(40))")) }
        if let updatedAt, let hit = cache.get(id: id, stamp: updatedAt) {
            return .success(hit)
        }
        var request = URLRequest(url: base.appendingPathComponent("asks")
            .appendingPathComponent("\(id).json"))
        request.timeoutInterval = readTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        switch Self.send(request, timeout: readTimeout) {
        case .failure(let failure):
            return .failure(failure.code == 404 ? .notFound : .problem(failure.problem))
        case .success(let reply):
            switch AskThread.decode(reply.data) {
            case .failure(let problem):
                return .failure(.problem(problem))
            case .success(let thread):
                // Key on what the *thread* says when the caller had no stamp,
                // so a later call carrying that stamp still hits.
                if let stamp = updatedAt ?? thread.ask.updatedAt {
                    cache.put(id: id, stamp: stamp, thread: thread)
                }
                return .success(thread)
            }
        }
    }

    /// Fetches a thread on a background queue and calls back on the main one,
    /// so a view can ask for it without ever blocking a click.
    func threadAsync(id: String,
                     updatedAt: String? = nil,
                     cache: AskThreadCache = .shared,
                     completion: @escaping (Result<AskThread, AskFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.thread(id: id, updatedAt: updatedAt, cache: cache)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - writes

    /// `POST /asks/<id>/<move>` with a JSON body (`{}` when there is none).
    /// Never throws and never returns a bare error: every outcome, a 409
    /// included, comes back as a `MoveResult` the caller can show.
    func post(id: String, move: String, body: [String: Any] = [:]) -> MoveResult {
        guard Self.isValidID(id) else { return .transportFailure("not an ask id") }
        guard !move.isEmpty,
              move.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" })
        else { return .transportFailure("not a move name") }
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .transportFailure("the move body is not JSON")
        }
        var request = URLRequest(url: base.appendingPathComponent("asks")
            .appendingPathComponent(id).appendingPathComponent(move))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = actionTimeout
        switch Self.send(request, timeout: actionTimeout) {
        case .success(let reply):
            return MoveResult.parse(status: reply.code, data: reply.data)
        case .failure(let failure):
            if failure.code == 0 { return .transportFailure(failure.problem.message) }
            return MoveResult.parse(status: failure.code, data: failure.body)
        }
    }

    // MARK: - transport

    struct Reply {
        let code: Int
        let data: Data
    }

    struct HTTPFailure: Error {
        /// 0 for a transport failure.
        let code: Int
        let body: Data
        let problem: Problem
    }

    /// Blocking round trip. Same shape as PassClient's: the completion runs on
    /// URLSession's queue, only the caller's thread waits.
    static func send(_ request: URLRequest, timeout: TimeInterval) -> Result<Reply, HTTPFailure> {
        var outcome: Result<Reply, HTTPFailure> = .failure(
            HTTPFailure(code: 0, body: Data(), problem: "no response"))
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                outcome = .failure(HTTPFailure(code: 0, body: Data(),
                                               problem: Problem(describe(error))))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data ?? Data()
            guard (200..<300).contains(code) else {
                let text = (String(data: body, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                outcome = .failure(HTTPFailure(
                    code: code, body: body,
                    problem: text.isEmpty
                        ? "the Pass answered HTTP \(code)"
                        : "HTTP \(code): \(String(text.prefix(120)))"))
                return
            }
            outcome = .success(Reply(code: code, data: body))
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return .failure(HTTPFailure(code: 0, body: Data(),
                                        problem: "the Pass did not answer in \(Int(timeout))s"))
        }
        return outcome
    }

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
