//
//  CalyxWindowControllerHerdrAutoCloseTests.swift
//  CalyxTests
//
//  Herdr auto-close: a surface registered in
//  HerdrHostedSurfaces, or bridged via HerdrPaneRegistry, reports
//  GHOSTTY_ACTION_SHOW_CHILD_EXITED (`processChildExited`, wired from
//  `handleShowChildExitedNotification`) -- Calyx must automatically
//  close that pane instead of leaving ghostty's own "process exited"
//  banner up. herdr attach tabs run with wait-after-command forced on
//  (so ghostty itself never auto-closes the surface), and both a
//  herdr-hosted and a herdr-bridged surface are deliberately never
//  registered in SessionSurfaceMap, so SessionReconnectCoordinator
//  .childExited provably no-ops for either (see HerdrHostedSurfaces
//  .swift's header) -- there is no competing close/reconnect path.
//
//  Wiring-level coverage only (the pure decision itself is
//  HerdrChildExitedPolicyTests' job, not this file's): does
//  `processChildExited` consult that decision and take the right
//  branch for a herdr-hosted surface, a herdr-bridged surface, and a
//  plain surface.
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
//  herdr-hosted or herdr-bridged surface is NEVER in SessionSurfaceMap).
//  Neither leaf carries a SessionRef or a SessionSurfaceMap entry; each
//  test registers whichever leaf it needs with HerdrHostedSurfaces or
//  HerdrPaneRegistry (`.shared` in both cases -- production hardcodes
//  the shared instance at this call site, so a test cannot inject a
//  throwaway one instead). Two panes (not one) keep
//  `closeSurfaceAndCleanUp`'s tab/window-removal cascade out of play,
//  mirroring TwoPaneSessionFixture's own documented reasoning.
//
//  Coverage:
//  - A herdr-hosted surface's child-exited event fires
//    `_herdrHostedAutoCloseObserverForTesting` with its surfaceID AND
//    actually closes the pane (removed from the split tree) --
//    CURRENTLY FAILS: `processChildExited` does not yet consult
//    HerdrHostedSurfaces/HerdrChildExitedPolicy at all, so neither the
//    observer fires nor does the leaf ever get removed.
//  - A herdr-bridged surface's child-exited event fires the same
//    observer, closes the pane, and prunes its HerdrPaneRegistry entry
//    (`isBridgeSurface` reads false afterward) through the same
//    `closeSurfaceAndCleanUp` path a Cmd+W close of a bridged pane
//    already uses. `herdrTabCoordinator` is nil in this test host, so
//    the coordinator hop that path would otherwise take is untaken here
//    -- that hop's own transport silence is HerdrTabCoordinatorTests'
//    job, not this file's.
//  - Neither case ever fires `_killSessionIfPersistentRouteObserverForTesting`
//    -- closing a herdr pane must not kill anything herdr-side (the
//    child process is already dead, nothing left to signal). Passes
//    today incidentally (nothing kills an untracked surface either),
//    kept as a direct pin on that requirement.
//  - A plain (neither hosted nor bridged) surface's child-exited event
//    must NOT fire the herdr auto-close observer, must NOT close the
//    pane, and must still defer to the existing childExitedTasks/
//    sessionReconnectCoordinator path (a Task is still inserted,
//    mirroring CalyxWindowControllerChildExitedTasksTests) -- baseline/
//    negative coverage, passes today since that existing path is
//    untouched.
//
//  The herdr-hosted and plain tests each `await`
//  `_childExitedTasksForTesting[leafID]?.value` (nil-safe: instant
//  no-op once the implementation returns before ever inserting a Task
//  for an auto-close branch, harmlessly drains the real Task in the
//  meantime under the plain-surface path) rather than assuming either a
//  synchronous or an asynchronous completion timing. The bridged test
//  instead reads `_childExitedTasksForTesting[leafID]` directly, with
//  no `await`: every auto-close branch returns synchronously, so no
//  Task is ever inserted to wait on.
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

    /// Set by the bridged-surface test right after registering with
    /// `HerdrPaneRegistry.shared` (production hardcodes `.shared`, so
    /// this file cannot inject a throwaway registry instead), and
    /// unregistered in `tearDown` -- a defensive backstop for a failed
    /// assertion leaving a real entry behind for a later test; the
    /// close path under test is expected to have already unregistered
    /// it by then.
    private var registeredBridgeSurfaceIDForCleanup: UUID?

    /// Two untracked panes -- neither carries a `SessionRef` nor a
    /// `SessionSurfaceMap` entry, matching the permanent invariant that
    /// a herdr-hosted or herdr-bridged surface is never in
    /// `SessionSurfaceMap` (see this file's header). Which leaf (if any)
    /// is herdr-hosted or herdr-bridged is decided per test, via
    /// `HerdrHostedSurfaces.shared.register(_:)` or
    /// `HerdrPaneRegistry.shared.register(surfaceID:ref:)`.
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
        if let id = registeredBridgeSurfaceIDForCleanup {
            HerdrPaneRegistry.shared.unregister(surfaceID: id)
            registeredBridgeSurfaceIDForCleanup = nil
        }
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

    // MARK: - herdr-bridged surface -> auto-close, and unregistered from HerdrPaneRegistry

    func test_processChildExited_bridgedSurface_firesAutoCloseObserver_andClosesThePane_andUnregistersFromHerdrPaneRegistry() {
        let fixture = makeFixture()
        HerdrPaneRegistry.shared.startObserving()
        let ref = HerdrPaneRef(socketPath: "/tmp/calyx-herdr-bridge-autoclose-test.sock", paneID: "wZ:p1")
        HerdrPaneRegistry.shared.register(surfaceID: fixture.ordinaryLeafID, ref: ref)
        registeredBridgeSurfaceIDForCleanup = fixture.ordinaryLeafID
        var observedSurfaceID: UUID?
        fixture.controller._herdrHostedAutoCloseObserverForTesting = { observedSurfaceID = $0 }
        var killObserverFired = false
        fixture.controller._killSessionIfPersistentRouteObserverForTesting = { _, _ in killObserverFired = true }

        fixture.controller.processChildExited(surfaceView: fixture.ordinarySurfaceView)

        XCTAssertEqual(observedSurfaceID, fixture.ordinaryLeafID,
                       "A herdr-bridged surface's child-exited event must fire the auto-close observer " +
                       "with its surfaceID")
        XCTAssertNil(fixture.controller._childExitedTasksForTesting[fixture.ordinaryLeafID],
                    "A herdr-bridged surface's child-exited event must return before the " +
                    "childExitedTasks Task insert, never reaching sessionReconnectCoordinator")
        XCTAssertFalse(fixture.tab.splitTree.allLeafIDs().contains(fixture.ordinaryLeafID),
                       "A herdr-bridged surface's child-exited event must close the pane -- its attach " +
                       "client is gone, herdr sends no pane.closed for a client-side exit, and nothing " +
                       "else would ever close it")
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(fixture.herdrLeafID),
                     "The sibling pane must remain untouched")
        XCTAssertFalse(killObserverFired,
                       "Closing a herdr-bridged pane must never kill anything herdr-side -- the attach " +
                       "process is already dead, there is nothing left to signal")
        XCTAssertFalse(HerdrPaneRegistry.shared.isBridgeSurface(fixture.ordinaryLeafID),
                      "Closing a herdr-bridged pane must prune its HerdrPaneRegistry entry through the " +
                      "same close path a Cmd+W close of a bridged pane already uses")
    }

    // MARK: - plain surface -> defer to existing behavior (baseline, may PASS)

    func test_processChildExited_nonHostedSurface_doesNotFireAutoCloseObserver_stillDefersToExistingPath() async {
        let fixture = makeFixture()
        // Deliberately no HerdrHostedSurfaces/HerdrPaneRegistry registration for either leaf.
        var observedSurfaceID: UUID?
        fixture.controller._herdrHostedAutoCloseObserverForTesting = { observedSurfaceID = $0 }

        fixture.controller.processChildExited(surfaceView: fixture.ordinarySurfaceView)

        let task = fixture.controller._childExitedTasksForTesting[fixture.ordinaryLeafID]
        XCTAssertNotNil(task,
                        "A plain surface must still defer to the existing childExitedTasks/" +
                        "sessionReconnectCoordinator path, unmodified -- precondition for the rest of " +
                        "this test")
        await task?.value

        XCTAssertNil(observedSurfaceID,
                    "A plain surface's child-exited event must never fire the herdr auto-close observer")
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(fixture.ordinaryLeafID),
                     "A plain surface must not be auto-closed by this path -- it has no tracked " +
                     "session, so the existing sessionReconnectCoordinator path also leaves it alone, " +
                     "exactly as it does today")
    }
}
