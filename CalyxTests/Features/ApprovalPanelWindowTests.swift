//
//  ApprovalPanelWindowTests.swift
//  CalyxTests
//
//  Covers `ApprovalPanelWindow`'s fixed configuration: a
//  non-activating, always-on-top-of-its-Space panel that never steals
//  key/main window semantics away from its host's real
//  `CalyxWindowController` window, and never lets Calyx close it out
//  from under a pending approval.
//
//  Every window built below is NEVER shown (no `orderFront`/
//  `makeKeyAndOrderFront` call anywhere in this file) -- mirrors
//  `QuickTerminalWindowCalyxPerformCloseRoutingTests`'s own established
//  safety discipline for a bare, unshown panel/window fixture in this
//  test host, and `isReleasedWhenClosed` is forced `false` defensively
//  on top of the production default the same way that file's
//  `makeBareWindow()` does.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class ApprovalPanelWindowTests: XCTestCase {

    // MARK: - Test double

    /// Always answers `false` (never actually close) and records how
    /// many times AppKit asked -- mirrors
    /// `QuickTerminalWindowCalyxPerformCloseRoutingTests.RecordingDelegate`.
    private final class RecordingDelegate: NSObject, NSWindowDelegate {
        private(set) var windowShouldCloseCallCount = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            windowShouldCloseCallCount += 1
            return false
        }
    }

    private func makePanel() -> ApprovalPanelWindow {
        let panel = ApprovalPanelWindow()
        panel.isReleasedWhenClosed = false
        return panel
    }

    // MARK: - styleMask / signal lights

    func test_styleMask_isBorderlessFullSizeContentViewNonactivatingPanel() {
        let panel = makePanel()

        XCTAssertEqual(panel.styleMask, [.borderless, .fullSizeContentView, .nonactivatingPanel],
                       "styleMask must be exactly [.borderless, .fullSizeContentView, .nonactivatingPanel] -- .titled is dropped so the system window shadow's own bright 1px alpha-silhouette outline never shows, and no closable/miniaturizable/resizable bit may be present")
    }

    func test_standardCloseButton_isNil() {
        let panel = makePanel()

        XCTAssertNil(panel.standardWindowButton(.closeButton),
                    "with no .closable bit in styleMask, no traffic-light close button may exist")
    }

    // MARK: - Key/main semantics

    func test_canBecomeKey_isTrue() {
        let panel = makePanel()

        XCTAssertTrue(panel.canBecomeKey, "the panel must be able to become key -- e.g. the question form's free-text field needs to take first responder")
    }

    func test_canBecomeMain_isFalse() {
        let panel = makePanel()

        XCTAssertFalse(panel.canBecomeMain, "the panel must never become main -- taking main away from the host window would misroute Cmd+W to closeTab on the wrong window (see NSWindow+CalyxClose.swift)")
    }

    func test_becomesKeyOnlyIfNeeded_isTrue() {
        let panel = makePanel()

        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded,
                     "clicking Allow/Deny must not itself take key status -- only an explicit first-responder request (the question form's free-text field) may")
    }

    // MARK: - Visibility / lifecycle behavior

    func test_hidesOnDeactivate_isFalse() {
        let panel = makePanel()

        XCTAssertFalse(panel.hidesOnDeactivate, "the panel must keep showing when Calyx is deactivated -- it must be answerable without bringing Calyx to the front")
    }

    func test_level_isFloating() {
        let panel = makePanel()

        XCTAssertEqual(panel.level, .floating, "the panel must float above ordinary windows, notification-style")
    }

    func test_collectionBehavior_containsAllRequiredFlags() {
        let panel = makePanel()

        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces),
                     "the panel must follow the user across Spaces, independent of its host window's own Space")
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary),
                     "the panel must be able to appear above a fullscreen host window")
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle),
                     "the panel must never appear in Cmd+` window cycling")
    }

    func test_isRestorable_isFalse() {
        let panel = makePanel()

        XCTAssertFalse(panel.isRestorable, "the panel is derived state (whatever is currently pending) -- it must never be saved into / restored from macOS window state")
    }

    func test_isReleasedWhenClosed_isFalse() {
        // Constructed fresh (not through makePanel(), which forces this
        // to false defensively) -- this test is specifically pinning the
        // PRODUCTION default itself.
        let panel = ApprovalPanelWindow()

        XCTAssertFalse(panel.isReleasedWhenClosed,
                       "the panel must survive its own close() (tearDown() calls close() but the controller keeps its own reference alive)")
    }

    func test_hasShadow_isFalse() {
        let panel = makePanel()

        XCTAssertFalse(panel.hasShadow, "the panel must not cast the system window shadow -- it draws its own soft shadow and rim in ApprovalPanelContentView.glassWrapped(request:) instead, since the system shadow of a non-opaque dark window adds its own bright alpha-silhouette outline that a real notification banner does not have")
    }

    func test_isOpaque_isFalse() {
        let panel = makePanel()

        XCTAssertFalse(panel.isOpaque, "the panel must be non-opaque so its glass background can render translucently")
    }

    func test_isMovable_isFalse() {
        let panel = makePanel()

        XCTAssertFalse(panel.isMovable, "the panel is always positioned by ApprovalPanelArranger -- the user must never be able to drag it")
    }

    func test_identifier_isComCalyxApprovalPanel() {
        let panel = makePanel()

        XCTAssertEqual(panel.identifier?.rawValue, "com.calyx.approvalPanel")
    }

    // MARK: - calyxPerformClose(_:) / cancelOperation(_:) are no-ops

    func test_calyxPerformClose_neverCallsWindowShouldClose() {
        let panel = makePanel()
        let delegate = RecordingDelegate()
        panel.delegate = delegate
        defer { panel.delegate = nil }
        let wasVisibleBefore = panel.isVisible

        panel.calyxPerformClose(nil)

        XCTAssertEqual(delegate.windowShouldCloseCallCount, 0,
                       "calyxPerformClose(_:) must be a complete no-op -- Calyx never lets Cmd+W close a pending approval out from under the human")
        XCTAssertEqual(panel.isVisible, wasVisibleBefore, "the panel's visibility must be completely untouched")
    }

    func test_cancelOperation_neverCallsWindowShouldClose() {
        let panel = makePanel()
        let delegate = RecordingDelegate()
        panel.delegate = delegate
        defer { panel.delegate = nil }
        let wasVisibleBefore = panel.isVisible

        panel.cancelOperation(nil)

        XCTAssertEqual(delegate.windowShouldCloseCallCount, 0,
                       "cancelOperation(_:) (Esc) must be a complete no-op -- Esc must never dismiss a pending approval")
        XCTAssertEqual(panel.isVisible, wasVisibleBefore, "the panel's visibility must be completely untouched")
    }
}
