// GitRefSelectionTests.swift
// CalyxTests
//
// GitRefSelection.reconciled(withLiveRefs:) is the one place a stale
// saved selection meets the refs a repository actually has right now:
// a ref that vanished must not silently keep filtering as if it still
// existed, and one that survives must keep its place in the order the
// user picked.

import Foundation
import Testing
@testable import Calyx

struct GitRefSelectionTests {
    @Test func test_reconciled_autoStaysAutoRegardlessOfLiveRefs() {
        let selection = GitRefSelection.auto
        #expect(selection.reconciled(withLiveRefs: []) == .auto)
        #expect(selection.reconciled(withLiveRefs: ["refs/heads/main"]) == .auto)
    }

    @Test func test_reconciled_allStaysAllRegardlessOfLiveRefs() {
        let selection = GitRefSelection.all
        #expect(selection.reconciled(withLiveRefs: []) == .all)
        #expect(selection.reconciled(withLiveRefs: ["refs/heads/main"]) == .all)
    }

    @Test func test_reconciled_refsWhereEverySavedRefIsStillLive_keepsThemAll() {
        let selection = GitRefSelection.refs(["refs/heads/main", "refs/heads/feature"])
        let live: Set<String> = ["refs/heads/main", "refs/heads/feature", "refs/heads/unrelated"]

        #expect(selection.reconciled(withLiveRefs: live) == selection)
    }

    @Test func test_reconciled_refsWhereEverySavedRefVanished_fallsBackToAuto() {
        let selection = GitRefSelection.refs(["refs/heads/deleted-one", "refs/heads/deleted-two"])
        let live: Set<String> = ["refs/heads/main"]

        #expect(selection.reconciled(withLiveRefs: live) == .auto)
    }

    @Test func test_reconciled_refsWherePartialVanish_keepsSurvivorsInOriginalOrder() {
        let selection = GitRefSelection.refs(["refs/heads/zed", "refs/heads/deleted", "refs/heads/alpha"])
        let live: Set<String> = ["refs/heads/alpha", "refs/heads/zed"]

        #expect(selection.reconciled(withLiveRefs: live) == .refs(["refs/heads/zed", "refs/heads/alpha"]))
    }

    @Test func test_codableRoundTrip_auto() throws {
        let original = GitRefSelection.auto
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GitRefSelection.self, from: data)
        #expect(decoded == original)
    }

    @Test func test_codableRoundTrip_all() throws {
        let original = GitRefSelection.all
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GitRefSelection.self, from: data)
        #expect(decoded == original)
    }

    @Test func test_codableRoundTrip_refs() throws {
        let original = GitRefSelection.refs(["refs/heads/main", "refs/remotes/origin/main"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GitRefSelection.self, from: data)
        #expect(decoded == original)
    }
}
