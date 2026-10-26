import AppKit
import ApplicationServices

/// A small floating panel that shows the text recognized so far while Fn is held. It only shows;
/// nothing reaches the target app before release, so it cannot clash with an input method or the
/// app's own editing. Placed under the text cursor when the focused app reports one, otherwise
/// near the bottom of the screen with the mouse. Main thread only.
final class LiveOverlay {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let iconSize: CGFloat = 24
    private let gap: CGFloat = 8
    private let maxWidth: CGFloat = 600
    private let padding: CGFloat = 12
    private let font = NSFont.systemFont(ofSize: 16, weight: .medium)
    private let maxLines = 4
    /// The recording the panel is showing; updates for any other one are dropped.
    private var session: Int?
    /// Where the panel's top-left goes, fixed for the whole recording so it does not wander.
    private var anchor: NSPoint = .zero
    /// Shown in place of the placeholder while nothing has been recognized (see `warn`).
    private var warning: String?
    /// The text on the panel, so a warning can be drawn over it again.
    private var shown: (committed: String, full: String) = ("", "")

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Solid rather than a translucent material, so the text stays readable over any window.
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.97).cgColor
        background.layer?.cornerRadius = 12
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        panel.contentView = background

        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        background.addSubview(icon)

        label.font = font
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        background.addSubview(label)
    }

    func show(session id: Int) {
        session = id
        flashing = nil
        warning = nil
        anchor = Self.caretAnchor() ?? Self.fallbackAnchor()
        render(committed: "", full: "")
        panel.orderFrontRegardless()
    }

    /// `committed` is text of finished stretches; the rest of `full` is still being spoken and
    /// may change, so it is drawn dimmer.
    func update(session id: Int, committed: String, full: String) {
        guard id == session else { return }
        render(committed: committed, full: full)
    }

    /// Shows `message` on recording `id`'s panel for as long as no text has been recognized.
    /// Returns false when the panel is not showing that recording.
    func warn(session id: Int, _ message: String) -> Bool {
        guard id == session else { return false }
        warning = message
        render(committed: shown.committed, full: shown.full)
        return true
    }

    func hide() {
        session = nil
        flashing = nil
        warning = nil
        panel.orderOut(nil)
    }

    /// Counts flashes, so only the newest one's timer hides the panel.
    private var flashCount = 0
    /// The flash on screen, if the panel shows one rather than a recording.
    private var flashing: Int?

    /// Shows a short message for `seconds`, unless a recording takes the panel over. While a
    /// recording shows, it is not shown at all. Returns an id for `hideFlash`.
    @discardableResult
    func flash(_ message: String, seconds: Double = 2) -> Int {
        flashCount += 1
        let id = flashCount
        guard session == nil else { return id }
        flashing = id
        anchor = Self.caretAnchor() ?? Self.fallbackAnchor()
        render(committed: message, full: message)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.hideFlash(id)
        }
        return id
    }

    func hideFlash(_ id: Int) {
        if flashing == id { hide() }
    }

    private func render(committed: String, full: String) {
        shown = (committed, full)
        // A warning stands in for the text, through the same fitting, while there is none.
        let warned = full.isEmpty ? warning.map { "⚠︎ " + $0 } : nil
        let committed = warned == nil ? committed : ""
        let full = warned ?? full
        let fixedCount = full.hasPrefix(committed) ? committed.count : 0
        // Only the end matters while talking: drop text from the front until what is left fits in
        // `maxLines` as actually wrapped (line breaks included), so the newest words stay visible.
        let lineLimit = ceil(NSLayoutManager().defaultLineHeight(for: font) * CGFloat(maxLines)) + 1
        let textX = padding + iconSize + gap
        let fitWidth = maxWidth - textX - padding
        var dropped = 0
        // Measured with the label itself, so the wrapping matches what is drawn.
        func measuredHeight() -> CGFloat {
            label.sizeThatFits(NSSize(width: fitWidth, height: .greatestFiniteMagnitude)).height
        }
        label.attributedStringValue = attributed(full, fixedCount: fixedCount, dropped: 0, font: font, warned: warned != nil)
        while dropped < full.count, measuredHeight() > lineLimit {
            dropped = min(full.count, dropped + max(1, (full.count - dropped) / 8))
            label.attributedStringValue = attributed(full, fixedCount: fixedCount, dropped: dropped, font: font, warned: warned != nil)
        }

        let size = label.sizeThatFits(NSSize(width: fitWidth, height: .greatestFiniteMagnitude))
        let textHeight = ceil(size.height)
        let width = min(maxWidth, textX + ceil(size.width) + padding)
        let height = max(textHeight, iconSize) + padding * 2
        label.frame = NSRect(x: textX, y: height - padding - textHeight, width: width - textX - padding, height: textHeight)
        // Level with the first line of text.
        let firstLine = NSLayoutManager().defaultLineHeight(for: font)
        icon.frame = NSRect(x: padding, y: height - padding - (firstLine + iconSize) / 2, width: iconSize, height: iconSize)
        var frame = NSRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
        // Keep it on the screen that holds the anchor.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - width - 8)
            frame.origin.y = max(frame.origin.y, visible.minY + 8)
        }
        panel.setFrame(frame, display: true)
    }

    /// `full` without its first `dropped` characters (marked by "…"); the first
    /// `fixedCount` characters of `full` are settled text, the rest is drawn dimmer (or as a warning).
    private func attributed(_ full: String, fixedCount: Int, dropped: Int, font: NSFont, warned: Bool) -> NSAttributedString {
        let settled = NSColor.white
        let pending = warned ? NSColor.systemYellow : NSColor(white: 1, alpha: 0.62)
        let text = NSMutableAttributedString()
        if full.isEmpty {
            text.append(NSAttributedString(string: "聞いています…", attributes: [.foregroundColor: pending]))
        } else {
            if dropped > 0 { text.append(NSAttributedString(string: "…", attributes: [.foregroundColor: pending])) }
            let rest = full.dropFirst(dropped)
            let split = rest.index(rest.startIndex, offsetBy: min(max(fixedCount - dropped, 0), rest.count))
            text.append(NSAttributedString(string: String(rest[..<split]), attributes: [.foregroundColor: settled]))
            text.append(NSAttributedString(string: String(rest[split...]), attributes: [.foregroundColor: pending]))
        }
        text.addAttribute(.font, value: font, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// Just below the focused app's text cursor, via Accessibility. nil when the app does not
    /// expose it (many terminals and web views don't).
    private static func caretAnchor() -> NSPoint? {
        let system = AXUIElementCreateSystemWide()
        // A hung app must not stall the main thread.
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.1)
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 || rect.width > 0 else { return nil }
        // Accessibility uses top-left origin coordinates on the primary screen.
        guard let primary = NSScreen.screens.first else { return nil }
        let point = NSPoint(x: rect.minX, y: primary.frame.maxY - rect.maxY - 6)
        return NSScreen.screens.contains(where: { $0.frame.contains(point) }) ? point : nil
    }

    /// Bottom centre of the screen with the mouse.
    private static func fallbackAnchor() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return mouse }
        return NSPoint(x: visible.midX - 200, y: visible.minY + 140)
    }
}
