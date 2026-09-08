// Layout.swift -- `--dump-layout` measures the panel the way MenuBarExtra
// actually hosts it, and prints the result as JSON.
//
// MenuBarExtra(.window) puts MenuView inside a window managed by Auto Layout,
// with the content pinned top and bottom. A bare SwiftUI ScrollView is fully
// flexible along its scroll axis, and under that regime SwiftUI once
// compressed it to ZERO height: the whole task list disappeared from the real
// dropdown while the header, computed from the same model, went on counting
// rows it was not drawing.
//
// `--snapshot` cannot catch that class of bug, because Snapshot.swift measures
// with `hosting.fittingSize`, which asks SwiftUI for the size it *wants*
// rather than the size Auto Layout's pin-top-and-bottom constraints actually
// *give* it. fittingSize reports a healthy height whether or not the
// ScrollView is collapsed underneath a real MenuBarExtra window -- it never
// sees the compression at all. So this seam builds both regimes side by side
// against the same model and reports both numbers: `panel_height` is the one
// that would have caught the regression, `fitting_height` is what --snapshot
// sees, and the gap between them (334 vs. 152 before the fix; 334 vs. 326
// after) is the whole point of printing them together.
//
// `list_height` adds a second, more direct check: it walks the Auto-Layout
// hosting view's subviews for the tallest NSScrollView (or its clip view) it
// can find, so a test can confirm the row list itself -- not just the panel
// around it -- actually has height.

import SwiftUI
import AppKit

enum LayoutProbe {
    static func run() -> Int32 {
        let app = NSApplication.shared
        // Accessory, so this never puts an icon in the Dock or steals focus.
        app.setActivationPolicy(.accessory)

        let width = MenuView.panelWidth

        // A long interval: the initial synchronous load in init() is the data
        // we want, and a polling timer would only add churn during measuring.
        let controller = StatusController(interval: 3600, activatesGlobalHotkey: false)

        // Let the initial file load and the first refresh() (Pass or files)
        // land before either regime measures anything.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        // ---- Regime A: fittingSize, exactly what --snapshot measures. ----
        // No window needed -- fittingSize is answerable from a bare, framed
        // hosting view, which is itself part of why it cannot see the bug:
        // it never goes anywhere near Auto Layout.
        let fittingHosting = NSHostingView(rootView: MenuView(controller: controller))
        fittingHosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        fittingHosting.layoutSubtreeIfNeeded()
        let fittingHeight = fittingHosting.fittingSize.height

        // ---- Regime B: Auto Layout window, content pinned top and bottom --
        // the way MenuBarExtra(.window) really hosts the panel. This is the
        // regime that collapsed a flexible ScrollView to nothing.
        let hosting = NSHostingView(rootView: MenuView(controller: controller))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                    styleMask: [.borderless],
                                    backing: .buffered,
                                    defer: false)
        let host = NSView(frame: .zero)
        panelWindow.contentView = host
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        // Positioned off any screen so a visible flash is impossible. Ordered
        // back, never front-and-key: this must never steal focus or become
        // the frontmost window.
        panelWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panelWindow.orderBack(nil)
        panelWindow.layoutIfNeeded()

        // The real height comes from a SwiftUI preference (MenuView's
        // ListHeightKey, read back into `.frame(height:)`) that needs a
        // layout pass to land, so settle, then measure -- the same
        // settle-then-layout the throwaway probe that first proved this bug
        // used.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        panelWindow.layoutIfNeeded()

        let panelSize = panelWindow.frame.size
        let listHeight = maxScrollViewHeight(hosting)

        let now = controller.now
        let model = controller.model
        let sections = model.sections(now: now)
        var sectionCounts: [String: Int] = [:]
        for entry in sections { sectionCounts[entry.section.rawValue] = entry.records.count }
        // The rows a freshly opened menu actually shows: sections filtered by
        // the controller's real collapse state, exactly what MenuView reads
        // via `controller.isCollapsed(_:)` when it decides which rows to
        // draw. Lets a test cross-check the rendered panel against the rows
        // the model says are there.
        let visibleIDs = model.visibleRecords(collapsed: controller.collapsed, now: now)
            .map { $0.id }

        let payload: [String: Any] = [
            "panel_height": Double(panelSize.height),
            "panel_width": Double(panelSize.width),
            "fitting_height": Double(fittingHeight),
            "list_height": Double(listHeight),
            "record_count": model.records.count,
            "section_keys": sections.map { $0.section.rawValue },
            "section_counts": sectionCounts,
            "visible_ids": visibleIDs,
            "source": model.source.rawValue,
            "headline": model.headlineText,
        ]

        return emit(payload)
    }

    /// Walks an Auto-Layout-hosted view's subviews for the tallest scroll
    /// region it can find. SwiftUI's ScrollView is an NSScrollView (with an
    /// NSClipView as its content view) once it lands in AppKit, so either one
    /// reporting a real height is proof the row list is not collapsed. Zero
    /// when none is found, so a regression that removes the ScrollView
    /// entirely still prints a number instead of crashing a test.
    private static func maxScrollViewHeight(_ view: NSView) -> CGFloat {
        var best: CGFloat = 0
        if let scroll = view as? NSScrollView {
            best = max(best, scroll.frame.height, scroll.contentView.frame.height)
        } else if let clip = view as? NSClipView {
            best = max(best, clip.frame.height)
        }
        for sub in view.subviews {
            best = max(best, maxScrollViewHeight(sub))
        }
        return best
    }

    private static func emit(_ payload: [String: Any]) -> Int32 {
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]) else {
            FileHandle.standardError.write(Data("could not serialise payload\n".utf8))
            return 1
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }
}
