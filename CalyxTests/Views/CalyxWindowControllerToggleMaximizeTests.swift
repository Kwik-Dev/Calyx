//
//  CalyxWindowControllerToggleMaximizeTests.swift
//  CalyxTests
//
//  TDD RED phase, second missing-observer investigation:
//  `GhosttyActionRouter.handleAction` still lists
//  `GHOSTTY_ACTION_TOGGLE_MAXIMIZE` in its "Known but unimplemented" group
//  (`return false`, GhosttyAction.swift) -- ghostty's default
//  toggle_maximize keybind does nothing.
//  `CalyxWindowController.processToggleMaximize()` is the intended
//  receiver once a `.ghosttyToggleMaximize` case/observer exists; today it
//  is an intentional no-op stub (see its own doc comment in
//  CalyxWindowController.swift).
//
//  Deliberately NOT tested here: the "happy path" (non-fullscreen ->
//  `performZoom` actually changes the window frame). `performZoom` asks
//  AppKit to compute a target frame from the window's current screen,
//  which is unstable/environment-dependent in a unit test host, so that
//  assertion is left to manual verification. Only the deterministic GUARD
//  side is covered here: while `trackedFullScreen` is true,
//  `processToggleMaximize` must not touch the window's frame at all.
//
//  NOTE: against today's empty stub, the test below is a currently-vacuous
//  pass -- "the frame didn't change" trivially holds when the stub does
//  nothing for ANY input. It stays in this suite as the regression guard
//  for once `processToggleMaximize` has a real body: a correct
//  implementation must check `trackedFullScreen` BEFORE calling
//  `performZoom`, and this is the only automatable way to verify that,
//  per this file's own note on why the positive case is manual-only.
//
//  `processToggleMaximize` takes no parameters and operates on `self
//  .window` directly, so it is called directly here, not via a posted
//  notification.
//
//  Coverage-gap follow-up: `registerNotificationObservers()` never
//  registered an observer for `.ghosttyToggleMaximize` either (see
//  CalyxWindowControllerSetTabTitleTests's own identically-worded
//  follow-up note), so ghostty's toggle_maximize keybind stayed silently
//  inert despite `process*` having a real body. The "Notification post
//  (Tactic A)" section below closes that gap for the MISFIRE side only --
//  a posted-for-own-surface positive test is deliberately NOT added here,
//  for the same `performZoom`-geometry-is-unstable-in-a-test-host reason
//  this file's own header already gives for skipping the "happy path"
//  above. Posting `.ghosttyToggleMaximize` for a surface no window owns
//  and asserting the frame doesn't move is still a meaningful regression
//  guard: it depends on `handleToggleMaximizeNotification`'s own `guard
//  findTab(for:) != nil` actually gating the dispatch, catching a future
//  implementation that skips the ownership check.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerToggleMaximizeTests: XCTestCase {

    private func makeController() -> CalyxWindowController {
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    func test_processToggleMaximize_whileTrackedFullScreen_doesNotChangeWindowFrame() {
        let controller = makeController()
        controller.trackedFullScreen = true
        let frameBefore = controller.window?.frame

        controller.processToggleMaximize()

        XCTAssertEqual(
            controller.window?.frame,
            frameBefore,
            "processToggleMaximize must not change the window frame while trackedFullScreen is true"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Unlike `makeController()` above, `findTab(for:)` needs a real
    /// `SurfaceRegistry` entry -- mirrors `CalyxWindowControllerCloseWindowTests
    /// .SurfaceOwningFixture`.
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
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SurfaceOwningFixture(controller: controller, surfaceView: surfaceView)
    }

    /// Regression guard (see this file's header for why this is the only
    /// notification-post test in this suite): posting `.ghosttyToggleMaximize`
    /// for a surface NO controller's `windowSession` owns must leave the
    /// window's frame unchanged.
    func test_ghosttyToggleMaximize_postedForSurfaceNoWindowOwns_doesNotChangeWindowFrame() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if findTab(for:)'s ownership
        // check were removed entirely.
        let fixture = makeSurfaceOwningFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)
        let frameBefore = fixture.controller.window?.frame

        NotificationCenter.default.post(name: .ghosttyToggleMaximize, object: orphanSurfaceView)

        XCTAssertEqual(
            fixture.controller.window?.frame,
            frameBefore,
            "Posting .ghosttyToggleMaximize for a surface no window owns must not change the window frame"
        )
    }
}
