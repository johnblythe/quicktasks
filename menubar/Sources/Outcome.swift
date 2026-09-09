// Outcome.swift -- the persistent record of "what just happened", replacing
// the old `flash` (a single string that vanished the moment the dropdown
// closed). Every producer -- quick-fire, a row action, a login-item toggle,
// a Restart Pass verdict, Settings Apply, a Pass health transition -- writes
// one of these instead of poking a `@State` string, so the outcome survives
// the dropdown tearing down (MenuBarExtra(.window) throws its view away on
// close) and a relaunch.
//
// Stored in UserDefaults rather than a file: it is small, it already lives
// next to Settings, and StatusController's Keys.store() is the one place
// that knows which suite a test wants (QT_MENUBAR_DEFAULTS_SUITE), so
// piggybacking on it keeps outcomes isolated from a real widget's the same
// way every other test-visible piece of state already is.

import Foundation

struct Outcome: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case ok
        case error
        case info
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String?
    let at: Date
    var seen: Bool

    init(kind: Kind,
        title: String,
        detail: String? = nil,
        at: Date = Date(),
        seen: Bool = false,
        id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.at = at
        self.seen = seen
    }
}

enum OutcomeStore {
    /// "~20" per the spec: round, and generous enough that a burst of row
    /// actions never pushes out something John hasn't looked at yet.
    static let limit = 20
    private static let key = "menubar.outcomes"

    /// Newest first. Silently returns an empty list on a decode failure --
    /// a corrupt or pre-v8 defaults value is not worth crashing the widget
    /// over, and there is nothing to recover from a partial outcome anyway.
    static func load(_ defaults: UserDefaults) -> [Outcome] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Outcome].self, from: data) else {
            return []
        }
        return Array(list.prefix(limit))
    }

    static func save(_ outcomes: [Outcome], _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Array(outcomes.prefix(limit))) else { return }
        defaults.set(data, forKey: key)
    }
}
