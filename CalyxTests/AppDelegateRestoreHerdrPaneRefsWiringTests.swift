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
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

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

    func test_restoreTabSurfaces_herdrPaneRefWithDeadSocket_prunesRefAndRestoresPlainShell_neverRegistersInHerdrPaneRegistry() {
        let appDelegate = AppDelegate()

        let leafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            oldLeafID == leafID ? newSurfaceID : nil
        }

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
    }
}
