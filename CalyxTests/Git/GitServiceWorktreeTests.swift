// GitServiceWorktreeTests.swift
// CalyxTests
//
// Integration tests for commit history scoping across Git worktrees.

import Foundation
import Testing
@testable import Calyx

struct GitServiceWorktreeTests {
    @Test func test_linkedWorktree_commitLogExcludesSiblingBranchCommits() async throws {
        let scratchDirectory = try GitScratch.makeDirectory("GitServiceWorktreeTests")
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let sourceRepository = scratchDirectory.appendingPathComponent("source")
        try GitScratch.run(["init", "-q", "-b", "main", sourceRepository.path], in: scratchDirectory)
        let baseCommit = try GitScratch.commit(
            file: "base.txt",
            contents: "base\n",
            message: "base commit",
            in: sourceRepository
        )

        let bareRepository = scratchDirectory.appendingPathComponent("shared.git")
        try GitScratch.run(["clone", "-q", "--bare", sourceRepository.path, bareRepository.path], in: scratchDirectory)

        let currentWorktree = scratchDirectory.appendingPathComponent("current-worktree")
        let siblingWorktree = scratchDirectory.appendingPathComponent("sibling-worktree")
        try GitScratch.run(
            ["--git-dir=\(bareRepository.path)", "worktree", "add", "-q", currentWorktree.path, "main"],
            in: scratchDirectory
        )
        try GitScratch.run(
            ["--git-dir=\(bareRepository.path)", "worktree", "add", "-q", "-b", "sibling", siblingWorktree.path, "main"],
            in: scratchDirectory
        )

        let siblingCommit = try GitScratch.commit(
            file: "sibling.txt",
            contents: "sibling only\n",
            message: "sibling-only commit",
            in: siblingWorktree
        )

        let location = try await GitService.repositoryLocation(workDir: currentWorktree.path)
        #expect(location.workTree.hasSuffix("/current-worktree"))
        #expect(location.gitDirectory.hasSuffix("/shared.git/worktrees/current-worktree"))
        #expect(location.gitCommonDirectory.hasSuffix("/shared.git"))

        let commits = try await GitService.commitLog(
            workDir: currentWorktree.path,
            maxCount: 100,
            skip: 0
        )
        let commitIDs = Set(commits.map(\.id))

        #expect(commitIDs.contains(baseCommit))
        #expect(!commitIDs.contains(siblingCommit))
    }

    @Test func test_standardRepository_commitLogIncludesAllBranches() async throws {
        let scratchDirectory = try GitScratch.makeDirectory("GitServiceWorktreeTests")
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let repository = scratchDirectory.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratchDirectory)
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
        #expect(location.workTree.hasSuffix("/repository"))
        #expect(location.gitDirectory == location.workTree + "/.git")
        #expect(location.gitCommonDirectory == location.gitDirectory)

        let commits = try await GitService.commitLog(
            workDir: repository.path,
            maxCount: 100,
            skip: 0
        )
        let commitIDs = Set(commits.map(\.id))

        #expect(commitIDs.contains(baseCommit))
        #expect(commitIDs.contains(siblingCommit))
    }
}
