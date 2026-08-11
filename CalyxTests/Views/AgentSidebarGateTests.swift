//
//  AgentSidebarGateTests.swift
//  CalyxTests
//
//  Tests (herdr Stage 2, TRACK B): AgentSidebarGate.decide, the
//  pure decision behind AgentStatusView.content's placeholder branch.
//  Mirrors HerdrChildExitedPolicyTests' shape: a plain (non-@MainActor)
//  XCTestCase directly calling a pure, already-computed-discriminator
//  static function.
//
//  Coverage: the full 4-row truth table for
//  decide(isServerRunning:hasExternal:). Rows must show when EITHER
//  input is true; the "AI Agent IPC is disabled" placeholder is shown
//  only when BOTH are false -- an external (herdr) row must remain
//  visible even while Calyx's own IPC server is stopped, since it
//  doesn't depend on it.
//

import XCTest
@testable import Calyx

final class AgentSidebarGateTests: XCTestCase {

    func test_decide_serverRunning_noExternal_showsRows() {
        XCTAssertTrue(AgentSidebarGate.decide(isServerRunning: true, hasExternal: false))
    }

    func test_decide_serverRunning_hasExternal_showsRows() {
        XCTAssertTrue(AgentSidebarGate.decide(isServerRunning: true, hasExternal: true))
    }

    func test_decide_serverStopped_hasExternal_stillShowsRows() {
        // The case this change adds: external (herdr) rows must stay
        // visible even while Calyx's own IPC server is off.
        XCTAssertTrue(
            AgentSidebarGate.decide(isServerRunning: false, hasExternal: true),
            "External entries must keep the sidebar showing rows even while the IPC server is stopped"
        )
    }

    func test_decide_serverStopped_noExternal_showsPlaceholder() {
        XCTAssertFalse(AgentSidebarGate.decide(isServerRunning: false, hasExternal: false))
    }
}
