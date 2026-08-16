// GitServiceSubmoduleTests.swift
// CalyxTests
//
// Coverage for the facts a submodule section is built from: the gitlinks
// the index records, what HEAD points at, and which superproject a work
// tree belongs to.

import Foundation
import Testing
@testable import Calyx

/// Lays out records the way `git ls-files -z --stage` does:
/// `<mode> <sha> <stage>`, a tab, then the path, each NUL-terminated.
private func indexEntries(
    _ entries: [(mode: String, sha: String, stage: Int, path: String)]
) -> String {
    entries.map { "\($0.mode) \($0.sha) \($0.stage)\t\($0.path)\u{0}" }.joined()
}

private let gitlinkOID = "60c29a2d2e948639d7830d512e5adb62a9752f86"
private let siblingGitlinkOID = "9f1c1b8a1a3f2f7c0d4e5b6a7c8d9e0f1a2b3c4d"
private let blobOID = "1a9cc2b7fbfa834924f4c03780d767ccbecf0c9c"

struct GitServiceSubmoduleTests {

    // MARK: - parseIndexGitlinks

    @Test func test_parseIndexGitlinks_readsThePathAfterTheFirstTab() {
        let output = indexEntries([
            (mode: "160000", sha: gitlinkOID, stage: 0, path: "dir with space/sub")
        ])

        #expect(GitService.parseIndexGitlinks(output) == [
            GitSubmoduleInfo(path: "dir with space/sub")
        ])
    }

    @Test func test_parseIndexGitlinks_keepsAPathContainingATab() {
        // `-z` output is unquoted, so a tab inside a path reaches the parser
        // as itself and only the first one separates the fields.
        let output = indexEntries([
            (mode: "160000", sha: gitlinkOID, stage: 0, path: "we\tird/sub")
        ])

        #expect(GitService.parseIndexGitlinks(output) == [GitSubmoduleInfo(path: "we\tird/sub")])
    }

    @Test func test_parseIndexGitlinks_reportsAnUnmergedGitlinkOnce() {
        // A merge that moved the gitlink on both sides lists the same path
        // at stages 1, 2 and 3.
        let output = indexEntries([
            (mode: "160000", sha: gitlinkOID, stage: 1, path: "sub"),
            (mode: "160000", sha: siblingGitlinkOID, stage: 2, path: "sub"),
            (mode: "160000", sha: blobOID, stage: 3, path: "sub"),
        ])

        #expect(GitService.parseIndexGitlinks(output) == [GitSubmoduleInfo(path: "sub")])
    }

    @Test func test_parseIndexGitlinks_ignoresEntriesThatAreNotGitlinks() {
        let output = indexEntries([
            (mode: "100644", sha: blobOID, stage: 0, path: ".gitmodules"),
            (mode: "160000", sha: gitlinkOID, stage: 0, path: "sub"),
            (mode: "100755", sha: blobOID, stage: 0, path: "scripts/build.sh"),
            (mode: "120000", sha: blobOID, stage: 0, path: "link"),
        ])

        #expect(GitService.parseIndexGitlinks(output) == [GitSubmoduleInfo(path: "sub")])
    }

    @Test func test_parseIndexGitlinks_keepsTheOrderTheEntriesArriveIn() {
        let output = indexEntries([
            (mode: "160000", sha: gitlinkOID, stage: 0, path: "zeta/sub"),
            (mode: "100644", sha: blobOID, stage: 0, path: "README.md"),
            (mode: "160000", sha: siblingGitlinkOID, stage: 0, path: "alpha/sub"),
        ])

        #expect(GitService.parseIndexGitlinks(output) == [
            GitSubmoduleInfo(path: "zeta/sub"),
            GitSubmoduleInfo(path: "alpha/sub"),
        ])
    }

    @Test func test_parseIndexGitlinks_returnsNothingWhenThereAreNoEntries() {
        #expect(GitService.parseIndexGitlinks("") == [])
        #expect(GitService.parseIndexGitlinks("\u{0}\u{0}") == [])
    }

    // MARK: - submoduleList

    @Test func test_submoduleList_reportsEveryGitlinkTheIndexRecords() async throws {
        let scratch = try GitScratch.makeDirectory("submodule-list")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let alphaSource = try GitSubmoduleScratch.makeRepository("source-alpha", in: scratch)
        let zetaSource = try GitSubmoduleScratch.makeRepository("source-zeta", in: scratch)
        let superproject = try GitSubmoduleScratch.makeRepository("proj", in: scratch)
        try GitSubmoduleScratch.addSubmodule(from: alphaSource, at: "alpha sub", in: superproject)
        try GitSubmoduleScratch.addSubmodule(from: zetaSource, at: "zeta/sub", in: superproject)

        let submodules = try await GitService.submoduleList(repoRoot: superproject.path)

        #expect(submodules == [
            GitSubmoduleInfo(path: "alpha sub"),
            GitSubmoduleInfo(path: "zeta/sub"),
        ])
    }

    @Test func test_submoduleList_ignoresGitmodulesDeclarationsTheIndexDoesNotBack() async throws {
        let fixture = try GitSubmoduleScratch.makeSuperproject("submodule-gitmodules")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        // `.gitmodules` is a tracked text file, so a checkout can declare a
        // path outside the work tree or the work tree itself.
        let gitmodules = fixture.root.appendingPathComponent(".gitmodules")
        let declarations = try String(contentsOf: gitmodules, encoding: .utf8) + [
            "[submodule \"escape\"]", "\tpath = ../../../../etc", "\turl = /nowhere",
            "[submodule \"self\"]", "\tpath = .", "\turl = /nowhere", "",
        ].joined(separator: "\n")
        try declarations.write(to: gitmodules, atomically: true, encoding: .utf8)

        let declared = try GitScratch.run(
            ["config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.path$"],
            in: fixture.root
        )
        try #require(declared.contains("submodule.escape.path ../../../../etc"))
        try #require(declared.contains("submodule.self.path ."))

        let submodules = try await GitService.submoduleList(repoRoot: fixture.root.path)

        #expect(submodules == [GitSubmoduleInfo(path: "sub")])
    }

    @Test func test_submoduleList_dropsAPathWhoseGitlinkLeftTheIndex() async throws {
        let fixture = try GitSubmoduleScratch.makeSuperproject("submodule-uncached")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        let before = try await GitService.submoduleList(repoRoot: fixture.root.path)
        #expect(before == [GitSubmoduleInfo(path: "sub")])

        try GitScratch.run(["rm", "--cached", "-q", "--", "sub"], in: fixture.root)
        // Removing the gitlink leaves the declaration behind.
        let declared = try GitScratch.run(
            ["config", "--file", ".gitmodules", "--get", "submodule.sub.path"],
            in: fixture.root
        )
        try #require(declared == "sub")

        let after = try await GitService.submoduleList(repoRoot: fixture.root.path)
        #expect(after == [])
    }

    @Test func test_submoduleList_keepsAGitlinkWhoseDirectoryWasDeinitialized() async throws {
        let fixture = try GitSubmoduleScratch.makeSuperproject("submodule-deinit")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        try GitScratch.run(["submodule", "deinit", "-f", "--", "sub"], in: fixture.root)
        try #require(
            !FileManager.default.fileExists(
                atPath: fixture.submodule.appendingPathComponent(".git").path
            )
        )

        // Deinitializing empties the directory and leaves the index alone,
        // so the gitlink is still what the repository records.
        let submodules = try await GitService.submoduleList(repoRoot: fixture.root.path)

        #expect(submodules == [GitSubmoduleInfo(path: "sub")])
    }

    @Test func test_submoduleList_reportsNothingForARepositoryWithoutGitlinks() async throws {
        let fixture = try GitSubmoduleScratch.makeSuperproject("submodule-none")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        let standalone = try await GitService.submoduleList(repoRoot: fixture.source.path)
        // The superproject of the same fixture answers with its gitlink, so
        // the empty result above is the absence of submodules.
        let superproject = try await GitService.submoduleList(repoRoot: fixture.root.path)

        #expect(standalone == [])
        #expect(superproject == [GitSubmoduleInfo(path: "sub")])
    }

    // MARK: - headSummary

    @Test func test_headSummary_reportsTheBranchAndShortCommitHeadPointsAt() async throws {
        let scratch = try GitScratch.makeDirectory("head-branch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repository = try GitSubmoduleScratch.makeRepository("proj", in: scratch)
        let head = try GitScratch.run(["rev-parse", "HEAD"], in: repository)

        let summary = try await GitService.headSummary(workDir: repository.path)

        #expect(summary.branch == "main")
        let shortHash = try #require(summary.shortHash)
        #expect(head.hasPrefix(shortHash))
        #expect(shortHash.count >= 7)
    }

    @Test func test_headSummary_reportsNoBranchWhenHeadIsDetached() async throws {
        let scratch = try GitScratch.makeDirectory("head-detached")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repository = try GitSubmoduleScratch.makeRepository("proj", in: scratch)
        let head = try GitScratch.run(["rev-parse", "HEAD"], in: repository)
        try GitScratch.run(["checkout", "-q", "--detach", "HEAD"], in: repository)

        let summary = try await GitService.headSummary(workDir: repository.path)

        #expect(summary.branch == nil)
        let shortHash = try #require(summary.shortHash)
        #expect(head.hasPrefix(shortHash))
        #expect(shortHash.count >= 7)
    }

    @Test func test_headSummary_reportsNoShortCommitBeforeTheFirstCommit() async throws {
        let scratch = try GitScratch.makeDirectory("head-unborn")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repository = scratch.appendingPathComponent("unborn")
        try GitScratch.run(["init", "-q", "-b", "main", repository.path], in: scratch)

        // HEAD names a branch that has no commit yet, which is what every
        // repository looks like between `git init` and the first commit.
        let summary = try await GitService.headSummary(workDir: repository.path)

        #expect(summary.branch == "main")
        #expect(summary.shortHash == nil)
    }

    // MARK: - superprojectWorkTree

    @Test func test_superprojectWorkTree_answersOnlyInsideASubmoduleWorkTree() async throws {
        let fixture = try GitSubmoduleScratch.makeSuperproject("superproject-lookup")
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        let fromSubmodule = try await GitService.superprojectWorkTree(workDir: fixture.submodule.path)
        let fromSuperproject = try await GitService.superprojectWorkTree(workDir: fixture.root.path)
        let fromStandalone = try await GitService.superprojectWorkTree(workDir: fixture.source.path)

        #expect(fromSubmodule == fixture.root.path)
        #expect(fromSuperproject == nil)
        #expect(fromStandalone == nil)
    }
}
