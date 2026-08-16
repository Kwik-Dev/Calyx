// GitRepoDiscoveryTests.swift
// CalyxTests
//
// Turning terminal working directories into Changes sidebar sections:
// which repositories are found, in which fixed order, and which section
// owns the active pane.

import Foundation
import Testing
@testable import Calyx

private struct WorktreeFamily {
    let scratch: URL
    let mainRepo: URL
    let alpha: URL
    let beta: URL
    let baseCommit: String
}

/// A repository whose directory name sorts after both of its worktrees, so
/// "main worktree first" is distinguishable from plain path ordering.
private func makeWorktreeFamily(_ label: String) throws -> WorktreeFamily {
    let scratch = try GitScratch.makeDirectory(label)
    let mainRepo = scratch.appendingPathComponent("zeta-main")
    try GitScratch.run(["init", "-q", "-b", "main", mainRepo.path], in: scratch)
    let baseCommit = try GitScratch.commit(
        file: "base.txt",
        contents: "base\n",
        message: "base commit",
        in: mainRepo
    )

    let alpha = scratch.appendingPathComponent("alpha-wt")
    let beta = scratch.appendingPathComponent("beta-wt")
    try GitScratch.run(["worktree", "add", "-q", "-b", "alpha", alpha.path], in: mainRepo)
    try GitScratch.run(["worktree", "add", "-q", "-b", "beta", beta.path], in: mainRepo)

    return WorktreeFamily(
        scratch: scratch,
        mainRepo: mainRepo,
        alpha: alpha,
        beta: beta,
        baseCommit: baseCommit
    )
}

private func section(_ rootPath: String) -> GitRepoDescriptor {
    GitRepoDescriptor(
        rootPath: rootPath,
        displayName: (rootPath as NSString).lastPathComponent,
        kind: .repository,
        branch: "main",
        headShortHash: "0123456",
        location: GitRepositoryLocation(
            workTree: rootPath,
            gitDirectory: rootPath + "/.git",
            gitCommonDirectory: rootPath + "/.git"
        )
    )
}

struct GitRepoDiscoveryTests {

    // MARK: - discover

    @Test func test_discover_fromLinkedWorktreeSeedFindsTheMainRepositoryAndItsSiblings() async throws {
        let family = try makeWorktreeFamily("discover-siblings")
        defer { try? FileManager.default.removeItem(at: family.scratch) }

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [family.alpha.path])

        #expect(result.sections.map(\.rootPath) == [
            family.mainRepo.path, family.alpha.path, family.beta.path,
        ])
        #expect(result.sections.map(\.displayName) == ["zeta-main", "alpha-wt", "beta-wt"])
        #expect(result.sections.map(\.kind) == [.repository, .worktree, .worktree])
        #expect(result.sections.map(\.branch) == ["main", "alpha", "beta"])
        #expect(result.failureMessage == nil)
    }

    @Test func test_discover_collapsesSeedsThatResolveToTheSameRepository() async throws {
        let family = try makeWorktreeFamily("discover-dedupe")
        defer { try? FileManager.default.removeItem(at: family.scratch) }

        let nested = family.mainRepo.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [
            family.mainRepo.path, nested.path, family.alpha.path, family.alpha.path,
        ])

        #expect(result.sections.map(\.rootPath) == [
            family.mainRepo.path, family.alpha.path, family.beta.path,
        ])
    }

    @Test func test_discover_skipsWorktreeWhoseDirectoryIsGone() async throws {
        let family = try makeWorktreeFamily("discover-prunable")
        defer { try? FileManager.default.removeItem(at: family.scratch) }

        try FileManager.default.removeItem(at: family.beta)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [family.mainRepo.path])

        #expect(result.sections.map(\.rootPath) == [family.mainRepo.path, family.alpha.path])
    }

    @Test func test_discover_skipsSeedThatIsNotARepository() async throws {
        let family = try makeWorktreeFamily("discover-nonrepo")
        defer { try? FileManager.default.removeItem(at: family.scratch) }

        let plain = family.scratch.appendingPathComponent("plain-directory")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [plain.path, family.alpha.path])

        #expect(result.sections.map(\.rootPath) == [
            family.mainRepo.path, family.alpha.path, family.beta.path,
        ])
        #expect(result.failureMessage == nil)
    }

    @Test func test_discover_keepsSectionOrderWhenSeedsAreShuffled() async throws {
        let family = try makeWorktreeFamily("discover-order")
        defer { try? FileManager.default.removeItem(at: family.scratch) }

        let expected = [family.mainRepo.path, family.alpha.path, family.beta.path]

        let inOrder = await GitRepoDiscovery.discover(seedWorkDirs: [
            family.mainRepo.path, family.alpha.path, family.beta.path,
        ])
        let shuffled = await GitRepoDiscovery.discover(seedWorkDirs: [
            family.beta.path, family.alpha.path, family.mainRepo.path,
        ])

        #expect(inOrder.sections.map(\.rootPath) == expected)
        #expect(shuffled.sections.map(\.rootPath) == expected)
    }

    @Test func test_discover_treatsEveryWorktreeOfABareRepositoryAsAWorktree() async throws {
        let scratch = try GitScratch.makeDirectory("discover-bare")
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

        let attached = scratch.appendingPathComponent("w-attached")
        let detached = scratch.appendingPathComponent("w-detached")
        try GitScratch.run(
            ["--git-dir=\(bare.path)", "worktree", "add", "-q", attached.path, "main"],
            in: scratch
        )
        try GitScratch.run(
            ["--git-dir=\(bare.path)", "worktree", "add", "-q", "--detach", detached.path, "main"],
            in: scratch
        )

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [attached.path])

        #expect(result.sections.map(\.rootPath) == [attached.path, detached.path])
        #expect(result.sections.map(\.kind) == [.worktree, .worktree])
        #expect(result.sections.map(\.branch) == ["main", nil])

        let detachedHead = try #require(result.sections.last?.headShortHash)
        #expect(baseCommit.hasPrefix(detachedHead))
        #expect(detachedHead.count >= 7)
    }

    @Test func test_discover_reportsNoFailureWhenNoSeedIsARepository() async throws {
        let scratch = try GitScratch.makeDirectory("discover-none")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let first = scratch.appendingPathComponent("plain-one")
        let second = scratch.appendingPathComponent("plain-two")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [first.path, second.path])

        #expect(result.sections.isEmpty)
        #expect(result.failureMessage == nil)
    }

    @Test func test_discover_reportsFailureWhenEverySeedFailedForAnotherReason() async throws {
        let scratch = try GitScratch.makeDirectory("discover-failure")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // A pane whose working directory has been deleted fails before git
        // can answer "not a git repository", so it is a real error.
        let missing = scratch.appendingPathComponent("deleted-pane-cwd")

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [missing.path])

        #expect(result.sections.isEmpty)
        let message = try #require(result.failureMessage)
        #expect(!message.isEmpty)
    }

    @Test func test_discover_reportsNoFailureWhenAtLeastOneSectionWasBuilt() async throws {
        let family = try makeWorktreeFamily("discover-partial-failure")
        defer { try? FileManager.default.removeItem(at: family.scratch) }

        let missing = family.scratch.appendingPathComponent("deleted-pane-cwd")

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [missing.path, family.alpha.path])

        #expect(result.sections.map(\.rootPath) == [
            family.mainRepo.path, family.alpha.path, family.beta.path,
        ])
        #expect(result.failureMessage == nil)
    }

    @Test func test_discover_reportsNoFailureWithoutSeeds() async {
        let result = await GitRepoDiscovery.discover(seedWorkDirs: [])

        #expect(result.sections.isEmpty)
        #expect(result.failureMessage == nil)
    }

    // MARK: - activeRepoID

    @Test func test_activeRepoID_choosesTheDeepestEnclosingSection() {
        let sections = [section("/a/Calyx"), section("/a/Calyx/ghostty")]

        #expect(GitRepoDiscovery.activeRepoID(for: "/a/Calyx/ghostty/src", in: sections) == "/a/Calyx/ghostty")
        #expect(GitRepoDiscovery.activeRepoID(for: "/a/Calyx/ghostty", in: sections) == "/a/Calyx/ghostty")
        #expect(GitRepoDiscovery.activeRepoID(for: "/a/Calyx/Features/Git", in: sections) == "/a/Calyx")
        #expect(GitRepoDiscovery.activeRepoID(for: "/a/Calyx", in: sections) == "/a/Calyx")
    }

    @Test func test_activeRepoID_isNilOutsideEverySection() {
        let sections = [section("/a/Calyx"), section("/a/Calyx/ghostty")]

        #expect(GitRepoDiscovery.activeRepoID(for: "/b/other", in: sections) == nil)
        #expect(GitRepoDiscovery.activeRepoID(for: nil, in: sections) == nil)
        #expect(GitRepoDiscovery.activeRepoID(for: "/a/Calyx", in: []) == nil)
    }

    @Test func test_activeRepoID_ignoresSiblingsSharingANamePrefix() {
        let sections = [section("/a/Calyx"), section("/a/Calyx-worktrees/git-repo-sections")]

        #expect(
            GitRepoDiscovery.activeRepoID(
                for: "/a/Calyx-worktrees/git-repo-sections/Calyx/Features",
                in: sections
            ) == "/a/Calyx-worktrees/git-repo-sections"
        )
        #expect(
            GitRepoDiscovery.activeRepoID(
                for: "/a/Calyx-worktrees/git-repo-sections",
                in: [section("/a/Calyx")]
            ) == nil
        )
    }
}
