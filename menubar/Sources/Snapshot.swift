// Snapshot.swift -- `--snapshot <file.png>` renders the dropdown to a PNG.
//
// Draws the real MenuView against the real ledgers, so it is a faithful
// picture of what the menu shows rather than a mock. Uses the view's own
// cacheDisplay, not a screen grab: that needs no Screen Recording permission,
// works headless, and cannot catch a stray window sitting on top of the menu.
//
// Kept in the shipping binary because it is the cheapest way to iterate on the
// layout (no menu to open, no clicking) and to eyeball the widget on a machine
// you are only connected to over SSH.

import SwiftUI
import AppKit

enum Snapshot {
    /// `--snapshot-settings <file.png>`. The same trick against the settings
    /// window's view rather than the panel's, so the settings can be eyeballed
    /// without opening a window on a machine nobody is sitting at. Renders the
    /// view and not the NSWindow the app really opens: the titled frame and its
    /// traffic lights belong to AppKit, and cacheDisplay cannot draw them.
    static func runSettings(path: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusController(interval: 3600)
        return render(NSHostingView(rootView: SettingsView(controller: controller)),
                      width: SettingsView.windowWidth,
                      minHeight: 320,
                      to: path)
    }

    static func run(path: String, width: CGFloat = MenuView.panelWidth) -> Int32 {
        let app = NSApplication.shared
        // Accessory, so rendering never puts an icon in the Dock or steals focus.
        app.setActivationPolicy(.accessory)

        // A long interval: the initial synchronous load in init() is the data
        // we want, and a polling timer would only add churn during rendering.
        let controller = StatusController(interval: 3600)
        return render(NSHostingView(rootView: MenuView(controller: controller)),
                      width: width,
                      minHeight: 140,
                      to: path)
    }

    /// Measures, settles, re-measures, and writes the PNG. Shared by both
    /// snapshot flags so the dropdown and the settings window are rendered by
    /// exactly the same code, and a fix to the settling logic cannot land on
    /// one and miss the other.
    private static func render(_ hosting: NSHostingView<some View>,
                               width: CGFloat,
                               minHeight: CGFloat,
                               to path: String) -> Int32 {

        // Measure at the real menu width, then grow to whatever height the
        // content needs, the same way the MenuBarExtra panel sizes itself.
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height, minHeight)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // The view has to belong to a window before cacheDisplay will draw it.
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = hosting
        window.backgroundColor = .windowBackgroundColor
        // Positioned off any screen so a visible flash is impossible.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()

        // Let SwiftUI finish layout, and let the first Pass poll land: the
        // synchronous load in init() is only the file model, so measuring
        // once would render the widget as it looks before it has heard from
        // The Pass.
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        hosting.layoutSubtreeIfNeeded()
        // Re-measure, because rows arriving from the poll changed the height.
        let settled = max(hosting.fittingSize.height, minHeight)
        if abs(settled - hosting.frame.height) > 0.5 {
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: settled)
            window.setContentSize(NSSize(width: width, height: settled))
            hosting.layoutSubtreeIfNeeded()
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            FileHandle.standardError.write(Data("could not allocate a bitmap\n".utf8))
            return 1
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("could not write \(path): \(error)\n".utf8))
            return 1
        }
        print("wrote \(path) (\(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)))")
        return 0
    }
}
