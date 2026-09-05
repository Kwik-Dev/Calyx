// ClosureMenuItem.swift
// Calyx

import AppKit

/// `NSMenuItem` subclass that dispatches to a stored closure instead of
/// requiring a separate target object. `NSMenuItem.target` is weak and
/// the menu owns the item, so holding `self` as `target` is not a
/// retain cycle.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        target = self
    }

    /// Convenience for the common context-menu-item shape: a system
    /// symbol image, an optional enabled state, and an optional
    /// accessibility identifier, in one call.
    convenience init(
        title: String,
        symbolName: String,
        identifier: String? = nil,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.init(title: title, handler: handler)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        self.isEnabled = isEnabled
        if let identifier {
            setAccessibilityIdentifier(identifier)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke(_ sender: Any?) {
        handler()
    }
}
