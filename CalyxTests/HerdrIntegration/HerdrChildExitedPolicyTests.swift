//
//  HerdrChildExitedPolicyTests.swift
//  CalyxTests
//
//  TDD Red Phase for HerdrChildExitedPolicy.shouldAutoClose: the pure
//  decision behind Calyx auto-closing a herdr-hosted surface's pane on
//  GHOSTTY_ACTION_SHOW_CHILD_EXITED instead of leaving ghostty's own
//  "process exited" banner up forever (SessionReconnectCoordinator
//  provably no-ops for a herdr surface -- never registered in
//  SessionSurfaceMap, see HerdrHostedSurfaces.swift's header -- so
//  nothing else would ever close it).
//
//  Mirrors SessionCloseKillPolicyTests' shape: a plain (non-@MainActor)
//  XCTestCase directly calling a pure, already-computed-discriminator
//  static function -- no actor isolation, no fixtures, no daemon/FFI
//  involved.
//
//  Coverage: the full 2-row truth table for
//  shouldAutoClose(isHerdrHosted:). herdr-hosted (true) must decide
//  auto-close (true); non-hosted (false) must decide leave-alone /
//  defer to the existing session-reconnect handling (false).
//

import XCTest
@testable import Calyx

final class HerdrChildExitedPolicyTests: XCTestCase {

    // MARK: - herdr-hosted surface -> auto-close

    func test_shouldAutoClose_herdrHostedSurface_decidesTrue() {
        XCTAssertTrue(
            HerdrChildExitedPolicy.shouldAutoClose(isHerdrHosted: true),
            "A herdr-hosted surface's child-exited event must decide to auto-close the pane -- " +
            "SessionReconnectCoordinator.childExited provably no-ops for it (never registered in " +
            "SessionSurfaceMap), so nothing else would ever close it, leaving ghostty's own " +
            "\"process exited\" banner up forever"
        )
    }

    // MARK: - non-hosted surface -> leave alone / defer to existing behavior

    func test_shouldAutoClose_nonHostedSurface_decidesFalse() {
        XCTAssertFalse(
            HerdrChildExitedPolicy.shouldAutoClose(isHerdrHosted: false),
            "A non-hosted surface's child-exited event must NOT auto-close -- it must defer to the " +
            "existing (persistent-session reconnect) child-exited handling, unaffected by this policy"
        )
    }
}
