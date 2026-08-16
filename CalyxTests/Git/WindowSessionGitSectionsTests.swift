// WindowSessionGitSectionsTests.swift
// CalyxTests
//
// Applying a discovery result to the window: surviving sections keep
// their loaded data and expansion, new sections start empty, and every
// trace of a section that disappeared is dropped.

import Foundation
import Testing
@testable import Calyx

private func descriptor(
    _ rootPath: String,
    kind: GitRepoKind = .repository,
    branch: String? = "main"
) -> GitRepoDescriptor {
    GitRepoDescriptor(
        rootPath: rootPath,
        displayName: (rootPath as NSString).lastPathComponent,
        kind: kind,
        branch: branch,
        headShortHash: "0123456",
        location: GitRepositoryLocation(
            workTree: rootPath,
            gitDirectory: rootPath + "/.git",
            gitCommonDirectory: rootPath + "/.git"
        )
    )
}

private let repoA = descriptor("/repos/alpha")
private let repoB = descriptor("/repos/beta", kind: .worktree, branch: "beta")
private let repoC = descriptor("/repos/gamma", kind: .worktree, branch: "gamma")

private func loadedChanges() -> GitRepoChanges {
    GitRepoChanges(
        state: .loaded,
        entries: [
            GitFileEntry(
                path: "Sources/App.swift",
                origPath: nil,
                status: .modified,
                isStaged: false,
                renameScore: nil
            )
        ],
        commits: [
            GitCommit(
                id: "3f5a1c9d2b4e6f8a0c1d3e5f7a9b1c3d5e7f9a1b",
                shortHash: "3f5a1c9",
                message: "base commit",
                author: "Calyx Tests",
                relativeDate: "2 days ago",
                parentIDs: [],
                graphPrefix: "* "
            )
        ],
        expandedCommitIDs: ["3f5a1c9d2b4e6f8a0c1d3e5f7a9b1c3d5e7f9a1b"],
        isLogLoaded: true,
        hasMoreCommits: false,
        staleRefreshMessage: nil
    )
}

@MainActor
@Suite("WindowSession git sections")
struct WindowSessionGitSectionsTests {
    @Test func test_applyGitSections_installsSectionsAndStartsNewOnesNotLoaded() {
        let session = WindowSession()

        session.applyGitSections([repoA, repoB])

        #expect(session.gitRepoSections == [repoA, repoB])
        #expect(session.gitRepoChanges == [
            repoA.id: GitRepoChanges(),
            repoB.id: GitRepoChanges(),
        ])
    }

    @Test func test_applyGitSections_keepsDataAndExpansionOfSurvivingSections() {
        let session = WindowSession()
        session.applyGitSections([repoA, repoB])
        let existing = loadedChanges()
        session.gitRepoChanges[repoA.id] = existing
        session.gitExpandedRepoIDs = [repoA.id, repoB.id]

        session.applyGitSections([repoA, repoC])

        #expect(session.gitRepoSections == [repoA, repoC])
        #expect(session.gitRepoChanges[repoA.id] == existing)
        #expect(session.gitRepoChanges[repoC.id] == GitRepoChanges())
        #expect(session.gitExpandedRepoIDs == [repoA.id])
    }

    @Test func test_applyGitSections_dropsStateOfSectionsThatDisappeared() {
        let session = WindowSession()
        session.applyGitSections([repoA, repoB])
        session.gitRepoChanges[repoB.id] = loadedChanges()
        session.gitExpandedRepoIDs = [repoB.id]

        session.applyGitSections([repoA])

        #expect(session.gitRepoSections == [repoA])
        #expect(session.gitRepoChanges[repoB.id] == nil)
        #expect(session.gitExpandedRepoIDs.isEmpty)
    }

    @Test func test_applyGitSections_clearsTheActiveRepoOnlyWhenItDisappears() {
        let session = WindowSession()
        session.applyGitSections([repoA, repoB])
        session.gitActiveRepoID = repoB.id

        session.applyGitSections([repoB, repoA])
        #expect(session.gitActiveRepoID == repoB.id)

        session.applyGitSections([repoA])
        #expect(session.gitActiveRepoID == nil)
    }

    @Test func test_applyGitSections_changesNothingWhenReappliedUnchanged() {
        let session = WindowSession()
        session.applyGitSections([repoA, repoB])
        let existing = loadedChanges()
        session.gitRepoChanges[repoA.id] = existing
        session.gitExpandedRepoIDs = [repoA.id]
        session.gitActiveRepoID = repoA.id
        let changesBefore = session.gitRepoChanges

        session.applyGitSections([repoA, repoB])

        #expect(session.gitRepoSections == [repoA, repoB])
        #expect(session.gitRepoChanges == changesBefore)
        #expect(session.gitRepoChanges[repoA.id] == existing)
        #expect(session.gitExpandedRepoIDs == [repoA.id])
        #expect(session.gitActiveRepoID == repoA.id)
    }
}
