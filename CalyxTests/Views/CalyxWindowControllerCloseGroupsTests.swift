// CalyxWindowControllerCloseGroupsTests.swift
// CalyxTests
//
// Covers the group-close batch entry points on `CalyxWindowController`
// (Calyx/Views/MainWindow/CalyxWindowController.swift):
// `closeGroups(relativeTo:mode:)` (the shared entry, resolving
// `GroupCloseMode` against `windowSession.groups` order, used by the
// group context menu's `.others`/`.below` and by the single-group paths
// `closeActiveGroup()`/`closeAllTabsInGroup(id:)` via `.this`) and
// `closeGroups(_:)` (closes every tab of every given group through one
// batch). Also covers the delegation of the EXISTING `closeActiveGroup()`
// (via the public `closeGroup(_:)` action) and `closeAllTabsInGroup(id:)`
// onto that same batch path.
//
// `ThreeGroupFixture` (`CalyxTests/GroupControllerFixture.swift`): A
// (tabs [a0, a1], active a0, the window's active group), B (tabs
// [b0, b1, b2], active b0), C (tab [c0], active c0), groups in order
// [A, B, C].
//
// Every expected `groups`/`activeGroupID`/`activeTabID` value below was
// computed BY HAND from `WindowSession.removeGroup(id:)`'s own rule
// (emptying a group removes it; if it was the active group, the
// neighbour at the same index -- or the last group if that index no
// longer exists -- becomes active) and `TabGroup.removeTab(id:)`'s own
// rule (removing the active tab promotes the survivor at the same
// index, or the last remaining tab if none), applied once per victim
// tab in the order `closeGroups(_:)` closes them: group by group, in
// the order the victim groups were given, tabs within a group in their
// existing order -- NOT by running the implementation and reading back
// its output.
//
// The activation count is read through the DEBUG-only test seam
// `_activateCurrentTabCountForTesting`, as a DELTA: captured immediately
// before the call under test and compared after, since controller
// construction may or may not itself call `activateCurrentTab()`.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseGroupsTests: XCTestCase {

    // MARK: - .others

    /// `.others` on B: victims = groups.filter { $0.id != B.id } = [A, C]
    /// (order preserved). By hand: closing a0 (active, a victim) leaves A
    /// at [a1] with a1 promoted active; closing a1 next empties A, which
    /// is removed -- A was the active group, so its neighbour at the
    /// same index (now B) becomes active, with B's own activeTabID (b0)
    /// untouched. Closing c0 next empties C, which is removed -- C was
    /// never the active group (now B), so activeGroupID is left as B.
    /// End state: groups == [B], active B, B.activeTabID == b0. The
    /// window's active tab (a0) was among the victims, so
    /// `activateCurrentTab()` must run exactly once (only once, at the
    /// end, not per intermediate group removal).
    func test_others_targetB_closesAthenC_activeChainMigratesToB_activatesOnce() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupB.id, mode: .others)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupB.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupB.id)
        XCTAssertEqual(fixture.groupB.activeTabID, fixture.tabsB[0].id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
        XCTAssertTrue(fixture.controller._closingTabIDsForTesting.isEmpty)
    }

    /// `.others` on A: victims = [B, C]. By hand: neither B nor C is the
    /// active group and A's own active tab (a0) is never touched, so
    /// `activeGroupID` stays A throughout and `activateCurrentTab()`
    /// must run zero times. A's own tabs are completely untouched.
    func test_others_targetA_closesBandC_activeStaysA_doesNotActivate() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupA.id, mode: .others)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.groupA.tabs.map(\.id), [fixture.tabsA[0].id, fixture.tabsA[1].id])
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    /// `.others` on C: victims = [A, B]. By hand: closing all of A first
    /// empties it (A was active), migrating activeGroupID to B (the
    /// group now at A's old index); closing all of B next empties B too
    /// (B is now the active group), migrating activeGroupID again, this
    /// time to C (the sole remaining group). The window's active tab
    /// (a0) was among the victims, so `activateCurrentTab()` must run
    /// exactly once.
    func test_others_targetC_closesAthenB_chainMigratesAtoBtoC_activatesOnce() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupC.id, mode: .others)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupC.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupC.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
    }

    // MARK: - .below

    /// `.below` on A (index 0): victims = groups[1...] = [B, C], the
    /// same set and order as `.others` on A above, so the same
    /// end state and zero activations.
    func test_below_targetA_closesBandC_activeStaysA_doesNotActivate() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupA.id, mode: .below)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    /// `.below` on B (index 1): victims = groups[2...] = [C] only. By
    /// hand: closing c0 empties C, which is removed; C was never the
    /// active group (A is), so activeGroupID is left as A, and A's own
    /// active tab (a0) was never touched, so `activateCurrentTab()` must
    /// run zero times. The right-clicked group (B) survives, untouched
    /// and non-active.
    func test_below_targetB_closesOnlyC_rightClickedGroupStaysNonActive() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupB.id, mode: .below)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id, fixture.groupB.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    /// `windowSession.activeGroupID` is first moved to C (so C, not A,
    /// is the window's active group; C's own activeTabID stays c0), then
    /// `.below` is fired on A (index 0): victims = groups[1...] = [B, C]
    /// again. By hand: closing all of B first (not active) leaves
    /// activeGroupID at C untouched; closing all of C next (now the
    /// active group, its own active tab c0 IS a victim) empties C, which
    /// is removed -- C was active, so its neighbour at the same removed
    /// index (now out of range: A is the sole survivor) becomes active:
    /// A. The window's active tab (c0, read once before the loop) was
    /// among the victims, so `activateCurrentTab()` must run exactly
    /// once.
    func test_below_activeIsC_targetA_closesBandC_activeBecomesA_activatesOnce() {
        let fixture = ThreeGroupFixture.make()
        fixture.session.activeGroupID = fixture.groupC.id
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupA.id, mode: .below)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
    }

    // MARK: - .this

    /// `.this` on the non-active B: victims = [B] only. By hand: closing
    /// all of B empties it, which is removed; B was never the active
    /// group (A is), so activeGroupID is left as A, and A's own active
    /// tab (a0) was never touched, so `activateCurrentTab()` must run
    /// zero times.
    func test_this_nonActiveB_removed_activeUnchanged_doesNotActivate() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupB.id, mode: .this)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id, fixture.groupC.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    // MARK: - No-ops

    /// `.below` on the LAST group (C, index 2 of 3): `groups[3...]` is
    /// an empty slice, so there is nothing to close at all.
    func test_below_onLastGroup_isNoOp() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: fixture.groupC.id, mode: .below)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id, fixture.groupB.id, fixture.groupC.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    /// An unknown group id (not present in `windowSession.groups`) must
    /// be a complete no-op: no group is found, so no victims are ever
    /// resolved.
    func test_unknownGroupID_isNoOp() {
        let fixture = ThreeGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroups(relativeTo: UUID(), mode: .others)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id, fixture.groupB.id, fixture.groupC.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    // MARK: - Every group closes: the window itself closes

    /// `AppDelegate` subclass that suppresses the real, async
    /// `SessionPersistenceActor`-backed `requestSave()` -- left
    /// unmocked, it would reach the real `AppDelegate.requestSave()`
    /// and risk a real, if empty, write to the developer's actual
    /// `~/.calyx` (see `ConfirmQuitCallCountAppDelegate`'s own doc
    /// comment in `CalyxWindowControllerCloseArmsTests.swift` for the
    /// confirmed-by-observation incident this mirrors).
    /// `removeWindowController`'s no-op override comes from the shared
    /// `ConfirmQuitMockAppDelegate` base (test-process safety only: a
    /// real close here reaches `window?.close()` -> `windowWillClose` ->
    /// `AppDelegate.removeWindowController`).
    private final class SaveSuppressingAppDelegate: ConfirmQuitMockAppDelegate {
        override func requestSave() {}
    }

    /// Closing every group in the window (`closeGroups(session.groups)`)
    /// must empty `windowSession.groups` entirely and drive the window
    /// through `closeLastWindow()`, setting `isClosingForShutdown`.
    func test_allGroups_windowCloses_setsIsClosingForShutdown() {
        let fixture = ThreeGroupFixture.make()
        let mock = SaveSuppressingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeGroups(fixture.session.groups)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown)
        XCTAssertTrue(fixture.session.groups.isEmpty)
        XCTAssertTrue(fixture.controller._closingTabIDsForTesting.isEmpty)
    }

    // MARK: - closingTabIDs cleanup (non-window-closing case)

    /// After any batch that does not empty the whole window, every
    /// victim tab must have been removed from `closingTabIDs` again
    /// (inserted before prompting, removed after teardown).
    func test_afterBatch_closingTabIDsEmpty() {
        let fixture = ThreeGroupFixture.make()

        fixture.controller.closeGroups(relativeTo: fixture.groupB.id, mode: .this)

        XCTAssertTrue(fixture.controller._closingTabIDsForTesting.isEmpty)
    }

    // MARK: - Existing entry points delegate onto the same batch path

    /// `closeGroup(_:)` (the public action wired to the "Close Group"
    /// menu item and `closeActiveGroup()`) must delegate onto the same
    /// batch path as the group-menu entry points, closing the window's
    /// entire active group (A) in one batch. By hand (`TwoGroupFixture`:
    /// A [A0, A1] active A0, the window's active group; B [B0, B1, B2]
    /// active B0): closing A0 (active) leaves [A1] with A1 promoted
    /// active; closing A1 next empties A, which is removed -- A was
    /// active, so its neighbour at the same index (now B) becomes
    /// active, B's own activeTabID (B0) untouched. The window's active
    /// tab (A0) was among the victims, so `activateCurrentTab()` must
    /// run exactly once.
    func test_closeActiveGroup_viaCloseGroupAction_delegatesToBatch() {
        let fixture = TwoGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeGroup(nil)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupB.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupB.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 1)
    }

    /// `closeAllTabsInGroup(id:)` on the NON-active group (B) must
    /// delegate onto the same batch path, closing all of B in one batch
    /// while leaving A (the window's active group, never touched)
    /// completely alone. B was never the active group, so
    /// `activateCurrentTab()` must run zero times.
    func test_closeAllTabsInGroup_nonActive_delegatesToBatch() {
        let fixture = TwoGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeAllTabsInGroup(id: fixture.groupB.id)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    // MARK: - Empty groups

    /// `closeAllTabsInGroup(id:)` on a group with zero tabs must still
    /// remove it: `closeGroups(_:)` passes it through as `emptyGroups`
    /// even though it contributes no tab victims, so the batch's
    /// `guard !tabsToClose.isEmpty || !emptyGroups.isEmpty` never
    /// short-circuits before `windowSession.removeGroup(id:)` runs. A
    /// (the window's active group) is never touched: the empty group was
    /// never active, so `activateCurrentTab()` must run zero times and
    /// no tab ever enters `closingTabIDs`.
    func test_closeAllTabsInGroup_emptyGroup_removesIt() {
        let fixture = TwoGroupFixture.make()
        let empty = TabGroup(name: "Empty")
        fixture.session.addGroup(empty)
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.closeAllTabsInGroup(id: empty.id)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id, fixture.groupB.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
        XCTAssertTrue(fixture.controller._closingTabIDsForTesting.isEmpty)
    }

    /// `closeActiveGroup()` (via `closeGroup(nil)`) on a window whose
    /// only OTHER group is empty must close the window: removing the
    /// active, single-tab group leaves only the empty group, which has
    /// no active tab, so the tail's "no group remains OR the active
    /// group has no active tab" condition is satisfied by the second
    /// half and `closeLastWindow()` runs.
    func test_closeActiveGroup_onlyOtherGroupIsEmpty_closesWindow() {
        let fixture = GroupFixture.make(tabCount: 1)
        let empty = TabGroup(name: "Empty")
        fixture.session.addGroup(empty)
        let mock = SaveSuppressingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeGroup(nil)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown)
    }

    /// `.others` on B (`ThreeGroupFixture`) with an appended empty group
    /// E among the victims: E contributes no tab victims but must still
    /// be removed, leaving only the right-clicked group B.
    func test_others_emptyGroupAmongVictims_isRemoved() {
        let fixture = ThreeGroupFixture.make()
        let empty = TabGroup(name: "Empty")
        fixture.session.addGroup(empty)

        fixture.controller.closeGroups(relativeTo: fixture.groupB.id, mode: .others)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupB.id])
    }
}
