import Cocoa

class QuickTerminalWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        // Keep .titled (required for glass effect) but add .nonactivatingPanel
        var adjustedStyle = style
        adjustedStyle.insert(.nonactivatingPanel)
        adjustedStyle.insert(.fullSizeContentView)
        super.init(contentRect: contentRect, styleMask: adjustedStyle, backing: backingStoreType, defer: flag)

        self.identifier = .init(rawValue: "com.calyx.quickTerminal")
        self.setAccessibilitySubrole(.floatingWindow)
        self.isRestorable = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isOpaque = false
        self.backgroundColor = .clear
    }

    /// GitHub issue #45 (see `NSWindow+CalyxClose.swift`'s header
    /// comment for the full root-cause writeup): routes Cmd+W to
    /// `QuickTerminalController.requestHide()` (an animated hide, NOT a
    /// real window close) instead of `NSApplication.targetForAction:`'s
    /// key-window-chain resolution falling through to a DIFFERENT
    /// (main) window's `CalyxWindowController.closeTab(_:)`.
    override func calyxPerformClose(_ sender: Any?) {
        guard let controller = delegate as? QuickTerminalController else {
            super.calyxPerformClose(sender)
            return
        }
        controller.requestHide()
    }
}
