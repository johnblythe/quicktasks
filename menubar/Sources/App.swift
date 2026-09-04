// App.swift -- entry point, polling controller, and the MenuBarExtra scene.

import SwiftUI
import AppKit

/// Holds the current model and re-reads the ledgers on a timer.
final class StatusController: ObservableObject {
    @Published private(set) var model: MenuModel

    private let config: StoreConfig
    private var timer: Timer?

    init(config: StoreConfig = .resolve(), interval: TimeInterval = 5) {
        self.config = config
        self.model = Store.load(config: config)
        // Reading ~40 small JSON files every few seconds is cheap, and the
        // tolerance lets the system coalesce the wakeups rather than holding
        // a precise 5s cadence the widget does not need.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let config = self.config
        // Disk reads move off the main thread so a slow volume cannot stall
        // the menu while it is open.
        DispatchQueue.global(qos: .utility).async {
            let fresh = Store.load(config: config)
            DispatchQueue.main.async { self.model = fresh }
        }
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

              (no arguments)      run the menu-bar app
              --dump-model        print the computed menu model as JSON and exit
              --snapshot <png>    render the dropdown to a PNG and exit
              --limit <n>         rows to include (default 12)
              --help              this text

            Environment:
              QT_DATA               quicktasks data dir (default ~/.quicktasks)
              QT_HUB                hub checkout; overrides config.json hub_dir
              QT_BIN                path to the qt script
              QT_MENUBAR_FIRE_DIR   cwd for quick-fired tasks (default $HOME)
            """)
            return
        }
        if args.contains("--dump-model") {
            exit(DumpModel.run(args: args))
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
