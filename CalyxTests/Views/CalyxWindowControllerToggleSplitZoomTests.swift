//
//  CalyxWindowControllerToggleSplitZoomTests.swift
//  CalyxTests
//
//  18th and final action from the missing-observer keybind-wiring
//  investigation: `GhosttyActionRouter.handleAction` used to list
//  `GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM` in its "Known but unimplemented"
//  group (GhosttyAction.swift) -- ghostty's default toggle_split_zoom
//  keybind did nothing in Calyx, and Calyx had no zoom concept at all
//  (`SplitTree.zoomedLeafID` -- see SplitTreeTests.swift's own
//  "Split Zoom" section for the full model-layer contract).
//
//  `CalyxWindowController.processToggleSplitZoom(surfaceView:)` is the
//  receiver for the real `.ghosttyToggleSplitZoom` Notification.Name/
//  `handleToggleSplitZoomNotification` observer registered in
//  `registerNotificationObservers()`. The tests above the "Notification
//  post (Tactic A)" section call it directly; the section itself exercises
//  the real posted-notification path end to end, mirroring
//  CalyxWindowControllerPromptTitleTests/ToggleMaximizeTests's own
//  identically-named sections.
//
//  Fixtures mirror `CalyxWindowControllerChildExitedTasksTests
//  .makeOrdinaryPaneFixture()`'s shape (`SurfaceView(frame: .zero)` +
//  `registry._testInsert`, never a real ghostty surface -- see
//  `SurfaceLocator.swift`'s header on why a real one hangs the XCTest
//  process).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerToggleSplitZoomTests: XCTestCase {

    private struct TwoPaneFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let firstView: SurfaceView
        let firstID: UUID
        let secondView: SurfaceView
        let secondID: UUID
    }

    private func makeTwoPaneFixture() -> TwoPaneFixture {
        let registry = SurfaceRegistry()
        let firstID = UUID()
        let secondID = UUID()
        let firstView = SurfaceView(frame: .zero)
        let secondView = SurfaceView(frame: .zero)
        registry._testInsert(view: firstView, id: firstID)
        registry._testInsert(view: secondView, id: secondID)

        let (splitTree, _) = SplitTree(leafID: firstID).insert(at: firstID, direction: .horizontal, newID: secondID)
        let tab = Tab(splitTree: splitTree, registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return TwoPaneFixture(
            controller: controller,
            tab: tab,
            firstView: firstView,
            firstID: firstID,
            secondView: secondView,
            secondID: secondID
        )
    }

    private struct SinglePaneFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let surfaceView: SurfaceView
        let leafID: UUID
    }

    private func makeSinglePaneFixture() -> SinglePaneFixture {
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
        return SinglePaneFixture(controller: controller, tab: tab, surfaceView: surfaceView, leafID: leafID)
    }

    /// Toggling zoom on one pane of a 2-pane tab must zoom exactly that
    /// pane's own leaf.
    func test_processToggleSplitZoom_onTwoPaneTab_zoomsTheTargetPane() {
        let fixture = makeTwoPaneFixture()

        fixture.controller.processToggleSplitZoom(surfaceView: fixture.firstView)

        XCTAssertEqual(
            fixture.tab.splitTree.zoomedLeafID,
            fixture.firstID,
            "processToggleSplitZoom must zoom the target pane's own leaf"
        )
    }

    /// Toggling the SAME already-zoomed pane a second time must clear
    /// zoom.
    func test_processToggleSplitZoom_calledTwiceOnSamePane_clearsZoom() {
        let fixture = makeTwoPaneFixture()

        fixture.controller.processToggleSplitZoom(surfaceView: fixture.firstView)
        XCTAssertEqual(
            fixture.tab.splitTree.zoomedLeafID,
            fixture.firstID,
            "processToggleSplitZoom must zoom the target pane on the first call, as a precondition for this test"
        )

        fixture.controller.processToggleSplitZoom(surfaceView: fixture.firstView)

        XCTAssertNil(
            fixture.tab.splitTree.zoomedLeafID,
            "A second processToggleSplitZoom call on the SAME pane must clear zoom"
        )
    }

    /// A single-pane (non-split) tab must never enter a zoomed state --
    /// exercises `SplitTree.togglingZoom(at:)`'s own `isSplit` guard,
    /// mirroring upstream ghostty's `guard surfaceTree.isSplit else {
    /// return }` (`BaseTerminalController.ghosttyDidToggleSplitZoom`).
    func test_processToggleSplitZoom_onSinglePaneTab_leavesZoomNil() {
        let fixture = makeSinglePaneFixture()

        fixture.controller.processToggleSplitZoom(surfaceView: fixture.surfaceView)

        XCTAssertNil(
            fixture.tab.splitTree.zoomedLeafID,
            "A single-pane (non-split) tab must never enter a zoomed state"
        )
    }

    // MARK: - Notification post ("Tactic A")
    //
    // Every test above calls `processToggleSplitZoom` directly. This
    // section exercises `registerNotificationObservers()`'s
    // `.ghosttyToggleSplitZoom` registration and
    // `handleToggleSplitZoomNotification` end to end via a real
    // `NotificationCenter.default.post` -- exactly the "post side written,
    // observer forgotten" class of bug this whole keybind-wiring pass
    // exists to fix (it has happened twice before in this project; see
    // CalyxWindowControllerPromptTitleTests/ToggleMaximizeTests's own
    // identically-named sections).

    /// Posting the real `.ghosttyToggleSplitZoom` notification for a
    /// surface THIS window's active tab owns must zoom that surface's own
    /// leaf -- proves the notification actually reaches
    /// `processToggleSplitZoom(surfaceView:)`, not just that the method
    /// itself works when called directly.
    func test_ghosttyToggleSplitZoom_postedForOwnSurface_zoomsThatPane() {
        let fixture = makeTwoPaneFixture()

        NotificationCenter.default.post(name: .ghosttyToggleSplitZoom, object: fixture.firstView)

        XCTAssertEqual(
            fixture.tab.splitTree.zoomedLeafID,
            fixture.firstID,
            "Posting .ghosttyToggleSplitZoom for a surface this window's active tab owns must zoom that pane"
        )
    }

    /// Regression guard: posting `.ghosttyToggleSplitZoom` for a surface
    /// registered in NO tab's registry (never `_testInsert`ed anywhere)
    /// must leave the fixture's zoom state untouched. An orphan surface,
    /// not some OTHER window's owned surface, is the right shape here --
    /// it structurally guarantees no other live controller (this suite's
    /// own, or one left over from another test) can react and make the
    /// assertion pass for the wrong reason; mirrors
    /// CalyxWindowControllerPromptTitleTests's identical choice.
    func test_ghosttyToggleSplitZoom_postedForSurfaceInNoRegistry_doesNothing() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if the observer were never
        // registered at all.
        let fixture = makeTwoPaneFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)

        NotificationCenter.default.post(name: .ghosttyToggleSplitZoom, object: orphanSurfaceView)

        XCTAssertNil(
            fixture.tab.splitTree.zoomedLeafID,
            "Posting .ghosttyToggleSplitZoom for a surface registered in no tab's registry must not zoom anything"
        )
    }
}
