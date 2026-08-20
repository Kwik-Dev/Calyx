//
//  RestoreHerdrPaneRefsTests.swift
//  CalyxTests
//
//  Covers HerdrRestoreCommandPolicy (app-layer
//  wiring): the pure decision AppDelegate.restoreTabSurfaces' per-leaf
//  branch (createSurfaceWithPwd, AppDelegate.swift) will consult once a
//  leaf's HerdrPaneRef survives a snapshot restore, mirroring the
//  existing invalid-ULID SessionRef precedent in that same method
//  (AppDelegate.swift, restoreTabSurfaces: "Reject any persisted
//  SessionRef whose sessionID isn't shaped like a genuine ULID... The
//  rejected leaf simply restores as an ordinary passthrough shell").
//
//  restoreTabSurfaces/createSurfaceWithPwd have NO herdr seam today (a
//  full read of both functions in AppDelegate.swift found zero herdr
//  references), so this is a pure helper, not a test through an
//  existing seam.
//
//  Mirrors HerdrChildExitedPolicy/HerdrHeuristicIngestionPolicy's own
//  extraction shape: the caller resolves every raw domain lookup itself
//  (herdr binary resolution, HerdrSessionDiscovery.isAlive(socketPath:))
//  into already-computed values before calling in; this function does no
//  I/O and touches no actor-isolated state.
//
//  Coverage:
//  - a leaf with a herdr ref, herdr binary resolvable, socket alive, and
//    a valid pane id -> .bridgeCommand(String), the string being EXACTLY
//    HerdrAttachBridgeCommand.build(...)'s own output for that ref.
//  - herdr binary NOT resolvable (nil) -> .plainShellAndPrune.
//  - socket dead (binary resolvable, but not alive) -> .plainShellAndPrune.
//  - an invalid pane id in an otherwise-available ref -> .plainShellAndPrune.
//  - no herdr ref for the leaf at all -> .plainShell (the untouched,
//    pre-Stage-3 path) -- herdr availability/socket liveness are
//    deliberately left "available" in this fixture so only the absence
//    of a ref itself can be driving the outcome.
//

import XCTest
@testable import Calyx

final class RestoreHerdrPaneRefsTests: XCTestCase {

    private let socketPath = "/tmp/herdr-restore-command-policy-test/herdr.sock"
    private let herdrBinPath = "/opt/homebrew/bin/herdr"
    /// Production `decide` takes `terminalID: String?`; a resolved id is
    /// passed in every fixture below (including the prune-path ones) so
    /// each test isolates exactly the one gate its own name describes,
    /// rather than incidentally also passing through the separate
    /// terminalID-nil gate.
    private let terminalID = "term_658cabe34ba1713"

    // MARK: - Valid ref, herdr available, valid pane id -> bridge command

    func test_decide_validRef_herdrAvailable_validPaneID_returnsBridgeCommandMatchingHerdrAttachBridgeCommandOutput() throws {
        let ref = HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1")
        let expectedCommand = try XCTUnwrap(
            HerdrAttachBridgeCommand.build(herdrBin: herdrBinPath, socketPath: socketPath, terminalID: terminalID),
            "Precondition: this fixture's own terminalID must build a valid bridge command"
        )

        let outcome = HerdrRestoreCommandPolicy.decide(
            herdrPaneRef: ref, herdrBinPath: herdrBinPath, isSocketAlive: true, terminalID: terminalID
        )

        XCTAssertEqual(
            outcome, .bridgeCommand(expectedCommand),
            "a valid, available herdr ref with a resolved terminal id must decide .bridgeCommand with EXACTLY " +
            "HerdrAttachBridgeCommand.build's own output"
        )
    }

    // MARK: - Herdr binary not resolvable -> plainShellAndPrune

    func test_decide_herdrBinaryNotResolvable_returnsPlainShellAndPrune() {
        let ref = HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1")

        let outcome = HerdrRestoreCommandPolicy.decide(
            herdrPaneRef: ref, herdrBinPath: nil, isSocketAlive: true, terminalID: terminalID
        )

        XCTAssertEqual(
            outcome, .plainShellAndPrune,
            "a ref that can never be reattached (no herdr binary resolvable) must decide .plainShellAndPrune -- " +
            "the stale ref must not linger to be written back out by the next snapshot"
        )
    }

    // MARK: - Socket dead -> plainShellAndPrune

    func test_decide_socketDead_returnsPlainShellAndPrune() {
        let ref = HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1")

        let outcome = HerdrRestoreCommandPolicy.decide(
            herdrPaneRef: ref, herdrBinPath: herdrBinPath, isSocketAlive: false, terminalID: terminalID
        )

        XCTAssertEqual(
            outcome, .plainShellAndPrune,
            "a ref whose own socket is dead must decide .plainShellAndPrune, even when the herdr binary itself " +
            "is resolvable and a terminal id is known"
        )
    }

    // MARK: - Invalid pane id -> plainShellAndPrune

    func test_decide_invalidPaneIDInRef_returnsPlainShellAndPrune() {
        let hostilePaneID = "wF:p1; rm"
        XCTAssertFalse(HerdrPaneRef.isValidPaneID(hostilePaneID), "Precondition: this fixture's pane id must actually be invalid")
        let ref = HerdrPaneRef(socketPath: socketPath, paneID: hostilePaneID)

        let outcome = HerdrRestoreCommandPolicy.decide(
            herdrPaneRef: ref, herdrBinPath: herdrBinPath, isSocketAlive: true, terminalID: terminalID
        )

        XCTAssertEqual(
            outcome, .plainShellAndPrune,
            "an invalid pane id must decide .plainShellAndPrune even though herdr itself is fully available and " +
            "a terminal id is known -- a corrupted/malicious persisted ref must never reach command synthesis"
        )
    }

    // MARK: - No herdr ref for the leaf -> plainShell (untouched path)

    func test_decide_noHerdrRefForLeaf_returnsPlainShell() {
        // herdr itself is fully available here -- only the absent ref should be able to
        // drive this outcome, isolating the variable actually under test.
        let outcome = HerdrRestoreCommandPolicy.decide(
            herdrPaneRef: nil, herdrBinPath: herdrBinPath, isSocketAlive: true, terminalID: terminalID
        )

        XCTAssertEqual(
            outcome, .plainShell,
            "a leaf with no herdr ref at all must decide .plainShell -- the ordinary, pre-Stage-3 passthrough " +
            "path, untouched"
        )
    }
}
