//
//  HerdrHeuristicIngestionPolicyBridgeTests.swift
//  CalyxTests
//
//  Covers HerdrHeuristicIngestionPolicy's extension:
//  a surface bridged via HerdrPaneRegistry (native-tab pane
//  bridge) must be skipped by title-heuristic ingestion exactly like a
//  HerdrHostedSurfaces member already is (see
//  HerdrHeuristicIngestionPolicyTests.swift).
//
//  INTERFACE CHANGE: shouldIngest
//  gains a REQUIRED second parameter, isBridgeSurface: Bool, with NO
//  default value. This REPLACES the existing single-parameter overload
//  (shouldIngest(isHerdrHosted:)) rather than coexisting alongside it --
//  mirrors this codebase's own killSessionIfPersistent precedent
//  (CalyxWindowController.swift), whose own isTerminating parameter was
//  made required, no default, specifically because a defaulted
//  discriminator let a real call site silently keep the OLD (wrong)
//  behavior by omission. A defaulted isBridgeSurface here would let
//  CalyxWindowController's own two title-heuristic call sites compile
//  unchanged without ever consulting HerdrPaneRegistry -- exactly the
//  bug a required parameter prevents.
//
//  Coverage: the full 4-row truth table for
//  shouldIngest(isHerdrHosted:isBridgeSurface:). Only "neither hosted
//  nor bridged" decides true; every other row (hosted alone, bridged
//  alone, both) decides false.
//

import XCTest
@testable import Calyx

final class HerdrHeuristicIngestionPolicyBridgeTests: XCTestCase {

    // MARK: - Bridged (not hosted) -> skip

    func test_shouldIngest_bridgedSurface_notHosted_decidesFalse() {
        XCTAssertFalse(
            HerdrHeuristicIngestionPolicy.shouldIngest(isHerdrHosted: false, isBridgeSurface: true),
            "A surface bridged via HerdrPaneRegistry must skip title-heuristic ingestion, exactly like a " +
            "HerdrHostedSurfaces member already does -- its \"real\" state arrives over herdr's own layout " +
            "export/event stream, and ingesting too would produce a duplicate Agents-sidebar row"
        )
    }

    // MARK: - Neither hosted nor bridged -> ingest

    func test_shouldIngest_neitherHostedNorBridged_decidesTrue() {
        XCTAssertTrue(
            HerdrHeuristicIngestionPolicy.shouldIngest(isHerdrHosted: false, isBridgeSurface: false),
            "A surface that is neither herdr-hosted nor herdr-bridged must proceed with heuristic ingestion"
        )
    }

    // MARK: - Hosted (not bridged) -> still skip (behavior preserved under the new signature)

    func test_shouldIngest_hostedSurface_notBridged_decidesFalse() {
        XCTAssertFalse(
            HerdrHeuristicIngestionPolicy.shouldIngest(isHerdrHosted: true, isBridgeSurface: false),
            "A herdr-hosted surface must still skip ingestion under the two-input signature, exactly as it " +
            "did under the single-input one"
        )
    }

    // MARK: - Both hosted and bridged -> skip

    func test_shouldIngest_hostedAndBridgedSurface_decidesFalse() {
        XCTAssertFalse(
            HerdrHeuristicIngestionPolicy.shouldIngest(isHerdrHosted: true, isBridgeSurface: true),
            "A surface that is somehow both herdr-hosted and herdr-bridged must still skip ingestion"
        )
    }
}
