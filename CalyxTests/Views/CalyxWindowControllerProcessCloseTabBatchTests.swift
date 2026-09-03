// CalyxWindowControllerProcessCloseTabBatchTests.swift
// CalyxTests
//
// Covers `CalyxWindowController.processCloseTab(tab:group:mode:)` for
// `GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER`/`_RIGHT`: both close their
// victims through one batch, `closeTabs(_:in:)` (not `private`, so this
// file can exercise it directly for the group-emptying cases below),
// which deactivates the current tab at most once, tears down every
// victim, removes them from the group, then activates the current tab at
// most once. `activateCurrentTab()` runs exactly once when the window's
// active tab was among the victims or `windowSession.activeGroupID`
// changed as a result of the close, and not at all otherwise. `THIS` is
// unaffected: it always closes only the target via the single-tab
// `closeTab(id:)` path.
//
// When the victims are every tab of `group`, `WindowSession.removeTab`
// removes the now-empty group; if no group is left, the window closes
// via `closeLastWindow()` (`isClosingForShutdown = true`, then
// `window?.close()`); otherwise, if the emptied group was the window's
// active group, `activeGroupID` is reassigned to the group now at the
// emptied group's index, or the last group if that index no longer
// exists. If the emptied group was NOT the active group, `activeGroupID`
// is left unchanged.
//
// The activation count is read through the DEBUG-only test seam
// `_activateCurrentTabCountForTesting` (incremented at the top of
// `activateCurrentTab()`), as a DELTA: captured immediately before
// `processCloseTab`/`closeTabs(_:in:)` and compared after, since
// controller construction may or may not itself call
// `activateCurrentTab()`.
//
// Every expected `tabs`/`activeTabID` value below was computed BY HAND
// from `TabGroup.removeTab(id:)`'s own rule ("if the removed tab was
// active: the tab now at the same index, else the last remaining tab"),
// applied once per victim in the order `closeTabs(_:in:)` closes them
// (`OTHER`: every other tab in original tab-bar order; `RIGHT`: tabs
// positioned after the target, in original tab-bar order) -- NOT by
// running the implementation and reading back its output.

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerProcessCloseTabBatchTests: XCTestCase {

    // MARK: - OTHER

    /// tabs [t0, t1, t2], target t1, active t0 (a victim), single active
    /// group. By hand (per-victim application of `TabGroup.removeTab(id:)`):
    /// closing t0 (active) leaves [t1, t2] with the survivor at the same
    /// index (0) becoming active: t1; closing t2 next (not active) leaves
    /// [t1], activeTabID unchanged (t1). The active tab was among the
    /// victims and the group is the window's active group, so
    /// `activateCurrentTab()` must run exactly once.
    func test_other_activeIsVictim_activeGroup_activatesOnce() {
        let fixture = GroupFixture.make(tabCount: 3)
        let target = fixture.tabs[1]
        fixture.group.activeTabID = fixture.tabs[0].id
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
        XCTAssertEqual(fixture.group.tabs.map(\.id), [target.id])
        XCTAssertEqual(fixture.group.activeTabID, target.id)
    }

    /// tabs [t0, t1, t2], target t1, active t2 (a victim). By hand:
    /// closing t0 (not active) leaves [t1, t2] unchanged active; closing
    /// t2 (active) next leaves only [t1], so activeTabID falls to the
    /// last remaining tab: t1. Active tab was a victim in the active
    /// group, so `activateCurrentTab()` must run exactly once.
    func test_other_activeIsSecondVictim_activeGroup_activatesOnce() {
        let fixture = GroupFixture.make(tabCount: 3)
        let target = fixture.tabs[1]
        fixture.group.activeTabID = fixture.tabs[2].id
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
        XCTAssertEqual(fixture.group.tabs.map(\.id), [target.id])
        XCTAssertEqual(fixture.group.activeTabID, target.id)
    }

    /// OTHER on the LAST tab of [t0, t1, t2] (target = t2), active t0
    /// (a victim). By hand: closing t0 (active) leaves [t1, t2], survivor
    /// at index 0 becomes active: t1; closing t1 next (active) leaves
    /// only [t2], activeTabID falls to the last remaining tab: t2. Active
    /// tab was a victim in the active group, so `activateCurrentTab()`
    /// must run exactly once.
    func test_other_targetIsLastTab_activeIsVictim_activeGroup_activatesOnce() {
        let fixture = GroupFixture.make(tabCount: 3)
        let target = fixture.tabs[2]
        fixture.group.activeTabID = fixture.tabs[0].id
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
        XCTAssertEqual(fixture.group.tabs.map(\.id), [target.id])
        XCTAssertEqual(fixture.group.activeTabID, target.id)
    }

    /// The batch inserts every victim into `closingTabIDs` before the
    /// prompts and must remove them all after teardown.
    func test_other_afterBatch_closingTabIDsIsEmpty() {
        let fixture = GroupFixture.make(tabCount: 3)
        let target = fixture.tabs[1]

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertTrue(fixture.controller._closingTabIDsForTesting.isEmpty)
        XCTAssertEqual(fixture.group.tabs.map(\.id), [target.id])
    }

    // MARK: - RIGHT

    /// tabs [t0, t1, t2, t3], target t1, active t3 (a victim). By hand:
    /// closing t2 (not active) leaves [t0, t1, t3] unchanged active;
    /// closing t3 (active) next leaves [t0, t1], so activeTabID falls to
    /// the last remaining tab: t1. Active tab was a victim in the active
    /// group, so `activateCurrentTab()` must run exactly once.
    func test_right_activeIsLastVictim_activeGroup_activatesOnce() {
        let fixture = GroupFixture.make(tabCount: 4)
        let target = fixture.tabs[1]
        fixture.group.activeTabID = fixture.tabs[3].id
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT)

        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
        XCTAssertEqual(fixture.group.tabs.map(\.id), [fixture.tabs[0].id, target.id])
        XCTAssertEqual(fixture.group.activeTabID, target.id)
    }

    /// tabs [t0, t1, t2, t3], target t1, active t0 (survives -- not a
    /// victim). By hand: closing t2 then t3, neither is active, so
    /// activeTabID never changes: stays t0. Active tab was never among
    /// the victims, so `activateCurrentTab()` must run zero times.
    func test_right_activeSurvivesLeftOfTarget_doesNotActivate() {
        let fixture = GroupFixture.make(tabCount: 4)
        let target = fixture.tabs[1]
        fixture.group.activeTabID = fixture.tabs[0].id
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT)

        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
        XCTAssertEqual(fixture.group.tabs.map(\.id), [fixture.tabs[0].id, target.id])
        XCTAssertEqual(fixture.group.activeTabID, fixture.tabs[0].id)
    }

    /// tabs [t0, t1, t2, t3], target t1, active t1 (the target itself --
    /// survives, never a victim). By hand: closing t2 then t3, neither is
    /// active, so activeTabID never changes: stays t1.
    /// `activateCurrentTab()` must run zero times.
    func test_right_activeIsTargetItself_doesNotActivate() {
        let fixture = GroupFixture.make(tabCount: 4)
        let target = fixture.tabs[1]
        fixture.group.activeTabID = target.id
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT)

        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
        XCTAssertEqual(fixture.group.tabs.map(\.id), [fixture.tabs[0].id, target.id])
        XCTAssertEqual(fixture.group.activeTabID, target.id)
    }

    // MARK: - Two groups (non-active group is untouched)

    /// Two groups in one `WindowSession`: A (tabs [a0, a1], active a0,
    /// the window's active group) and B (tabs [b0, b1, b2], active b0).
    /// OTHER targeting b1 in B. By hand for B (same derivation as
    /// `test_other_activeIsVictim_activeGroup_activatesOnce` above):
    /// closing b0 (active) leaves [b1, b2], survivor at index 0 becomes
    /// active: b1; closing b2 next (not active) leaves [b1] unchanged
    /// active. B's own active tab (b0) is among its victims, but B is
    /// NOT the window's active group -- the window's active tab is a0,
    /// which is never touched -- so `activateCurrentTab()` must run zero
    /// times, and A / `session.activeGroupID` stay completely untouched.
    func test_twoGroups_targetInNonActiveGroup_doesNotActivate_otherGroupUntouched() {
        let fixture = TwoGroupFixture.make()
        let target = fixture.tabsB[1]
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.processCloseTab(tab: target, group: fixture.groupB, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(
            fixture.controller._activateCurrentTabCountForTesting - before, 0,
            "The window's active tab lives in group A, never touched by a close in group B"
        )
        XCTAssertEqual(fixture.groupB.tabs.map(\.id), [target.id], "Group B must end with only the target tab")
        XCTAssertEqual(fixture.groupB.activeTabID, target.id, "Group B's activeTabID must become the target")
        XCTAssertEqual(fixture.groupA.tabs.map(\.id), fixture.tabsA.map(\.id), "Group A's tabs must be completely untouched")
        XCTAssertEqual(fixture.groupA.activeTabID, fixture.tabsA[0].id, "Group A's activeTabID must be completely untouched")
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id, "windowSession.activeGroupID must be completely untouched")
    }

    // MARK: - THIS

    /// `GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS` always closes only the
    /// target, through the single-tab `closeTab(id:)` path, never the
    /// batch `closeTabs(_:in:)` path OTHER/RIGHT use. By hand: starting
    /// tabs [t0, t1], active t0; closing t0 with THIS must leave exactly
    /// [t1], active t1. No count assertion: this test only documents
    /// that THIS never goes through the batch path.
    func test_this_closesOnlyTargetTab_unaffectedByBatchPath() {
        let fixture = GroupFixture.make(tabCount: 2)
        let target = fixture.tabs[0]
        let survivor = fixture.tabs[1]
        fixture.group.activeTabID = target.id

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS)

        XCTAssertEqual(fixture.group.tabs.map(\.id), [survivor.id])
        XCTAssertEqual(fixture.group.activeTabID, survivor.id)
    }

    // MARK: - Group empties

    /// A single group of 3, victims = all three tabs, driven through the
    /// internal `closeTabs(_:in:)` directly: OTHER and RIGHT always
    /// leave their target behind, so neither mode can ever empty a group
    /// on its own. By hand: after removing all three, `WindowSession
    /// .removeTab` finds the group empty and removes it; with no group
    /// left, the window closes via `closeLastWindow()`.
    func test_allTabsInOnlyGroup_windowCloses() {
        let fixture = GroupFixture.make(tabCount: 3)
        // Test-process safety only, mirroring
        // CalyxWindowControllerCloseArmsTests: closeLastWindow() runs a
        // real window?.close(), which reaches AppDelegate.removeWindowController.
        let mock = ConfirmQuitMockAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeTabs(fixture.tabs, in: fixture.group)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown, "Emptying the only group must close the window")
        XCTAssertTrue(fixture.session.groups.isEmpty, "The emptied group must be removed, leaving no group at all")
    }

    /// Two groups: A (tabs [a0, a1], active a0, the window's active
    /// group) and B (tabs [b0, b1, b2], active b0). Victims = all of B
    /// (the non-active group). By hand: B is removed at index 1, leaving
    /// only A; B was never the window's active group, so `activeGroupID`
    /// is left unchanged (A). A's own tab was never touched, and the
    /// active tab (a0) was never a victim, so `activateCurrentTab()` must
    /// run zero times.
    func test_twoGroups_allOfNonActiveGroup_thatGroupIsRemoved_activeGroupUnchanged() {
        let fixture = TwoGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeTabs(fixture.tabsB, in: fixture.groupB)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.groupA.tabs.map(\.id), fixture.tabsA.map(\.id))
        XCTAssertEqual(fixture.groupA.activeTabID, fixture.tabsA[0].id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    /// Same two groups as above. Victims = all of A (the active group).
    /// By hand: closing a0 (active) leaves [a1], survivor becomes active:
    /// a1; closing a1 next (now active) leaves A empty, so A is removed
    /// at index 0; the neighbour is `groups[0]` = B, so `activeGroupID`
    /// becomes B, and B's own `activeTabID` (b0) is untouched. A's active
    /// tab (a0) was a victim in the active group, so `activateCurrentTab()`
    /// must run exactly once.
    func test_twoGroups_allOfActiveGroup_thatGroupIsRemoved_activeGroupBecomesTheOther() {
        let fixture = TwoGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeTabs(fixture.tabsA, in: fixture.groupA)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupB.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupB.id)
        XCTAssertEqual(fixture.groupB.activeTabID, fixture.tabsB[0].id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
    }

    /// Three groups: A (tabs [a0, a1], active a0, the window's active
    /// group), B (tabs [b0, b1, b2], active b0) and C (tab [c0], active
    /// c0). Victims = all of B (a non-active, middle group). By hand: B
    /// is removed at index 1, leaving [A, C]; B was never the window's
    /// active group, so `activeGroupID` is left unchanged (A). Neither A
    /// nor C was touched, and the active tab (a0) was never a victim, so
    /// `activateCurrentTab()` must run zero times.
    func test_threeGroups_allOfMiddleNonActiveGroup_thatGroupIsRemoved_activeGroupUnchanged() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeTabs(fixture.tabsB, in: fixture.groupB)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id, fixture.groupC.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.groupA.activeTabID, fixture.tabsA[0].id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }
}
