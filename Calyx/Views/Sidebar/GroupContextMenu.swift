// GroupContextMenu.swift
// Calyx

import AppKit

/// Builds the context menu for a sidebar tab-group header. Shares its
/// `Close`/`Rename` shape with `TabContextMenu` and adds a `Color`
/// submenu for `TabGroup.color`.
enum GroupContextMenu {
    struct Actions {
        var close: () -> Void
        var closeOthers: () -> Void
        var closeBelow: () -> Void
        var rename: () -> Void
        var setColor: (TabGroupColor) -> Void
    }

    @MainActor
    static func make(groupIndex: Int, groupCount: Int, currentColor: TabGroupColor, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(ClosureMenuItem(
            title: "Close Group", symbolName: "xmark", identifier: AccessibilityID.GroupContextMenu.close,
            handler: actions.close
        ))

        menu.addItem(ClosureMenuItem(
            title: "Close Other Groups", symbolName: "xmark", identifier: AccessibilityID.GroupContextMenu.closeOthers,
            isEnabled: groupCount > 1, handler: actions.closeOthers
        ))

        menu.addItem(ClosureMenuItem(
            title: "Close Groups Below", symbolName: "xmark", identifier: AccessibilityID.GroupContextMenu.closeBelow,
            isEnabled: groupIndex < groupCount - 1, handler: actions.closeBelow
        ))

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(
            title: "Rename Group...", symbolName: "pencil.line", identifier: AccessibilityID.GroupContextMenu.rename,
            handler: actions.rename
        ))

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorSubmenu(currentColor: currentColor, setColor: actions.setColor)
        colorItem.setAccessibilityIdentifier(AccessibilityID.GroupContextMenu.color)
        menu.addItem(colorItem)

        return menu
    }

    @MainActor
    private static func colorSubmenu(currentColor: TabGroupColor, setColor: @escaping (TabGroupColor) -> Void) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for color in TabGroupColor.allCases {
            let item = ClosureMenuItem(title: color.displayName) { setColor(color) }
            item.image = swatchImage(for: color)
            item.state = color == currentColor ? .on : .off
            item.setAccessibilityIdentifier(AccessibilityID.GroupContextMenu.color(color))
            submenu.addItem(item)
        }
        return submenu
    }

    /// A 12x12 filled circle in `color`'s system color. Uses the
    /// drawing-handler form of `NSImage` (rather than pre-rendering the
    /// circle once) so the handler runs at draw time and the system
    /// color resolves against the menu's own appearance (light/dark).
    @MainActor
    static func swatchImage(for color: TabGroupColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}
