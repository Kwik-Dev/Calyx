//
//  CalyxWindowControllerHerdrAutoCloseTests.swift
//  CalyxTests
//
//  TDD Red Phase (herdr Stage 1): a surface registered in
//  HerdrHostedSurfaces reports GHOSTTY_ACTION_SHOW_CHILD_EXITED
//  (`processChildExited`, wired from `handleShowChildExitedNotification`)
//  -- Calyx must automatically close that pane instead of leaving
//  ghostty's own "process exited" banner up. herdr attach tabs run with
//  wait-after-command forced on (so ghostty itself never auto-closes
//  the surface), and the surface is deliberately never registered in
//  SessionSurfaceMap, so SessionReconnectCoordinator.childExited
//  provably no-ops for it (see HerdrHostedSurfaces.swift's header) --
//  there is no competing close/reconnect path.
//
//  Wiring-level coverage only (the pure herdr-hosted/not-hosted
//  decision itself is HerdrChildExitedPolicyTests' job, not this
//  file's): does `processChildExited` consult that decision and take
//  the right branch for a herdr-hosted vs. a non-hosted surface.
//
//  Drives `processChildExited(surfaceView:)` directly, exactly like
//  CalyxWindowControllerChildExitedTasksTests, rather than posting the
//  real `.ghosttyShowChildExited` notification -- avoids also having to
//  attach the fixture's SurfaceView into the real window's view
//  hierarchy to satisfy `handleShowChildExitedNotification`'s
//  `belongsToThisWindow` guard.
//
//  Fixture: a fresh two-pane/single-tab/single-group window (built
//  locally, NOT via TwoPaneSessionFixture.swift's makeTwoPaneSessionFixture:
//  that fixture registers a SessionRef + SessionSurfaceMap entry for its
//  tracked leaf, which would contradict the herdr invariant that a
//  herdr-hosted surface is NEVER in SessionSurfaceMap). Neither leaf
//  carries a SessionRef or a SessionSurfaceMap entry; only the
//  `herdrLeafID` pane is registered with HerdrHostedSurfaces per test.
//  Two panes (not one) keep `closeSurfaceAndCleanUp`'s tab/window-removal
//  cascade out of play, mirroring TwoPaneSessionFixture's own documented
//  reasoning.
//
//  Coverage:
//  - A herdr-hosted surface's child-exited event fires
//    `_herdrHostedAutoCloseObserverForTesting` with its surfaceID AND
//    actually closes the pane (removed from the split tree) --
//    CURRENTLY FAILS: `processChildExited` does not yet consult
//    HerdrHostedSurfaces/HerdrChildExitedPolicy at all, so neither the
//    observer fires nor does the leaf ever get removed.
//  - ...and never fires `_killSessionIfPersistentRouteObserverForTesting`
//    -- closing a herdr pane must not kill anything herdr-side (the
//    child process is already dead, nothing left to signal). Passes
//    today incidentally (nothing kills an untracked surface either),
//    kept as a direct pin on that requirement for the eventual
//    implementation.
//  - A non-hosted (ordinary) surface's child-exited event must NOT fire
//    the herdr auto-close observer, must NOT close the pane, and must
//    still defer to the existing childExitedTasks/
//    sessionReconnectCoordinator path (a Task is still inserted,
//    mirroring CalyxWindowControllerChildExitedTasksTests) -- baseline/
//    negative coverage, passes today since that existing path is
//    untouched.
//
//  Both tests `await` `_childExitedTasksForTesting[leafID]?.value`
//  (nil-safe: instant no-op once the implementation returns before ever
//  inserting a Task for the herdr-hosted branch, harmlessly drains the
//  real Task in the meantime under today's unmodified code) rather than
//  assuming either a synchronous or an asynchronous completion timing.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerHerdrAutoCloseTests: XCTestCase {

    private struct TwoPaneNoSessionFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let herdrLeafID: UUID
        let herdrSurfaceView: SurfaceView
        let ordinaryLeafID: UUID
        let ordinarySurfaceView: SurfaceView
    }

    /// Two untracked panes -- neither carries a `SessionRef` nor a
    /// `SessionSurfaceMap` entry, matching the permanent invariant that
    /// a herdr-hosted surface is never in `SessionSurfaceMap` (see this
    /// file's header). Which leaf (if either) is herdr-hosted is decided
    /// per test via `HerdrHostedSurfaces.shared.register(_:)`.
    private func makeFixture() -> TwoPaneNoSessionFixture {
        let registry = SurfaceRegistry()
        let herdrLeafID = UUID()
        let ordinaryLeafID = UUID()
        let herdrSurfaceView = SurfaceView(frame: .zero)
        let ordinarySurfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: herdrSurfaceView, id: herdrLeafID)
        registry._testInsert(view: ordinarySurfaceView, id: ordinaryLeafID)

        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: herdrLeafID),
            second: .leaf(id: ordinaryLeafID)
        ))
        let tab = Tab(splitTree: SplitTree(root: root, focusedLeafID: herdrLeafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return TwoPaneNoSessionFixture(
            controller: controller, tab: tab,
            herdrLeafID: herdrLeafID, herdrSurfaceView: herdrSurfaceView,
            ordinaryLeafID: ordinaryLeafID, ordinarySurfaceView: ordinarySurfaceView
        )
    }

    // async throws (not the plain synchronous overload) -- required to
    // call HerdrHostedSurfaces.shared._testReset() (itself @MainActor)
    // from this @MainActor class, mirroring
    // AppDelegateOpenHerdrAttachTabTests' identical precedent (verified
    // there: the plain sync overload does not compile for this).
    override func setUp() async throws {
        try await super.setUp()
        HerdrHostedSurfaces.shared._testReset()
    }

    override func tearDown() async throws {
        HerdrHostedSurfaces.shared._testReset()
        try await super.tearDown()
    }

    // MARK: - herdr-hosted surface -> auto-close (core behavior, must FAIL)

    func test_processChildExited_herdrHostedSurface_firesAutoCloseObserver_andClosesThePane() async {
        let fixture = makeFixture()
        HerdrHostedSurfaces.shared.register(fixture.herdrLeafID)
        var observedSurfaceID: UUID?
        fixture.controller._herdrHostedAutoCloseObserverForTesting = { observedSurfaceID = $0 }
        var killObserverFired = false
        fixture.controller._killSessionIfPersistentRouteObserverForTesting = { _, _ in killObserverFired = true }

        fixture.controller.processChildExited(surfaceView: fixture.herdrSurfaceView)
        await fixture.controller._childExitedTasksForTesting[fixture.herdrLeafID]?.value

        XCTAssertEqual(observedSurfaceID, fixture.herdrLeafID,
                       "A herdr-hosted surface's child-exited event must fire the auto-close observer " +
                       "with its surfaceID")
        XCTAssertFalse(fixture.tab.splitTree.allLeafIDs().contains(fixture.herdrLeafID),
                       "A herdr-hosted surface's child-exited event must close the pane -- " +
                       "SessionReconnectCoordinator provably no-ops for it (never registered in " +
                       "SessionSurfaceMap), so nothing else would ever close it, leaving ghostty's own " +
                       "\"process exited\" banner up forever")
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(fixture.ordinaryLeafID),
                     "The sibling (non-herdr) pane must remain untouched")
        XCTAssertFalse(killObserverFired,
                       "Closing a herdr-hosted pane must never kill anything herdr-side -- the child " +
                       "process is already dead, there is nothing left to signal")
    }

    // MARK: - non-hosted surface -> defer to existing behavior (baseline, may PASS)

    func test_processChildExited_nonHostedSurface_doesNotFireAutoCloseObserver_stillDefersToExistingPath() async {
        let fixture = makeFixture()
        // Deliberately no HerdrHostedSurfaces registration for either leaf.
        var observedSurfaceID: UUID?
        fixture.controller._herdrHostedAutoCloseObserverForTesting = { observedSurfaceID = $0 }

        fixture.controller.processChildExited(surfaceView: fixture.ordinarySurfaceView)

        let task = fixture.controller._childExitedTasksForTesting[fixture.ordinaryLeafID]
        XCTAssertNotNil(task,
                        "A non-hosted surface must still defer to the existing childExitedTasks/" +
                        "sessionReconnectCoordinator path, unmodified -- precondition for the rest of " +
                        "this test")
        await task?.value

        XCTAssertNil(observedSurfaceID,
                    "A non-hosted surface's child-exited event must never fire the herdr auto-close " +
                    "observer")
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(fixture.ordinaryLeafID),
                     "A non-hosted surface must not be auto-closed by this path -- it has no tracked " +
                     "session, so the existing sessionReconnectCoordinator path also leaves it alone, " +
                     "exactly as it does today")
    }
}
