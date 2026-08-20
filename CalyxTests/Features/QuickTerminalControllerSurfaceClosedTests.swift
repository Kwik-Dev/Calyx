//
//  QuickTerminalControllerSurfaceClosedTests.swift
//  CalyxTests
//
//  BUG 2, fixed in this change: the quick terminal used to be
//  permanently dead after its shell exited. `QuickTerminalController`'s
//  `init` now registers a `.ghosttyCloseSurface` observer,
//  `handleCloseSurfaceNotification(_:)` (QuickTerminalController.swift,
//  "Surface Lifecycle" section), which extracts the notification's
//  `SurfaceView` and delegates to `processCloseSurface(surfaceView:)`.
//  That method guards ownership (`tab?.registry.id(for: surfaceView) !=
//  nil`) and, only on a match, calls `handleSurfaceClosed()`, which
//  clears `tab`/`splitContainerView`, destroys the registry's surfaces,
//  and ends in `requestHide()` -- so `ensureSurface()`'s `guard tab ==
//  nil else { return }` never blocks on a dead `tab` again, and
//  re-opening the quick terminal spawns a new shell.
//
//  `processCloseSurface(surfaceView:)` is deliberately not `private` --
//  see its own doc comment in QuickTerminalController.swift -- so
//  `QuickTerminalControllerSurfaceClosedTests` can call it directly
//  instead of always going through a real `.ghosttyCloseSurface` post.
//  This mirrors `CalyxWindowController.processChildExited(surfaceView:)`'s
//  identical "Not `private`, called directly by tests" shape -- see
//  that method's own doc comment for the rationale in full.
//  `CalyxWindowController`'s own `processCloseSurface(surfaceView:)` is
//  a different shape: it stays `private`, and even its own tests
//  (`CalyxWindowControllerCloseSurfaceTerminationDiscriminatorTests`)
//  drive it only through a real notification post; it is cited here for
//  the matching notification-handler/core-method naming pattern only,
//  not for visibility.
//
//  Fixture: `SurfaceRegistry._testInsert(view:id:)` fixtures only -- a
//  real ghostty surface HANGS XCTest (confirmed hazard, see
//  `AppDelegateAttachWindowTests`'s header). `ensureSurface()` is never
//  called. Bare `SurfaceView(frame: .zero)` construction and isolated
//  commandLogStore/sessionSurfaceMap/approvalInboxStore/
//  agentHookApprovalMemory injection both mirror established precedent:
//  `TwoPaneSessionFixture.swift` (bare `SurfaceView(frame: .zero)` +
//  `_testInsert`) and `SurfaceRegistryDestroySurfaceOrphanGatingTests.swift`
//  (isolated store injection, same DI shape as `CalyxMCPServer
//  .commandLogStore` etc.) respectively. Store injection is load-bearing
//  today: `handleSurfaceClosed()`'s teardown loop calls `destroySurface`
//  per registry ID, and `destroySurface` reads these injected stores.
//
//  Never drives a real window/animation: `QuickTerminalController()`'s
//  `init` only registers notification observers (`.ghosttyConfigChange`
//  and `.ghosttyCloseSurface` -- same guarantee
//  `QuickTerminalControllerRequestHideTests`'s header documents), and
//  every test below uses `_setVisibleForTesting`/
//  `_requestHideHookForTesting` instead of a real `animateIn()`/
//  `animateOut()` call. `handleSurfaceClosed()`'s body ends in
//  `requestHide()`, not a direct `animateOut()` call, so the same
//  `_requestHideHookForTesting` seam that intercepts a direct
//  `requestHide()` call intercepts teardown here too -- tests 4 and 6
//  below pin that routing.
//
//  History: before this change,
//  `init` registered only a `.ghosttyConfigChange` observer -- no
//  `.ghosttyCloseSurface` observer existed, which was bug 2's root
//  cause ("no production caller" for `handleSurfaceClosed()`) -- and
//  `handleSurfaceClosed()`'s pre-existing body called `animateOut()`
//  directly instead of ending in `requestHide()`. Even reaching that
//  unmodified direct call would still have been a harmless no-op in
//  this test host: `quickWindow` is never created by any test here
//  (`ensureWindow()` is never called), so `animateOut()`'s own `guard
//  let window = quickWindow else { return }` would have short-circuited
//  it immediately.
//
//  This file's first version deliberately landed only
//  `processCloseSurface(surfaceView:)` as an empty no-op, plus the
//  `#if DEBUG` seams `_setTabForTesting`/`_tabForTesting`;
//  `handleCloseSurfaceNotification` and its `init` registration were
//  withheld at that point, since pre-wiring the observer then would
//  have started implementing the fix itself and risked a double
//  registration once the real fix added its own. Tests 1-3 below
//  therefore failed via the notification genuinely going nowhere in
//  this class at that point; tests 4-6 called
//  `processCloseSurface(surfaceView:)` directly, bypassing the
//  not-yet-wired notification layer entirely -- the same direct-call
//  pattern `CalyxWindowControllerChildExitedTasksTests` uses for
//  `processChildExited`.
//
//  Notification cross-talk: posting the REAL `.ghosttyCloseSurface` in
//  tests 1-3 also reaches any live `CalyxWindowController` in this
//  hosted test process (`registerNotificationObservers()` registers it
//  with `object: nil`). Confirmed harmless: its own `processCloseSurface`
//  -> `findTab(for:)` cannot resolve a `SurfaceView` that was only ever
//  `_testInsert`-ed into one of THIS file's standalone, disconnected
//  `Tab`/`SurfaceRegistry` fixtures, so it is always a no-op for every
//  surface used here (mirrors the same reasoning
//  `CalyxWindowControllerCloseSurfaceTerminationDiscriminatorTests`'s
//  header spells out for the converse, owned case).
//
//  What each test pins, against the empty-stub
//  `processCloseSurface(surfaceView:)` the History section above
//  describes:
//   - `test_ghosttyCloseSurfaceNotification_forOwnedSurface_clearsTabAndDestroysRegistryEntry`
//     pins the fix: the stub left `controller._tabForTesting` as the
//     installed `Tab` and left `registry.contains(surfaceID)` `true`,
//     because at that point nothing in
//     `QuickTerminalController` observed `.ghosttyCloseSurface` at all,
//     so the post reached no code in this class whatsoever.
//   - `test_ghosttyCloseSurfaceNotification_forForeignSurface_leavesTabAndRegistryUntouched`
//     is a regression guard: it passed against the stub too,
//     since "untouched" was what happened when nothing observed
//     the notification at all -- indistinguishable, at that point, from
//     correctly rejecting an unowned surface. It has real teeth now
//     that the observer is wired: a regression that clears `tab`
//     unconditionally, ignoring the ownership guard, would fail it.
//   - `test_ghosttyCloseSurfaceNotification_whenNoTabInstalled_isSafeNoOp`
//     is a regression guard: it passed against the stub too, for the
//     same "nothing observed this notification yet" reason. It
//     pins the literal safety property required here:
//     no crash when the real observer fires with `tab == nil`.
//   - `test_processCloseSurface_whenVisible_routesTeardownThroughHideHookExactlyOnce`
//     pins the fix: the stub left `hookCallCount` at 0 rather than 1,
//     because `processCloseSurface(surfaceView:)`
//     was, at that point, an empty stub, so it never reached
//     `handleSurfaceClosed()` and never fired the hide hook.
//   - `test_processCloseSurface_whenNotVisible_doesNotInvokeHideHook` is
//     a regression guard: it passed against the stub too --
//     the empty stub never invoked the hook regardless of `visible`,
//     which happened to already satisfy "must not invoke it while not
//     visible". It pins `requestHide()`'s own `guard visible else {
//     return }`, now reached through `handleSurfaceClosed()`.
//   - `test_processCloseSurface_calledTwiceForSameSurface_secondCallIsCleanNoOp`
//     pins the fix: all three of its assertions failed against the
//     stub -- `hookCallCount` 0 rather than 1,
//     `controller._tabForTesting` still non-nil, and
//     `registry.contains(surfaceID)` still `true` --
//     same root cause: the stub never tore anything down on either
//     call.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class QuickTerminalControllerSurfaceClosedTests: XCTestCase {

    // MARK: - Fixture

    /// One `_testInsert`-only surface in its own standalone `Tab`/
    /// `SurfaceRegistry` -- see header comment for the injected-store and
    /// notification-cross-talk rationale.
    private func makeFixtureTab() -> (tab: Tab, surfaceID: UUID, surfaceView: SurfaceView) {
        let registry = SurfaceRegistry()
        registry.commandLogStore = CommandLogStore()
        registry.sessionSurfaceMap = SessionSurfaceMap()
        registry.approvalInboxStore = ApprovalInboxStore()
        registry.agentHookApprovalMemory = AgentHookApprovalMemory()

        let surfaceID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: surfaceID)

        let tab = Tab(splitTree: SplitTree(leafID: surfaceID), registry: registry)
        return (tab, surfaceID, surfaceView)
    }

    // MARK: - Notification pipeline (pins the fix)

    func test_ghosttyCloseSurfaceNotification_forOwnedSurface_clearsTabAndDestroysRegistryEntry() {
        let controller = QuickTerminalController()
        let fixture = makeFixtureTab()
        controller._setTabForTesting(fixture.tab)

        NotificationCenter.default.post(
            name: .ghosttyCloseSurface, object: fixture.surfaceView, userInfo: ["process_alive": false]
        )

        XCTAssertNil(
            controller._tabForTesting,
            "A real .ghosttyCloseSurface for the quick terminal's own surface must tear down tab -- " +
            "otherwise ensureSurface()'s `guard tab == nil` holds the dead tab forever and re-opening " +
            "the quick terminal never spawns a new shell"
        )
        XCTAssertFalse(
            fixture.tab.registry.contains(fixture.surfaceID),
            "...and must destroy the registry entry too (tab.registry.destroySurface(surfaceID)), or " +
            "pending Cockpit approvals/CommandLogStore entries for it are stranded forever"
        )
    }

    // MARK: - Notification pipeline (regression guards)

    func test_ghosttyCloseSurfaceNotification_forForeignSurface_leavesTabAndRegistryUntouched() {
        let controller = QuickTerminalController()
        let fixture = makeFixtureTab()
        controller._setTabForTesting(fixture.tab)
        let foreignView = SurfaceView(frame: .zero) // never inserted into fixture.tab.registry

        NotificationCenter.default.post(
            name: .ghosttyCloseSurface, object: foreignView, userInfo: ["process_alive": false]
        )

        XCTAssertNotNil(
            controller._tabForTesting,
            "A close notification for a surface this controller does not own must not tear down its tab"
        )
        XCTAssertTrue(
            fixture.tab.registry.contains(fixture.surfaceID),
            "...and must not touch the registry entry it does own, either"
        )
    }

    func test_ghosttyCloseSurfaceNotification_whenNoTabInstalled_isSafeNoOp() {
        let controller = QuickTerminalController()
        XCTAssertNil(controller._tabForTesting, "Precondition: a freshly constructed controller has no tab")
        let someView = SurfaceView(frame: .zero)

        NotificationCenter.default.post(
            name: .ghosttyCloseSurface, object: someView, userInfo: ["process_alive": false]
        )

        XCTAssertNil(controller._tabForTesting, "Posting with no tab installed must remain a safe no-op")
    }

    // MARK: - processCloseSurface: teardown routes through the hide path

    func test_processCloseSurface_whenVisible_routesTeardownThroughHideHookExactlyOnce() {
        let controller = QuickTerminalController()
        let fixture = makeFixtureTab()
        controller._setTabForTesting(fixture.tab)
        controller._setVisibleForTesting(true)
        var hookCallCount = 0
        controller._requestHideHookForTesting = { hookCallCount += 1 }

        controller.processCloseSurface(surfaceView: fixture.surfaceView)

        XCTAssertEqual(
            hookCallCount, 1,
            "Tearing down the quick terminal's own surface while visible must hide it through the same " +
            "requestHide()/_requestHideHookForTesting path Cmd+W uses -- calling animateOut() directly, " +
            "unhooked, would also leave this counter at 0 in this test host (quickWindow is nil here, so " +
            "animateOut() itself no-ops), so a count of exactly 1 proves teardown routed through the hide " +
            "hook specifically, not merely that some no-op ran"
        )
    }

    func test_processCloseSurface_whenNotVisible_doesNotInvokeHideHook() {
        let controller = QuickTerminalController()
        let fixture = makeFixtureTab()
        controller._setTabForTesting(fixture.tab)
        XCTAssertFalse(controller.visible, "Precondition: a freshly constructed controller starts hidden")
        var hookCallCount = 0
        controller._requestHideHookForTesting = { hookCallCount += 1 }

        controller.processCloseSurface(surfaceView: fixture.surfaceView)

        XCTAssertEqual(hookCallCount, 0, "Must not attempt to hide anything that was never shown")
    }

    // MARK: - Re-entrancy guard

    /// `destroySurface(_:)` -> `entry.controller.requestClose()` can
    /// synchronously re-post `.ghosttyCloseSurface` for a REAL surface
    /// (this file's fixtures are `_testInsert`-only and never reach that
    /// call, so the recursive post itself is not reproducible here -- see
    /// `SurfaceRegistry.destroySurface`'s no-live-entry branch) -- so a
    /// second, re-entrant `processCloseSurface(surfaceView:)` call for
    /// the SAME surface, arriving after the first call has already torn
    /// `tab` down to `nil`, must be a clean no-op: the ownership guard
    /// (`tab?.registry.id(for: surfaceView) != nil`) fails once `tab` is
    /// `nil`, so `handleSurfaceClosed()` (and the hide hook it drives)
    /// must fire exactly ONCE total, not twice.
    func test_processCloseSurface_calledTwiceForSameSurface_secondCallIsCleanNoOp() {
        let controller = QuickTerminalController()
        let fixture = makeFixtureTab()
        controller._setTabForTesting(fixture.tab)
        controller._setVisibleForTesting(true)
        var hookCallCount = 0
        controller._requestHideHookForTesting = { hookCallCount += 1 }

        controller.processCloseSurface(surfaceView: fixture.surfaceView)
        controller.processCloseSurface(surfaceView: fixture.surfaceView)

        XCTAssertEqual(hookCallCount, 1, "The hide hook must fire exactly once across both calls, not twice")
        XCTAssertNil(controller._tabForTesting, "tab must be cleared after the (single, real) teardown")
        XCTAssertFalse(
            fixture.tab.registry.contains(fixture.surfaceID),
            "The registry entry must be destroyed exactly once, not double-destroyed or left behind"
        )
    }
}
