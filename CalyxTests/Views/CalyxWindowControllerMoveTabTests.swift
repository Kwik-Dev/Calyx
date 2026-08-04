//
//  CalyxWindowControllerMoveTabTests.swift
//  CalyxTests
//
//  TDD RED phase, second missing-observer investigation:
//  `GhosttyActionRouter.handleAction` still lists `GHOSTTY_ACTION_MOVE_TAB`
//  in its "Known but unimplemented" group (`return false`,
//  GhosttyAction.swift) -- ghostty's default move_tab keybinds do nothing.
//  `CalyxWindowController.processMoveTab(tab:group:amount:)` is the
//  intended receiver once a `.ghosttyMoveTab` case/observer exists; today
//  it is an intentional no-op stub (see its own doc comment in
//  CalyxWindowController.swift), so every test below that expects
//  `group.tabs` to reorder fails.
//
//  `ghostty_action_move_tab_s.amount` (ghostty.h) is `ssize_t` -> Swift
//  `Int`, matching `processMoveTab`'s own `amount: Int` parameter exactly.
//
//  `processMoveTab` is called directly, not via a posted notification --
//  see CalyxWindowControllerSetTabTitleTests's header for why (mirrors
//  CalyxWindowControllerCloseTabTests's established split). The wrap
//  arithmetic itself is exhaustively covered by `TabGroupMoveTabTests`
//  (`TabGroup.moveTab(fromIndex:by:)`, the pure function this method is
//  intended to delegate to) -- this file only checks that `processMoveTab`
//  resolves `tab`'s index within `group` and forwards `amount` correctly,
//  plus the activeTabID regression guard once more at this call boundary.
//
//  Coverage-gap follow-up: see CalyxWindowControllerSetTabTitleTests's own
//  identically-worded follow-up note -- `registerNotificationObservers()`
//  never registered an observer for `.ghosttyMoveTab` either, so ghostty's
//  move_tab keybinds stayed silently inert despite `process*` having a
//  real body. The "Notification post (Tactic A)" section below closes the
//  gap and covers the fix.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerMoveTabTests: XCTestCase {

    private struct GroupFixture {
        let controller: CalyxWindowController
        let group: TabGroup
        let tabs: [Tab]
    }

    /// Mirrors `CalyxWindowControllerCloseTabTests.makeGroupFixture(tabCount:)`.
    private func makeGroupFixture(tabCount: Int) -> GroupFixture {
        let tabs = (0..<tabCount).map { Tab(title: "Tab \($0)") }
        let group = TabGroup(name: "Default", tabs: tabs, activeTabID: tabs.first?.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return GroupFixture(controller: controller, group: group, tabs: tabs)
    }

    /// By hand: [Tab 0, Tab 1, Tab 2], move Tab 2 (index 2, the last) by
    /// +1. newIndex = ((2 + 1) % 3 + 3) % 3 = 0, so Tab 2 wraps to the
    /// front: [Tab 2, Tab 0, Tab 1].
    func test_processMoveTab_reordersGroupTabs() {
        let fixture = makeGroupFixture(tabCount: 3)
        let target = fixture.tabs[2]

        fixture.controller.processMoveTab(tab: target, group: fixture.group, amount: 1)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabs[2].id, fixture.tabs[0].id, fixture.tabs[1].id],
            "processMoveTab must resolve the target tab's index within group and move it by amount, wrapping"
        )
    }

    /// Regression guard (mirrors `TabGroupMoveTabTests
    /// .test_moveTab_preservesActiveTabID_whenActiveTabIsTheOneMoved`, at
    /// this call boundary): the moved tab, if it was the active one, must
    /// remain active by id after processMoveTab, not just after the raw
    /// TabGroup call.
    func test_processMoveTab_preservesActiveTabID_whenActiveTabIsTheOneMoved() {
        let fixture = makeGroupFixture(tabCount: 3)
        let target = fixture.tabs[2]
        fixture.group.activeTabID = target.id

        fixture.controller.processMoveTab(tab: target, group: fixture.group, amount: 1)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabs[2].id, fixture.tabs[0].id, fixture.tabs[1].id],
            "Precondition for this regression guard to mean anything: the move must actually reorder tabs"
        )
        XCTAssertEqual(
            fixture.group.activeTabID,
            target.id,
            "activeTabID must keep pointing at the moved tab after processMoveTab, even though its index changed"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Unlike `GroupFixture` above, `findTab(for:)` needs a real
    /// `SurfaceRegistry` entry on the tab under test -- mirrors
    /// `CalyxWindowControllerCloseWindowTests.SurfaceOwningFixture`. Only
    /// `targetIndex`'s `Tab` gets a real registry/surface (the one
    /// `.ghosttyMoveTab` will be posted for); its siblings are plain
    /// `Tab(title:)`, matching `makeGroupFixture(tabCount:)`'s shape --
    /// `findTab(for:)` only needs ONE tab in `group` to resolve the
    /// posted surface back to `(tab, group)`.
    private struct SurfaceOwningGroupFixture {
        let controller: CalyxWindowController
        let group: TabGroup
        let tabs: [Tab]
        let surfaceView: SurfaceView
    }

    private func makeSurfaceOwningGroupFixture(tabCount: Int, targetIndex: Int) -> SurfaceOwningGroupFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tabs = (0..<tabCount).map { index -> Tab in
            if index == targetIndex {
                return Tab(title: "Tab \(index)", splitTree: SplitTree(leafID: leafID), registry: registry)
            }
            return Tab(title: "Tab \(index)")
        }
        let group = TabGroup(name: "Default", tabs: tabs, activeTabID: tabs.first?.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SurfaceOwningGroupFixture(controller: controller, group: group, tabs: tabs, surfaceView: surfaceView)
    }

    /// Same wrap-around scenario as `test_processMoveTab_reordersGroupTabs`
    /// above (`[Tab 0, Tab 1, Tab 2]`, move Tab 2 by +1 wraps to the
    /// front), but posted as the real `.ghosttyMoveTab` notification --
    /// exercises `handleMoveTabNotification`'s `findTab(for:)` routing and
    /// `userInfo["amount"]` extraction end to end, not just `processMoveTab`
    /// called directly.
    func test_ghosttyMoveTab_postedForOwnSurface_reordersGroupTabs() {
        let fixture = makeSurfaceOwningGroupFixture(tabCount: 3, targetIndex: 2)

        NotificationCenter.default.post(
            name: .ghosttyMoveTab,
            object: fixture.surfaceView,
            userInfo: ["amount": 1]
        )

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabs[2].id, fixture.tabs[0].id, fixture.tabs[1].id],
            "Posting .ghosttyMoveTab for a surface this window owns must resolve its owning tab/group and move it by amount"
        )
    }

    /// Regression guard: posting `.ghosttyMoveTab` for a surface NO
    /// controller's `windowSession` owns must leave every group's `tabs`
    /// order untouched -- depends on `handleMoveTabNotification`'s own
    /// `guard let (owningTab, owningGroup) = findTab(for:)` actually
    /// gating the dispatch.
    func test_ghosttyMoveTab_postedForSurfaceNoWindowOwns_doesNotReorderGroupTabs() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if findTab(for:)'s ownership
        // check were removed entirely.
        let fixture = makeSurfaceOwningGroupFixture(tabCount: 3, targetIndex: 2)
        let orphanSurfaceView = SurfaceView(frame: .zero)
        let idsBefore = fixture.group.tabs.map(\.id)

        NotificationCenter.default.post(
            name: .ghosttyMoveTab,
            object: orphanSurfaceView,
            userInfo: ["amount": 1]
        )

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            idsBefore,
            "Posting .ghosttyMoveTab for a surface no window owns must not reorder any group's tabs"
        )
    }
}
