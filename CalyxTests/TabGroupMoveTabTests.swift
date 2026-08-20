//
//  TabGroupMoveTabTests.swift
//  CalyxTests
//
//  Missing observer:
//  `TabGroup.moveTab(fromIndex:by:)` is `GHOSTTY_ACTION_MOVE_TAB`'s intended
//  pure-logic core (via `CalyxWindowController.processMoveTab(tab:group:
//  amount:)`) but is currently an intentional no-op stub (see its own doc
//  comment in TabGroup.swift), so every test below that expects `group.tabs`
//  to actually reorder fails.
//
//  Semantics (confirmed by reading `ghostty/src/input/Binding.zig`'s
//  `move_tab` doc comment directly, not inferred): moving a tab WRAPS
//  cyclically at the ends, it does not clamp. `newIndex` for a move of
//  `amount` starting at `fromIndex` in a `count`-tab group is the
//  mathematical (never-negative) modulus `((fromIndex + amount) % count +
//  count) % count` -- Swift's own `%` returns a NEGATIVE result for a
//  negative left operand (e.g. `-5 % 3 == -2`, not `1`), so a correct
//  implementation needs that `+ count` renormalization step, not a bare
//  `%`. Several tests below exist specifically to catch an implementation
//  that skips it.
//
//  Every "no-op" test (amount 0, amount == count, count == 1, out-of-range
//  fromIndex) is, against TODAY's empty stub, a currently-vacuous pass --
//  the stub does nothing for EVERY input, so "nothing changed" trivially
//  holds regardless of whether the guard the test is meant to verify
//  actually exists. They stay in this suite as regression guards for the
//  real implementation (e.g. a missing `fromIndex` bounds check would crash
//  via `tabs.remove(at:)` rather than merely misbehave).

import XCTest
@testable import Calyx

@MainActor
final class TabGroupMoveTabTests: XCTestCase {

    // MARK: - Fixture

    /// Three distinctly-titled tabs, so a reordered `group.tabs.map(\.id)`
    /// is unambiguous to read in each assertion's failure message.
    private func makeThreeTabGroup() -> (group: TabGroup, tabA: Tab, tabB: Tab, tabC: Tab) {
        let tabA = Tab(title: "A")
        let tabB = Tab(title: "B")
        let tabC = Tab(title: "C")
        let group = TabGroup(tabs: [tabA, tabB, tabC])
        return (group, tabA, tabB, tabC)
    }

    // MARK: - Wrap: +1 / -1

    /// By hand: [A, B, C], move index 2 (C, the LAST tab) by +1.
    /// newIndex = ((2 + 1) % 3 + 3) % 3 = 0. Removing C leaves [A, B];
    /// inserting C at 0 gives [C, A, B] -- the last tab wraps to the front,
    /// exactly matching Binding.zig's own "move_tab:1 ... wraps around and
    /// becomes the first tab" example.
    func test_moveTab_byPositiveOne_wrapsLastTabToFront() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: 2, by: 1)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabC.id, fixture.tabA.id, fixture.tabB.id],
            "amount: +1 on the last tab must wrap it to the front of the list"
        )
    }

    /// By hand: [A, B, C], move index 0 (A, the FIRST tab) by -1.
    /// Real-math modulus: (0 - 1) mod 3 = 2 (NOT Swift's raw `-1 % 3 ==
    /// -1`). Removing A leaves [B, C]; inserting A at 2 (the end) gives
    /// [B, C, A] -- the first tab wraps to the end, matching Binding.zig's
    /// "move_tab:-1 ... if it was the first tab, then it will become the
    /// last tab".
    func test_moveTab_byNegativeOne_wrapsFirstTabToEnd() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: 0, by: -1)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabB.id, fixture.tabC.id, fixture.tabA.id],
            "amount: -1 on the first tab must wrap it to the end of the list"
        )
    }

    // MARK: - No-Op: amount 0

    /// By hand: newIndex = ((1 + 0) % 3 + 3) % 3 = 1 == fromIndex, so this
    /// must be a no-op. NOTE: against today's empty stub this test is a
    /// vacuous pass (nothing changes for ANY input) -- see this file's
    /// header comment.
    func test_moveTab_byZero_isNoOp() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: 1, by: 0)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabA.id, fixture.tabB.id, fixture.tabC.id],
            "amount: 0 must never reorder tabs"
        )
    }

    // MARK: - Wrap: |amount| > count

    /// By hand: newIndex = ((0 + 5) % 3 + 3) % 3 = (2 + 3) % 3 = 2 -- the
    /// same landing position a plain amount: 2 would produce (5 mod 3 ==
    /// 2), i.e. one full lap plus two steps. Removing A (index 0) leaves
    /// [B, C]; inserting A at index 2 gives [B, C, A].
    func test_moveTab_byAmountExceedingCount_wrapsToEquivalentSmallerAmount() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: 0, by: 5)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabB.id, fixture.tabC.id, fixture.tabA.id],
            "amount: +5 with count 3 must land where amount: +2 would (5 mod 3 == 2)"
        )
    }

    /// By hand: real-math modulus (0 - 5) mod 3 = 1 (NOT Swift's raw
    /// `-5 % 3 == -2`, and NOT `-2` naively renormalized without the `+
    /// count` step either -- `((-5 % 3) + 3) % 3 == ((-2) + 3) % 3 == 1`).
    /// Removing A (index 0) leaves [B, C]; inserting A at index 1 gives
    /// [B, A, C]. Large-magnitude negative counterpart to the +5 test
    /// above; a naive `(fromIndex + amount) % count` without the `+ count`
    /// renormalization would compute an invalid negative index here and
    /// crash `Array.insert(at:)`, not just misbehave.
    func test_moveTab_byNegativeAmountExceedingCount_wrapsToEquivalentSmallerAmount() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: 0, by: -5)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabB.id, fixture.tabA.id, fixture.tabC.id],
            "amount: -5 with count 3 must land at the real-math modulus position (1), not crash or " +
            "misplace the tab"
        )
    }

    // MARK: - No-Op: amount == count (full lap)

    /// By hand: newIndex = ((1 + 3) % 3 + 3) % 3 = (1 + 3) % 3 = 1 ==
    /// fromIndex, a full lap back to the start. NOTE: currently a vacuous
    /// pass against the empty stub -- see this file's header comment.
    func test_moveTab_byAmountEqualToCount_isNoOp() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: 1, by: 3)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabA.id, fixture.tabB.id, fixture.tabC.id],
            "amount: 3 (== count) must be a no-op, a full lap back to the same position"
        )
    }

    // MARK: - No-Op: single-tab group

    /// A single-tab group has nowhere else to put the tab: newIndex =
    /// ((0 + 1) % 1 + 1) % 1 = 0 == fromIndex for ANY amount. NOTE:
    /// currently a vacuous pass against the empty stub -- see this file's
    /// header comment; the real value of this test is guarding against a
    /// future implementation that divides by `tabs.count - 1` (a division-
    /// by-zero trap for a 1-tab group) instead of `tabs.count`.
    func test_moveTab_withSingleTab_isNoOp() {
        let onlyTab = Tab(title: "Solo")
        let group = TabGroup(tabs: [onlyTab])

        group.moveTab(fromIndex: 0, by: 1)

        XCTAssertEqual(
            group.tabs.map(\.id),
            [onlyTab.id],
            "A single-tab group must never change, and moveTab must not crash on it"
        )
    }

    // MARK: - Regression Guard: activeTabID Survives a Move

    /// The most important regression guard: `activeTabID` is UUID-based
    /// (`TabGroup`'s own header: "ID-based selection for safety"), so a
    /// correct remove-then-reinsert implementation (mirroring the sibling
    /// `moveTab(fromIndex:toIndex:)` immediately above in TabGroup.swift)
    /// preserves it automatically, with no explicit reassignment needed --
    /// UNLIKE `removeTab(id:)`, which DOES explicitly recompute
    /// `activeTabID` by index after a removal. An implementation that
    /// copies that index-recomputation pattern into `moveTab(fromIndex:
    /// by:)` (a plausible mistake to make by analogy) would corrupt
    /// `activeTabID` here even while still reordering `tabs` correctly.
    ///
    /// By hand: same movement as `test_moveTab_byPositiveOne_
    /// wrapsLastTabToFront` above (index 2 by +1 => [C, A, B]), but with
    /// the MOVED tab (C) set as the active one beforehand -- the case most
    /// likely to expose an index-based (rather than id-based) active-tab
    /// bug, since C's index changes from 2 to 0.
    func test_moveTab_preservesActiveTabID_whenActiveTabIsTheOneMoved() {
        let fixture = makeThreeTabGroup()
        fixture.group.activeTabID = fixture.tabC.id

        fixture.group.moveTab(fromIndex: 2, by: 1)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabC.id, fixture.tabA.id, fixture.tabB.id],
            "Precondition for this regression guard to mean anything: the move must actually reorder tabs"
        )
        XCTAssertEqual(
            fixture.group.activeTabID,
            fixture.tabC.id,
            "activeTabID must keep pointing at the same tab (by id) after it moves, even though its index changed"
        )
        XCTAssertTrue(
            fixture.group.activeTab === fixture.tabC,
            "activeTab must resolve to the moved tab at its NEW position, not lose it or resolve to a different tab"
        )
    }

    // MARK: - No-Op: Out-of-Range fromIndex

    /// `fromIndex` far past the end of the list must be safely ignored,
    /// not crash `tabs.remove(at:)`. NOTE: currently a vacuous pass against
    /// the empty stub -- see this file's header comment.
    func test_moveTab_withFromIndexPastTheEnd_isNoOp() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: 99, by: 1)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabA.id, fixture.tabB.id, fixture.tabC.id],
            "An out-of-range fromIndex must be a safe no-op, not a crash"
        )
    }

    /// Same guard as above, negative side. NOTE: currently a vacuous pass
    /// against the empty stub -- see this file's header comment.
    func test_moveTab_withNegativeFromIndex_isNoOp() {
        let fixture = makeThreeTabGroup()

        fixture.group.moveTab(fromIndex: -1, by: 1)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.tabA.id, fixture.tabB.id, fixture.tabC.id],
            "A negative fromIndex must be a safe no-op, not a crash"
        )
    }
}
