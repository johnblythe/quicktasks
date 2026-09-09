// Freshness.swift -- the footer's always-on freshness line (LD-201 v8).
//
// Distinct from the dot: MenuBarIcon's IconHealth says *which* state the
// widget is in, this says how long ago that state was confirmed, so
// "synced 12 s ago" can tick every second on its own timer while the dot
// itself only redraws when the health actually changes.

import Foundation

enum FreshnessLine {
    static func text(for model: MenuModel, now: Date = Date()) -> String {
        let health = IconHealth.of(source: model.source,
                                   passReachable: model.passReachable,
                                   passStaleSince: model.passStaleSince)
        switch health {
        case .normal:
            let seconds = max(0, Int(now.timeIntervalSince(model.refreshedAt).rounded()))
            return "synced \(seconds) s ago"
        case .heldStale:
            return "holding since \(since(model))"
        case .filesOnly:
            return "file feeds \u{00B7} Pass down since \(since(model))"
        }
    }

    private static func since(_ model: MenuModel) -> String {
        guard let stale = model.passStaleSince else { return "recently" }
        return MenuView.clock.string(from: stale)
    }
}
