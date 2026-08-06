//
//  AppDelegateAdjacentWindowIndexTests.swift
//  CalyxTests
//
//  TDD Red phase: GHOSTTY_ACTION_GOTO_WINDOW keybind wiring (app-scoped
//  action wiring, phase 1). `AppDelegate.adjacentWindowIndex(currentIndex:
//  step:count:)` is the pure index-arithmetic core of that action
//  (`GHOSTTY_GOTO_WINDOW_PREVIOUS`/`GHOSTTY_GOTO_WINDOW_NEXT` map to
//  `step: -1`/`step: +1` respectively — confirmed against
//  GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h, which declares
//  only those two cases, no index-targeted variant). It is currently an
//  empty stub (`{ nil }`) — `GhosttyActionRouter.handleAction` has no
//  case for `GHOSTTY_ACTION_GOTO_WINDOW` yet.
//
//  Deliberately does NOT test `AppDelegate.focusAdjacentWindow(step:)`
//  (the instance method that resolves real window candidates and calls
//  `makeKeyAndOrderFront`): that needs real, visible NSWindow instances
//  to exercise the isVisible/isKeyWindow/isMiniaturized filtering it is
//  responsible for, which is unsafe to drive in this test host (see this
//  cycle's own task brief). All of the bug-prone logic — the actual
//  index resolution — lives in `adjacentWindowIndex`, a `nonisolated
//  static` pure function with no NSWindow/NSApp access, so coverage is
//  concentrated there instead, mirroring `AppDelegateKeyMonitorTests`'
//  identical "test the pure static matcher, not the NSEvent-installing
//  instance method" split for `matchKeyEvent`.
//
//  Semantics under test (derived from the implementation spec, not by
//  simulating any particular implementation):
//    - count == 0, count == 1        -> nil (nothing to cycle to)
//    - step == 0                     -> nil (no direction requested)
//    - currentIndex == nil           -> always resolves to 0, regardless
//                                        of step's sign (no reference
//                                        point to step "from", so there
//                                        is nothing for a direction to
//                                        modify — this is a standalone
//                                        rule, not currentIndex ?? 0
//                                        substituted into the modular
//                                        step formula below)
//    - otherwise: resolvedIndex = properMod(currentIndex + step, count),
//      and if resolvedIndex == currentIndex, the result is nil (a full
//      cycle back to where we started is not a "move" at all)
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateAdjacentWindowIndexTests: XCTestCase {

    // ==================== count == 0 / count == 1 ====================

    func test_adjacentWindowIndex_countZero_returnsNil() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: nil, step: 1, count: 0)

        XCTAssertNil(result, "With zero windows there is nothing to focus")
    }

    func test_adjacentWindowIndex_countOne_returnsNil() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: 0, step: 1, count: 1)

        XCTAssertNil(result, "With exactly one window there is no OTHER window to cycle to")
    }

    // ==================== step == 0 ====================

    func test_adjacentWindowIndex_stepZero_returnsNil() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: 1, step: 0, count: 3)

        XCTAssertNil(result, "A zero step requests no direction, so there is nothing to resolve")
    }

    /// `step == 0` must win even when `currentIndex` is ALSO nil — proves
    /// the two guards are independent checks, not an if/else-if chain
    /// where a naive implementation might test `currentIndex == nil`
    /// first and return 0 without ever looking at `step`.
    func test_adjacentWindowIndex_stepZero_withNilCurrentIndex_returnsNil() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: nil, step: 0, count: 3)

        XCTAssertNil(result, "step == 0 must take priority over the nil-currentIndex '0 起点' rule")
    }

    // ==================== currentIndex == nil ("0 起点") ====================

    /// currentIndex == nil resolves to plain index 0 for a forward step —
    func test_adjacentWindowIndex_nilCurrentIndex_stepForward_returnsZero() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: nil, step: 1, count: 3)

        XCTAssertEqual(result, 0, "With no current window, the next-direction step must land on window 0")
    }

    /// — and for a backward step too: the "0 起点" rule is step-direction
    /// independent (NOT currentIndex ?? 0 substituted into the modular
    /// step formula below, which would instead give count - 1 = 2 here).
    func test_adjacentWindowIndex_nilCurrentIndex_stepBackward_returnsZero() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: nil, step: -1, count: 3)

        XCTAssertEqual(result, 0, "With no current window, the previous-direction step must ALSO land on window 0")
    }

    // ==================== Circular wraparound ====================

    /// Explicitly-given example: the last window, stepping forward, wraps
    /// to the first.
    func test_adjacentWindowIndex_stepForward_fromLastIndex_wrapsToZero() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: 2, step: 1, count: 3)

        XCTAssertEqual(result, 0, "count-1 stepping forward must wrap around to 0")
    }

    /// Symmetric case: the first window, stepping backward, wraps to the
    /// last.
    func test_adjacentWindowIndex_stepBackward_fromFirstIndex_wrapsToLastIndex() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: 0, step: -1, count: 3)

        XCTAssertEqual(result, 2, "Index 0 stepping backward must wrap around to count - 1")
    }

    // ==================== Non-wrapping (interior) steps ====================
    //
    // Guards against an implementation that only special-cases the
    // boundary wrap and gets the ordinary, non-wrapping case wrong.

    func test_adjacentWindowIndex_stepForward_fromInteriorIndex_movesByOne() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: 0, step: 1, count: 3)

        XCTAssertEqual(result, 1, "A forward step with no wrap involved must simply advance by one")
    }

    func test_adjacentWindowIndex_stepBackward_fromInteriorIndex_movesByOne() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: 2, step: -1, count: 3)

        XCTAssertEqual(result, 1, "A backward step with no wrap involved must simply retreat by one")
    }

    // ==================== Resolved index == currentIndex ====================

    /// A full cycle back to the starting index (here: three windows,
    /// stepping by exactly `count`) must resolve to nil, not to
    /// `currentIndex` itself — distinct from the count == 1 case above,
    /// which this rule would also cover, but only incidentally; this
    /// exercises the GENERAL "did we actually move" safety net on its
    /// own, with count > 1.
    func test_adjacentWindowIndex_stepEqualToCount_returnsNil() {
        let result = AppDelegate.adjacentWindowIndex(currentIndex: 1, step: 3, count: 3)

        XCTAssertNil(result, "Stepping by a full multiple of count returns to currentIndex, which must resolve to nil")
    }
}
