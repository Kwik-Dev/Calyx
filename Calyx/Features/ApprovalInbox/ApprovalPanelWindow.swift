// ApprovalPanelWindow.swift
// Calyx
//
// The floating, notification-style panel that hosts the Cockpit
// approval banner (`ApprovalPanelContentView`), independent of any
// `CalyxWindowController`'s own window -- stays visible across its
// host's minimize, Space switch, or full screen. Non-activating: Allow/
// Deny must work without bringing Calyx to the front.
//
// `becomesKeyOnlyIfNeeded = true`: ordering the panel front or clicking
// through it (Allow/Deny/a choice row) never itself takes key status;
// only a view that requests key status (the question form's free-text
// field, or `NSHostingView` when it answers `needsPanelToBecomeKey`
// true) can. Any key status the panel does take is handed back to the
// host window by `ApprovalPanelController.render()`, either when the
// displayed request changes or when the panel orders out.
//
// `canBecomeMain = false`: taking main away from the host window would
// misroute Cmd+W to `closeTab(_:)` on the wrong window (see
// `NSWindow+CalyxClose.swift`'s own header comment for the full
// mis-routing writeup this mirrors).
//
// See CalyxTests/Features/ApprovalPanelWindowTests.swift for the
// specced configuration, and QuickTerminalWindow.swift for the sibling
// non-activating panel this is modeled on.

import AppKit

final class ApprovalPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isRestorable = false
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Approval"
        isMovable = false
        identifier = NSUserInterfaceItemIdentifier("com.calyx.approvalPanel")
        setAccessibilitySubrole(.floatingWindow)
    }

    /// Calyx never lets Cmd+W close a pending approval out from under
    /// the human -- a complete no-op, never routed anywhere else (see
    /// `NSWindow+CalyxClose.swift`'s own header comment for why every
    /// window answers this selector at all).
    override func calyxPerformClose(_ sender: Any?) {}

    /// Esc must never dismiss a pending approval -- a complete no-op.
    override func cancelOperation(_ sender: Any?) {}
}
