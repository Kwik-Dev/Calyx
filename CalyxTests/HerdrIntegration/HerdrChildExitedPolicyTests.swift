//
//  HerdrChildExitedPolicyTests.swift
//  CalyxTests
//
//  Covers HerdrChildExitedPolicy.shouldAutoClose: the pure
//  decision behind Calyx auto-closing a herdr-hosted or herdr-bridged
//  surface's pane on GHOSTTY_ACTION_SHOW_CHILD_EXITED instead of
//  leaving ghostty's own "process exited" banner up forever
//  (SessionReconnectCoordinator provably no-ops for a herdr surface --
//  never registered in SessionSurfaceMap, see HerdrHostedSurfaces.swift's
//  header -- so nothing else would ever close it).
//
//  Mirrors SessionCloseKillPolicyTests' shape: a plain (non-@MainActor)
//  XCTestCase directly calling a pure, already-computed-discriminator
//  static function -- no actor isolation, no fixtures, no daemon/FFI
//  involved.
//
//  Coverage: the full 4-row truth table for
//  shouldAutoClose(isHerdrHosted:isBridgeSurface:). Herdr-hosted alone,
//  herdr-bridged alone, and both together must all decide auto-close
//  (true); neither must decide leave-alone / defer to the existing
//  session-reconnect handling (false).
//

import XCTest
@testable import Calyx

final class HerdrChildExitedPolicyTests: XCTestCase {

    // MARK: - herdr-hosted surface (not bridged) -> auto-close

    func test_shouldAutoClose_herdrHostedSurface_notBridged_decidesTrue() {
        XCTAssertTrue(
            HerdrChildExitedPolicy.shouldAutoClose(isHerdrHosted: true, isBridgeSurface: false),
            "A herdr-hosted surface's child-exited event must decide to auto-close the pane -- " +
            "SessionReconnectCoordinator.childExited provably no-ops for it (never registered in " +
            "SessionSurfaceMap), so nothing else would ever close it, leaving ghostty's own " +
            "\"process exited\" banner up forever"
        )
    }

    // MARK: - herdr-bridged surface (not hosted) -> auto-close

    func test_shouldAutoClose_bridgedSurface_notHosted_decidesTrue() {
        XCTAssertTrue(
            HerdrChildExitedPolicy.shouldAutoClose(isHerdrHosted: false, isBridgeSurface: true),
            "A herdr-bridged surface's child-exited event must decide to auto-close the pane -- it is " +
            "never registered in SessionSurfaceMap either, and the attach client's own exit is not a " +
            "herdr-side pane.closed event, so nothing else would ever close it"
        )
    }

    // MARK: - both hosted and bridged -> auto-close

    func test_shouldAutoClose_hostedAndBridgedSurface_decidesTrue() {
        XCTAssertTrue(
            HerdrChildExitedPolicy.shouldAutoClose(isHerdrHosted: true, isBridgeSurface: true),
            "A surface that is somehow both herdr-hosted and herdr-bridged must still decide to auto-close"
        )
    }

    // MARK: - neither hosted nor bridged -> leave alone / defer to existing behavior

    func test_shouldAutoClose_plainSurface_decidesFalse() {
        XCTAssertFalse(
            HerdrChildExitedPolicy.shouldAutoClose(isHerdrHosted: false, isBridgeSurface: false),
            "A surface that is neither herdr-hosted nor herdr-bridged must NOT auto-close -- it must " +
            "defer to the existing (persistent-session reconnect) child-exited handling, unaffected by " +
            "this policy"
        )
    }
}
