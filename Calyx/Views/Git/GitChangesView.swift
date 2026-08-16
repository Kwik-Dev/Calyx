// GitChangesView.swift
// Calyx
//
// SwiftUI sidebar content for git changes display.

import SwiftUI

struct GitChangesView: View {
    let state: GitSidebarViewState

    var onWorkingFileSelected: ((String, GitFileEntry) -> Void)?
    var onCommitFileSelected: ((String, CommitFileEntry) -> Void)?
    var onRefresh: (() -> Void)?
    var onLoadMore: ((String) -> Void)?
    var onExpandCommit: ((String, String) -> Void)?
    var onToggleRepoSection: ((String) -> Void)?
    var onRetryRepoSection: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes")
                    .font(.headline)
                Spacer()
                if let staleRefreshMessage = state.staleRefreshMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(staleRefreshMessage)
                }
                if state.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: { onRefresh?() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Git.refreshButton)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            content
        }
        .frame(minWidth: 180)
        .accessibilityIdentifier(AccessibilityID.Git.changesContainer)
    }

    /// The content-replacing spinner is reachable only before any section
    /// exists. Once sections are on screen a refresh updates them in place.
    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .notLoaded, .loading:
            if state.sections.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                sectionList
            }
        case .notRepository:
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Not a git repository")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .error(let message):
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if state.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Retry") { onRefresh?() }
                        .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
        case .loaded:
            sectionList
        }
    }

    private var sectionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(state.sections) { section in
                    GitRepoSectionView(
                        data: section,
                        commitFiles: state.commitFiles,
                        onToggle: { onToggleRepoSection?(section.id) },
                        onRetry: { onRetryRepoSection?(section.id) },
                        onWorkingFileSelected: { entry in onWorkingFileSelected?(section.id, entry) },
                        onCommitFileSelected: { file in onCommitFileSelected?(section.id, file) },
                        onLoadMore: { onLoadMore?(section.id) },
                        onExpandCommit: { hash in onExpandCommit?(section.id, hash) }
                    )
                    .accessibilityIdentifier(AccessibilityID.Git.repoSection(section.id))
                }
            }
        }
    }
}

// MARK: - Repository Section

private struct GitRepoSectionView: View {
    let data: GitRepoSectionViewData
    let commitFiles: [String: [CommitFileEntry]]
    var onToggle: (() -> Void)?
    var onRetry: (() -> Void)?
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onLoadMore: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if data.isExpanded {
                sectionContent
            }
        }
    }

    private var header: some View {
        Button(action: { onToggle?() }) {
            HStack(spacing: 5) {
                Image(systemName: data.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)

                Image(systemName: kindIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(data.descriptor.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let reference {
                    Text(reference)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if let staleRefreshMessage = data.changes.staleRefreshMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(staleRefreshMessage)
                }

                if data.changes.changedFileCount > 0 {
                    Text("\(data.changes.changedFileCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(Color.secondary.opacity(0.18))
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if data.isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch data.changes.sectionContent {
        case .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        case .error(let message):
            failure(message: message)
        case .notRepository:
            failure(message: "Not a git repository")
        case .changes:
            GitRepoChangesBody(
                entries: data.changes.entries,
                commits: data.changes.commits,
                expandedCommitIDs: data.changes.expandedCommitIDs,
                commitFiles: commitFiles,
                onWorkingFileSelected: onWorkingFileSelected,
                onCommitFileSelected: onCommitFileSelected,
                onLoadMore: onLoadMore,
                onExpandCommit: onExpandCommit
            )
        }
    }

    /// What a section shows instead of content it cannot vouch for: why,
    /// and the way back.
    private func failure(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { onRetry?() }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var kindIcon: String {
        switch data.descriptor.kind {
        case .repository: "folder"
        case .worktree: "arrow.triangle.branch"
        case .submodule: "shippingbox"
        }
    }

    private var reference: String? {
        data.descriptor.branch ?? data.descriptor.headShortHash
    }
}

// MARK: - Repository Section Body

private struct GitRepoChangesBody: View {
    let entries: [GitFileEntry]
    let commits: [GitCommit]
    let expandedCommitIDs: Set<String>
    let commitFiles: [String: [CommitFileEntry]]
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onLoadMore: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?

    @State private var isStagedExpanded = true
    @State private var isUnstagedExpanded = true
    @State private var isUntrackedExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workingChangesSection
            commitGraphSection
        }
    }

    // MARK: - Working Changes

    @ViewBuilder
    private var workingChangesSection: some View {
        let staged = entries.filter { $0.isStaged }
        let unstaged = entries.filter { !$0.isStaged && $0.status != .untracked }
        let untracked = entries.filter { $0.status == .untracked }

        if !staged.isEmpty || !unstaged.isEmpty || !untracked.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !staged.isEmpty {
                    DisclosureGroup(isExpanded: $isStagedExpanded) {
                        ForEach(staged) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Staged")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(staged.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isStagedExpanded.toggle() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.stagedSection)
                }

                if !unstaged.isEmpty {
                    DisclosureGroup(isExpanded: $isUnstagedExpanded) {
                        ForEach(unstaged) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Unstaged")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(unstaged.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isUnstagedExpanded.toggle() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.unstagedSection)
                }

                if !untracked.isEmpty {
                    DisclosureGroup(isExpanded: $isUntrackedExpanded) {
                        ForEach(untracked) { entry in
                            GitFileRow(entry: entry)
                                .onTapGesture { onWorkingFileSelected?(entry) }
                        }
                    } label: {
                        HStack {
                            Text("Untracked")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(untracked.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isUntrackedExpanded.toggle() }
                    }
                    .accessibilityIdentifier(AccessibilityID.Git.untrackedSection)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Commit Graph

    @ViewBuilder
    private var commitGraphSection: some View {
        if !commits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Commits")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier(AccessibilityID.Git.commitsSection)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(commits) { commit in
                        CommitRowView(
                            commit: commit,
                            isExpanded: expandedCommitIDs.contains(commit.id),
                            files: commitFiles[commit.id] ?? [],
                            onTap: { onExpandCommit?(commit.id) },
                            onFileSelected: { file in onCommitFileSelected?(file) }
                        )
                        .accessibilityIdentifier(AccessibilityID.Git.commitRow(commit.shortHash))
                    }

                    Color.clear
                        .frame(height: 1)
                        .onAppear { onLoadMore?() }
                }
            }
        }
    }
}

// MARK: - Git File Row

private struct GitFileRow: View {
    let entry: GitFileEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.status.rawValue)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text(fileName)
                .font(.caption)
                .lineLimit(1)

            if let dir = directory {
                Text(dir)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.Git.fileEntry(entry.path))
    }

    private var fileName: String {
        (entry.path as NSString).lastPathComponent
    }

    private var directory: String? {
        let dir = (entry.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }

    private var statusColor: Color {
        switch entry.status {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .copied: .blue
        case .untracked: .gray
        case .unmerged: .purple
        case .typeChanged: .yellow
        }
    }
}

// MARK: - Commit Row

private struct CommitRowView: View {
    let commit: GitCommit
    let isExpanded: Bool
    let files: [CommitFileEntry]
    var onTap: (() -> Void)?
    var onFileSelected: ((CommitFileEntry) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { onTap?() }) {
                HStack(alignment: .top, spacing: 4) {
                    GraphPrefixView(prefix: commit.graphPrefix)
                        .frame(width: graphWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(commit.shortHash)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(commit.message)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Text(commit.author)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(commit.relativeDate)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if isExpanded {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(files) { file in
                    CommitFileRow(file: file)
                        .onTapGesture { onFileSelected?(file) }
                }
            }
        }
    }

    private var graphWidth: CGFloat {
        max(CGFloat(commit.graphPrefix.count) * 8, 16)
    }
}

private struct GraphPrefixView: View {
    let prefix: String

    var body: some View {
        Text(AttributedString(CommitGraphRenderer.attributedString(from: CommitGraphRenderer.parse(prefix))))
    }
}

private struct CommitFileRow: View {
    let file: CommitFileEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text((file.path as NSString).lastPathComponent)
                .font(.caption2)
                .lineLimit(1)

            Spacer()
        }
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.Git.fileEntry(file.path))
    }

    private var statusColor: Color {
        switch file.status {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .untracked: .gray
        case .unmerged: .purple
        case .typeChanged: .yellow
        }
    }
}
