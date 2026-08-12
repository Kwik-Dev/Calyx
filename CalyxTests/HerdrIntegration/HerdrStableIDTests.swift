//
//  HerdrStableIDTests.swift
//  CalyxTests
//
//  Tests (herdr ): HerdrStableID.make, the deterministic
//  UUID derivation that keeps an Agents-sidebar row for a herdr pane
//  identified consistently across app restarts and reconnects. See
//  HerdrStableID.swift's own header for the frozen algorithm.
//
//  Coverage:
//  - an exact SHA-256 vector, hand-derived independently of this file's
//    implementation via `shasum -a 256` (see that test's own derivation
//    comment) -- the one test in this file that can catch a
//    "looks-plausible-but-wrong" implementation (e.g. one built on
//    `String.hashValue`, which is reseeded every process launch and
//    therefore unstable across restarts) that would otherwise slip
//    through every purely-relational test below
//  - determinism: the same (socketPath, paneID) pair always derives the
//    same UUID, including across calls interleaved with OTHER differing
//    inputs (rules out a stateful/counter-based implementation)
//  - distinctness: a different socketPath (same paneID), or a different
//    paneID (same socketPath), must always derive a DIFFERENT UUID
//
//  Coverage rationale: the two "determinism" tests below trivially PASS
//  against ANY constant/deterministic implementation (this is
//  mathematically unavoidable for a pure-function determinism check --
//  determinism can only ever be violated by a NON-deterministic
//  implementation). The exact-vector test and both distinctness tests
//  are what actually pin that the real implementation derives its
//  output FROM both parameters, catching a wrong-but-deterministic
//  implementation that the determinism tests alone could not.
//

import XCTest
@testable import Calyx

final class HerdrStableIDTests: XCTestCase {

    // MARK: - Exact vector

    func test_make_matchesHandDerivedSHA256Vector() {
        // Derivation (reproducible in any shell, independent of this
        // file's implementation -- printf, never echo, to avoid a
        // trailing-newline byte silently changing the digest):
        //
        //   printf '%s' "calyx-herdr:/tmp/herdr-stableid-test/herdr.sock:w9:p1" \
        //     | shasum -a 256
        //   -> 36c35f1433147dd2030c11e2abf445627718b5e9421e9c3e0aaa3cead7886195
        //
        //   First 32 hex characters, formatted 8-4-4-4-12:
        //   36c35f14-3314-7dd2-030c-11e2abf44562
        let expected = UUID(uuidString: "36c35f14-3314-7dd2-030c-11e2abf44562")!

        let actual = HerdrStableID.make(
            socketPath: "/tmp/herdr-stableid-test/herdr.sock", paneID: "w9:p1"
        )

        XCTAssertEqual(
            actual, expected,
            "must be SHA-256(\"calyx-herdr:<socketPath>:<paneID>\") truncated to its first 16 bytes, " +
            "formatted as an 8-4-4-4-12 UUID -- see this test's own derivation comment"
        )
    }

    // MARK: - Determinism

    func test_make_sameInput_returnsIdenticalUUID_acrossMultipleCalls() {
        let first = HerdrStableID.make(socketPath: "/tmp/herdr-a/herdr.sock", paneID: "w1:p1")
        let second = HerdrStableID.make(socketPath: "/tmp/herdr-a/herdr.sock", paneID: "w1:p1")

        XCTAssertEqual(first, second, "identical (socketPath, paneID) must always derive the identical UUID")
    }

    func test_make_sameInput_isAlwaysIdentical_evenInterleavedWithOtherInputs() {
        let target = HerdrStableID.make(socketPath: "/tmp/herdr-a/herdr.sock", paneID: "w1:p1")
        _ = HerdrStableID.make(socketPath: "/tmp/herdr-b/herdr.sock", paneID: "w2:p9")
        _ = HerdrStableID.make(socketPath: "/tmp/herdr-c/herdr.sock", paneID: "w3:p2")
        let targetAgain = HerdrStableID.make(socketPath: "/tmp/herdr-a/herdr.sock", paneID: "w1:p1")

        XCTAssertEqual(
            target, targetAgain,
            "computing OTHER (differing) ids in between must not perturb a later identical call -- rules " +
            "out a stateful/counter-based implementation masquerading as a pure hash"
        )
    }

    // MARK: - Distinctness

    func test_make_differentSocketPath_sameLocalPaneID_producesDifferentUUID() {
        let a = HerdrStableID.make(socketPath: "/tmp/herdr-session-a/herdr.sock", paneID: "w9:p1")
        let b = HerdrStableID.make(socketPath: "/tmp/herdr-session-b/herdr.sock", paneID: "w9:p1")

        XCTAssertNotEqual(
            a, b,
            "two independent herdr sessions can legitimately reuse the same pane id -- the socket path " +
            "must be part of the hash input, or their rows would collide onto the same AgentEntry.id"
        )
    }

    func test_make_differentPaneID_sameSocketPath_producesDifferentUUID() {
        let a = HerdrStableID.make(socketPath: "/tmp/herdr-session/herdr.sock", paneID: "w9:p1")
        let b = HerdrStableID.make(socketPath: "/tmp/herdr-session/herdr.sock", paneID: "w9:p2")

        XCTAssertNotEqual(a, b, "two different panes on the same herdr session must never share a UUID")
    }
}
