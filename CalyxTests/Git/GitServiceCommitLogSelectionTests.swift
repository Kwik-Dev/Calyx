// GitServiceCommitLogSelectionTests.swift
// CalyxTests
//
// GitService.commitLog(selection:) against a live repository: `.auto`
// never reaches an orphan branch nobody's HEAD, upstream, or base
// points at, `.all` reaches every branch including it, `.refs` reaches
// only what it names, and an unsafe-looking ref argument is dropped
// rather than ever reaching the git subprocess.

import Foundation
import Testing
@testable import Calyx

struct GitServiceCommitLogSelectionTests {
    @Test func test_auto_excludesOrphanBranch_allIncludesIt() async throws {
        let scratch = try GitScratch.makeDirectory("selection-orphan")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        let mainCommit = try GitScratch.commit(
            file: "base.txt", contents: "base\n", message: "base commit", in: repository
        )

        try GitScratch.run(["checkout", "-q", "--orphan", "gh-pages"], in: repository)
        try GitScratch.run(["rm", "-rf", "-q", "."], in: repository)
        let orphanCommit = try GitScratch.commit(
            file: "index.html", contents: "<html></html>\n", message: "publish", in: repository
        )
        try GitScratch.run(["checkout", "-q", "main"], in: repository)

        let location = try await GitService.repositoryLocation(workDir: repository.path)

        let autoCommits = try await GitService.commitLog(
            location: location, selection: .auto, maxCount: 100, skip: 0
        )
        #expect(autoCommits.map(\.id) == [mainCommit])

        let allCommits = try await GitService.commitLog(
            location: location, selection: .all, maxCount: 100, skip: 0
        )
        #expect(Set(allCommits.map(\.id)) == [mainCommit, orphanCommit])
    }

    @Test func test_refsSelection_namingOneBranch_excludesOtherBranches() async throws {
        let scratch = try GitScratch.makeDirectory("selection-refs")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        let mainCommit = try GitScratch.commit(
            file: "base.txt", contents: "base\n", message: "base commit", in: repository
        )
        try GitScratch.run(["checkout", "-q", "-b", "sibling"], in: repository)
        try GitScratch.commit(
            file: "sibling.txt", contents: "sibling\n", message: "sibling commit", in: repository
        )
        try GitScratch.run(["checkout", "-q", "main"], in: repository)

        let location = try await GitService.repositoryLocation(workDir: repository.path)
        let commits = try await GitService.commitLog(
            location: location, selection: .refs(["refs/heads/main"]), maxCount: 100, skip: 0
        )

        #expect(commits.map(\.id) == [mainCommit])
    }

    @Test func test_refsSelection_rejectsUnsafeLookingArguments_yieldingNoCommits() async throws {
        let scratch = try GitScratch.makeDirectory("selection-unsafe")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base commit", in: repository)

        let location = try await GitService.repositoryLocation(workDir: repository.path)

        let unsafeSelections: [GitRefSelection] = [
            .refs(["--exec=/bin/false"]),
            .refs(["-x"]),
            .refs(["refs/he ads/main"]),
            .refs(["refs/heads/ma\nin"]),
        ]

        for selection in unsafeSelections {
            let commits = try await GitService.commitLog(
                location: location, selection: selection, maxCount: 100, skip: 0
            )
            #expect(commits.isEmpty, "\(selection) must not reach the git subprocess")
        }
    }

    @Test func test_unbornRepository_autoAndAllYieldNoCommits() async throws {
        let scratch = try GitScratch.makeDirectory("selection-unborn")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)

        let location = try await GitService.repositoryLocation(workDir: repository.path)

        let autoCommits = try await GitService.commitLog(
            location: location, selection: .auto, maxCount: 100, skip: 0
        )
        #expect(autoCommits.isEmpty)

        let allCommits = try await GitService.commitLog(
            location: location, selection: .all, maxCount: 100, skip: 0
        )
        #expect(allCommits.isEmpty)
    }

    @Test func test_all_detachedHeadWithNoRefsAtAll_returnsHeadHistoryNotEmpty() async throws {
        // Zero refs (no branch, no tag) is not the same fact as unborn: a
        // detached HEAD still points at a real commit with real history.
        // `.all` must log from HEAD in that case, not answer empty the way
        // it correctly does for an actually-unborn repository.
        let scratch = try GitScratch.makeDirectory("selection-detached-no-refs")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("repository")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)
        let commit = try GitScratch.commit(
            file: "base.txt", contents: "base\n", message: "base commit", in: repository
        )
        try GitScratch.run(["checkout", "-q", "--detach", commit], in: repository)
        try GitScratch.run(["branch", "-D", "main"], in: repository)

        let location = try await GitService.repositoryLocation(workDir: repository.path)
        let refs = try await GitService.refList(location: location)
        #expect(refs.isEmpty, "fixture must actually have zero refs for this test to mean anything")

        let commits = try await GitService.commitLog(
            location: location, selection: .all, maxCount: 100, skip: 0
        )

        #expect(commits.map(\.id) == [commit])
    }
}
