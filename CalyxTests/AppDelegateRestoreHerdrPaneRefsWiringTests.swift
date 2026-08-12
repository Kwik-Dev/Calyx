//
//  AppDelegateRestoreHerdrPaneRefsWiringTests.swift
//  CalyxTests
//
//  Integration coverage for the AppDelegate-level glue that wires
//  HerdrRestoreCommandPolicy and Tab.herdrPaneRefs together in
//  production. HerdrRestoreCommandPolicy itself is thoroughly
//  unit-tested in isolation (RestoreHerdrPaneRefsTests.swift), and
//  Tab.herdrPaneRefs / TabSnapshot.herdrPaneRefs round-tripping is
//  thoroughly tested at the model level (TabSnapshotHerdrRefsTests.swift),
//  but neither exercises the actual GLUE in
//  AppDelegate.createSurfaceWithPwd / restoreTabSurfaces that wires them
//  together. Mirrors
//  AppDelegateRestoreTabSurfacesOwnershipTests.swift's own driving style
//  (a real AppDelegate, `_createSurfaceWithPwdHookForTesting` standing in
//  for the one actually-unsafe call -- a real ghostty surface -- with
//  everything else, including the herdr consultation and pruning under
//  test, real, unmodified production code).
//
//  SCOPE, DELIBERATELY NARROWED (see this file's own coverage below):
//  only the `.plainShellAndPrune` outcome is exercised here.
//  `HerdrRestoreCommandPolicy.decide`'s `.bridgeCommand` outcome requires
//  BOTH a herdr binary `AppDelegate`'s own `herdrBinaryResolver` can
//  actually resolve (a real, uninjectable `HerdrBinaryResolver()`
//  instance reading this process's real environment/PATH -- no seam
//  exists on `AppDelegate` to fake it) AND a genuinely alive herdr
//  socket (`HerdrSessionDiscovery.isAlive`'s own real, non-blocking BSD
//  `connect()` probe) -- neither is available hermetically without
//  either depending on ambient machine state (herdr actually installed)
//  or adding new `AppDelegate` injection seams, both out of this fix's
//  own scope. Reaching that leg via a `CALYX_HERDR_BIN` environment
//  override plus a real bound socket was considered and rejected: the
//  override is read once, at `AppDelegate`'s own `herdrBinaryResolver`
//  property-initialization time, from `ProcessInfo.processInfo
//  .environment` (a live, global, mutable snapshot of this whole
//  process's environment) -- an ambient, order-dependent dependency this
//  project's own testing discipline avoids elsewhere (`HerdrBinaryResolver`'s
//  own doc comment: "tests never depend on this machine's actual PATH").
//  That leg -- `HerdrPaneRegistry.shared` actually being registered on a
//  successful bridge, and a SURVIVING (not pruned) `herdrPaneRefs` entry
//  being re-keyed to the new surface UUID -- is left to the E2E suite,
//  per this project's own "a feature that talks to an external process
//  is not done until production code has talked to the real one" rule.
//
//  A dead socket path (guaranteed: nothing is listening at a freshly
//  generated temp path this test never binds) makes
//  `HerdrRestoreCommandPolicy.decide`'s own `isSocketAlive` gate fail
//  deterministically regardless of whether herdr happens to be
//  installed on the machine running this suite -- see that method's own
//  header: `herdrBinPath` unresolvable OR the socket dead OR an invalid
//  pane id all fall through to the SAME `.plainShellAndPrune` outcome.
//
//  Coverage:
//  - restoreTabSurfaces, given a Tab whose one leaf carries a
//    HerdrPaneRef pointing at a dead socket: the restore still succeeds
//    (falls through to an ordinary passthrough shell surface), and
//    tab.herdrPaneRefs ends up EMPTY afterward -- proving
//    HerdrRestoreCommandPolicy.decide's .plainShellAndPrune outcome
//    actually reaches Tab.pruneHerdrPaneRefs through the REAL
//    createSurfaceWithPwd call path, not just as a standalone pure
//    function.
//  - The same restore never registers the leaf's surface with
//    HerdrPaneRegistry.shared -- registration is gated on .bridgeCommand
//    only, never .plainShellAndPrune.
//  - The same restore also never triggers an adoptRestoredTab call to
//    HerdrTabCoordinator (observed via
//    _restoreTabSurfacesHerdrAdoptionObserverForTesting) -- adoption is
//    gated on a surviving herdrPaneRefs entry, and .plainShellAndPrune
//    leaves none.
//  - restoreTabSurfaces, given a tab whose herdrPaneRefs carries a
//    surviving (bridged) entry once the restore completes: computes
//    exactly one adoption carrying the workspace id parsed from the
//    surviving ref's own pane id, its socket path, the tab's own id, and
//    the surviving herdrPaneRefs pairs verbatim (this AppDelegate never
//    has a herdrTabCoordinator, so this specifically exercises the
//    queueing branch -- see the two tests below for the direct branch
//    and for a queued entry actually being flushed to a real
//    coordinator).
//  - restoreTabSurfaces, with a coordinator already set via
//    _setHerdrTabCoordinatorForTesting before the restore runs: the
//    surviving entry's adoption reaches that REAL HerdrTabCoordinator
//    directly and synchronously, with nothing queued.
//  - restoreTabSurfaces, with no coordinator set: the surviving entry's
//    adoption is queued, is not yet visible to a coordinator created
//    afterward, and becomes visible (workspace id, socket path, AND the
//    exact paneRefs -- proven by closing the specific pane they name)
//    the moment _setHerdrTabCoordinatorForTesting flushes the queue.
//  - a queue already flushed into one coordinator is cleared: a SECOND
//    coordinator set afterward never sees the same entry replayed into
//    it.
//  - a tab restored with no herdrPaneRefs at all (never populated, not
//    merely pruned to empty) never queues or directly triggers an
//    adoption.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

// MARK: - Fakes

/// `HerdrNativeSurfaceFactory` fake for this file's own
/// `makeCoordinator(registry:)` -- see that method's own doc comment for
/// why both methods are unreachable no-ops here.
@MainActor
private final class NoopHerdrNativeSurfaceFactory: HerdrNativeSurfaceFactory {
    func createSurface(command: String) -> UUID? { nil }
    func destroySurface(_ id: UUID) {}
}

/// `HerdrNativeTabAttacher` fake for the same coordinator construction.
/// `closeLeaf` is the one method actually reachable here, indirectly, via
/// `handlePaneClosed` in the pending-adoption flush test below.
@MainActor
private final class NoopHerdrNativeTabAttacher: HerdrNativeTabAttacher {
    func attachTab(plan: HerdrNativeTabPlan) -> Bool { false }
    func focusExistingTab(withWorkspaceID workspaceID: String, socketPath: String) -> Bool { false }
    func updateRatio(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double) {}
    func closeLeaf(_ id: UUID) {}
}

@MainActor
final class AppDelegateRestoreHerdrPaneRefsWiringTests: XCTestCase {

    /// Never dereferenced: every call this test drives through
    /// createSurfaceWithPwd is intercepted by
    /// _createSurfaceWithPwdHookForTesting before the real ghostty FFI
    /// call that would otherwise use this value -- mirrors
    /// AppDelegateRestoreTabSurfacesOwnershipTests.swift's own identical
    /// precedent and its own doc comment on why.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    private func makeWindow() -> NSWindow {
        CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    /// A real `HerdrTabCoordinator`, so the queueing/flush tests below
    /// can observe an actual `adoptRestoredTab` delivery (via
    /// `hasOpenTab`/`handlePaneClosed`) rather than only the computed
    /// arguments `_restoreTabSurfacesHerdrAdoptionObserverForTesting`
    /// already proves. `adoptRestoredTab` itself never touches
    /// `transportFactory`/`surfaceFactory`/`attacher` (its own doc
    /// comment: "sending herdr nothing and creating no surface"), so
    /// `NoopHerdrNativeSurfaceFactory`/`NoopHerdrNativeTabAttacher` below
    /// stand in as unreachable no-ops -- mirrors
    /// HerdrTabCoordinatorTests.swift's own "fresh, file-scoped private
    /// redeclaration" precedent (that file's own SpyHerdrTransportFactory
    /// doc comment) rather than sharing fakes across files.
    private func makeCoordinator(registry: HerdrPaneRegistry) -> HerdrTabCoordinator {
        HerdrTabCoordinator(
            transportFactory: LiveHerdrTransportFactory(),
            herdrBinPath: "/dummy/bin/herdr",
            registry: registry,
            surfaceFactory: NoopHerdrNativeSurfaceFactory(),
            attacher: NoopHerdrNativeTabAttacher()
        )
    }

    func test_restoreTabSurfaces_herdrPaneRefWithDeadSocket_prunesRefAndRestoresPlainShell_neverRegistersInHerdrPaneRegistry() {
        let appDelegate = AppDelegate()

        let leafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            oldLeafID == leafID ? newSurfaceID : nil
        }
        var adoptionCallCount = 0
        appDelegate._restoreTabSurfacesHerdrAdoptionObserverForTesting = { _, _, _, _ in adoptionCallCount += 1 }

        // A syntactically valid but definitely-dead pane ref: nothing in
        // this test (or any other) ever binds a socket at this freshly
        // generated temp path, so HerdrSessionDiscovery.isAlive's own
        // real, non-blocking connect() probe fails deterministically,
        // regardless of whether herdr itself happens to be installed on
        // the machine running this suite.
        let deadSocketPath = "/tmp/calyx-herdr-wiring-test-\(UUID().uuidString)/herdr.sock"
        let herdrRef = HerdrPaneRef(socketPath: deadSocketPath, paneID: "wF:p1")
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.herdrPaneRefs = [leafID: herdrRef]

        let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())

        XCTAssertTrue(
            restored, "a leaf whose herdr ref can never be reattached (dead socket) must still restore " +
            "successfully, as an ordinary passthrough shell"
        )
        XCTAssertTrue(
            tab.herdrPaneRefs.isEmpty,
            "HerdrRestoreCommandPolicy.decide's .plainShellAndPrune outcome must actually reach " +
            "Tab.pruneHerdrPaneRefs through the real createSurfaceWithPwd call path -- a stale ref must not " +
            "linger to be written back out by the next snapshot"
        )
        XCTAssertNil(
            HerdrPaneRegistry.shared.paneRef(forSurfaceID: newSurfaceID),
            "a .plainShellAndPrune outcome must never register the restored surface with HerdrPaneRegistry -- " +
            "registration is gated on .bridgeCommand only"
        )
        XCTAssertFalse(HerdrPaneRegistry.shared.isBridgeSurface(newSurfaceID))
        XCTAssertEqual(
            adoptionCallCount, 0,
            "a tab whose herdrPaneRefs all degraded to plain shells must never trigger an adoptRestoredTab call"
        )
    }

    /// Pins the OTHER half of the adoption trigger: a tab whose
    /// `herdrPaneRefs` still carries a SURVIVING entry once
    /// `restoreTabSurfaces` completes must have its adoption computed
    /// exactly once, with the right arguments -- observed via
    /// `_restoreTabSurfacesHerdrAdoptionObserverForTesting` rather than
    /// `herdrTabCoordinator` itself (this `AppDelegate` never gets one,
    /// so this exercises the queueing branch specifically: the entry
    /// lands in `pendingHerdrTabAdoptions`, not a direct
    /// `adoptRestoredTab` call. See
    /// `test_restoreTabSurfaces_coordinatorAlreadyExists_...` below for
    /// the direct branch, and
    /// `test_restoreTabSurfaces_noCoordinatorYet_...` for this same
    /// queued entry actually reaching a real coordinator once one is
    /// created).
    ///
    /// `survivingSurfaceID` is deliberately NOT `leafID` (not a real
    /// split-tree leaf at all): `restoreTabSurfaces`' own per-leaf loop
    /// only ever consults/prunes `tab.herdrPaneRefs[oldLeafID]` for an
    /// `oldLeafID` actually in `tab.splitTree.allLeafIDs()`, and
    /// `remappingKeys(_:)` leaves a key absent from its own mapping
    /// untouched -- so this entry survives the whole call exactly like a
    /// real `.bridgeCommand`-outcome leaf's own (already re-keyed to its
    /// new surface id) ref would, without needing a live herdr binary or
    /// an alive socket -- neither is available hermetically here (this
    /// file's own header).
    func test_restoreTabSurfaces_tabWithSurvivingBridgedHerdrPaneRef_triggersExactlyOneAdoptionCall_withWorkspaceIDSocketPathTabIDAndPaneRefs() {
        let appDelegate = AppDelegate()

        let leafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            oldLeafID == leafID ? newSurfaceID : nil
        }

        let survivingSurfaceID = UUID()
        let survivingRef = HerdrPaneRef(
            socketPath: "/tmp/calyx-herdr-wiring-test-\(UUID().uuidString)/herdr.sock", paneID: "wR:p9"
        )
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.herdrPaneRefs = [survivingSurfaceID: survivingRef]

        var observedCalls: [(workspaceID: String, socketPath: String, tabID: UUID, paneRefs: [UUID: HerdrPaneRef])] = []
        appDelegate._restoreTabSurfacesHerdrAdoptionObserverForTesting = { workspaceID, socketPath, tabID, paneRefs in
            observedCalls.append((workspaceID: workspaceID, socketPath: socketPath, tabID: tabID, paneRefs: paneRefs))
        }

        let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())

        XCTAssertTrue(restored, "the tab's own real leaf restores as an ordinary passthrough shell, unaffected by the dangling ref")
        XCTAssertEqual(
            observedCalls.count, 1,
            "a restored tab with a surviving bridged herdr leaf must trigger exactly one adoption call"
        )
        guard let call = observedCalls.first else { return }
        XCTAssertEqual(call.workspaceID, "wR", "the workspace id must be parsed from the surviving ref's own pane id")
        XCTAssertEqual(call.socketPath, survivingRef.socketPath)
        XCTAssertEqual(call.tabID, tab.id, "the Calyx tab id must be the restored Tab's own id")
        XCTAssertEqual(call.paneRefs, [survivingSurfaceID: survivingRef], "every surviving herdrPaneRefs pair must be carried verbatim")
    }

    /// The direct-adoption branch `adoptRestoredHerdrTabIfNeeded` gained:
    /// a coordinator that already exists at restore time is adopted into
    /// DIRECTLY, synchronously, inside the very same `restoreTabSurfaces`
    /// call -- nothing is queued. Uses a real `HerdrTabCoordinator`
    /// (`makeCoordinator(registry:)` above) rather than only
    /// `_restoreTabSurfacesHerdrAdoptionObserverForTesting`, so this
    /// proves the adoption actually reached the coordinator, not merely
    /// that `AppDelegate` computed the right arguments for it.
    func test_restoreTabSurfaces_coordinatorAlreadyExists_adoptsDirectly_synchronouslyWithinTheRestoreCall() {
        let appDelegate = AppDelegate()
        let registry = HerdrPaneRegistry()
        defer { registry._stopObserving() }
        let coordinator = makeCoordinator(registry: registry)
        appDelegate._setHerdrTabCoordinatorForTesting(coordinator)

        let leafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            oldLeafID == leafID ? newSurfaceID : nil
        }

        let survivingSurfaceID = UUID()
        let survivingRef = HerdrPaneRef(
            socketPath: "/tmp/calyx-herdr-wiring-test-\(UUID().uuidString)/herdr.sock", paneID: "wD:p1"
        )
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.herdrPaneRefs = [survivingSurfaceID: survivingRef]

        XCTAssertFalse(coordinator.hasOpenTab(workspaceID: "wD", socketPath: survivingRef.socketPath))

        let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())

        XCTAssertTrue(restored)
        XCTAssertTrue(
            coordinator.hasOpenTab(workspaceID: "wD", socketPath: survivingRef.socketPath),
            "a coordinator that already exists at restore time must be adopted into directly, with no queueing"
        )
    }

    /// The pending-queue path: `herdrTabCoordinator` is still nil when
    /// `restoreTabSurfaces` runs, so the adoption is queued into
    /// `pendingHerdrTabAdoptions` instead of reaching any coordinator.
    /// Creating one afterward (`_setHerdrTabCoordinatorForTesting`, which
    /// flushes exactly like `startHerdrIntegrationIfNeeded()`'s own
    /// assign-then-flush sequence) adopts that queued entry -- proven by
    /// `hasOpenTab` for its workspace id/socket path, and, for the
    /// paneRefs specifically, by closing the EXACT pane the surviving ref
    /// names: `handlePaneClosed` only drains `remainingPaneIDs` to empty
    /// (and so only clears `hasOpenTab`) if the flushed entry's own
    /// paneRefs seeded that workspace's tracked pane set with exactly
    /// that one pane id (HerdrTabCoordinator.swift's own
    /// closeTrackedPane/pruneIfLastPaneClosed).
    func test_restoreTabSurfaces_noCoordinatorYet_queuesAdoption_flushedExactlyOnceWithRightArgsWhenCoordinatorIsCreated() async {
        let appDelegate = AppDelegate()
        let registry = HerdrPaneRegistry()
        defer { registry._stopObserving() }

        let leafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            oldLeafID == leafID ? newSurfaceID : nil
        }

        let survivingSurfaceID = UUID()
        let survivingRef = HerdrPaneRef(
            socketPath: "/tmp/calyx-herdr-wiring-test-\(UUID().uuidString)/herdr.sock", paneID: "wP:p9"
        )
        // Registered directly on this test's own registry, standing in
        // for the registration a real .bridgeCommand restore would
        // already have made on HerdrPaneRegistry.shared -- lets the
        // handlePaneClosed proof below resolve a surfaceID for "wP:p9"
        // at all, without a live herdr binary or socket (this file's own
        // header).
        registry.register(surfaceID: survivingSurfaceID, ref: survivingRef)

        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.herdrPaneRefs = [survivingSurfaceID: survivingRef]

        let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())
        XCTAssertTrue(restored)

        let coordinator = makeCoordinator(registry: registry)
        XCTAssertFalse(
            coordinator.hasOpenTab(workspaceID: "wP", socketPath: survivingRef.socketPath),
            "queued while no coordinator existed -- must not already be adopted before one is created"
        )

        appDelegate._setHerdrTabCoordinatorForTesting(coordinator)

        XCTAssertTrue(
            coordinator.hasOpenTab(workspaceID: "wP", socketPath: survivingRef.socketPath),
            "creating the coordinator must flush the queued restore-time adoption"
        )

        await coordinator.handlePaneClosed(paneID: "wP:p9", socketPath: survivingRef.socketPath)
        XCTAssertFalse(
            coordinator.hasOpenTab(workspaceID: "wP", socketPath: survivingRef.socketPath),
            "the flushed adoption's paneRefs must be exactly the tab's own surviving herdrPaneRefs entry"
        )
    }

    /// The queue must be CLEARED on flush, not merely delivered: a
    /// second coordinator created afterward, sharing the same registry,
    /// must never see the first flush's own entry replayed into it. An
    /// uncleared queue would make this assertion fail (`hasOpenTab` true
    /// on the second coordinator too).
    func test_restoreTabSurfaces_queuedAdoption_clearedAfterFirstFlush_neverReplayedIntoALaterCoordinator() {
        let appDelegate = AppDelegate()
        let registry = HerdrPaneRegistry()
        defer { registry._stopObserving() }

        let leafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            oldLeafID == leafID ? newSurfaceID : nil
        }

        let survivingSurfaceID = UUID()
        let survivingRef = HerdrPaneRef(
            socketPath: "/tmp/calyx-herdr-wiring-test-\(UUID().uuidString)/herdr.sock", paneID: "wQ:p1"
        )
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.herdrPaneRefs = [survivingSurfaceID: survivingRef]

        _ = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())

        let firstCoordinator = makeCoordinator(registry: registry)
        appDelegate._setHerdrTabCoordinatorForTesting(firstCoordinator)
        XCTAssertTrue(firstCoordinator.hasOpenTab(workspaceID: "wQ", socketPath: survivingRef.socketPath))

        let secondCoordinator = makeCoordinator(registry: registry)
        appDelegate._setHerdrTabCoordinatorForTesting(secondCoordinator)

        XCTAssertFalse(
            secondCoordinator.hasOpenTab(workspaceID: "wQ", socketPath: survivingRef.socketPath),
            "the pending queue must be cleared once flushed -- a second coordinator created afterward must not " +
            "re-adopt an entry the first flush already consumed"
        )
    }

    /// The queue's other guard: a tab restored with no herdrPaneRefs at
    /// all (never populated in the first place, unlike the dead-socket
    /// case above which starts populated and gets pruned to empty) must
    /// never queue, or directly trigger, an adoption.
    /// `adoptRestoredHerdrTabIfNeeded`'s own early-return guard covers
    /// the queue append and the observer notification identically (both
    /// sit after the same guard, in the same method), so an observer
    /// count of zero is equivalent, by construction, to nothing having
    /// been queued.
    func test_restoreTabSurfaces_tabWithNoHerdrPaneRefsAtAll_neverQueuesOrAdopts() {
        let appDelegate = AppDelegate()

        let leafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            oldLeafID == leafID ? newSurfaceID : nil
        }
        var adoptionCallCount = 0
        appDelegate._restoreTabSurfacesHerdrAdoptionObserverForTesting = { _, _, _, _ in adoptionCallCount += 1 }

        let tab = Tab(splitTree: SplitTree(leafID: leafID))

        let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())

        XCTAssertTrue(restored)
        XCTAssertEqual(
            adoptionCallCount, 0,
            "a tab restored with no herdrPaneRefs at all must never queue (or directly trigger) an adoption"
        )
    }
}
