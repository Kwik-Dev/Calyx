// GitServiceWorktreeListTests.swift
// CalyxTests
//
// Coverage for the `git worktree list --porcelain -z` schema: one
// attribute per NUL-terminated element, label and value split by a single
// space, an empty element ending each record, and `worktree` as the only
// attribute the schema guarantees.

import Foundation
import Testing
@testable import Calyx

/// Lays out records the way `--porcelain -z` does: every attribute is
/// NUL-terminated and an empty element closes the record.
private func porcelain(_ records: [[String]]) -> String {
    records
        .map { attributes in attributes.map { $0 + "\u{0}" }.joined() + "\u{0}" }
        .joined()
}

private let headOID = "9f1c1b8a1a3f2f7c0d4e5b6a7c8d9e0f1a2b3c4d"
private let siblingOID = "1234567890abcdef1234567890abcdef12345678"

struct GitServiceWorktreeListTests {

    // MARK: - Parser

    @Test func test_parseWorktreeList_readsBranchRecord() {
        let output = porcelain([
            ["worktree /repos/main", "HEAD \(headOID)", "branch refs/heads/main"]
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/main", headOID: headOID, branchRef: "refs/heads/main")
        ])
    }

    @Test func test_parseWorktreeList_readsDetachedRecord() {
        let output = porcelain([
            ["worktree /repos/detached", "HEAD \(headOID)", "detached"]
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/detached", headOID: headOID, isDetached: true)
        ])
    }

    @Test func test_parseWorktreeList_readsBareRecord() {
        let output = porcelain([["worktree /repos/shared.git", "bare"]])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/shared.git", isBare: true)
        ])
    }

    @Test func test_parseWorktreeList_readsLockedWithoutReason() {
        let output = porcelain([
            ["worktree /repos/locked", "HEAD \(headOID)", "detached", "locked"]
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(
                path: "/repos/locked",
                headOID: headOID,
                isDetached: true,
                isLocked: true
            )
        ])
    }

    @Test func test_parseWorktreeList_keepsLockReasonContainingSpacesAndNewlines() {
        let output = porcelain([
            ["worktree /repos/locked", "HEAD \(headOID)", "detached", "locked why not\nmulti line"]
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(
                path: "/repos/locked",
                headOID: headOID,
                isDetached: true,
                isLocked: true,
                lockReason: "why not\nmulti line"
            )
        ])
    }

    @Test func test_parseWorktreeList_readsPrunableWithReason() {
        let output = porcelain([
            [
                "worktree /repos/gone",
                "HEAD \(headOID)",
                "branch refs/heads/gone",
                "prunable gitdir file points to non-existent location",
            ]
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(
                path: "/repos/gone",
                headOID: headOID,
                branchRef: "refs/heads/gone",
                isPrunable: true,
                prunableReason: "gitdir file points to non-existent location"
            )
        ])
    }

    @Test func test_parseWorktreeList_readsMultipleRecordsInOrder() {
        let output = porcelain([
            ["worktree /repos/shared.git", "bare"],
            ["worktree /repos/detached", "HEAD \(headOID)", "detached", "locked in use"],
            ["worktree /repos/feature", "HEAD \(siblingOID)", "branch refs/heads/feature"],
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/shared.git", isBare: true),
            GitWorktreeInfo(
                path: "/repos/detached",
                headOID: headOID,
                isDetached: true,
                isLocked: true,
                lockReason: "in use"
            ),
            GitWorktreeInfo(
                path: "/repos/feature",
                headOID: siblingOID,
                branchRef: "refs/heads/feature"
            ),
        ])
    }

    @Test func test_parseWorktreeList_readsLastRecordWithoutTrailingTerminator() {
        let output = "worktree /repos/shared.git\u{0}bare\u{0}\u{0}"
            + "worktree /repos/feature\u{0}HEAD \(headOID)\u{0}branch refs/heads/feature\u{0}"

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/shared.git", isBare: true),
            GitWorktreeInfo(
                path: "/repos/feature",
                headOID: headOID,
                branchRef: "refs/heads/feature"
            ),
        ])
    }

    @Test func test_parseWorktreeList_readsMinimalPayload() {
        #expect(GitService.parseWorktreeList("worktree /p") == [GitWorktreeInfo(path: "/p")])
    }

    @Test func test_parseWorktreeList_keepsPathsContainingSpaces() {
        let output = porcelain([
            ["worktree /repos/main wt", "HEAD \(headOID)", "branch refs/heads/main"]
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/main wt", headOID: headOID, branchRef: "refs/heads/main")
        ])
    }

    @Test func test_parseWorktreeList_ignoresUnknownLabels() {
        let output = porcelain([
            [
                "worktree /repos/main",
                "HEAD \(headOID)",
                "somethingnew with a value",
                "branch refs/heads/main",
            ]
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/main", headOID: headOID, branchRef: "refs/heads/main")
        ])
    }

    @Test func test_parseWorktreeList_skipsRecordsNotStartingWithWorktree() {
        let output = porcelain([
            ["HEAD \(headOID)", "detached"],
            ["worktree /repos/main", "HEAD \(headOID)", "branch refs/heads/main"],
        ])

        #expect(GitService.parseWorktreeList(output) == [
            GitWorktreeInfo(path: "/repos/main", headOID: headOID, branchRef: "refs/heads/main")
        ])
    }

    @Test func test_parseWorktreeList_returnsNothingWhenThereAreNoRecords() {
        #expect(GitService.parseWorktreeList("") == [])
        #expect(GitService.parseWorktreeList("\u{0}\u{0}") == [])
    }

    // MARK: - Integration

    @Test func test_worktreeList_reportsBareRepositoryAndItsLinkedWorktrees() async throws {
        let scratch = try GitScratch.makeDirectory("worktree-list")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", source.path], in: scratch)
        let baseCommit = try GitScratch.commit(
            file: "base.txt",
            contents: "base\n",
            message: "base commit",
            in: source
        )

        let bare = scratch.appendingPathComponent("shared.git")
        try GitScratch.run(["clone", "-q", "--bare", source.path, bare.path], in: scratch)

        let linkedMain = scratch.appendingPathComponent("linked-main")
        let linkedFeature = scratch.appendingPathComponent("linked feature")
        try GitScratch.run(
            ["--git-dir=\(bare.path)", "worktree", "add", "-q", linkedMain.path, "main"],
            in: scratch
        )
        try GitScratch.run(
            ["--git-dir=\(bare.path)", "worktree", "add", "-q", "-b", "feature", linkedFeature.path, "main"],
            in: scratch
        )

        let infos = try await GitService.worktreeList(workDir: linkedMain.path)

        // git lists the main worktree (here the bare repository) first; the
        // order of the linked worktrees after it is not specified.
        #expect(infos.first == GitWorktreeInfo(path: bare.path, isBare: true))
        #expect(infos.dropFirst().sorted { $0.path < $1.path } == [
            GitWorktreeInfo(
                path: linkedFeature.path,
                headOID: baseCommit,
                branchRef: "refs/heads/feature"
            ),
            GitWorktreeInfo(
                path: linkedMain.path,
                headOID: baseCommit,
                branchRef: "refs/heads/main"
            ),
        ])
    }
}
