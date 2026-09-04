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

enum MenuBarIcon {
    private static let dotDiameter: CGFloat = 9
    private static let gap: CGFloat = 3
    private static let height: CGFloat = 16

    static func image(for aggregate: Aggregate) -> NSImage {
        let badge = aggregate.badge
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let badgeWidth = badge.isEmpty ? 0 : (badge as NSString)
            .size(withAttributes: [.font: font]).width + gap
        let width = dotDiameter + badgeWidth
        let color = StatusPalette.color(for: aggregate)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let y = (height - dotDiameter) / 2
            let dot = NSBezierPath(ovalIn: NSRect(x: 0, y: y, width: dotDiameter, height: dotDiameter))
            color.setFill()
            dot.fill()

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
