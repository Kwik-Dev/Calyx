//
//  HerdrRestoreTerminalIDCacheTests.swift
//  CalyxTests
//
//  HerdrRestoreTerminalIDCache: per-restore-pass memoization of the
//  terminal ids AppDelegate.createSurfaceWithPwd resolves for a herdr
//  bridge leaf. Coverage:
//  - a repeated lookup for the same socket path resolves once and
//    returns the same map
//  - an EMPTY resolve result is memoized too (a dead socket costs one
//    attempt, not one per leaf)
//  - two different socket paths resolve independently
//  - two SEPARATE instances never share a memoized result for the same
//    socket path (the regression pin: a later restore pass must always
//    resolve fresh terminal ids, never reuse a previous pass's map)
//  - a cache never asked for anything never invokes resolve
//

import XCTest
@testable import Calyx

@MainActor
final class HerdrRestoreTerminalIDCacheTests: XCTestCase {

    // MARK: - Memoization

    func test_terminalIDs_repeatedLookupSameSocketPath_resolvesOnceAndReturnsSameMap() {
        var callCount = 0
        let expected = ["k1": "term_abc"]
        let cache = HerdrRestoreTerminalIDCache { _ in
            callCount += 1
            return expected
        }

        let first = cache.terminalIDs(forSocketPath: "/tmp/herdr.sock")
        let second = cache.terminalIDs(forSocketPath: "/tmp/herdr.sock")

        XCTAssertEqual(callCount, 1, "a repeated lookup for the same socket path must not re-invoke resolve")
        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
    }

    // MARK: - Empty result memoized too

    func test_terminalIDs_emptyResolveResult_stillMemoizedOnSecondLookup() {
        var callCount = 0
        let cache = HerdrRestoreTerminalIDCache { _ in
            callCount += 1
            return [:]
        }

        XCTAssertEqual(cache.terminalIDs(forSocketPath: "/tmp/dead-herdr.sock"), [:])
        XCTAssertEqual(cache.terminalIDs(forSocketPath: "/tmp/dead-herdr.sock"), [:])

        XCTAssertEqual(
            callCount, 1,
            "an empty map (a dead socket) must still be memoized -- a dead socket costs exactly one resolve " +
            "attempt per pass, not one per leaf on that socket"
        )
    }

    // MARK: - Independent socket paths

    func test_terminalIDs_twoDifferentSocketPaths_resolveIndependently() {
        var resolvedSocketPaths: [String] = []
        let cache = HerdrRestoreTerminalIDCache { socketPath in
            resolvedSocketPaths.append(socketPath)
            return [socketPath: "term_\(socketPath)"]
        }

        _ = cache.terminalIDs(forSocketPath: "/tmp/herdr-a.sock")
        _ = cache.terminalIDs(forSocketPath: "/tmp/herdr-b.sock")

        XCTAssertEqual(resolvedSocketPaths, ["/tmp/herdr-a.sock", "/tmp/herdr-b.sock"])
    }

    // MARK: - Separate instances never share state (regression pin)

    func test_terminalIDs_twoSeparateInstances_eachResolveIndependentlyForSameSocketPath() {
        let socketPath = "/tmp/herdr.sock"

        var firstPassCallCount = 0
        let firstPassCache = HerdrRestoreTerminalIDCache { _ in
            firstPassCallCount += 1
            return ["k1": "term_first"]
        }

        var secondPassCallCount = 0
        let secondPassCache = HerdrRestoreTerminalIDCache { _ in
            secondPassCallCount += 1
            return ["k1": "term_second"]
        }

        _ = firstPassCache.terminalIDs(forSocketPath: socketPath)
        let secondPassResult = secondPassCache.terminalIDs(forSocketPath: socketPath)

        XCTAssertEqual(firstPassCallCount, 1)
        XCTAssertEqual(
            secondPassCallCount, 1,
            "a second, independent HerdrRestoreTerminalIDCache instance (a later restore pass) must resolve " +
            "the same socket path fresh rather than reusing the first instance's memoized result -- a " +
            "process-lifetime cache would wrongly leave this at 0"
        )
        XCTAssertEqual(
            secondPassResult, ["k1": "term_second"],
            "must be the second instance's own resolve result, not the first instance's"
        )
    }

    // MARK: - Never asked, never resolves

    func test_terminalIDs_neverCalled_resolveNeverInvoked() {
        var callCount = 0
        _ = HerdrRestoreTerminalIDCache { _ in
            callCount += 1
            return [:]
        }

        XCTAssertEqual(callCount, 0, "a cache that is never asked for anything must never invoke resolve")
    }
}
