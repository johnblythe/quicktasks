// MenuBarIcon.swift -- the status dot drawn into the menu bar.
//
// The dot must keep its colour, so the NSImage is explicitly not a template
// image. The count beside it must follow the menu bar's own text colour, so it
// is drawn inside a drawingHandler block: that block re-runs when the system
// appearance changes, which is what keeps the number legible in both themes.

import AppKit

enum StatusPalette {
    static func color(for status: TaskStatus) -> NSColor {
        switch status {
        case .running: return NSColor.systemBlue
        case .queued: return NSColor.systemGray
        case .blocked: return NSColor.systemOrange
        case .failed, .timeout: return NSColor.systemRed
        case .done: return NSColor.systemGreen
        case .unknown: return NSColor.systemGray
        }
    }

    /// Needs-you rows are coloured by *why* they need John, not by the job
    /// status underneath: a finished job awaiting a verdict is not green.
    static func color(for reason: NeedsReason) -> NSColor {
        switch reason {
        case .verify: return NSColor.systemTeal
        case .gate: return NSColor.systemPurple
        case .blocked: return NSColor.systemOrange
        case .failed: return NSColor.systemRed
        }
    }

    static func color(for record: TaskRecord) -> NSColor {
        if let reason = record.reason { return color(for: reason) }
        return color(for: record.status)
    }

    static func color(for aggregate: Aggregate) -> NSColor {
        switch aggregate {
        case .running: return NSColor.systemBlue
        case .attention: return NSColor.systemOrange
        case .idle: return NSColor.systemGray
        }
    }
}

/// The dot's health, independent of its busy/attention/idle color: whether
/// what's on screen is live from Pass, held over from a Pass that stopped
/// answering (still legitimately Pass data, just delayed), or a fallback to
/// the file ledgers because the hold window ran out. Mirrors
/// MenuModel.headlineText's own rule exactly -- `source == .files &&
/// passStaleSince != nil` is "down", everything else with `passReachable ==
/// false` is "holding" -- so the dot, the tooltip, and the footer's
/// freshness line can never disagree about which state the widget is in. A
/// deliberate files-only setup (Pass discovery switched off) reads as
/// `.normal`: there is no Pass to be down, so nothing should look broken.
enum IconHealth: String {
    case normal
    case heldStale = "held-stale"
    case filesOnly = "files-only"

    static func of(source: FeedSource, passReachable: Bool, passStaleSince: Date?) -> IconHealth {
        if source == .files, passStaleSince != nil { return .filesOnly }
        if source == .pass, !passReachable { return .heldStale }
        return .normal
    }
}

enum MenuBarIcon {
    private static let dotDiameter: CGFloat = 9
    private static let gap: CGFloat = 3
    private static let height: CGFloat = 16

    static func image(for aggregate: Aggregate, health: IconHealth = .normal) -> NSImage {
        let badge = aggregate.badge
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let badgeWidth = badge.isEmpty ? 0 : (badge as NSString)
            .size(withAttributes: [.font: font]).width + gap
        let width = dotDiameter + badgeWidth
        let color = StatusPalette.color(for: aggregate)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let y = (height - dotDiameter) / 2
            let dotRect = NSRect(x: 0, y: y, width: dotDiameter, height: dotDiameter)
            switch health {
            case .normal:
                color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            case .heldStale:
                // The same filled dot, with a small transparent notch punched
                // out of the upper-right edge -- subtle on purpose, since the
                // data on screen is still legitimately from Pass.
                color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
                let notchDiameter = dotDiameter * 0.45
                let notchRect = NSRect(x: dotRect.maxX - notchDiameter * 0.65,
                                       y: dotRect.maxY - notchDiameter * 0.65,
                                       width: notchDiameter,
                                       height: notchDiameter)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: notchRect).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .filesOnly:
                // Pass is genuinely down: a hollow ring instead of a filled
                // dot, the more visible departure from "idle and fine".
                let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 1.6
                color.setStroke()
                ring.stroke()
            }

            if !badge.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    // Resolved on every draw, so it tracks light/dark.
                    .foregroundColor: NSColor.labelColor,
                ]
                let size = (badge as NSString).size(withAttributes: attrs)
                (badge as NSString).draw(
                    at: NSPoint(x: dotDiameter + gap, y: (height - size.height) / 2),
                    withAttributes: attrs)
            }
            return true
        }
        // Template rendering would flatten the dot to monochrome and lose the
        // running/attention distinction that is the whole point of the icon.
        image.isTemplate = false
        return image
    }
}
