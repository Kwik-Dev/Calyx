//
//  HerdrBinaryResolverTests.swift
//  CalyxTests
//
//  TDD Red Phase for HerdrBinaryResolver: resolving the optional,
//  user-installed `herdr` binary. Unlike SessionBinaryResolverTests
//  (calyx-session is a bundled resource), every tier here depends on
//  either an injected environment or an injected candidate list --
//  NONE of these tests may depend on this machine's real PATH or real
//  install locations, both because that would be nondeterministic
//  across dev machines/CI, and because Stage 1's own manual smoke test
//  `brew install`s herdr onto this exact development machine, which
//  would silently flip any test relying on real defaults from red to
//  green (or vice versa) the day that happens.
//
//  Coverage:
//  - CALYX_HERDR_BIN env override wins over PATH and known candidates
//    simultaneously, verbatim, without an existence check
//  - An empty (but present) CALYX_HERDR_BIN falls through to the next
//    tier, mirroring SessionBinaryResolver's own !isEmpty handling
//  - PATH scan finds an executable `herdr` in a single injected PATH
//    directory
//  - PATH scan skips a NON-executable `herdr` in an earlier PATH
//    directory and finds the executable one in a later directory --
//    pins FileManager.isExecutableFile specifically, not a
//    fileExists-only check
//  - PATH wins over known candidates when both have a valid match
//  - Known-candidate fallback is used when PATH has no match
//  - All three tiers missing resolves to nil
//  - A miss (nil) is never permanently cached: once herdr appears on
//    disk after an earlier miss, the next resolve() call on the SAME
//    instance finds it -- installed-after-launch detection
//  - A FOUND path stays memoized across subsequent calls even if later
//    removed from disk -- only a miss re-scans, never a hit
//  - Two resolver instances constructed with different environments
//    resolve independently (no global/static memoization leak)
//

import XCTest
@testable import Calyx

final class HerdrBinaryResolverTests: XCTestCase {

    // MARK: - Fixture helpers

    private func uniqueTempDir() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    private func makeExecutableHerdr(inDirectory dir: String) -> String {
        let path = dir + "/herdr"
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @discardableResult
    private func makeNonExecutableHerdr(inDirectory dir: String) -> String {
        let path = dir + "/herdr"
        FileManager.default.createFile(atPath: path, contents: Data("not a binary\n".utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        return path
    }

    // MARK: - CALYX_HERDR_BIN override

    func test_envOverride_winsOverPathAndKnownCandidatesSimultaneously() {
        let pathDir = uniqueTempDir()
        let pathCandidate = makeExecutableHerdr(inDirectory: pathDir)
        let knownDir = uniqueTempDir()
        let knownCandidate = makeExecutableHerdr(inDirectory: knownDir)
        let overridePath = "/some/override/location/herdr"

        let resolver = HerdrBinaryResolver(
            environment: ["CALYX_HERDR_BIN": overridePath, "PATH": pathDir],
            knownCandidates: [knownCandidate]
        )

        XCTAssertEqual(resolver.resolve(), overridePath,
                       "CALYX_HERDR_BIN must win over BOTH a valid PATH match (\(pathCandidate)) and a " +
                       "valid known-candidate match, returned verbatim with no existence check")
    }

    func test_envOverride_emptyString_fallsThroughToKnownCandidates() {
        let knownDir = uniqueTempDir()
        let knownCandidate = makeExecutableHerdr(inDirectory: knownDir)

        let resolver = HerdrBinaryResolver(
            environment: ["CALYX_HERDR_BIN": "", "PATH": ""],
            knownCandidates: [knownCandidate]
        )

        XCTAssertEqual(resolver.resolve(), knownCandidate,
                       "An empty (but present) CALYX_HERDR_BIN must be treated as unset and fall all the " +
                       "way through to the known-candidate tier, mirroring SessionBinaryResolver's own " +
                       "!override.isEmpty handling for CALYX_SESSION_BIN")
    }

    // MARK: - PATH scan

    func test_pathScan_findsExecutableHerdrInSingleDirectory() {
        let dir = uniqueTempDir()
        let candidate = makeExecutableHerdr(inDirectory: dir)

        let resolver = HerdrBinaryResolver(environment: ["PATH": dir], knownCandidates: [])

        XCTAssertEqual(resolver.resolve(), candidate)
    }

    func test_pathScan_skipsNonExecutableEarlierDirectory_findsExecutableLaterDirectory() {
        let nonExecutableDir = uniqueTempDir()
        _ = makeNonExecutableHerdr(inDirectory: nonExecutableDir)
        let executableDir = uniqueTempDir()
        let executableCandidate = makeExecutableHerdr(inDirectory: executableDir)

        let resolver = HerdrBinaryResolver(
            environment: ["PATH": "\(nonExecutableDir):\(executableDir)"],
            knownCandidates: []
        )

        XCTAssertEqual(resolver.resolve(), executableCandidate,
                       "A non-executable herdr file in an earlier PATH directory must be skipped -- this " +
                       "must check FileManager.isExecutableFile specifically, not merely fileExists")
    }

    func test_pathScan_winsOverKnownCandidatesWhenBothMatch() {
        let pathDir = uniqueTempDir()
        let pathCandidate = makeExecutableHerdr(inDirectory: pathDir)
        let knownDir = uniqueTempDir()
        let knownCandidate = makeExecutableHerdr(inDirectory: knownDir)

        let resolver = HerdrBinaryResolver(
            environment: ["PATH": pathDir],
            knownCandidates: [knownCandidate]
        )

        XCTAssertEqual(resolver.resolve(), pathCandidate,
                       "PATH must win over known candidates when CALYX_HERDR_BIN is unset and both tiers " +
                       "have a valid match")
    }

    // MARK: - Known-candidate fallback

    func test_knownCandidateFallback_usedWhenPathHasNoMatch() {
        let knownDir = uniqueTempDir()
        let knownCandidate = makeExecutableHerdr(inDirectory: knownDir)
        let emptyPathDir = uniqueTempDir()

        let resolver = HerdrBinaryResolver(
            environment: ["PATH": emptyPathDir],
            knownCandidates: [knownCandidate]
        )

        XCTAssertEqual(resolver.resolve(), knownCandidate)
    }

    // MARK: - All-miss

    func test_allTiersMiss_resolvesToNil() {
        let emptyPathDir = uniqueTempDir()
        let nonexistentKnownCandidate = emptyPathDir + "/does-not-exist-herdr"

        let resolver = HerdrBinaryResolver(
            environment: ["PATH": emptyPathDir],
            knownCandidates: [nonexistentKnownCandidate]
        )

        XCTAssertNil(resolver.resolve())
    }

    // MARK: - A miss is never permanently cached (installed-after-launch detection)

    func test_resolve_returningNil_thenBinaryAppearsOnDisk_reResolvesToNewPathOnNextCall() {
        let dir = uniqueTempDir()
        let expectedPath = dir + "/herdr" // not created yet below

        let resolver = HerdrBinaryResolver(environment: [:], knownCandidates: [expectedPath])

        XCTAssertNil(resolver.resolve(),
                     "Precondition: herdr isn't installed anywhere yet, so the first resolve() must miss")

        makeExecutableHerdr(inDirectory: dir) // simulates `brew install herdr` happening after Calyx launched

        XCTAssertEqual(resolver.resolve(), expectedPath,
                       "A miss must never be permanently memoized -- once herdr appears on disk, the very " +
                       "next resolve() call on the SAME resolver instance must find it, without requiring " +
                       "a new instance or an app restart")
    }

    func test_resolve_foundPath_staysMemoizedOnSubsequentCalls_evenIfRemovedFromDisk() {
        let dir = uniqueTempDir()
        let candidate = makeExecutableHerdr(inDirectory: dir)
        let resolver = HerdrBinaryResolver(environment: [:], knownCandidates: [candidate])

        XCTAssertEqual(resolver.resolve(), candidate, "Precondition: the first resolve() must find the binary")

        try! FileManager.default.removeItem(atPath: candidate)

        XCTAssertEqual(resolver.resolve(), candidate,
                       "Only a MISS re-scans on the next call -- a FOUND path must stay memoized for the " +
                       "rest of this instance's lifetime, so a resolver that already found a real path " +
                       "must keep returning it even if that path is later removed")
    }

    // MARK: - No global memoization leak

    func test_distinctResolverInstances_withDifferentEnvironments_resolveIndependently() {
        let dirA = uniqueTempDir()
        let candidateA = makeExecutableHerdr(inDirectory: dirA)
        let dirB = uniqueTempDir()
        let candidateB = makeExecutableHerdr(inDirectory: dirB)

        let resolverA = HerdrBinaryResolver(environment: ["PATH": dirA], knownCandidates: [])
        let resolverB = HerdrBinaryResolver(environment: ["PATH": dirB], knownCandidates: [])

        XCTAssertEqual(resolverA.resolve(), candidateA,
                       "Resolving resolverB below must never overwrite resolverA's own already-resolved value")
        XCTAssertEqual(resolverB.resolve(), candidateB,
                       "A per-type-global/static memoization cache would leak resolverA's PATH match here " +
                       "instead of independently resolving resolverB's own distinct PATH")
    }
}
