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

    /// Re-resolved on every poll, not just at launch: a Pass that restarted on
    /// another port rewrites `.pass-url`, and the widget should follow it
    /// without being relaunched. Two small file reads every five seconds, off
    /// the main thread with the poll itself.
    @Published private(set) var config: StoreConfig
    private let defaults: UserDefaults
    private var poll: Timer?
    private var ticker: Timer?

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

    init(config: StoreConfig = .resolve(),
         interval: TimeInterval? = nil,
         defaults: UserDefaults = Keys.store()) {
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
    }

    deinit {
        poll?.invalidate()
        ticker?.invalidate()
    }

    var hasLiveRows: Bool { model.records.contains { $0.status.isActive } }

    func refresh() {
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
            let fresh = Feed.load(config: config)
            DispatchQueue.main.async {
                self?.config = config
                self?.model = fresh
                self?.now = Date()
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
        new.save(defaults)
        config = StoreConfig.resolve(settings: new)
        if abs(new.pollInterval - oldInterval) > 0.01 { restartPoll(new.pollInterval) }
        refresh()
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

    // MARK: - acting

    func setLoginItem(_ on: Bool, report: @escaping (Result<Void, Problem>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = LoginItem.set(on)
            DispatchQueue.main.async {
                self?.loginItem = LoginItem.isEnabled()
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
                    if backUp { self?.refresh() }
                }
            case .success:
                DispatchQueue.main.async {
                    self?.busy.remove(Self.restartBusyKey)
                    report(.stopped)
                }
            case .failure(let failure):
                DispatchQueue.main.async {
                    self?.busy.remove(Self.restartBusyKey)
                    report(.problem(failure.problem.message))
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

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: controller.model.aggregate))
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
              --dump-keys <seq>       walk the keyboard highlight (e.g. down,down,up)
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
              QT_MENUBAR_FIRE_DIR     cwd for quick-fired tasks (default $HOME)
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
