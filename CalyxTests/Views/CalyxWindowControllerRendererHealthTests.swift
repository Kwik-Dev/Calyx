//
//  CalyxWindowControllerRendererHealthTests.swift
//  CalyxTests
//
//  TDD RED phase, missing-observer investigation: `GhosttyActionRouter
//  .handleRendererHealth` (GhosttyAction.swift) posts
//  `.ghosttyRendererHealth` for every `GHOSTTY_ACTION_RENDERER_HEALTH`
//  action, but no observer has ever been registered for it — a renderer
//  reporting itself unhealthy is silently ignored.
//  `CalyxWindowController.processRendererHealth(surfaceView:healthy:)` is
//  the intended receiver once that observer exists; today it is an
//  intentional no-op stub, called directly here (this file only tests
//  the flag-setting contract, not notification routing).
//
//  `ghostty_action_renderer_health_e` (ghostty.h) has two cases:
//  `GHOSTTY_RENDERER_HEALTH_HEALTHY` / `GHOSTTY_RENDERER_HEALTH_UNHEALTHY`;
//  the not-yet-written notification handler is expected to translate
//  that into this method's plain `Bool healthy` parameter.
//
//  A single test suffices (per the investigation's own scope): receiving
//  `healthy: false` must flip `SurfaceView.isRendererHealthy` to `false`.
//
//  Coverage-gap follow-up (code review): the test above only calls
//  `processRendererHealth` directly, never exercising
//  `handleRendererHealthNotification`'s own `findTab(for:)` routing / the
//  real `.ghosttyRendererHealth` notification wiring. The "Notification
//  post" section below closes that gap.
//
//  Unlike its siblings (`CalyxWindowControllerCloseTabTests`/
//  `CloseWindowTests`/`InitialSizeTests`/`ToggleFullscreenTests`), this
//  file's regression guard is NOT an "other window's surface" test:
//  `processRendererHealth(surfaceView:healthy:)` mutates the passed-in
//  `surfaceView` directly, not any window/group-scoped state, so posting
//  for a DIFFERENT window's surface would never touch THIS window's
//  surface either way — that assertion would hold regardless of whether
//  `findTab(for:)`'s ownership check is even present, making it a vacuous
//  test. Posting for a surface NO controller owns at all is the
//  meaningful regression guard instead: it actually depends on
//  `handleRendererHealthNotification`'s `guard findTab(for:) != nil`
//  gating the mutation.

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerRendererHealthTests: XCTestCase {

    /// Minimal controller fixture: `processRendererHealth` has no
    /// ownership/routing logic of its own (that lives in the
    /// not-yet-written notification handler), so the surface under test
    /// does not need to belong to this controller's `windowSession` at
    /// all. Mirrors `CalyxWindowControllerFullScreenTests.makeController()`.
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

    /// `processRendererHealth(surfaceView:healthy: false)` must set
    /// `surfaceView.isRendererHealthy` to `false`. Against the current
    /// no-op stub, `isRendererHealthy` never leaves its default (`true`),
    /// so this fails.
    func test_processRendererHealth_unhealthy_setsIsRendererHealthyFalse() {
        let controller = makeController()
        let surfaceView = SurfaceView(frame: .zero)
        XCTAssertTrue(surfaceView.isRendererHealthy, "Precondition: a freshly created SurfaceView must default to healthy")

        controller.processRendererHealth(surfaceView: surfaceView, healthy: false)

        XCTAssertFalse(
            surfaceView.isRendererHealthy,
            "processRendererHealth(surfaceView:healthy: false) must flip isRendererHealthy to false"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Unlike `makeController()` above, `findTab(for:)` needs a real
    /// `SurfaceRegistry` entry — mirrors `CalyxWindowControllerCloseWindowTests
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

    /// Posting the real `.ghosttyRendererHealth` notification for a
    /// surface THIS window owns must flip `isRendererHealthy` — exercises
    /// `handleRendererHealthNotification`'s `findTab(for:)` routing and
    /// `userInfo["health"]` extraction end to end, not just
    /// `processRendererHealth` called directly.
    func test_ghosttyRendererHealth_postedForOwnSurface_setsIsRendererHealthyFalse() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertTrue(fixture.surfaceView.isRendererHealthy, "Precondition: a freshly created SurfaceView must default to healthy")

        NotificationCenter.default.post(
            name: .ghosttyRendererHealth,
            object: fixture.surfaceView,
            userInfo: ["health": GHOSTTY_RENDERER_HEALTH_UNHEALTHY]
        )

        XCTAssertFalse(
            fixture.surfaceView.isRendererHealthy,
            "Posting .ghosttyRendererHealth(unhealthy) for a surface this window owns must flip isRendererHealthy to false"
        )
    }

    /// Regression guard (see this file's header for why this is "no
    /// owner" rather than "a different window's owned surface"): posting
    /// `.ghosttyRendererHealth` for a surface NO controller's
    /// `windowSession` owns must leave `isRendererHealthy` untouched —
    /// this depends on `handleRendererHealthNotification`'s own
    /// `guard findTab(for:) != nil` actually gating the dispatch.
    func test_ghosttyRendererHealth_postedForSurfaceNoWindowOwns_doesNotChangeIsRendererHealthy() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if findTab(for:)'s ownership
        // check were removed entirely.
        _ = makeSurfaceOwningFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)
        XCTAssertTrue(orphanSurfaceView.isRendererHealthy, "Precondition: a freshly created SurfaceView must default to healthy")

        NotificationCenter.default.post(
            name: .ghosttyRendererHealth,
            object: orphanSurfaceView,
            userInfo: ["health": GHOSTTY_RENDERER_HEALTH_UNHEALTHY]
        )

        XCTAssertTrue(
            orphanSurfaceView.isRendererHealthy,
            "Posting .ghosttyRendererHealth for a surface no window owns must not change isRendererHealthy"
        )
    }
}
