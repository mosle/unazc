import AppKit

extension NSMenu {
    /// Makes every actionable item here and in submenus act without closing the menu, so several
    /// options can be changed in one visit. Call after the items are final.
    func keepOpenOnClick() {
        for item in items {
            if let submenu = item.submenu {
                submenu.keepOpenOnClick()
            } else if item.action != nil, item.view == nil {
                item.view = StayOpenItemView(item: item)
            }
        }
    }

    /// Takes on the items of `fresh`. Level by level, when only their state changed, the items stay
    /// and take the new state, since replacing them would close a submenu open over them.
    func update(from fresh: NSMenu) {
        guard Self.sameShape(self, fresh) else {
            let items = fresh.items
            fresh.removeAllItems()
            removeAllItems()
            items.forEach(addItem)
            return
        }
        for (item, new) in zip(items, fresh.items) {
            item.state = new.state
            item.isEnabled = new.isEnabled
            item.representedObject = new.representedObject
            item.view?.needsDisplay = true
            if let view = item.view { NSAccessibility.post(element: view, notification: .valueChanged) }
            if let submenu = item.submenu, let newSubmenu = new.submenu { submenu.update(from: newSubmenu) }
        }
    }

    private static func sameShape(_ a: NSMenu, _ b: NSMenu) -> Bool {
        a.items.count == b.items.count && zip(a.items, b.items).allSatisfy { x, y in
            x.title == y.title && x.isSeparatorItem == y.isSeparatorItem && (x.submenu == nil) == (y.submenu == nil)
        }
    }
}

/// Draws its item like a standard one (check mark, title, highlight). A click sends the item's
/// action and leaves the menu open, which a standard item cannot do.
private final class StayOpenItemView: NSView {
    private static let height: CGFloat = 22
    private static let titleX: CGFloat = 22
    private static let indent: CGFloat = 14
    private static var font: NSFont { .menuFont(ofSize: 0) }

    init(item: NSMenuItem) {
        let width = Self.titleX + CGFloat(item.indentationLevel) * Self.indent
            + (item.title as NSString).size(withAttributes: [.font: Self.font]).width + 20
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        let highlighted = item.isHighlighted && item.isEnabled
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = !item.isEnabled ? .disabledControlTextColor : highlighted ? .selectedMenuItemTextColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let x = Self.titleX + CGFloat(item.indentationLevel) * Self.indent
        let title = item.title as NSString
        let y = (bounds.height - title.size(withAttributes: attributes).height) / 2
        if item.state == .on {
            ("✓" as NSString).draw(at: NSPoint(x: x - 14, y: y), withAttributes: attributes)
        }
        title.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    override func mouseUp(with event: NSEvent) {
        perform()
    }

    @discardableResult
    private func perform() -> Bool {
        guard let item = enclosingMenuItem, item.isEnabled, let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    // A view hides the item's own accessibility, so the view stands in for it.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityLabel() -> String? { enclosingMenuItem?.title }
    override func accessibilityValue() -> Any? { enclosingMenuItem?.state == .on }
    override func isAccessibilityEnabled() -> Bool { enclosingMenuItem?.isEnabled ?? false }
    override func accessibilityPerformPress() -> Bool { perform() }
}
