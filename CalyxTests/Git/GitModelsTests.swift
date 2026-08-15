// GitModelsTests.swift
// CalyxTests
//
// Tests for Git data models: GitFileEntry, CommitFileEntry, DiffSource, GitFileStatus,
// GitChangesState, and GitRefreshFailureOutcome.

import Testing
@testable import Calyx

struct GitModelsTests {
    @Test func gitFileEntryIDIsDeterministic() {
        let a = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        let b = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        #expect(a.id == b.id)
    }

    @Test func gitFileEntryIDDistinguishesStagedState() {
        let staged = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: true, renameScore: nil)
        let unstaged = GitFileEntry(path: "foo.swift", origPath: nil, status: .modified, isStaged: false, renameScore: nil)
        #expect(staged.id != unstaged.id)
    }

    @Test func commitFileEntryIDIsDeterministic() {
        let a = CommitFileEntry(commitHash: "abc123", path: "bar.swift", origPath: nil, status: .added)
        let b = CommitFileEntry(commitHash: "abc123", path: "bar.swift", origPath: nil, status: .added)
        #expect(a.id == b.id)
    }

    @Test func diffSourceEquality() {
        let a = DiffSource.unstaged(path: "foo.swift", workDir: "/tmp")
        let b = DiffSource.unstaged(path: "foo.swift", workDir: "/tmp")
        #expect(a == b)

        let c = DiffSource.staged(path: "foo.swift", workDir: "/tmp")
        #expect(a != c)
    }

    @Test func allGitFileStatusRawValues() {
        #expect(GitFileStatus.modified.rawValue == "M")
        #expect(GitFileStatus.added.rawValue == "A")
        #expect(GitFileStatus.deleted.rawValue == "D")
        #expect(GitFileStatus.renamed.rawValue == "R")
        #expect(GitFileStatus.copied.rawValue == "C")
        #expect(GitFileStatus.untracked.rawValue == "?")
        #expect(GitFileStatus.unmerged.rawValue == "U")
        #expect(GitFileStatus.typeChanged.rawValue == "T")
    }

    @Test func allowsInitialSpinnerOnlyForNotLoaded() {
        // .notLoaded is the only state with no content to preserve on screen,
        // so it is the only one allowed to show the content-replacing spinner.
        #expect(GitChangesState.notLoaded.allowsInitialSpinner == true)
        #expect(GitChangesState.notRepository.allowsInitialSpinner == false)
        #expect(GitChangesState.loading.allowsInitialSpinner == false)
        #expect(GitChangesState.loaded.allowsInitialSpinner == false)
        #expect(GitChangesState.error("git status failed").allowsInitialSpinner == false)
    }

    @Test func gitChangesStateEquatable() {
        #expect(GitChangesState.notLoaded == GitChangesState.notLoaded)
        #expect(GitChangesState.loaded == GitChangesState.loaded)
        #expect(GitChangesState.notLoaded != GitChangesState.loading)
        #expect(GitChangesState.loading != GitChangesState.loaded)
        #expect(GitChangesState.notRepository != GitChangesState.notLoaded)
        #expect(GitChangesState.error("a") == GitChangesState.error("a"))
        #expect(GitChangesState.error("a") != GitChangesState.error("b"))
    }

    @Test func notARepositoryFailureAlwaysShowsNotRepository() {
        // A "not a repository" failure is a real state change (the user cd'd
        // out of the repo), so it wins over any current state, including one
        // with content already on screen.
        let fromLoaded = GitRefreshFailureOutcome.resolve(
            current: .loaded,
            isNotARepository: true,
            message: "not a git repository"
        )
        #expect(fromLoaded == .showNotRepository)

        let fromNotLoaded = GitRefreshFailureOutcome.resolve(
            current: .notLoaded,
            isNotARepository: true,
            message: "not a git repository"
        )
        #expect(fromNotLoaded == .showNotRepository)
    }

    @Test func ordinaryFailureFromLoadedKeepsStaleContent() {
        let outcome = GitRefreshFailureOutcome.resolve(
            current: .loaded,
            isNotARepository: false,
            message: "git status failed: exit 128"
        )
        #expect(outcome == .keepStale(message: "git status failed: exit 128"))
    }

    @Test func ordinaryFailureFromNonLoadedStatesShowsError() {
        // Every state other than .loaded has no content worth preserving,
        // so an ordinary failure replaces it with the error state.
        let message = "git status failed: exit 128"

        let fromNotLoaded = GitRefreshFailureOutcome.resolve(
            current: .notLoaded,
            isNotARepository: false,
            message: message
        )
        #expect(fromNotLoaded == .showError(message))

        let fromLoading = GitRefreshFailureOutcome.resolve(
            current: .loading,
            isNotARepository: false,
            message: message
        )
        #expect(fromLoading == .showError(message))

        let fromError = GitRefreshFailureOutcome.resolve(
            current: .error("previous error"),
            isNotARepository: false,
            message: message
        )
        #expect(fromError == .showError(message))

        let fromNotRepository = GitRefreshFailureOutcome.resolve(
            current: .notRepository,
            isNotARepository: false,
            message: message
        )
        #expect(fromNotRepository == .showError(message))
    }
}
