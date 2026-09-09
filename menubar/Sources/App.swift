// App.swift -- entry point, polling controller, and the MenuBarExtra scene.

import SwiftUI
import AppKit

/// Holds the current model, re-reads the feed on a timer, and owns the two
/// preferences the dropdown remembers between openings.
final class StatusController: ObservableObject {
    @Published private(set) var model: MenuModel
    /// Ticks once a second while anything is in flight, so an open menu counts
    /// elapsed time up instead of freezing between five-second polls.
    @Published private(set) var now: Date = Date()
    /// Section keys the user has collapsed. Remembered in UserDefaults.
    @Published private(set) var collapsed: Set<String>
    /// Whether the suggestions section is folded shut. Open by default: it
    /// leads the list precisely because those rows are waiting to be decided.
    @Published private(set) var suggestionsCollapsed: Bool
    /// Which half of the quick-fire toggle is armed: to The Pass, or run now.
    @Published var fireToPass: Bool {
        didSet { defaults.set(fireToPass, forKey: Keys.fireToPass) }
    }
    @Published private(set) var loginItem: Bool
    /// Set while a row action is in flight, so the row can show it is busy and
    /// a second click cannot post the same verdict twice.
    @Published private(set) var busy: Set<String> = []
    /// Bumped after every `showHotkeyPanel()` call, once the panel has been
    /// asked to become key -- see that function. MenuView's summon panel
    /// observes this to re-run its focus dance on every re-show; a plain
    /// `.onAppear` only fires once for a view this class caches and reuses
    /// (see `hotkeyPanel`), which is why the panel used to focus on the
    /// first \u{2325}Q and go silent on every one after. Also observed by
    /// the real dropdown's own MenuView, harmlessly: writing that view's
    /// @FocusState while its window is not key has no visible effect.
    @Published private(set) var summonTick: Int = 0
    /// The persistent record of "what just happened" -- quick-fire, a row
    /// action, the login-item toggle, a Restart Pass verdict, Settings
    /// Apply, and a Pass health transition all write here instead of
    /// MenuView's old `flash` @State, so a banner survives the dropdown
    /// tearing down (MenuBarExtra(.window) discards its view on close) and
    /// a relaunch (reloaded from `defaults` in init). Newest first, capped
    /// at OutcomeStore.limit by `post`. See Outcome.swift.
    @Published private(set) var outcomes: [Outcome]

    /// Re-resolved on every poll, not just at launch: a Pass that restarted on
    /// another port rewrites `.pass-url`, and the widget should follow it
    /// without being relaunched. Two small file reads every five seconds, off
    /// the main thread with the poll itself.
    @Published private(set) var config: StoreConfig
    private let defaults: UserDefaults
    private var poll: Timer?
    private var ticker: Timer?
    /// Whether the real MenuBarExtra dropdown is currently on screen.
    /// Tracked separately from the summon panel's own `hotkeyPanel.isVisible`
    /// because a notification must stay silent while *either* window is up,
    /// and there is no AppKit-level query for a MenuBarExtra(.window)'s
    /// window the way there is for `hotkeyPanel` -- only MenuView's own
    /// `.onAppear`/`.onDisappear` can say when the dropdown itself is one of
    /// them. See `dropdownDidAppear`/`dropdownDidDisappear`/`anyWindowVisible`.
    private(set) var dropdownVisible = false
    /// Where a background outcome goes when neither window is on screen.
    /// `SystemNotifier` for the real, running widget; `RecordingNotifier`
    /// for every headless/CLI use, keyed off the same `activatesGlobalHotkey`
    /// flag that already distinguishes "a real widget" from "a seam" below.
    let notifier: Notifier
    /// Re-armed by `scheduleMarkOutcomesSeen`, not queued: there is only ever
    /// one banner on screen, so a second call before the first fires just
    /// restarts the same wait rather than stacking two.
    private var markSeenTimer: Timer?
    /// Set for the duration of one `refresh()`'s background hop, so a poll
    /// timer tick that fires while the previous poll is still waiting on
    /// the network (a slow Pass, up to PassClient.statusTimeout) skips that
    /// tick outright rather than starting a second, overlapping request --
    /// LD-201 v9: requests must never stack, whatever the Pass's mood.
    private var pollInFlight = false
    /// Debounces raw health-icon transitions into episodes -- see
    /// HealthEpisodeTracker in Transitions.swift -- so a Pass that answers
    /// slow under load, rather than actually going down, never earns a
    /// notification. Lives for the controller's whole life, same as `poll`.
    private let healthTracker = HealthEpisodeTracker()
    /// Cross-poll job-transition dedup -- see JobTransitionTracker in
    /// Transitions.swift -- so a job that is briefly absent from one poll's
    /// records (a blip) and then reappears finished is still caught,
    /// instead of reading as "no prior data, nothing to report".
    private let jobTracker = JobTransitionTracker()

    enum Keys {
        static let collapsed = "menubar.collapsedSections"
        static let fireToPass = "menubar.fireToPass"
        /// The suggestions section's own collapse flag. Kept apart from
        /// `collapsed`, which is keyed by `Section` raw values: suggestions are
        /// not rows of the task list, and folding them in would have meant a
        /// `Section` case that never holds a record.
        static let suggestionsCollapsed = "menubar.suggestionsCollapsed"

        /// Where the remembered preferences live. Overridable with
        /// QT_MENUBAR_DEFAULTS_SUITE so a snapshot or a test can seed them
        /// without writing into the real app's preferences.
        static func store(env: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
            guard let suite = env["QT_MENUBAR_DEFAULTS_SUITE"], !suite.isEmpty,
                  let defaults = UserDefaults(suiteName: suite) else {
                return .standard
            }
            return defaults
        }
    }

    /// The settings window, created on first use and reused after. Held here
    /// rather than declared as a SwiftUI `Window` scene because this is an
    /// LSUIElement app: it has no Dock icon and no menu bar of its own, so it
    /// has to activate itself before a window it opens will take a keystroke.
    private var settingsWindow: NSWindow?

    /// The summon shortcut, registered in `init` and re-registered by `apply`
    /// whenever the combo changes. nil for every `StatusController` built by
    /// `--snapshot`, `--snapshot-settings`, and `--dump-layout` -- those pass
    /// `activatesGlobalHotkey: false` because a measuring/rendering process
    /// has no business claiming a global shortcut out from under a real,
    /// already-running widget.
    private var globalHotkey: GlobalHotkey?

    /// The window the global hotkey shows. See `showHotkeyPanel` for why this
    /// is a second window rather than a simulated click on the MenuBarExtra's
    /// own dropdown.
    private var hotkeyPanel: NSPanel?

    init(config: StoreConfig = .resolve(),
         interval: TimeInterval? = nil,
         defaults: UserDefaults = Keys.store(),
         activatesGlobalHotkey: Bool = true,
         notifier: Notifier? = nil) {
        self.config = config
        self.defaults = defaults
        // The settings window's poll interval, unless a caller pinned one --
        // which --snapshot and --dump-layout both do, to keep a render from
        // churning while it is being measured.
        let interval = interval ?? config.settings.pollInterval
        let stored = defaults.array(forKey: Keys.collapsed) as? [String]
        self.collapsed = Set(stored ?? Section.allCases
            .filter { $0.collapsedByDefault }
            .map { $0.rawValue })
        self.fireToPass = defaults.bool(forKey: Keys.fireToPass)
        self.suggestionsCollapsed = defaults.bool(forKey: Keys.suggestionsCollapsed)
        self.loginItem = LoginItem.isEnabled()
        self.outcomes = OutcomeStore.load(defaults)
        // A real, running widget gets the real notification center; every
        // headless use (a CLI seam, a snapshot, a test) gets a recorder --
        // keyed off the same flag that already distinguishes the two, so a
        // caller never has to remember to pass a notifier just to stay safe.
        self.notifier = notifier ?? (activatesGlobalHotkey ? SystemNotifier() : RecordingNotifier())
        // The first read is the *file* model, synchronously: it is a handful
        // of small JSON files, so the menu-bar dot is right the moment the
        // icon appears. Asking The Pass first would put a network timeout
        // between launchd and the icon, which for a login item means a menu
        // bar that comes up blank for a second and a half.
        self.model = Store.load(config: config)

        // Reading ~40 small JSON files and one loopback GET every few seconds
        // is cheap, and the tolerance lets the system coalesce the wakeups
        // rather than holding a precise 5s cadence the widget does not need.
        let p = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        p.tolerance = interval / 2
        RunLoop.main.add(p, forMode: .common)
        poll = p

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.hasLiveRows else { return }
            self.now = Date()
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        // Now go ask The Pass, off the main thread. The window between the
        // file model and the first Pass answer is one refresh long.
        refresh()

        if activatesGlobalHotkey {
            let hotkey = GlobalHotkey { [weak self] in self?.toggleHotkeyPanel() }
            hotkey.register(config.settings.hotkeyCombo)
            globalHotkey = hotkey
        }
        // Clicking a notification shows the dropdown "if achievable" -- for
        // this app that is the summon panel, since a MenuBarExtra's own
        // dropdown cannot be opened from code at all (see `showHotkeyPanel`'s
        // own doc comment); the panel hosts the identical MenuView, so this
        // is the closest thing to "shows the dropdown" that actually exists.
        if let system = self.notifier as? SystemNotifier {
            system.onClicked = { [weak self] in self?.showHotkeyPanel() }
        }
        // Asked once here if the toggle is already on at launch; `apply`
        // asks again only on an off-to-on flip, so "requested on first
        // enable" holds whichever of the two ways the toggle got there.
        if config.settings.notifyWhenHidden {
            self.notifier.requestAuthorizationIfNeeded()
        }
    }

    deinit {
        poll?.invalidate()
        ticker?.invalidate()
        globalHotkey?.unregister()
        markSeenTimer?.invalidate()
    }

    var hasLiveRows: Bool { model.records.contains { $0.status.isActive } }

    func refresh() {
        // LD-201 v9: never let requests stack. A poll timer tick that lands
        // while the previous poll is still waiting on the network (a slow
        // Pass, up to PassClient.statusTimeout) is skipped outright rather
        // than starting a second, overlapping request -- the next tick five
        // seconds later gets its own chance instead.
        guard !pollInFlight else { return }
        pollInFlight = true
        // Snapshotted on the main thread before the hop to background, so the
        // hold-timer logic sees exactly what the last poll left on screen,
        // with no race against this same property being read or written back
        // on the main thread while the background block is in flight.
        let previous = model
        // Feed.load blocks on a loopback request, so it must never run on the
        // main thread: a wedged Pass would freeze the open menu. The config is
        // resolved out here too, so re-reading .pass-url and the settings costs
        // the main thread nothing either.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Probed here, off the main thread: this is the path that lets
            // the running widget self-heal from a stale `.pass-url` left
            // behind by a Pass that has since died, rather than polling a
            // dead port until the app is relaunched.
            let config = StoreConfig.resolve(probeDiscovery: true)
            let fresh = Feed.load(config: config, previous: previous)
            DispatchQueue.main.async {
                self?.pollInFlight = false
                self?.config = config
                self?.model = fresh
                self?.now = Date()
                // Health is diffed as an episode, not a raw transition: see
                // HealthEpisodeTracker for the 45-second-or-files-only gate
                // and the ten-minute down/back rate limit. Job transitions
                // are diffed against a persistent last-known-status map, not
                // just the exact `previous` snapshotted above, so a job that
                // is briefly absent from one poll's records and reappears
                // finished still fires -- see JobTransitionTracker.
                if let result = self?.healthTracker.process(previous: previous, fresh: fresh,
                                                            now: fresh.refreshedAt) {
                    self?.post(kind: result.kind, title: result.title, detail: result.detail,
                              notify: result.notify, seen: result.seen)
                }
                for job in self?.jobTracker.detect(fresh: fresh.records) ?? [] {
                    // Notification-only -- see JobTransition's own doc
                    // comment -- so straight to notifyIfHidden, never post.
                    self?.notifyIfHidden(title: job.outcomeTitle, detail: nil)
                }
            }
        }
    }

    // MARK: - sections

    func isCollapsed(_ section: Section) -> Bool { collapsed.contains(section.rawValue) }

    func toggle(_ section: Section) {
        if collapsed.contains(section.rawValue) {
            collapsed.remove(section.rawValue)
        } else {
            collapsed.insert(section.rawValue)
        }
        defaults.set(Array(collapsed).sorted(), forKey: Keys.collapsed)
    }

    func toggleSuggestions() {
        suggestionsCollapsed.toggle()
        defaults.set(suggestionsCollapsed, forKey: Keys.suggestionsCollapsed)
    }

    // MARK: - settings

    /// Current settings, straight off the resolved config so the window and
    /// the feed can never be reading two different generations of them.
    var settings: Settings { config.settings }

    /// Writes the settings and re-reads the feed with them, so a changed row
    /// limit or Pass URL takes effect on the spot rather than at the next poll.
    /// The poll timer is rebuilt only when its interval actually moved: tearing
    /// it down on every keystroke in the settings window would mean a widget
    /// that never gets round to polling while it is being configured.
    func apply(_ new: Settings) {
        let oldInterval = config.settings.pollInterval
        let oldCombo = config.settings.hotkeyCombo
        let oldNotify = config.settings.notifyWhenHidden
        new.save(defaults)
        config = StoreConfig.resolve(settings: new)
        if abs(new.pollInterval - oldInterval) > 0.01 { restartPoll(new.pollInterval) }
        if new.hotkeyCombo != oldCombo { globalHotkey?.register(new.hotkeyCombo) }
        // Only on the off -> on edge, so re-applying unchanged settings never
        // re-asks: the "requested exactly once" guarantee depends on that.
        if new.notifyWhenHidden && !oldNotify { notifier.requestAuthorizationIfNeeded() }
        refresh()
        post(kind: .ok, title: "Settings applied")
    }

    private func restartPoll(_ interval: TimeInterval) {
        poll?.invalidate()
        let p = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        p.tolerance = interval / 2
        RunLoop.main.add(p, forMode: .common)
        poll = p
    }

    /// Opens the settings window, or brings it forward when it is already up.
    /// Activates the app first: an accessory app's window comes up behind
    /// everything and will not take a keystroke until the app is frontmost.
    func showSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView(controller: self))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: SettingsView.windowWidth,
                                                  height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Quicktask Status Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - outcomes

    /// Every producer's single writing point -- quick-fire, a row action,
    /// the login-item toggle, a Restart Pass verdict, Settings Apply, and a
    /// Pass health episode all call this instead of poking MenuView's
    /// old `flash` @State, so what happened survives the dropdown tearing
    /// down and a relaunch. `notify: true` additionally offers it to
    /// `notifier`, gated on neither window being visible and the Settings
    /// toggle being on -- see `notifyIfHidden`. `seen: true` (LD-201 v9,
    /// HealthEpisodeTracker's blip outcome) inserts it already read: a
    /// Pass blip that resolved in under 45 seconds is history the moment it
    /// is recorded, never an unread banner. A job transition calls
    /// `notifyIfHidden` directly instead, since a job finishing does not
    /// belong in the persistent queue -- see JobTransition's doc comment.
    func post(kind: Outcome.Kind, title: String, detail: String? = nil,
             notify: Bool = false, seen: Bool = false) {
        outcomes.insert(Outcome(kind: kind, title: title, detail: detail, seen: seen), at: 0)
        outcomes = Array(outcomes.prefix(OutcomeStore.limit))
        OutcomeStore.save(outcomes, defaults)
        if notify { notifyIfHidden(title: title, detail: detail) }
    }

    /// The one place `notifier.post` is called from, so "only while hidden,
    /// only with the toggle on" cannot be reimplemented two different ways
    /// by two call sites.
    func notifyIfHidden(title: String, detail: String?) {
        guard settings.notifyWhenHidden, !anyWindowVisible else { return }
        notifier.post(title: title, body: detail)
    }

    /// "Neither the dropdown nor the summon panel is visible" -- the gate
    /// every notification goes through.
    var anyWindowVisible: Bool { dropdownVisible || (hotkeyPanel?.isVisible ?? false) }

    /// Called from MenuView's `.onAppear` for the real dropdown only -- the
    /// summon panel's own visibility is already tracked through
    /// `hotkeyPanel`, so this only needs to cover the one window AppKit has
    /// no query for.
    func dropdownDidAppear() { dropdownVisible = true }

    func dropdownDidDisappear() { dropdownVisible = false }

    /// Marks every currently unseen outcome seen after `after` seconds --
    /// "banner marks seen after ~2s visible" -- rather than the instant the
    /// dropdown opens, so a banner that opens and closes again in a
    /// heartbeat still had a moment to actually be read. Re-armed on every
    /// call rather than queued, since there is only ever one banner on
    /// screen to mark.
    func scheduleMarkOutcomesSeen(after seconds: TimeInterval = 2) {
        markSeenTimer?.invalidate()
        guard outcomes.contains(where: { !$0.seen }) else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.markOutcomesSeen()
        }
        RunLoop.main.add(timer, forMode: .common)
        markSeenTimer = timer
    }

    private func markOutcomesSeen() {
        guard outcomes.contains(where: { !$0.seen }) else { return }
        outcomes = outcomes.map { outcome in
            var seen = outcome
            seen.seen = true
            return seen
        }
        OutcomeStore.save(outcomes, defaults)
    }

    /// The banner's dismiss control.
    func dismissOutcome(_ id: String) {
        outcomes.removeAll { $0.id == id }
        OutcomeStore.save(outcomes, defaults)
    }

    // MARK: - global summon

    /// Shows the same quick-fire view the MenuBarExtra dropdown shows, in a
    /// standalone floating panel.
    ///
    /// A MenuBarExtra's own dropdown is not something this can drive by
    /// itself: NSStatusBar's public API exposes the status item's button, not
    /// the window the dropdown opens, and NSApp.windows only lists that window
    /// *after* something has already opened it -- there is no supported way
    /// to call `performClick` on a button and land the click's effect before
    /// the button exists to click. Chasing that with private API would trade
    /// a real feature for one a point release of macOS could silently break.
    /// So the summon hotkey hosts `MenuView` a second time in a panel built
    /// for exactly this: `.utilityWindow` so it floats above normal windows,
    /// `isFloatingPanel` and `becomesKeyOnlyIfNeeded = false` so it can take
    /// keyboard focus without a click, `hidesOnDeactivate = false` so
    /// switching apps does not yank it away mid-type. The real dropdown is
    /// untouched: clicking the status-bar dot still opens it exactly as
    /// before, and this panel is a second, independent window layered above
    /// whatever else is on screen -- not a replacement for it.
    ///
    /// Known limits: this is a second window, not the real dropdown, so it
    /// does not sit visually anchored under the status item the way the real
    /// dropdown does (see `positionNearStatusItem`); and because it has its
    /// own title bar (hidden here, but still AppKit chrome underneath), a
    /// screen reader or window switcher sees it as a distinct window titled
    /// "Quicktask Quick Fire" rather than as the menu-bar extra's dropdown.
    func showHotkeyPanel() {
        if let panel = hotkeyPanel {
            NSApp.activate(ignoringOtherApps: true)
            positionNearStatusItem(panel)
            panel.makeKeyAndOrderFront(nil)
            // Bumped here too, not just below: this branch is what every
            // summon after the first actually takes, since the panel below
            // is only ever built once.
            summonTick += 1
            return
        }
        let view = MenuView(controller: self, onEscapeExhausted: { [weak self] in
            self?.hideHotkeyPanel()
        })
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: MenuView.panelWidth, height: 420),
                            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered,
                            defer: false)
        panel.title = "Quicktask Quick Fire"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = hosting
        hotkeyPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        positionNearStatusItem(panel)
        panel.makeKeyAndOrderFront(nil)
        summonTick += 1
    }

    func hideHotkeyPanel() {
        hotkeyPanel?.orderOut(nil)
    }

    /// `hotkeyPanel`, read-only, for `--dump-summon` to check `isVisible`/
    /// `isKeyWindow`/`firstResponder` after driving a summon -- the same
    /// reason `passBase` and `settings` are exposed as plain reads
    /// elsewhere on this class.
    var summonPanel: NSPanel? { hotkeyPanel }

    /// The hotkey's own toggle: press once to summon, press again while it is
    /// already showing to dismiss it. Checked with `isVisible` rather than a
    /// separately tracked bool, so a panel the user already closed (its own
    /// close button, or Escape) is never mistaken for one still open.
    func toggleHotkeyPanel() {
        if let panel = hotkeyPanel, panel.isVisible {
            hideHotkeyPanel()
        } else {
            showHotkeyPanel()
        }
    }

    /// Best-effort placement at the top-right of the active screen, under the
    /// menu bar -- the same corner a Spotlight-adjacent utility would use.
    /// There is no public API for "under the status item" once the panel is
    /// summoned by a hotkey rather than opened by clicking that item: an
    /// NSStatusItem's frame is only meaningful relative to its own private
    /// window, so this does not promise to sit under any particular icon.
    private func positionNearStatusItem(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 4)
        panel.setFrameOrigin(origin)
    }

    // MARK: - acting

    func setLoginItem(_ on: Bool, report: @escaping (Result<Void, Problem>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = LoginItem.set(on)
            DispatchQueue.main.async {
                // Re-reads the real state regardless of outcome, which is
                // what reverts the toggle on failure: nothing was written,
                // so isEnabled() still reports whatever it said before.
                self?.loginItem = LoginItem.isEnabled()
                switch outcome {
                case .success:
                    self?.post(kind: .info, title: "Start at login \(on ? "on" : "off")")
                case .failure(let problem):
                    self?.post(kind: .error,
                              title: "Couldn't update the login item: \(problem.message)")
                }
                report(outcome)
            }
        }
    }

    /// Runs a blocking action off the main thread and reports back on it,
    /// marking `key` busy for the duration so a second click cannot post the
    /// same verdict twice.
    func perform(key: String,
                 _ work: @escaping () -> Result<String, Problem>,
                 then report: @escaping (Result<String, Problem>) -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = work()
            DispatchQueue.main.async {
                self?.busy.remove(key)
                report(outcome)
                if case .success = outcome { self?.refresh() }
            }
        }
    }

    /// Base URL for actions: the model's pass_url when The Pass answered, so
    /// the widget follows the server's own idea of where it lives.
    var passBase: URL {
        URL(string: model.passURL) ?? config.passURL ?? Actions.passURL
    }

    // MARK: - restart

    /// The `busy` key while a restart is in flight, exposed so SettingsView
    /// can disable the button and show a spinner for the same span
    /// `restartPass` treats as busy.
    static let restartBusyKey = "restart-pass"

    /// A Restart Pass click's outcome, as told to the settings view. For a
    /// launchd-supervised Pass, `then` fires twice: `.restarting` the moment
    /// the POST answers, then `.backUp` or `.stillDown` once the bounded poll
    /// settles. Every other outcome fires it exactly once.
    enum RestartMessage {
        case restarting
        case backUp
        case stillDown
        case stopped
        /// 404, 403, or any other failure -- already worded for display by
        /// `PassClient.RestartFailure.problem`.
        case problem(String)
    }

    /// POSTs /restart and, when the Pass is launchd-supervised, polls
    /// /status.json for up to ~20s so the view can say "Pass is back" rather
    /// than leaving "Restarting..." up forever. Runs off the main thread;
    /// `report` is always called back on the main thread.
    func restartPass(then report: @escaping (RestartMessage) -> Void) {
        guard !busy.contains(Self.restartBusyKey) else { return }
        busy.insert(Self.restartBusyKey)
        let base = passBase
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            switch PassClient(base: base).restart() {
            case .success(let outcome) where outcome.supervised:
                DispatchQueue.main.async { report(.restarting) }
                let backUp = Self.pollUntilBackUp(base: base)
                DispatchQueue.main.async {
                    self?.busy.remove(Self.restartBusyKey)
                    report(backUp ? .backUp : .stillDown)
                    // The final verdict, in addition to the inline message
                    // above: an outcome so it survives Settings closing
                    // mid-restart.
                    if backUp {
                        self?.refresh()
                        self?.post(kind: .ok, title: "Pass restarted", notify: true)
                    } else {
                        self?.post(kind: .error, title: "Pass didn't come back",
                                  detail: "Restarted, but it hasn't answered yet.", notify: true)
                    }
                }
            case .success:
                DispatchQueue.main.async {
                    self?.busy.remove(Self.restartBusyKey)
                    report(.stopped)
                    self?.post(kind: .ok, title: "Pass stopped",
                              detail: "Not supervised, so it will stay down.", notify: true)
                }
            case .failure(let failure):
                DispatchQueue.main.async {
                    self?.busy.remove(Self.restartBusyKey)
                    report(.problem(failure.problem.message))
                    self?.post(kind: .error, title: "Restart failed",
                              detail: failure.problem.message, notify: true)
                }
            }
        }
    }

    /// Polls /status.json once a second for up to `budget` seconds, starting
    /// after a one-second grace period for the old process to actually exit
    /// -- POST /restart's 200 lands about half a second before that happens,
    /// per the hub's own contract. Returns whether it answered in time.
    private static func pollUntilBackUp(base: URL,
                                        budget: TimeInterval = 20,
                                        interval: TimeInterval = 1) -> Bool {
        Thread.sleep(forTimeInterval: 1)
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if case .success = PassClient(base: base).status() { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }
}

struct QuicktaskStatusApp: App {
    @StateObject private var controller = StatusController()

    /// Mirrors IconHealth.of's own inputs exactly, the same rule the dot,
    /// the tooltip below, and the footer's freshness line all read off of.
    private var iconHealth: IconHealth {
        IconHealth.of(source: controller.model.source,
                      passReachable: controller.model.passReachable,
                      passStaleSince: controller.model.passStaleSince)
    }

    /// "Tooltip must name the state" -- distinct wording per health, so
    /// hovering the dot answers the question the dot's own shape only hints
    /// at.
    private var iconTooltip: String {
        switch iconHealth {
        case .normal:
            return controller.model.headlineText
        case .heldStale:
            return "Holding since \(sinceStale) \u{00B7} Pass isn't answering"
        case .filesOnly:
            return "Pass down since \(sinceStale) \u{00B7} file feeds"
        }
    }

    private var sinceStale: String {
        guard let stale = controller.model.passStaleSince else { return "recently" }
        return MenuView.clock.string(from: stale)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: controller.model.aggregate, health: iconHealth))
                .help(iconTooltip)
        }
        // Window style rather than a classic NSMenu: a real text field for
        // quick-fire is the requirement an NSMenu cannot satisfy.
        .menuBarExtraStyle(.window)
    }
}

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print("""
            QuicktaskStatus -- menu-bar status for qt and The Pass.

              (no arguments)          run the menu-bar app
              --dump-model            print the computed menu model as JSON and exit
              --dump-endpoint         print where the Pass was found, and how; probes a
                                      discovered .pass-url and falls back if it is dead
              --dump-capture <text>   print the POST /capture body and exit
              --dump-run <id>         print the POST /run body and exit
              --dump-decision <id> <accept|redo|reject> [comment]
                                      print the POST /save body and exit
              --dump-keys <seq>       walk the keyboard highlight (e.g. down,down,up), or the
                                      quick-fire mode toggle (tab, cmd-1, cmd-2, cmd-return);
                                      --mode run|pass seeds the toggle, --draft seeds the text
              --dump-fire <text> [--mode run|pass]
                                      print the resolved argv (Run now) or /capture body (To
                                      Pass) a quick-fire send would use, and exit
              --dump-fire-outcome <text> [--mode run|pass] [--panel]
                                      really fire it, and print the state and panel-hide
                                      decision the field lands on (--panel: as the summon
                                      panel; omitted: as the real dropdown)
              --dump-hotkey           print the registered summon shortcut and whether
                                      RegisterEventHotKey took it
              --dump-summon <seq>     drive summon/escape (comma-separated) on a headless
                                      panel and print {panel_visible, is_key,
                                      first_responder_is_field, focused_field, mode}
              --dump-outcomes <seq> [--seen-after <s>]
                                      drive outcome/notification producers (comma-separated:
                                      show, hide, panel-show, panel-hide, mark-seen, login-on,
                                      login-off, restart, apply, apply-notify-on,
                                      apply-notify-off, refresh, post-ok, post-error,
                                      post-info, notify-ok, notify-error, dismiss-newest) on a
                                      headless controller and print the resulting outcome
                                      queue and injected notifier state
              --dump-notifications <seq> [--poll-interval-seconds <s>]
                                      [--hold-window-seconds <s>]
                                      replay a comma-separated ok/fail poll sequence through
                                      a standalone health-episode/job tracker (not a live
                                      controller); print each step's outcome plus the
                                      episode_started/notified_down/last_pair_at bookkeeping,
                                      and the cumulative outcomes/notified queues
              --dump-recent-dirs      print the directory chip's recent-directory list
              --dump-decide <id> <confirm|deny|go|snooze> [comment]
                                      print the POST /decide body and exit
              --dump-search <query>   print what the quick search matches, and why
              --dump-settings         print the stored settings and what they resolved to
              --post-run <id>         really POST /run for an item and print the outcome
              --post-decide <id> <action>
                                      really decide a suggestion; says which route took it
              --dump-restart          print the POST /restart request (method, path, Origin)
              --post-restart          really POST /restart and print the outcome
              --snapshot <png>        render the dropdown to a PNG and exit
              --snapshot-settings <png>
                                      render the settings window to a PNG and exit
              --dump-layout           print panel-layout measurements as JSON and exit
              --search <query>        with --dump-model, filter the rows first
              --limit <n>             rows to include (default: the settings row limit)
              --help                  this text

            Environment:
              QT_DATA                 quicktasks data dir (default ~/.quicktasks)
              QT_HUB                  hub checkout; overrides config.json hub_dir
              QT_PASS_URL             The Pass's base URL; overrides <hub>/.pass-url,
                                      which overrides \(PassEndpoint.defaultURL).
                                      Empty pins the widget to the file ledgers
              QT_BIN                  path to the qt script
              QT_MENUBAR_FIRE_DIR     cwd for a Run-now fire with no typed --in/@ prefix;
                                      overrides the directory chip's own last choice
                                      (default $HOME)
              QT_MENUBAR_AGENT_PLIST  LaunchAgent plist (default ~/Library/LaunchAgents)
            """)
            return
        }
        if args.contains("--dump-model") {
            exit(DumpModel.run(args: args))
        }
        if args.contains("--dump-endpoint") {
            exit(DumpModel.runEndpoint())
        }
        if args.contains("--dump-capture") || args.contains("--dump-decision")
            || args.contains("--dump-run") {
            exit(DumpModel.runPayload(args: args))
        }
        if args.contains("--dump-keys") {
            exit(DumpModel.runKeys(args: args))
        }
        if args.contains("--dump-fire") {
            exit(DumpModel.runFire(args: args))
        }
        if args.contains("--dump-fire-outcome") {
            exit(DumpModel.runFireOutcome(args: args))
        }
        if args.contains("--dump-hotkey") {
            exit(DumpModel.runHotkey())
        }
        if args.contains("--dump-summon") {
            exit(DumpModel.runSummon(args: args))
        }
        if args.contains("--dump-outcomes") {
            exit(DumpModel.runOutcomes(args: args))
        }
        if args.contains("--dump-notifications") {
            exit(DumpModel.runNotifications(args: args))
        }
        if args.contains("--dump-recent-dirs") {
            exit(DumpModel.runRecentDirs())
        }
        if args.contains("--dump-decide") {
            exit(DumpModel.runDecidePayload(args: args))
        }
        if args.contains("--dump-search") {
            exit(DumpModel.runSearch(args: args))
        }
        if args.contains("--dump-settings") {
            exit(DumpModel.runSettings())
        }
        if args.contains("--post-run") {
            exit(DumpModel.runPost(args: args))
        }
        if args.contains("--post-decide") {
            exit(DumpModel.runPostDecide(args: args))
        }
        if args.contains("--dump-restart") {
            exit(DumpModel.runDumpRestart())
        }
        if args.contains("--post-restart") {
            exit(DumpModel.runPostRestart())
        }
        // Checked before --snapshot, which is a prefix of it.
        if let i = args.firstIndex(of: "--snapshot-settings") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(
                    Data("--snapshot-settings needs a file path\n".utf8))
                exit(2)
            }
            exit(Snapshot.runSettings(path: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--snapshot") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("--snapshot needs a file path\n".utf8))
                exit(2)
            }
            exit(Snapshot.run(path: args[i + 1]))
        }
        if args.contains("--dump-layout") { exit(LayoutProbe.run()) }
        QuicktaskStatusApp.main()
    }
}
