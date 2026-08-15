// DiffTabLifecycleTests.swift
// CalyxTests
//
// Tests for diff tab lifecycle: GitChangesState transitions, SidebarMode, DiffSource dedup.

import Testing
@testable import Calyx

@MainActor
struct DiffTabLifecycleTests {
    @Test func gitChangesStateTransitions() {
        let session = WindowSession()
        if case .notLoaded = session.gitChangesState {} else {
            Issue.record("Expected initial state .notLoaded")
        }

        session.gitChangesState = .loading
        if case .loading = session.gitChangesState {} else {
            Issue.record("Expected .loading")
        }

        session.gitChangesState = .loaded
        if case .loaded = session.gitChangesState {} else {
            Issue.record("Expected .loaded")
        }
    }

    @Test func gitChangesStateNotRepository() {
        let session = WindowSession()
        session.gitChangesState = .loading
        session.gitChangesState = .notRepository
        if case .notRepository = session.gitChangesState {} else {
            Issue.record("Expected .notRepository")
        }
    }

    @Test func gitChangesStateError() {
        let session = WindowSession()
        session.gitChangesState = .error("test error")
        if case .error(let msg) = session.gitChangesState {
            #expect(msg == "test error")
        } else {
            Issue.record("Expected .error")
        }
    }

    @Test func sidebarModeToggle() {
        let session = WindowSession()
        #expect(session.sidebarMode == .tabs)
        session.sidebarMode = .changes
        #expect(session.sidebarMode == .changes)
        session.sidebarMode = .tabs
        #expect(session.sidebarMode == .tabs)
    }

    @Test func diffSourceDedup() {
        let a = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        let b = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        #expect(a == b)

        let c = DiffSource.staged(path: "foo.swift", workDir: "/repo")
        #expect(a != c)

        let d = DiffSource.commit(hash: "abc", path: "foo.swift", workDir: "/repo")
        #expect(a != d)
    }

    @Test func gitStaleRefreshMessageLifecycle() {
        let session = WindowSession()
        #expect(session.isGitRefreshing == false)
        #expect(session.gitStaleRefreshMessage == nil)

        session.gitChangesState = .loaded

        // A quiet refresh failure while content is already loaded must keep
        // that content on screen and only surface a warning message.
        let failureMessage = "git status failed: exit 128"
        let outcome = GitRefreshFailureOutcome.resolve(
            current: session.gitChangesState,
            isNotARepository: false,
            message: failureMessage
        )
        #expect(outcome == .keepStale(message: failureMessage))

        session.gitStaleRefreshMessage = failureMessage
        #expect(session.gitChangesState == .loaded)
        #expect(session.gitStaleRefreshMessage == failureMessage)

        // The next successful refresh clears the warning without disturbing
        // the loaded state.
        session.gitChangesState = .loaded
        session.gitStaleRefreshMessage = nil
        #expect(session.gitChangesState == .loaded)
        #expect(session.gitStaleRefreshMessage == nil)
    }
}
