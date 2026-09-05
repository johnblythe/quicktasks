// Settings.swift -- the preferences the settings window writes and the feed
// reads, in one place.
//
// Everything here is stored in UserDefaults and every one of them is an
// *override*: absent means "work it out the way v3 did", so a fresh install
// behaves exactly as before and clearing a field puts the old behaviour back.
// That is why each string setting reads as nil when empty rather than as the
// empty string -- an empty Pass URL field has to mean "discover it", not "the
// Pass feed is off", which is what an empty QT_PASS_URL means.
//
// The environment still wins. QT_PASS_URL, QT_HUB, and QT_DATA are how the
// tests point the widget at fixtures and how a second Pass gets used, so a
// setting that could shadow them would make the widget's behaviour depend on
// which of two places was written last. Order, highest first:
//
//   Pass URL   QT_PASS_URL -> this setting -> <hub>/.pass-url -> port 8811
//   hub dir    QT_HUB      -> this setting -> config.json's hub_dir -> off
//
// Section visibility, the row limit, and the poll interval have no environment
// form and are read straight off here, clamped to ranges the widget can
// actually draw: a zero row limit or a half-second poll would be a setting
// that breaks the thing it configures.

import Foundation

struct Settings {
    /// Pass base URL the user typed, nil when the field is empty. Validated the
    /// same way a discovered `.pass-url` is -- http on loopback -- because a
    /// typo here should be refused with a reason rather than silently pointing
    /// the widget at a host it will never reach.
    var passURLOverride: String?
    /// Hub checkout the user chose, nil when the field is empty.
    var hubDirOverride: String?
    /// Seconds between polls. Clamped: too fast burns battery re-reading
    /// ledgers, too slow and the widget stops being a status widget.
    var pollInterval: TimeInterval
    /// Sections the dropdown is allowed to draw. A section switched off here
    /// leaves the list entirely -- unlike collapsing it, which keeps its
    /// header and its count.
    var visibleSections: Set<String>
    /// Rows to keep after ordering. The aggregate still counts everything, so
    /// this trims what is drawn and never what is tallied.
    var rowLimit: Int

    static let pollRange: ClosedRange<TimeInterval> = 2...120
    static let limitRange: ClosedRange<Int> = 5...200
    static let defaultPollInterval: TimeInterval = 5
    static let defaultRowLimit = 12

    /// Every section on by default. Suggestions included: when the Pass does
    /// not send any the section hides itself regardless, so defaulting it off
    /// would mean the feature ships invisible.
    static var allSectionKeys: Set<String> {
        Set(Section.allCases.map { $0.rawValue })
    }

    static let `default` = Settings(passURLOverride: nil,
                                    hubDirOverride: nil,
                                    pollInterval: defaultPollInterval,
                                    visibleSections: allSectionKeys,
                                    rowLimit: defaultRowLimit)

    enum Keys {
        static let passURL = "menubar.passURLOverride"
        static let hubDir = "menubar.hubDirOverride"
        static let pollInterval = "menubar.pollInterval"
        static let visibleSections = "menubar.visibleSections"
        static let rowLimit = "menubar.rowLimit"
    }

    /// Reads the stored settings, falling back to the defaults key by key. A
    /// value out of range is clamped rather than refused: a preference file
    /// edited by hand should not be able to leave the widget unable to draw.
    static func load(_ defaults: UserDefaults = StatusController.Keys.store()) -> Settings {
        Settings(
            passURLOverride: text(defaults, Keys.passURL),
            hubDirOverride: text(defaults, Keys.hubDir),
            pollInterval: defaults.object(forKey: Keys.pollInterval) == nil
                ? defaultPollInterval
                : clamp(defaults.double(forKey: Keys.pollInterval), to: pollRange),
            visibleSections: (defaults.array(forKey: Keys.visibleSections) as? [String])
                .map { Set($0).intersection(allSectionKeys) } ?? allSectionKeys,
            rowLimit: defaults.object(forKey: Keys.rowLimit) == nil
                ? defaultRowLimit
                : clamp(defaults.integer(forKey: Keys.rowLimit), to: limitRange))
    }

    func save(_ defaults: UserDefaults = StatusController.Keys.store()) {
        // An empty field removes the key rather than storing "", so "no
        // override" and "overridden to nothing" cannot end up looking alike.
        write(defaults, Keys.passURL, passURLOverride)
        write(defaults, Keys.hubDir, hubDirOverride)
        defaults.set(Settings.clamp(pollInterval, to: Settings.pollRange), forKey: Keys.pollInterval)
        defaults.set(Array(visibleSections).sorted(), forKey: Keys.visibleSections)
        defaults.set(Settings.clamp(rowLimit, to: Settings.limitRange), forKey: Keys.rowLimit)
    }

    func shows(_ section: Section) -> Bool { visibleSections.contains(section.rawValue) }

    /// The Pass URL override, checked the same way a discovered `.pass-url` is.
    /// Returns nil when there is no override, and a failure when there is one
    /// the widget refuses to use.
    func validatedPassURL() -> Result<URL, Problem>? {
        guard let raw = passURLOverride else { return nil }
        return PassEndpoint.validate(raw)
    }

    private static func text(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func write(_ defaults: UserDefaults, _ key: String, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    static func clamp(_ value: TimeInterval, to range: ClosedRange<TimeInterval>) -> TimeInterval {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
