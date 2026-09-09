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
import Carbon.HIToolbox

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
    /// The directory chip's last choice, nil when the field is empty (falls
    /// through to $HOME). QT_MENUBAR_FIRE_DIR still overrides this when set --
    /// same precedence every other override in this file follows.
    var fireDirOverride: String?
    /// The global summon shortcut. nil is a real, distinct state from "never
    /// configured": it means Clear was pressed, and the hotkey should not be
    /// registered at all. A fresh install (never configured) uses
    /// `KeyCombo.defaultCombo` instead of nil, which is why this is loaded and
    /// saved through its own three-state logic rather than `text(_:_:)`.
    var hotkeyCombo: KeyCombo?
    /// Whether a background outcome (a job finishing, a Pass health
    /// transition, a Restart Pass verdict, a quick-fire failure) posts a
    /// real macOS notification. Only takes effect while neither the dropdown
    /// nor the summon panel is visible -- see StatusController.notifyIfHidden.
    /// Defaults on: "never an unsure moment" means background news should
    /// reach John even when he is not looking at the menu bar.
    var notifyWhenHidden: Bool

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
                                    rowLimit: defaultRowLimit,
                                    fireDirOverride: nil,
                                    hotkeyCombo: KeyCombo.defaultCombo,
                                    notifyWhenHidden: true)

    enum Keys {
        static let passURL = "menubar.passURLOverride"
        static let hubDir = "menubar.hubDirOverride"
        static let pollInterval = "menubar.pollInterval"
        static let visibleSections = "menubar.visibleSections"
        static let rowLimit = "menubar.rowLimit"
        static let fireDir = "menubar.fireDirOverride"
        static let hotkeyKeyCode = "menubar.hotkeyKeyCode"
        static let hotkeyModifiers = "menubar.hotkeyModifiers"
        /// Distinct from the keyCode/modifiers keys being absent: absent means
        /// "never configured, use the default"; this true means "configured
        /// to nothing, on purpose" -- the difference Clear exists to make.
        static let hotkeyCleared = "menubar.hotkeyCleared"
        static let notifyWhenHidden = "menubar.notifyWhenHidden"
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
                : clamp(defaults.integer(forKey: Keys.rowLimit), to: limitRange),
            fireDirOverride: text(defaults, Keys.fireDir),
            hotkeyCombo: loadHotkey(defaults),
            notifyWhenHidden: defaults.object(forKey: Keys.notifyWhenHidden) == nil
                ? true
                : defaults.bool(forKey: Keys.notifyWhenHidden))
    }

    /// The hotkey's three states: cleared (nil, on purpose), configured (a
    /// stored combo), or never touched (the default). Checked in that order
    /// because `hotkeyCleared` has to win even though a stale keyCode/modifiers
    /// pair from before a Clear could otherwise still be sitting in the store.
    private static func loadHotkey(_ defaults: UserDefaults) -> KeyCombo? {
        if defaults.bool(forKey: Keys.hotkeyCleared) { return nil }
        guard defaults.object(forKey: Keys.hotkeyKeyCode) != nil else {
            return KeyCombo.defaultCombo
        }
        return KeyCombo(keyCode: UInt32(defaults.integer(forKey: Keys.hotkeyKeyCode)),
                        modifiers: UInt32(defaults.integer(forKey: Keys.hotkeyModifiers)))
    }

    func save(_ defaults: UserDefaults = StatusController.Keys.store()) {
        // An empty field removes the key rather than storing "", so "no
        // override" and "overridden to nothing" cannot end up looking alike.
        write(defaults, Keys.passURL, passURLOverride)
        write(defaults, Keys.hubDir, hubDirOverride)
        defaults.set(Settings.clamp(pollInterval, to: Settings.pollRange), forKey: Keys.pollInterval)
        defaults.set(Array(visibleSections).sorted(), forKey: Keys.visibleSections)
        defaults.set(Settings.clamp(rowLimit, to: Settings.limitRange), forKey: Keys.rowLimit)
        write(defaults, Keys.fireDir, fireDirOverride)
        if let combo = hotkeyCombo {
            defaults.set(false, forKey: Keys.hotkeyCleared)
            defaults.set(Int(combo.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(Int(combo.modifiers), forKey: Keys.hotkeyModifiers)
        } else {
            defaults.set(true, forKey: Keys.hotkeyCleared)
            defaults.removeObject(forKey: Keys.hotkeyKeyCode)
            defaults.removeObject(forKey: Keys.hotkeyModifiers)
        }
        defaults.set(notifyWhenHidden, forKey: Keys.notifyWhenHidden)
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
