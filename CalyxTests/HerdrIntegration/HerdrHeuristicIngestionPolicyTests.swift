//
//  HerdrHeuristicIngestionPolicyTests.swift
//  CalyxTests
//
//  Tests (herdr TRACK B): HerdrHeuristicIngestionPolicy
//  .shouldIngest, the pure decision that stops Calyx's own title-change
//  / screen-classification heuristics from creating a second, duplicate
//  Agents-sidebar row for a pane whose "real" agent state already
//  arrives over herdr's own event stream as an external AgentRegistry
//  row.
//
//  Mirrors HerdrChildExitedPolicyTests' shape exactly: a plain
//  (non-@MainActor) XCTestCase directly calling a pure,
//  already-computed-discriminator static function -- no actor
//  isolation, no fixtures, no daemon/socket involved.
//
//  Coverage: the full 2-row truth table for shouldIngest(isHerdrHosted:).
//  herdr-hosted (true) must decide skip (false); non-hosted (false)
//  must decide proceed (true).
//

import XCTest
@testable import Calyx

final class HerdrHeuristicIngestionPolicyTests: XCTestCase {

    // MARK: - herdr-hosted surface -> skip

    func test_shouldIngest_herdrHostedSurface_decidesFalse() {
        XCTAssertFalse(
            HerdrHeuristicIngestionPolicy.shouldIngest(isHerdrHosted: true, isBridgeSurface: false),
            "A herdr-hosted surface must skip Calyx's own heuristic ingestion -- an external row " +
            "already covers it, and ingesting too would produce a duplicate Agents-sidebar row"
        )
    }

    // MARK: - non-hosted surface -> proceed

    func test_shouldIngest_nonHostedSurface_decidesTrue() {
        XCTAssertTrue(
            HerdrHeuristicIngestionPolicy.shouldIngest(isHerdrHosted: false, isBridgeSurface: false),
            "A non-hosted surface must proceed with heuristic ingestion, unaffected by this policy"
        )
    }
}
