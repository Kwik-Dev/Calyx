// TabContextMenu.swift
// Calyx

import AppKit

/// Builds the context menu for one tab. Shared by the tab bar
/// (`TabItemButton`) and the sidebar tab rows (`TabRowItemView`).
enum TabContextMenu {
    struct Actions {
        var close: () -> Void
        var closeOthers: () -> Void
        var closeToTheRight: () -> Void
        var rename: () -> Void
    }

    @MainActor
    static func make(tabIndex: Int, tabCount: Int, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let close = ClosureMenuItem(title: "Close Tab", handler: actions.close)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        menu.addItem(close)

        let closeOthers = ClosureMenuItem(title: "Close Other Tabs", handler: actions.closeOthers)
        closeOthers.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeOthers.isEnabled = tabCount > 1
        menu.addItem(closeOthers)

        let closeToTheRight = ClosureMenuItem(title: "Close Tabs to the Right", handler: actions.closeToTheRight)
        closeToTheRight.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeToTheRight.isEnabled = tabIndex < tabCount - 1
        menu.addItem(closeToTheRight)

        menu.addItem(.separator())

        let rename = ClosureMenuItem(title: "Rename Tab...", handler: actions.rename)
        rename.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: nil)
        menu.addItem(rename)

        return menu
    }
}

/// `NSMenuItem` subclass that dispatches to a stored closure instead of
/// requiring a separate target object. `NSMenuItem.target` is weak and
/// the menu owns the item, so holding `self` as `target` is not a
/// retain cycle.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke(_ sender: Any?) {
        handler()
    }
}
