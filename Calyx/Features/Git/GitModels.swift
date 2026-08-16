// GitModels.swift
// Calyx
//
// Data models for git source control integration.

import Foundation

// TODO: Move `SidebarMode` to a neutral location (e.g. Features/Sidebar/SidebarModels.swift).
// It is used by tabs, git-changes, and the AI-agent status view, so it no longer
// belongs to the git domain — it just lives here for historical reasons.
enum SidebarMode: Sendable {
    case tabs
    case changes
    case agents
}

enum GitChangesState: Sendable, Equatable {
    case notLoaded
    case notRepository
    case loading
    case loaded
    case error(String)

    /// `.notLoaded` is the only state with no content already on screen,
    /// so it is the only one allowed to show `GitChangesView`'s
    /// content-replacing spinner. Every other state keeps whatever is
    /// currently displayed while a refresh runs.
    var allowsInitialSpinner: Bool {
        self == .notLoaded
    }
}

/// What a failed git refresh should do to `GitChangesState`, decided
/// separately from applying it so the decision itself is testable
/// without a running refresh task.
enum GitRefreshFailureOutcome: Equatable, Sendable {
    case showError(String)
    case showNotRepository
    case keepStale(message: String)

    static func resolve(
        current: GitChangesState,
        isNotARepository: Bool,
        message: String
    ) -> GitRefreshFailureOutcome {
        if isNotARepository {
            return .showNotRepository
        }
        if current == .loaded {
            return .keepStale(message: message)
        }
        return .showError(message)
    }
}

// MARK: - Git Status

enum GitFileStatus: String, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case unmerged = "U"
    case typeChanged = "T"
}

struct GitFileEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(isStaged)-\(status.rawValue)-\(path)" }
    let path: String
    let origPath: String?
    let status: GitFileStatus
    let isStaged: Bool
    let renameScore: Int?
}

// MARK: - Commit Graph

struct GitCommit: Identifiable, Equatable, Sendable {
    let id: String              // full SHA
    let shortHash: String       // first 7 chars
    let message: String         // first line
    let author: String
    let relativeDate: String
    let parentIDs: [String]
    let graphPrefix: String     // git log --graph prefix string
}

struct CommitFileEntry: Identifiable, Equatable, Sendable {
    var id: String { "\(commitHash)-\(status.rawValue)-\(path)" }
    let commitHash: String
    let path: String
    let origPath: String?
    let status: GitFileStatus
}

// MARK: - Repository Sections

enum GitRepoKind: Equatable, Sendable {
    case repository
    case worktree
    case submodule
}

/// One Changes-sidebar section. `rootPath` is a standardized absolute
/// work-tree root and doubles as the stable identity across refreshes.
struct GitRepoDescriptor: Identifiable, Equatable, Sendable {
    let rootPath: String
    let displayName: String
    let kind: GitRepoKind
    /// `nil` when the work tree has a detached HEAD.
    let branch: String?
    let headShortHash: String?
    let location: GitRepositoryLocation

    var id: String { rootPath }
}

/// Per-section Changes state. Every field is scoped to one repository so
/// pruning a vanished section is a single dictionary removal.
struct GitRepoChanges: Equatable, Sendable {
    var state: GitChangesState = .notLoaded
    var entries: [GitFileEntry] = []
    var commits: [GitCommit] = []
    var expandedCommitIDs: Set<String> = []
    /// Distinguishes "history fetched and empty" from "history not fetched".
    var isLogLoaded = false
    var hasMoreCommits = true
    var staleRefreshMessage: String?
}

// MARK: - Diff

enum DiffLineType: Sendable {
    case context
    case addition
    case deletion
    case hunkHeader
    case meta
}

struct DiffLine: Equatable, Sendable {
    let type: DiffLineType
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct FileDiff: Equatable, Sendable {
    let path: String
    let lines: [DiffLine]
    let isBinary: Bool
    let isTruncated: Bool
}

enum DiffLoadState: Sendable {
    case loading
    case success(FileDiff)
    case error(String)
}

enum DiffSource: Sendable, Equatable {
    case unstaged(path: String, workDir: String)
    case staged(path: String, workDir: String)
    case commit(hash: String, path: String, workDir: String)
    case untracked(path: String, workDir: String)
}
