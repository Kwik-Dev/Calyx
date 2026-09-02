// GitServiceCommitLogLocationTests.swift
// CalyxTests
//
// Commit history scoping when the repository has already been resolved:
// `.auto` follows only HEAD (there is no upstream or base to add in
// these fixtures), so it never picks up sibling branch history -- in a
// linked worktree or in the main worktree alike -- and the pre-existing
// work-directory entry point must agree with the resolved-location one.

import Foundation
import Testing
@testable import Calyx

struct GitServiceCommitLogLocationTests {
    @Test func test_commitLogAutoExcludesSiblingBranchCommitsInLinkedWorktree() async throws {
        let scratch = try GitScratch.makeDirectory("commitlog-linked")
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

        let current = scratch.appendingPathComponent("current-worktree")
        let sibling = scratch.appendingPathComponent("sibling-worktree")
        try GitScratch.run(
            ["--git-dir=\(bare.path)", "worktree", "add", "-q", current.path, "main"],
            in: scratch
        )
        try GitScratch.run(
            ["--git-dir=\(bare.path)", "worktree", "add", "-q", "-b", "sibling", sibling.path, "main"],
            in: scratch
        )
        let siblingCommit = try GitScratch.commit(
            file: "sibling.txt",
            contents: "sibling only\n",
            message: "sibling-only commit",
            in: sibling
        )

        let location = try await GitService.repositoryLocation(workDir: current.path)
        let commits = try await GitService.commitLog(location: location, selection: .auto, maxCount: 100, skip: 0)

        #expect(commits.map(\.id) == [baseCommit])
        #expect(!commits.map(\.id).contains(siblingCommit))

        let viaWorkDir = try await GitService.commitLog(
            workDir: current.path,
            selection: .auto,
            maxCount: 100,
            skip: 0
        )
        #expect(commits.map(\.id) == viaWorkDir.map(\.id))
    }

    @Test func test_commitLogAutoExcludesUncheckedOutBranchInMainWorktree() async throws {
        let scratch = try GitScratch.makeDirectory("commitlog-main")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        let baseCommit = try GitScratch.commit(
            file: "base.txt",
            contents: "base\n",
            message: "base commit",
            in: repository
        )
        try GitScratch.run(["checkout", "-q", "-b", "sibling"], in: repository)
        let siblingCommit = try GitScratch.commit(
            file: "sibling.txt",
            contents: "sibling only\n",
            message: "sibling-only commit",
            in: repository
        )
        try GitScratch.run(["checkout", "-q", "main"], in: repository)

        let location = try await GitService.repositoryLocation(workDir: repository.path)
        let commits = try await GitService.commitLog(location: location, selection: .auto, maxCount: 100, skip: 0)

        #expect(commits.map(\.id) == [baseCommit])
        #expect(!commits.map(\.id).contains(siblingCommit))

        let viaWorkDir = try await GitService.commitLog(
            workDir: repository.path,
            selection: .auto,
            maxCount: 100,
            skip: 0
        )
        #expect(commits.map(\.id) == viaWorkDir.map(\.id))
    }
}
