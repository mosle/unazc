import AppKit

/// Menu bar glyph for the idle state: the app icon's waveform ending in a text caret,
/// drawn as a template so it follows the menu bar's light/dark appearance.
enum StatusIcon {
    static let idle: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            // Waveform bars, centered on y = 9.
            for (x, h) in [(2.0, 4.0), (5.25, 10.0), (8.5, 6.0)] as [(CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 9 - h / 2, width: 1.75, height: h),
                             xRadius: 0.875, yRadius: 0.875).fill()
            }
            // Text caret (I-beam).
            for rect in [NSRect(x: 13.25, y: 3, width: 1.5, height: 12),
                         NSRect(x: 11.75, y: 2.5, width: 4.5, height: 1.25),
                         NSRect(x: 11.75, y: 14.25, width: 4.5, height: 1.25)] {
                NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Unazc"
        return image
    }()
}
