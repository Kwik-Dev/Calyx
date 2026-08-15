//
//  AgentRowFocusTargetTests.swift
//  CalyxTests
//
//  AgentRowFocusTarget.resolve, the pure decision behind AgentRowView's
//  tap gesture. Mirrors AgentSidebarGateTests' shape: a plain
//  (non-@MainActor) XCTestCase directly calling a pure,
//  already-computed-argument static function.
//
//  Coverage:
//  - focusSurfaceID, when set, always wins -- regardless of source
//  - .hooks / .titleHeuristic with no focusSurfaceID: falls back to the
//    row's own surfaceID (always a real SurfaceRegistry id for those
//    sources)
//  - .external with no focusSurfaceID: resolves to nil -- no resolvable
//    target, the row must render as non-interactive (AgentRowView.body)
//    rather than posting .calyxFocusSurface for a synthetic herdr id no
//    SurfaceRegistry knows
//

import XCTest
@testable import Calyx

final class AgentRowFocusTargetTests: XCTestCase {

    // MARK: - focusSurfaceID always wins when present

    func test_resolve_focusSurfaceIDSet_external_returnsFocusSurfaceID() {
        let surfaceID = UUID()
        let focusSurfaceID = UUID()

        let resolved = AgentRowFocusTarget.resolve(source: .external, surfaceID: surfaceID, focusSurfaceID: focusSurfaceID)

        XCTAssertEqual(resolved, focusSurfaceID)
    }

    func test_resolve_focusSurfaceIDSet_hooks_returnsFocusSurfaceIDNotSurfaceID() {
        // Never produced by AgentRegistry today (AgentEntry.focusSurfaceID
        // stays nil for every .hooks/.titleHeuristic entry), but the
        // resolution rule itself must not special-case source when
        // focusSurfaceID is present -- it always wins.
        let surfaceID = UUID()
        let focusSurfaceID = UUID()

        let resolved = AgentRowFocusTarget.resolve(source: .hooks, surfaceID: surfaceID, focusSurfaceID: focusSurfaceID)

        XCTAssertEqual(resolved, focusSurfaceID)
    }

    // MARK: - No focusSurfaceID: .hooks / .titleHeuristic fall back to surfaceID

    func test_resolve_noFocusSurfaceID_hooks_fallsBackToSurfaceID() {
        let surfaceID = UUID()

        let resolved = AgentRowFocusTarget.resolve(source: .hooks, surfaceID: surfaceID, focusSurfaceID: nil)

        XCTAssertEqual(resolved, surfaceID)
    }

    func test_resolve_noFocusSurfaceID_titleHeuristic_fallsBackToSurfaceID() {
        let surfaceID = UUID()

        let resolved = AgentRowFocusTarget.resolve(source: .titleHeuristic, surfaceID: surfaceID, focusSurfaceID: nil)

        XCTAssertEqual(resolved, surfaceID)
    }

    // MARK: - No focusSurfaceID: .external has no resolvable target

    func test_resolve_noFocusSurfaceID_external_returnsNil() {
        // An .external entry's own surfaceID is a synthetic
        // HerdrStableID no SurfaceRegistry knows (HerdrStableID.swift's
        // own header), so it must never be used as a fallback the way
        // .hooks/.titleHeuristic do. This covers an unbridged herdr
        // pane: HerdrAgentMirror only resolves focusSurfaceID for a
        // pane the pane registry actually bridges (see that file's own
        // header), and leaves it nil otherwise.
        let surfaceID = UUID()

        let resolved = AgentRowFocusTarget.resolve(source: .external, surfaceID: surfaceID, focusSurfaceID: nil)

        XCTAssertNil(resolved, "An .external row with no focusSurfaceID must have no resolvable focus target")
    }
}
