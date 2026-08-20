//
//  CalyxWindowControllerToggleCommandPaletteTests.swift
//  CalyxTests
//
//  Missing observer: 
//  `GhosttyActionRouter.handleAction` still lists
//  `GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE` in its "Known but unimplemented"
//  group (`return false`, GhosttyAction.swift) -- ghostty's default
//  toggle_command_palette keybind does nothing.
//  `CalyxWindowController.processToggleCommandPalette()` is the intended
//  receiver once a `.ghosttyToggleCommandPalette` case/observer exists;
//  today it is an intentional no-op stub (see its own doc comment in
//  CalyxWindowController.swift), so the test below -- which expects
//  `windowSession.showCommandPalette` to actually flip -- fails.
//
//  `processToggleCommandPalette` takes no parameters and has no
//  ownership/routing logic of its own (intended to just delegate to the
//  existing `toggleCommandPalette()`), so it is called directly here, not
//  via a posted notification.
//
//  Coverage-gap follow-up: see CalyxWindowControllerSetTabTitleTests's own
//  identically-worded follow-up note -- `registerNotificationObservers()`
//  never registered an observer for `.ghosttyToggleCommandPalette` either,
//  so toggle_command_palette stayed silently inert despite `process*`
//  having a real body. The "Notification post (Tactic A)" section below
//  closes the gap and covers the fix.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerToggleCommandPaletteTests: XCTestCase {

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

    /// First call must SHOW the palette; a second call must HIDE it again
    /// -- a true toggle, not a one-way "always show".
    func test_processToggleCommandPalette_togglesShowCommandPalette() {
        let controller = makeController()
        XCTAssertFalse(controller.windowSession.showCommandPalette, "Precondition: palette starts hidden")

        controller.processToggleCommandPalette()
        XCTAssertTrue(
            controller.windowSession.showCommandPalette,
            "The first call to processToggleCommandPalette must show the command palette"
        )

        controller.processToggleCommandPalette()
        XCTAssertFalse(
            controller.windowSession.showCommandPalette,
            "The second call to processToggleCommandPalette must hide the command palette again"
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

    /// Posting the real `.ghosttyToggleCommandPalette` notification for a
    /// surface THIS window owns must show the command palette -- exercises
    /// `handleToggleCommandPaletteNotification`'s `findTab(for:)` routing
    /// end to end, not just `processToggleCommandPalette` called directly.
    func test_ghosttyToggleCommandPalette_postedForOwnSurface_showsCommandPalette() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertFalse(fixture.controller.windowSession.showCommandPalette, "Precondition: palette starts hidden")

        NotificationCenter.default.post(name: .ghosttyToggleCommandPalette, object: fixture.surfaceView)

        XCTAssertTrue(
            fixture.controller.windowSession.showCommandPalette,
            "Posting .ghosttyToggleCommandPalette for a surface this window owns must show the command palette"
        )
    }

    /// Regression guard: posting `.ghosttyToggleCommandPalette` for a
    /// surface NO controller's `windowSession` owns must leave
    /// `showCommandPalette` untouched -- depends on
    /// `handleToggleCommandPaletteNotification`'s own `guard findTab(for:)
    /// != nil` actually gating the dispatch.
    func test_ghosttyToggleCommandPalette_postedForSurfaceNoWindowOwns_doesNotShowCommandPalette() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if findTab(for:)'s ownership
        // check were removed entirely.
        let fixture = makeSurfaceOwningFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)
        XCTAssertFalse(fixture.controller.windowSession.showCommandPalette, "Precondition: palette starts hidden")

        NotificationCenter.default.post(name: .ghosttyToggleCommandPalette, object: orphanSurfaceView)

        XCTAssertFalse(
            fixture.controller.windowSession.showCommandPalette,
            "Posting .ghosttyToggleCommandPalette for a surface no window owns must not show the command palette"
        )
    }
}
