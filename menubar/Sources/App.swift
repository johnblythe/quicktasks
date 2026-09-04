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

        /// Where the two remembered preferences live. Overridable with
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

    init(config: StoreConfig = .resolve(),
         interval: TimeInterval = 5,
         defaults: UserDefaults = Keys.store()) {
        self.config = config
        self.defaults = defaults
        let stored = defaults.array(forKey: Keys.collapsed) as? [String]
        self.collapsed = Set(stored ?? Section.allCases
            .filter { $0.collapsedByDefault }
            .map { $0.rawValue })
        self.fireToPass = defaults.bool(forKey: Keys.fireToPass)
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
        let limit = config.limit
        // Feed.load blocks on a loopback request, so it must never run on the
        // main thread: a wedged Pass would freeze the open menu. The config is
        // resolved out here too, so re-reading .pass-url costs the main thread
        // nothing either.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let config = StoreConfig.resolve(limit: limit)
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
              --dump-endpoint         print where the Pass was found, and how; no request
              --dump-capture <text>   print the POST /capture body and exit
              --dump-run <id>         print the POST /run body and exit
              --dump-decision <id> <accept|redo|reject> [comment]
                                      print the POST /save body and exit
              --dump-keys <seq>       walk the keyboard highlight (e.g. down,down,up)
              --post-run <id>         really POST /run for an item and print the outcome
              --snapshot <png>        render the dropdown to a PNG and exit
              --limit <n>             rows to include (default 12)
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
        if args.contains("--post-run") {
            exit(DumpModel.runPost(args: args))
        }
        if let i = args.firstIndex(of: "--snapshot") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("--snapshot needs a file path\n".utf8))
                exit(2)
            }
            exit(Snapshot.run(path: args[i + 1]))
        }
        QuicktaskStatusApp.main()
    }
}
