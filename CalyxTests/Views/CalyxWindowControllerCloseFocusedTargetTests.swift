//
//  CalyxWindowControllerCloseFocusedTargetTests.swift
//  CalyxTests
//
//  TDD Red phase, GitHub issue #45 ("Cmd+W does nothing on the About/
//  Settings/Session Browser panel, and worse, closes the wrong terminal
//  window's tab"). Full root-cause writeup: `NSWindow+CalyxClose.swift`'s
//  header comment.
//
//  `CalyxWindowController.closeFocusedTarget(tabID:content:focusedLeafID:)`
//  is the pure decision of which of a window's focused pane, tab, or the
//  window itself Cmd+W (`CalyxWindow.calyxPerformClose(_:)`) should
//  close — mirrors this codebase's established "pure static decision
//  function, unit-tested directly, no NSWindow/NSApp access" idiom
//  (`AppDelegate.adjacentWindowIndex`, `AppDelegate.matchKeyEvent`,
//  `CalyxWindow.shouldPerformZoom`). It is currently an empty stub that
//  unconditionally returns `.window`.
//
//  Expected values below are derived directly from the spec (see
//  `CloseFocusedTarget`'s own doc comment in CalyxWindowController.swift),
//  not by simulating any particular implementation:
//    - `.terminal` tab + non-nil `focusedLeafID`         -> `.surface`
//    - `.terminal` tab + nil `focusedLeafID`              -> `.tab`
//    - `.browser`/`.diff` tab (regardless of focusedLeafID) -> `.tab`
//    - `tabID == nil` (no active tab at all)              -> `.window`
//
//  The `.browser`/`.diff` cases below deliberately pass a NON-nil
//  `focusedLeafID`: with `nil`, `.tab` would be the expected result for
//  two independent reasons (both "not a terminal" AND "no focused
//  leaf"), so an implementation that ignores `content` entirely and only
//  ever checks `focusedLeafID` would pass. A non-nil `focusedLeafID`
//  isolates `content` as the one discriminating input.
//
//  `tabID`/`focusedLeafID` below are always two DISTINCT `UUID()` values
//  (never reused as if they were the same identifier) so a swapped-
//  argument bug (e.g. `.surface(tabID: surfaceID, surfaceID: tabID)`)
//  would fail these assertions rather than passing by coincidence.
//
//  RED ledger (ran 2026-08-07): cases 1-4 below are RED-proving (the
//  current stub always returns `.window`, so only case 5's expectation
//  matches it). Case 5 (`tabID == nil -> .window`) PASSES against the
//  stub today — it is a regression guard, not RED-proving; kept because
//  it is one of the five cases the spec enumerates, and a future
//  implementation that regresses to e.g. always returning `.tab` for a
//  nil tabID must still be caught.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseFocusedTargetTests: XCTestCase {

    // ==================== Terminal tab, focused leaf present ====================

    /// RED-proving: the stub returns `.window`, not `.surface`.
    func test_closeFocusedTarget_terminalTabWithFocusedLeaf_returnsSurface() {
        let tabID = UUID()
        let leafID = UUID()

        let result = CalyxWindowController.closeFocusedTarget(
            tabID: tabID, content: .terminal, focusedLeafID: leafID
        )

        XCTAssertEqual(
            result, .surface(tabID: tabID, surfaceID: leafID),
            "A terminal tab with a focused pane must close just that pane, matching ghostty's own default " +
            "close_surface semantics for a single Cmd+W press"
        )
    }

    // ==================== Terminal tab, no focused leaf ====================

    /// RED-proving: the stub returns `.window`, not `.tab`.
    func test_closeFocusedTarget_terminalTabWithNoFocusedLeaf_returnsTab() {
        let tabID = UUID()

        let result = CalyxWindowController.closeFocusedTarget(
            tabID: tabID, content: .terminal, focusedLeafID: nil
        )

        XCTAssertEqual(
            result, .tab(tabID),
            "A terminal tab with no focused leaf has no single pane to close, so the whole tab must close"
        )
    }

    // ==================== Browser tab ====================

    /// RED-proving: the stub returns `.window`, not `.tab`. Passes a
    /// non-nil `focusedLeafID` deliberately (see file header) so this
    /// case actually exercises the `content` check, not just the
    /// nil-focusedLeafID branch.
    func test_closeFocusedTarget_browserTab_returnsTab() {
        let tabID = UUID()
        let leafID = UUID()

        let result = CalyxWindowController.closeFocusedTarget(
            tabID: tabID,
            content: .browser(url: URL(string: "https://example.com")!),
            focusedLeafID: leafID
        )

        XCTAssertEqual(
            result, .tab(tabID),
            "A browser tab has no ghostty-surface concept of \"the focused pane\" — a non-nil focusedLeafID " +
            "must not fool this into returning .surface"
        )
    }

    // ==================== Diff tab ====================

    /// RED-proving: the stub returns `.window`, not `.tab`. Same
    /// non-nil-`focusedLeafID` strengthening as the browser case above.
    func test_closeFocusedTarget_diffTab_returnsTab() {
        let tabID = UUID()
        let leafID = UUID()

        let result = CalyxWindowController.closeFocusedTarget(
            tabID: tabID,
            content: .diff(source: .unstaged(path: "README.md", workDir: "/tmp/repo")),
            focusedLeafID: leafID
        )

        XCTAssertEqual(
            result, .tab(tabID),
            "A diff tab has no ghostty-surface concept of \"the focused pane\" either — same contract as browser"
        )
    }

    // ==================== No active tab ====================

    /// NOT RED-proving (see file header): the stub's unconditional
    /// `.window` already matches this expectation. Kept as a regression
    /// guard — one of the five cases the spec enumerates, and a future
    /// implementation must not regress it (e.g. by force-unwrapping
    /// `tabID` and crashing, or by defaulting to `.tab` for a nil id).
    func test_closeFocusedTarget_noActiveTab_returnsWindow() {
        let result = CalyxWindowController.closeFocusedTarget(
            tabID: nil, content: nil, focusedLeafID: nil
        )

        XCTAssertEqual(
            result, .window,
            "A window with no active tab at all has nothing narrower than itself to close"
        )
    }
}
