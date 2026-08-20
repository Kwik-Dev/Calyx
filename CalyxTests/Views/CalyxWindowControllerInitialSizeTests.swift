//
//  CalyxWindowControllerInitialSizeTests.swift
//  CalyxTests
//
//  Missing observer: `GhosttyActionRouter
//  .handleInitialSize` (GhosttyAction.swift) posts `.ghosttyInitialSize`
//  for every `GHOSTTY_ACTION_INITIAL_SIZE` action, but no observer has
//  ever been registered for it — ghostty's requested initial window size
//  is silently ignored. `CalyxWindowController.applyInitialSize(_:)` is
//  the intended receiver once that observer exists; today it is an
//  intentional no-op stub, called directly here (this file only tests
//  the guard/apply CONTRACT, not notification routing).
//
//  Two of the three tests below are regression guards
//  (see `CalyxWindowControllerCloseWindowTests.swift`'s header for the
//  general reasoning this codebase already establishes for that
//  distinction): against a no-op stub, "the window size never changes"
//  is trivially true, so the two "must NOT apply" tests below pass today
//  by construction. They still have teeth against a future
//  implementation that DROPS the corresponding guard. The third test
//  ("single tab/pane, not restoring, MUST apply") is the one that pins
//  the fix: it expects the window to actually resize, which the pre-fix
//  stub never did.
//
//  `isRestoring` is `private` on `CalyxWindowController`
//  (`init(window:windowSession:restoring:)` stores its `restoring`
//  argument into it directly). Tests cannot read or set it, so — exactly
//  like `CalyxWindowControllerFullScreenTests.swift`'s own
//  "!isRestoring Guard" section — it is controlled indirectly:
//  constructing with `restoring: true` leaves `isRestoring == true`;
//  calling `activateRestoredSession()` afterward flips it to `false`.
//
//  Three follow-ups from code review, all added below:
//   - "One-shot guard" section: `applyInitialSize` also gained a
//     `!hasAppliedInitialSize` guard (a later `GHOSTTY_ACTION_INITIAL_SIZE`
//     re-fire -- e.g. from a font-size change or a config hot-reload,
//     both of which re-trigger it in real ghostty -- must not clobber a
//     user's manual resize once the window has already taken its first
//     size). `test_applyInitialSize_singleTabSinglePaneNotRestoring_
//     resizesWindowToRequestedSize` above already exercises the FIRST
//     call; the new tests below are its direct sequels.
//
//     `hasAppliedInitialSize` is SEEDED from `restoring` in `init` (a
//     restored/reattached window's size is already established, so it
//     must never apply ghostty's own initial size at all, including a
//     later re-fire — see that property's own doc comment in
//     CalyxWindowController.swift). Every fixture in this file builds
//     via `restoring: true` PURELY to skip `setupTerminalSurface` (no
//     live ghostty app in this test host — see `SurfaceLocator.swift`'s
//     header comment), not to represent an actual restored window, so
//     `restoring: true` alone now ALSO seeds `hasAppliedInitialSize =
//     true` — a fixture representing a genuinely NEW window must opt
//     back out via the `#if DEBUG` seam
//     `_setHasAppliedInitialSizeForTesting(false)`, called right after
//     `activateRestoredSession()`, everywhere this file wants to test
//     `applyInitialSize`'s FIRST-application behavior. The one test that
//     deliberately does NOT call that seam
//     (`test_applyInitialSize_restoredWindowAfterActivation_
//     doesNotResizeOnLaterReFire`) is the regression guard for the gap
//     this seeding closes: a genuinely restored window must not resize
//     on ITS OWN later re-fire either, not just a fresh window's.
//   - "Notification post" section: closes the coverage gap where every
//     test above calls `applyInitialSize` directly, never exercising
//     `handleInitialSizeNotification`'s own `findTab(for:)` routing /
//     `userInfo["width"]`/`["height"]` extraction — mirrors
//     `CalyxWindowControllerCloseWindowTests`/`ToggleFullscreenTests`'s
//     real-`NotificationCenter.post` "Tactic A" tests. `applyInitialSize`
//     has no `#if DEBUG` test hook for its production side effect (unlike
//     `processCloseWindow`/`processToggleFullscreen`) and needs none:
//     `window?.setContentSize` on a real-but-never-shown window is
//     already safely exercised by every direct-call test above, so a
//     second, legitimately-owning fixture controller reacting for real
//     is not a hazard here.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerInitialSizeTests: XCTestCase {

    // MARK: - Fixtures

    /// One group, one tab, one pane (`splitTree` has exactly one leaf via
    /// `SplitTree(leafID:)`) — the shape `applyInitialSize` must apply
    /// to. `restoring: true` skips `setupTerminalSurface` (no live
    /// ghostty app in the unit-test host); no `SurfaceRegistry`/
    /// `SurfaceView` is needed since `SplitTree.allLeafIDs()` reads only
    /// the split tree itself, not the registry.
    private func makeSinglePaneController() -> CalyxWindowController {
        let tab = Tab(splitTree: SplitTree(leafID: UUID()))
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return makeController(session: session)
    }

    /// One group, TWO tabs — the "more than one tab" shape
    /// `applyInitialSize` must NOT apply to.
    private func makeTwoTabController() -> CalyxWindowController {
        let tabs = [Tab(splitTree: SplitTree(leafID: UUID())), Tab(splitTree: SplitTree(leafID: UUID()))]
        let group = TabGroup(name: "Default", tabs: tabs, activeTabID: tabs[0].id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return makeController(session: session)
    }

    private func makeController(session: WindowSession) -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    private func contentSize(of controller: CalyxWindowController) -> NSSize {
        controller.window?.contentView?.frame.size ?? .zero
    }

    // MARK: - isRestoring guard (regression guard)

    /// While `isRestoring == true` (the fixture never calls
    /// `activateRestoredSession()`), applying an initial size must be a
    /// no-op — this is the guard against resetting every user's restored
    /// window size on every launch.
    func test_applyInitialSize_whileRestoring_doesNotResizeWindow() {
        let controller = makeSinglePaneController()
        let originalSize = contentSize(of: controller)
        let targetSize = NSSize(width: 1024, height: 768)
        XCTAssertNotEqual(originalSize, targetSize, "Precondition: target size must differ from the fixture's starting content size")

        controller.applyInitialSize(targetSize)

        XCTAssertEqual(
            contentSize(of: controller),
            originalSize,
            "While isRestoring == true, applyInitialSize must NOT resize the window"
        )
    }

    // MARK: - Multiple-tabs guard (regression guard)

    /// With more than one tab open, applying an initial size must be a
    /// no-op — a second tab appearing later in the window's life must
    /// not cause the window to jump back to ghostty's single-surface
    /// initial size. `activateRestoredSession()` leaves the restoring
    /// state first, and `_setHasAppliedInitialSizeForTesting(false)`
    /// leaves the one-shot state fresh too, so this test isolates the
    /// tab-count guard specifically from BOTH the isRestoring guard
    /// above and the one-shot guard below.
    func test_applyInitialSize_withMultipleTabs_doesNotResizeWindow() {
        let controller = makeTwoTabController()
        controller.activateRestoredSession()
        controller._setHasAppliedInitialSizeForTesting(false)
        let originalSize = contentSize(of: controller)
        let targetSize = NSSize(width: 1024, height: 768)
        XCTAssertNotEqual(originalSize, targetSize, "Precondition: target size must differ from the fixture's starting content size")

        controller.applyInitialSize(targetSize)

        XCTAssertEqual(
            contentSize(of: controller),
            originalSize,
            "With more than one tab open, applyInitialSize must NOT resize the window"
        )
    }

    // MARK: - Single tab/pane, not restoring (pins the fix)

    /// With exactly one group/tab/pane and outside the restoring window,
    /// applyInitialSize MUST resize the window's content area to the
    /// requested size. Against the current no-op stub, the window's
    /// content size never changes, so this fails.
    func test_applyInitialSize_singleTabSinglePaneNotRestoring_resizesWindowToRequestedSize() {
        let controller = makeSinglePaneController()
        controller.activateRestoredSession()
        // Opt out of the `restoring: true` seeding (see this file's
        // header): this test represents a genuinely NEW window's first
        // application, not a restored one.
        controller._setHasAppliedInitialSizeForTesting(false)
        let originalSize = contentSize(of: controller)
        let targetSize = NSSize(width: 1024, height: 768)
        XCTAssertNotEqual(originalSize, targetSize, "Precondition: target size must differ from the fixture's starting content size")

        controller.applyInitialSize(targetSize)

        XCTAssertEqual(
            contentSize(of: controller),
            targetSize,
            "With exactly one group/tab/pane and outside the restoring window, applyInitialSize MUST resize " +
            "the window's content area to the requested size"
        )
    }

    // MARK: - One-shot guard

    /// Direct sequel to the test above: once `applyInitialSize`
    /// has successfully resized the window once, a SECOND call (same
    /// single-pane shape, still not restoring -- e.g. a later
    /// `GHOSTTY_ACTION_INITIAL_SIZE` re-fire from a font-size change or a
    /// config hot-reload, both of which re-trigger it in real ghostty, per
    /// `Surface.zig`'s `recomputeInitialSize` call sites) must be a no-op,
    /// not clobber whatever size the window is ACTUALLY at by then (a
    /// user's own manual resize in between, simulated here directly via
    /// `setContentSize`).
    func test_applyInitialSize_secondCallAfterSuccessfulFirst_doesNotResizeAgain() {
        let controller = makeSinglePaneController()
        controller.activateRestoredSession()
        controller._setHasAppliedInitialSizeForTesting(false)
        let firstTargetSize = NSSize(width: 1024, height: 768)
        controller.applyInitialSize(firstTargetSize)
        XCTAssertEqual(contentSize(of: controller), firstTargetSize, "Precondition: first call must have applied")

        // Simulate the user manually resizing the window in between.
        let manualSize = NSSize(width: 1200, height: 900)
        controller.window?.setContentSize(manualSize)
        XCTAssertEqual(contentSize(of: controller), manualSize, "Precondition: manual resize must have taken effect")

        controller.applyInitialSize(NSSize(width: 640, height: 480))

        XCTAssertEqual(
            contentSize(of: controller),
            manualSize,
            "A second applyInitialSize call after the first already succeeded must NOT resize the window again, " +
            "even if the single-pane shape still holds"
        )
    }

    /// The gap `hasAppliedInitialSize`'s seeding (from `restoring`, in
    /// `init`) exists to close: a window built via `restoring: true` --
    /// what a REAL session restore/reattach always does
    /// (`AppDelegate.attachWindow`/`.restoreWindow`, both via
    /// `makeRestoringWindowController`) -- and then activated via
    /// `activateRestoredSession()`, exactly as production always does,
    /// must NOT apply a LATER `GHOSTTY_ACTION_INITIAL_SIZE` re-fire (a
    /// font-size keybind, a config hot-reload) even once `isRestoring`
    /// has flipped back to `false`. Unlike every other single-pane test
    /// above, this one deliberately does NOT call
    /// `_setHasAppliedInitialSizeForTesting`, so `hasAppliedInitialSize`
    /// stays at its production-seeded `true` — representing a GENUINE
    /// restore, not the "skip surface creation only" convenience the
    /// other fixtures in this file opt back out of via that seam.
    func test_applyInitialSize_restoredWindowAfterActivation_doesNotResizeOnLaterReFire() {
        let controller = makeSinglePaneController()
        controller.activateRestoredSession()
        let originalSize = contentSize(of: controller)
        let targetSize = NSSize(width: 1024, height: 768)
        XCTAssertNotEqual(originalSize, targetSize, "Precondition: target size must differ from the fixture's starting content size")

        controller.applyInitialSize(targetSize)

        XCTAssertEqual(
            contentSize(of: controller),
            originalSize,
            "A restored window, once activateRestoredSession() has run, must NOT resize on a LATER " +
            "GHOSTTY_ACTION_INITIAL_SIZE re-fire (e.g. a font-size change or config hot-reload) — its size is " +
            "already established by the restore, not by this later action"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Mirrors `CalyxWindowControllerCloseWindowTests`/
    /// `ToggleFullscreenTests`'s `SurfaceOwningFixture`: `findTab(for:)`
    /// needs a real `SurfaceRegistry` entry, unlike the leaf-only
    /// `SplitTree(leafID:)` fixtures above (which have no registry entry
    /// at all, since `allLeafIDs()`-based guard testing doesn't need one).
    /// Always represents a genuinely NEW window (not a restored one, see
    /// this file's header): both real posts in this section need their
    /// controller's FIRST `applyInitialSize` application to actually
    /// succeed.
    private struct SurfaceOwningFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
    }

    private func makeSurfaceOwningSinglePaneFixture() -> SurfaceOwningFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let controller = makeController(session: session)
        controller.activateRestoredSession()
        controller._setHasAppliedInitialSizeForTesting(false)
        return SurfaceOwningFixture(controller: controller, surfaceView: surfaceView)
    }

    /// Posting the real `.ghosttyInitialSize` notification for a surface
    /// THIS window owns must resize the window — exercises
    /// `handleInitialSizeNotification`'s `findTab(for:)` routing and
    /// `userInfo["width"]`/`["height"]` extraction end to end, not just
    /// `applyInitialSize` called directly.
    func test_ghosttyInitialSize_postedForOwnSurface_resizesWindowToRequestedSize() {
        let fixture = makeSurfaceOwningSinglePaneFixture()
        let originalSize = contentSize(of: fixture.controller)
        let targetSize = NSSize(width: 1024, height: 768)
        XCTAssertNotEqual(originalSize, targetSize, "Precondition: target size must differ from the fixture's starting content size")

        NotificationCenter.default.post(
            name: .ghosttyInitialSize,
            object: fixture.surfaceView,
            userInfo: ["width": UInt32(targetSize.width), "height": UInt32(targetSize.height)]
        )

        XCTAssertEqual(
            contentSize(of: fixture.controller),
            targetSize,
            "Posting .ghosttyInitialSize for a surface this window owns must resize the window to the requested size"
        )
    }

    /// Regression guard: posting `.ghosttyInitialSize` for a surface owned
    /// by a DIFFERENT window must never resize THIS window.
    /// `otherFixture.controller` legitimately owns `otherFixture
    /// .surfaceView` and correctly reacts for real (no `#if DEBUG` hook
    /// exists for `applyInitialSize`, and none is needed — see this file's
    /// header for why that's safe), so this only asserts `ownFixture`
    /// itself is untouched.
    func test_ghosttyInitialSize_postedForOtherWindowsSurface_doesNotResizeThisWindow() {
        let ownFixture = makeSurfaceOwningSinglePaneFixture()
        let otherFixture = makeSurfaceOwningSinglePaneFixture()
        let originalSize = contentSize(of: ownFixture.controller)
        let targetSize = NSSize(width: 1024, height: 768)
        XCTAssertNotEqual(originalSize, targetSize, "Precondition: target size must differ from the fixture's starting content size")

        NotificationCenter.default.post(
            name: .ghosttyInitialSize,
            object: otherFixture.surfaceView,
            userInfo: ["width": UInt32(targetSize.width), "height": UInt32(targetSize.height)]
        )

        XCTAssertEqual(
            contentSize(of: ownFixture.controller),
            originalSize,
            "Posting .ghosttyInitialSize for a surface owned by a DIFFERENT window must not resize THIS window"
        )
    }
}
