// GitChangesMonitor.swift
// Calyx
//
// Event-driven refresh coordination for the Changes sidebar.

import Foundation

struct GitRepositoryLocation: Equatable, Sendable {
    let workTree: String
    let gitDirectory: String
    let gitCommonDirectory: String

    var standardized: GitRepositoryLocation {
        GitRepositoryLocation(
            workTree: Self.standardize(workTree),
            gitDirectory: Self.standardize(gitDirectory),
            gitCommonDirectory: Self.standardize(gitCommonDirectory)
        )
    }

    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum GitChangesRefreshKind: Int, Equatable, Sendable {
    case workingTree
    case repositoryMetadata

    func merged(with other: GitChangesRefreshKind) -> GitChangesRefreshKind {
        rawValue >= other.rawValue ? self : other
    }
}

/// Watches the active repository and coalesces FSEvents batches into one
/// Changes refresh. A normal repository needs only its work-tree watcher
/// because `.git` is inside that tree. A linked worktree also watches the
/// shared Git directory so index, ref, checkout, and commit operations are
/// observed even though its `.git` entry is only a pointer file.
actor GitChangesMonitor {
    private struct WatchRoot: Sendable {
        let url: URL
        let defaultKind: GitChangesRefreshKind
    }

    private let debounceDuration: Duration
    private let eventSourceFactory: @Sendable () -> any FileSystemEventSource
    private let onRefresh: @MainActor @Sendable (GitChangesRefreshKind) async -> Void

    private var repository: GitRepositoryLocation?
    private var eventSources: [any FileSystemEventSource] = []
    private var debounceTask: Task<Void, Never>?
    private var pendingKind: GitChangesRefreshKind?
    private var generation: UInt64 = 0

    init(
        debounceDuration: Duration = .seconds(1),
        eventSourceFactory: @Sendable @escaping () -> any FileSystemEventSource
            = { FSEventsEventSource() },
        onRefresh: @MainActor @Sendable @escaping (GitChangesRefreshKind) async -> Void
    ) {
        self.debounceDuration = debounceDuration
        self.eventSourceFactory = eventSourceFactory
        self.onRefresh = onRefresh
    }

    func watch(repository requestedRepository: GitRepositoryLocation) async throws {
        let requestedRepository = requestedRepository.standardized
        if repository == requestedRepository, !eventSources.isEmpty {
            return
        }

        generation &+= 1
        let requestedGeneration = generation
        debounceTask?.cancel()
        debounceTask = nil
        pendingKind = nil

        let previousSources = eventSources
        eventSources = []
        repository = nil
        for source in previousSources {
            await source.stop()
        }
        guard generation == requestedGeneration else { return }

        var startedSources: [any FileSystemEventSource] = []
        do {
            for root in Self.watchRoots(for: requestedRepository) {
                guard generation == requestedGeneration else { break }
                let source = eventSourceFactory()
                try await source.start(at: root.url) { [weak self] events in
                    await self?.receive(
                        events,
                        from: root,
                        repository: requestedRepository,
                        generation: requestedGeneration
                    )
                }
                startedSources.append(source)
            }
        } catch {
            for source in startedSources {
                await source.stop()
            }
            throw error
        }

        guard generation == requestedGeneration else {
            for source in startedSources {
                await source.stop()
            }
            return
        }
        eventSources = startedSources
        repository = requestedRepository
    }

    func stop() async {
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingKind = nil
        repository = nil

        let sources = eventSources
        eventSources = []
        for source in sources {
            await source.stop()
        }
    }

    private func receive(
        _ events: [FileSystemEvent],
        from root: WatchRoot,
        repository: GitRepositoryLocation,
        generation eventGeneration: UInt64
    ) {
        guard generation == eventGeneration else { return }

        var batchKind: GitChangesRefreshKind?
        for event in events where !Self.shouldIgnore(event.path) {
            let kind: GitChangesRefreshKind
            if root.defaultKind == .repositoryMetadata
                || Self.isRepositoryMetadata(event.path, repository: repository) {
                kind = .repositoryMetadata
            } else {
                kind = .workingTree
            }
            batchKind = batchKind?.merged(with: kind) ?? kind
        }
        guard let batchKind else { return }

        pendingKind = pendingKind?.merged(with: batchKind) ?? batchKind
        debounceTask?.cancel()
        let delay = debounceDuration
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.deliver(generation: eventGeneration)
        }
    }

    private func deliver(generation eventGeneration: UInt64) async {
        guard generation == eventGeneration, let kind = pendingKind else { return }
        pendingKind = nil
        debounceTask = nil
        await onRefresh(kind)
    }

    private static func watchRoots(for repository: GitRepositoryLocation) -> [WatchRoot] {
        let workTreeURL = URL(fileURLWithPath: repository.workTree).standardizedFileURL
        var roots = [WatchRoot(url: workTreeURL, defaultKind: .workingTree)]

        let metadataCandidates = Set([
            repository.gitDirectory,
            repository.gitCommonDirectory,
        ])
        .map { URL(fileURLWithPath: $0).standardizedFileURL }
        .sorted { $0.pathComponents.count < $1.pathComponents.count }

        for candidate in metadataCandidates {
            if isSameOrDescendant(candidate, of: workTreeURL) {
                continue
            }
            if roots.contains(where: {
                $0.defaultKind == .repositoryMetadata
                    && isSameOrDescendant(candidate, of: $0.url)
            }) {
                continue
            }
            roots.append(WatchRoot(url: candidate, defaultKind: .repositoryMetadata))
        }
        return roots
    }

    private static func isRepositoryMetadata(
        _ eventURL: URL,
        repository: GitRepositoryLocation
    ) -> Bool {
        let eventURL = eventURL.standardizedFileURL
        let gitDirectory = URL(fileURLWithPath: repository.gitDirectory).standardizedFileURL
        let gitCommonDirectory = URL(fileURLWithPath: repository.gitCommonDirectory).standardizedFileURL
        if isSameOrDescendant(eventURL, of: gitDirectory)
            || isSameOrDescendant(eventURL, of: gitCommonDirectory) {
            return true
        }

        let workTree = URL(fileURLWithPath: repository.workTree).standardizedFileURL
        let relativePath = eventURL.path.replacingOccurrences(
            of: workTree.path + "/",
            with: "",
            options: [.anchored]
        )
        return relativePath == ".git" || relativePath.hasPrefix(".git/")
    }

    private static func shouldIgnore(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "index.lock" || name.hasPrefix(".watchman-cookie-")
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let descendantPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(descendantPrefix)
    }
}
