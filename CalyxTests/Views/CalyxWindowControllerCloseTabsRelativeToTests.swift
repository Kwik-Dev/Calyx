// CalyxWindowControllerCloseTabsRelativeToTests.swift
// CalyxTests
//
// Covers `CalyxWindowController.closeTabs(relativeTo:mode:)`: it
// resolves the tab (and its owning group) among
// `windowSession.groups` by `tabID`, then delegates to the existing
// `processCloseTab(tab:group:mode:)` (see
// `CalyxWindowControllerCloseTabTests`/`CalyxWindowControllerProcessCloseTabBatchTests`
// for that method's own OTHER/RIGHT coverage, which this file does not
// repeat). What's specific to this call boundary: id resolution to the
// owning group, an unknown id being a no-op, and targeting a tab in a
// non-active group.
//
// Every expected `tabs`/`activeTabID` value below was computed BY HAND
// from `TabGroup.removeTab(id:)`'s own rule ("if the removed tab was
// active: the tab now at the same index, else the last remaining tab"),
// applied once per victim in the order `processCloseTab` closes them
// (`OTHER`: every other tab in original tab-bar order) -- NOT by
// running the implementation and reading back its output.

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseTabsRelativeToTests: XCTestCase {

    // MARK: - Unknown tabID

    /// A `tabID` that matches no tab in any group must be a complete
    /// no-op: `tabs`/`activeTabID` stay exactly as they started.
    func test_unknownTabID_isNoOp_leavesTabsAndActiveUnchanged() {
        let fixture = GroupFixture.make(tabCount: 3)
        fixture.group.activeTabID = fixture.tabs[0].id
        let expectedIDs = fixture.tabs.map(\.id)

        fixture.controller.closeTabs(relativeTo: UUID(), mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(fixture.group.tabs.map(\.id), expectedIDs)
        XCTAssertEqual(fixture.group.activeTabID, fixture.tabs[0].id)
    }

    // MARK: - Two groups

    /// Two independent groups in one `WindowSession`: A (tabs [a0, a1],
    /// active a0) and B (tabs [b0, b1, b2], active b0). Targeting b1 in
    /// B with OTHER must only affect B. By hand: OTHER closes b0 then b2
    /// (original order, excluding b1). Closing b0 (B's active tab)
    /// leaves [b1, b2] with the survivor now at the same index (0)
    /// becoming active: b1. Closing b2 next (not active) leaves [b1],
    /// activeTabID unchanged (b1). A and `windowSession.activeGroupID`
    /// must be completely untouched.
    func test_twoGroups_targetInSecondGroup_onlyThatGroupChanges_otherGroupAndActiveGroupIDUntouched() {
        let fixture = TwoGroupFixture.make()
        let target = fixture.tabsB[1]

        fixture.controller.closeTabs(relativeTo: target.id, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(fixture.groupB.tabs.map(\.id), [target.id], "Group B must end with only the target tab")
        XCTAssertEqual(fixture.groupB.activeTabID, target.id, "Group B's activeTabID must become the target")
        XCTAssertEqual(fixture.groupA.tabs.map(\.id), fixture.tabsA.map(\.id), "Group A's tabs must be completely untouched")
        XCTAssertEqual(fixture.groupA.activeTabID, fixture.tabsA[0].id, "Group A's activeTabID must be completely untouched")
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id, "windowSession.activeGroupID must be completely untouched")
    }
}
