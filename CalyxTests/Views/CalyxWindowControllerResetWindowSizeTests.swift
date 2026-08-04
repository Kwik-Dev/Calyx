//
//  CalyxWindowControllerResetWindowSizeTests.swift
//  CalyxTests
//
//  TDD RED phase, second missing-observer investigation:
//  `GhosttyActionRouter.handleAction` still lists
//  `GHOSTTY_ACTION_RESET_WINDOW_SIZE` in its "Known but unimplemented"
//  group (`return false`, GhosttyAction.swift) -- ghostty's default
//  reset_window_size keybind does nothing.
//  `CalyxWindowController.processResetWindowSize()` is the intended
//  receiver once a `.ghosttyResetWindowSize` case/observer exists; today
//  it is an intentional no-op stub (see its own doc comment in
//  CalyxWindowController.swift), so the test below -- which expects the
//  window's content size to actually reset -- fails.
//
//  `contentSize(of:)` reads `window.contentView.frame.size`, NOT
//  `window.frame.size` -- mirrors `CalyxWindowControllerInitialSizeTests`'s
//  own identically-named helper (that file's sibling `applyInitialSize`
//  also calls `window?.setContentSize`, the same call
//  `processResetWindowSize` is intended to make), the established,
//  already-verified-correct way to assert an exact `setContentSize`
//  result in this codebase's test host. Only the window's SIZE is
//  asserted, not its post-`center()` position: the exact centered origin
//  depends on the test host's actual screen geometry
//  (`NSScreen.main?.visibleFrame`), which this suite has no control over
//  -- mirrors why CalyxWindowControllerToggleMaximizeTests avoids
//  asserting `performZoom`'s geometry.
//
//  `processResetWindowSize` takes no parameters and operates on `self
//  .window` directly, so it is called directly here, not via a posted
//  notification.
//
//  Coverage-gap follow-up: see CalyxWindowControllerSetTabTitleTests's own
//  identically-worded follow-up note -- `registerNotificationObservers()`
//  never registered an observer for `.ghosttyResetWindowSize` either, so
//  ghostty's reset_window_size keybind stayed silently inert despite
//  `process*` having a real body. The "Notification post (Tactic A)"
//  section below closes the gap and covers the fix.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerResetWindowSizeTests: XCTestCase {

    /// Constructs the window at a size deliberately DIFFERENT from
    /// `CalyxWindowController.defaultContentSize` (800x600), so a
    /// successful reset is unambiguous to detect.
    private func makeController() -> CalyxWindowController {
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    private func contentSize(of controller: CalyxWindowController) -> NSSize {
        controller.window?.contentView?.frame.size ?? .zero
    }

    func test_processResetWindowSize_resetsContentSizeToDefaultContentSize() {
        let controller = makeController()
        XCTAssertEqual(
            contentSize(of: controller),
            NSSize(width: 1200, height: 900),
            "Precondition: fixture window starts at a non-default content size"
        )

        controller.processResetWindowSize()

        XCTAssertEqual(
            contentSize(of: controller),
            CalyxWindowController.defaultContentSize,
            "processResetWindowSize must reset the window's content size to defaultContentSize (800x600)"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Unlike `makeController()` above, `findTab(for:)` needs a real
    /// `SurfaceRegistry` entry -- mirrors `CalyxWindowControllerCloseWindowTests
    /// .SurfaceOwningFixture`. Constructed at the same non-default
    /// 1200x900 content size as `makeController()` above, for the same
    /// "a successful reset is unambiguous to detect" reason.
    private struct SurfaceOwningFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
    }

    private func makeSurfaceOwningFixture() -> SurfaceOwningFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SurfaceOwningFixture(controller: controller, surfaceView: surfaceView)
    }

    /// Posting the real `.ghosttyResetWindowSize` notification for a
    /// surface THIS window owns must reset the window's content size to
    /// `defaultContentSize` -- exercises `handleResetWindowSizeNotification`'s
    /// `findTab(for:)` routing end to end, not just `processResetWindowSize`
    /// called directly.
    func test_ghosttyResetWindowSize_postedForOwnSurface_resetsContentSizeToDefaultContentSize() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertEqual(
            contentSize(of: fixture.controller),
            NSSize(width: 1200, height: 900),
            "Precondition: fixture window starts at a non-default content size"
        )

        NotificationCenter.default.post(name: .ghosttyResetWindowSize, object: fixture.surfaceView)

        XCTAssertEqual(
            contentSize(of: fixture.controller),
            CalyxWindowController.defaultContentSize,
            "Posting .ghosttyResetWindowSize for a surface this window owns must reset the window's content size to defaultContentSize"
        )
    }

    /// Regression guard: posting `.ghosttyResetWindowSize` for a surface
    /// NO controller's `windowSession` owns must leave the window's
    /// content size untouched -- depends on
    /// `handleResetWindowSizeNotification`'s own `guard findTab(for:) !=
    /// nil` actually gating the dispatch.
    func test_ghosttyResetWindowSize_postedForSurfaceNoWindowOwns_doesNotChangeContentSize() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if findTab(for:)'s ownership
        // check were removed entirely.
        let fixture = makeSurfaceOwningFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)
        XCTAssertEqual(
            contentSize(of: fixture.controller),
            NSSize(width: 1200, height: 900),
            "Precondition: fixture window starts at a non-default content size"
        )

        NotificationCenter.default.post(name: .ghosttyResetWindowSize, object: orphanSurfaceView)

        XCTAssertEqual(
            contentSize(of: fixture.controller),
            NSSize(width: 1200, height: 900),
            "Posting .ghosttyResetWindowSize for a surface no window owns must not change the window's content size"
        )
    }
}
