// Ask.swift -- the ask object as the hub serves it (contract v1, sections 1.2,
// 1.4 and 1.5 of the asks plan).
//
// An ask is one id, one address, one state machine. These are the Codable
// shapes for `GET /asks.json` rows and `GET /asks/<id>.json` threads, written
// to be read, not trusted:
//
//   - unknown fields are ignored (the contract says clients must);
//   - every field but `id` is optional, and a field of the wrong type decodes
//     as absent rather than failing the whole row;
//   - a row with no usable `id` is dropped, the rest of the list survives;
//   - an unknown `state` is kept verbatim and draws gray, so a hub that grows
//     a tenth state never blanks the menu.
//
// Timestamps stay as the ISO 8601 strings the hub sent (`createdDate` etc.
// parse them on demand), so a row re-encodes exactly as it arrived.

import Foundation

// MARK: - State

enum AskState: Equatable, Codable {
    case heard
    case wantsOk
    case working
    case question
    case blocked
    case failed
    case answer
    case done
    case yours
    /// A state this build has never heard of. The raw string is kept so the
    /// dump seams and tooltips can still say what the hub called it.
    case unknown(String)

    init(raw: String?) {
        switch raw {
        case "heard": self = .heard
        case "wants_ok": self = .wantsOk
        case "working": self = .working
        case "question": self = .question
        case "blocked": self = .blocked
        case "failed": self = .failed
        case "answer": self = .answer
        case "done": self = .done
        case "yours": self = .yours
        default: self = .unknown(raw ?? "")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(raw: try? c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    var raw: String {
        switch self {
        case .heard: return "heard"
        case .wantsOk: return "wants_ok"
        case .working: return "working"
        case .question: return "question"
        case .blocked: return "blocked"
        case .failed: return "failed"
        case .answer: return "answer"
        case .done: return "done"
        case .yours: return "yours"
        case .unknown(let s): return s
        }
    }

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// Unknown states draw gray: no colour claim about something this build
    /// cannot read.
    var isGray: Bool { !isKnown }

    /// The place a state lives in, per the table in section 1.2. Used only by
    /// the file fallback, which has no server to say; a hub row carries its
    /// own `place` and that wins.
    var place: String {
        switch self {
        case .heard, .working: return "working"
        case .wantsOk, .question, .blocked, .failed, .answer: return "needs"
        case .done: return "done"
        case .yours: return "yours"
        case .unknown: return ""
        }
    }
}

// MARK: - Tolerant decoding helpers

extension KeyedDecodingContainer {
    /// A value of the wanted type, or nil when the key is missing, null, or
    /// the wrong type. Never throws: one bad field must not cost the row.
    func opt<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let value = try? decodeIfPresent(type, forKey: key) else { return nil }
        return value
    }
}

/// Decodes to nil instead of throwing, so one malformed element of an array
/// does not discard its siblings.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Swallows any JSON value; used where only the *count* of an array of
/// unknown-shaped things matters (a run's `events`).
struct IgnoredJSON: Decodable {
    init(from decoder: Decoder) throws {}
}

/// A scalar that may arrive as a string or a number (`rev`).
private struct LooseString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s; return }
        if let i = try? c.decode(Int.self) { value = String(i); return }
        if let d = try? c.decode(Double.self) { value = String(d); return }
        value = nil
    }
}

// MARK: - Ask row

struct AskFacts: Codable, Equatable {
    var elapsedS: Double?
    var costUsd: Double?
    var model: String?
    var runDir: String?
    var runs: Int?
    var sessionId: String?
    var toolsUsed: [String]

    enum CodingKeys: String, CodingKey {
        case elapsedS = "elapsed_s", costUsd = "cost_usd", model
        case runDir = "run_dir", runs, sessionId = "session_id", toolsUsed = "tools_used"
    }

    init(elapsedS: Double? = nil, costUsd: Double? = nil, model: String? = nil,
         runDir: String? = nil, runs: Int? = nil, sessionId: String? = nil,
         toolsUsed: [String] = []) {
        self.elapsedS = elapsedS
        self.costUsd = costUsd
        self.model = model
        self.runDir = runDir
        self.runs = runs
        self.sessionId = sessionId
        self.toolsUsed = toolsUsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elapsedS = c.opt(Double.self, .elapsedS)
        costUsd = c.opt(Double.self, .costUsd)
        model = c.opt(String.self, .model)
        runDir = c.opt(String.self, .runDir)
        runs = c.opt(Int.self, .runs) ?? c.opt(Double.self, .runs).map { Int($0) }
        sessionId = c.opt(String.self, .sessionId)
        toolsUsed = c.opt([String].self, .toolsUsed) ?? []
    }
}

struct Ask: Codable, Equatable {
    var v: Int?
    let id: String
    var kind: String?
    var title: String
    var words: String
    var state: AskState
    var place: String
    var unseen: Bool
    var suggested: Bool
    var door: String?
    var ledger: String?
    var ref: String?
    var itemID: String?
    var createdAt: String?
    var updatedAt: String?
    var finishedAt: String?
    var nowLine: String?
    var reason: String?
    var question: String?
    var blockedTools: [String]
    var answerExcerpt: String?
    var facts: AskFacts
    var moves: [String]
    var canRun: Bool
    var remindAt: String?
    var filed: String?
    var url: String?

    enum CodingKeys: String, CodingKey {
        case v, id, kind, title, words, state, place, unseen, suggested, door, ledger, ref
        case itemID = "item_id"
        case createdAt = "created_at", updatedAt = "updated_at", finishedAt = "finished_at"
        case nowLine = "now_line", reason, question
        case blockedTools = "blocked_tools", answerExcerpt = "answer_excerpt"
        case facts, moves
        case canRun = "can_run", remindAt = "remind_at", filed, url
    }

    init(id: String,
         v: Int? = 1,
         kind: String? = nil,
         title: String = "",
         words: String = "",
         state: AskState = .heard,
         place: String? = nil,
         unseen: Bool = false,
         suggested: Bool = false,
         door: String? = nil,
         ledger: String? = nil,
         ref: String? = nil,
         itemID: String? = nil,
         createdAt: String? = nil,
         updatedAt: String? = nil,
         finishedAt: String? = nil,
         nowLine: String? = nil,
         reason: String? = nil,
         question: String? = nil,
         blockedTools: [String] = [],
         answerExcerpt: String? = nil,
         facts: AskFacts = AskFacts(),
         moves: [String] = [],
         canRun: Bool = false,
         remindAt: String? = nil,
         filed: String? = nil,
         url: String? = nil) {
        self.v = v
        self.id = id
        self.kind = kind
        self.title = title
        self.words = words
        self.state = state
        self.place = place ?? state.place
        self.unseen = unseen
        self.suggested = suggested
        self.door = door
        self.ledger = ledger
        self.ref = ref
        self.itemID = itemID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.nowLine = nowLine
        self.reason = reason
        self.question = question
        self.blockedTools = blockedTools
        self.answerExcerpt = answerExcerpt
        self.facts = facts
        self.moves = moves
        self.canRun = canRun
        self.remindAt = remindAt
        self.filed = filed
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The only hard requirement: a row nobody can address is not a row.
        guard let id = c.opt(String.self, .id), !id.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "ask has no id"))
        }
        self.id = id
        v = c.opt(Int.self, .v)
        kind = c.opt(String.self, .kind)
        words = c.opt(String.self, .words) ?? ""
        let rawTitle = c.opt(String.self, .title) ?? ""
        title = rawTitle.isEmpty ? Store.titleFrom(words.isEmpty ? id : words) : rawTitle
        state = AskState(raw: c.opt(String.self, .state))
        place = c.opt(String.self, .place) ?? state.place
        unseen = c.opt(Bool.self, .unseen) ?? false
        suggested = c.opt(Bool.self, .suggested) ?? false
        door = c.opt(String.self, .door)
        ledger = c.opt(String.self, .ledger)
        ref = c.opt(String.self, .ref)
        itemID = c.opt(String.self, .itemID)
        createdAt = c.opt(String.self, .createdAt)
        updatedAt = c.opt(String.self, .updatedAt)
        finishedAt = c.opt(String.self, .finishedAt)
        nowLine = c.opt(String.self, .nowLine)
        reason = c.opt(String.self, .reason)
        question = c.opt(String.self, .question)
        blockedTools = c.opt([String].self, .blockedTools) ?? []
        answerExcerpt = c.opt(String.self, .answerExcerpt)
        facts = c.opt(AskFacts.self, .facts) ?? AskFacts()
        moves = c.opt([String].self, .moves) ?? []
        canRun = c.opt(Bool.self, .canRun) ?? false
        remindAt = c.opt(String.self, .remindAt)
        filed = c.opt(String.self, .filed)
        url = c.opt(String.self, .url)
    }

    var createdDate: Date? { Store.parseDate(createdAt) }
    var updatedDate: Date? { Store.parseDate(updatedAt) }
    var finishedDate: Date? { Store.parseDate(finishedAt) }

    /// Needs-you asks the badge counts: place `needs`, except an answer the
    /// owner has already seen (section 1.2).
    var countsTowardBadge: Bool {
        guard place == "needs" else { return false }
        if state == .answer && !unseen { return false }
        return true
    }
}

// MARK: - List

struct AskCounts: Codable, Equatable {
    var badge: Int
    var needs: Int
    var working: Int
    var done: Int
    var yours: Int
    var unseen: Int

    enum CodingKeys: String, CodingKey { case badge, needs, working, done, yours, unseen }

    init(badge: Int = 0, needs: Int = 0, working: Int = 0,
         done: Int = 0, yours: Int = 0, unseen: Int = 0) {
        self.badge = badge
        self.needs = needs
        self.working = working
        self.done = done
        self.yours = yours
        self.unseen = unseen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        badge = c.opt(Int.self, .badge) ?? 0
        needs = c.opt(Int.self, .needs) ?? 0
        working = c.opt(Int.self, .working) ?? 0
        done = c.opt(Int.self, .done) ?? 0
        yours = c.opt(Int.self, .yours) ?? 0
        unseen = c.opt(Int.self, .unseen) ?? 0
    }

    /// The same arithmetic the hub does, for the file fallback.
    static func compute(_ asks: [Ask]) -> AskCounts {
        var counts = AskCounts()
        for ask in asks {
            switch ask.place {
            case "needs": counts.needs += 1
            case "working": counts.working += 1
            case "done": counts.done += 1
            case "yours": counts.yours += 1
            default: break
            }
            if ask.countsTowardBadge { counts.badge += 1 }
            if ask.unseen { counts.unseen += 1 }
        }
        return counts
    }
}

struct AskList: Equatable {
    var v: Int?
    var rev: String?
    var generatedAt: String?
    var counts: AskCounts
    var asks: [Ask]
}

/// What `GET /asks.json` can answer with.
enum AskListReply: Equatable {
    case list(AskList)
    /// `{unchanged: true, rev}`: the `since_rev` the client sent still holds.
    case unchanged(rev: String?)
}

private struct AskListWire: Decodable {
    let v: Int?
    let rev: String?
    let generatedAt: String?
    let counts: AskCounts?
    let asks: [Lossy<Ask>]?
    let unchanged: Bool?

    enum CodingKeys: String, CodingKey {
        case v, rev, counts, asks, unchanged
        case generatedAt = "generated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.opt(Int.self, .v)
        rev = c.opt(LooseString.self, .rev)?.value
        generatedAt = c.opt(String.self, .generatedAt)
        counts = c.opt(AskCounts.self, .counts)
        asks = c.opt([Lossy<Ask>].self, .asks)
        unchanged = c.opt(Bool.self, .unchanged)
    }
}

extension AskList {
    static func decode(_ data: Data) -> Result<AskListReply, Problem> {
        guard let wire = try? JSONDecoder().decode(AskListWire.self, from: data) else {
            return .failure("/asks.json did not return a JSON object")
        }
        if wire.unchanged == true {
            return .success(.unchanged(rev: wire.rev))
        }
        guard let rows = wire.asks else {
            return .failure("/asks.json has no asks list")
        }
        let asks = rows.compactMap { $0.value }
        return .success(.list(AskList(v: wire.v,
                                      rev: wire.rev,
                                      generatedAt: wire.generatedAt,
                                      counts: wire.counts ?? AskCounts.compute(asks),
                                      asks: asks)))
    }
}

// MARK: - Thread

struct AskTimelineEntry: Codable, Equatable {
    var at: String?
    var text: String

    enum CodingKeys: String, CodingKey { case at, text }

    init(at: String? = nil, text: String = "") {
        self.at = at
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = c.opt(String.self, .at)
        text = c.opt(String.self, .text) ?? ""
    }
}

struct AskFile: Codable, Equatable {
    var name: String
    var url: String?

    enum CodingKeys: String, CodingKey { case name, url }

    init(name: String, url: String? = nil) {
        self.name = name
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = c.opt(String.self, .name), !name.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.name,
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "file has no name"))
        }
        self.name = name
        url = c.opt(String.self, .url)
    }
}

struct AskRun: Codable, Equatable {
    var n: Int
    var kind: String?
    var prompt: String
    var status: String?
    var started: String?
    var finished: String?
    var resultText: String
    var resultTruncated: Bool
    var files: [AskFile]
    var costUsd: Double?
    var model: String?
    var sessionId: String?
    /// Only the count: the event shape is slice 4 and not read here.
    var eventCount: Int

    enum CodingKeys: String, CodingKey {
        case n, kind, prompt, status, started, finished
        case resultText = "result_text", resultTruncated = "result_truncated"
        case files, costUsd = "cost_usd", model, sessionId = "session_id", events
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = c.opt(Int.self, .n) ?? 0
        kind = c.opt(String.self, .kind)
        prompt = c.opt(String.self, .prompt) ?? ""
        status = c.opt(String.self, .status)
        started = c.opt(String.self, .started)
        finished = c.opt(String.self, .finished)
        resultText = c.opt(String.self, .resultText) ?? ""
        resultTruncated = c.opt(Bool.self, .resultTruncated) ?? false
        files = (c.opt([Lossy<AskFile>].self, .files) ?? []).compactMap { $0.value }
        costUsd = c.opt(Double.self, .costUsd)
        model = c.opt(String.self, .model)
        sessionId = c.opt(String.self, .sessionId)
        eventCount = c.opt([IgnoredJSON].self, .events)?.count ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(n, forKey: .n)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(started, forKey: .started)
        try c.encodeIfPresent(finished, forKey: .finished)
        try c.encode(resultText, forKey: .resultText)
        try c.encode(resultTruncated, forKey: .resultTruncated)
        try c.encode(files, forKey: .files)
        try c.encodeIfPresent(costUsd, forKey: .costUsd)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
    }
}

/// `GET /asks/<id>.json`: the row, plus the answer, the timeline, and the runs.
struct AskThread: Equatable {
    var ask: Ask
    var answerText: String
    var answerTruncated: Bool
    var timeline: [AskTimelineEntry]
    var runs: [AskRun]

    static func decode(_ data: Data) -> Result<AskThread, Problem> {
        guard let wire = try? JSONDecoder().decode(AskThreadWire.self, from: data) else {
            return .failure("the ask thread has no id")
        }
        return .success(AskThread(ask: wire.ask,
                                  answerText: wire.answerText,
                                  answerTruncated: wire.answerTruncated,
                                  timeline: wire.timeline,
                                  runs: wire.runs))
    }
}

private struct AskThreadWire: Decodable {
    let ask: Ask
    let answerText: String
    let answerTruncated: Bool
    let timeline: [AskTimelineEntry]
    let runs: [AskRun]

    enum CodingKeys: String, CodingKey {
        case answerText = "answer_text", answerTruncated = "answer_truncated"
        case timeline, runs
    }

    init(from decoder: Decoder) throws {
        // The thread is the row with extras, so the same payload decodes twice:
        // once as an Ask, once for the extras.
        ask = try Ask(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answerText = c.opt(String.self, .answerText) ?? ""
        answerTruncated = c.opt(Bool.self, .answerTruncated) ?? false
        timeline = (c.opt([Lossy<AskTimelineEntry>].self, .timeline) ?? []).compactMap { $0.value }
        runs = (c.opt([Lossy<AskRun>].self, .runs) ?? []).compactMap { $0.value }
    }
}
