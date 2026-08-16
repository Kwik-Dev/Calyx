// GitChangesMonitorPool.swift
// Calyx
//
// Keeps one GitChangesMonitor per displayed repository section.

import Foundation
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "GitChangesMonitorPool")

actor GitChangesMonitorPool {
    typealias MonitorFactory = @Sendable (
        @escaping @MainActor @Sendable (GitChangesRefreshKind) async -> Void
    ) -> GitChangesMonitor

    /// Delivers one file-system event to every section it belongs to.
    typealias RefreshHandler = @MainActor @Sendable (Set<String>, GitChangesRefreshKind) async -> Void

    private let monitorFactory: MonitorFactory
    private var monitors: [String: GitChangesMonitor] = [:]
    /// Each live section mapped to every section sharing its Git directory,
    /// which is who a write to that directory belongs to.
    private var families: [String: Set<String>] = [:]
    private var refreshHandler: RefreshHandler?
    /// Serializes the pool's own work. `sync` and `stopAll` both suspend
    /// while starting and stopping streams, and running two of them at once
    /// lets one install a monitor the other has already walked past.
    private var work: Task<Void, Never>?

    init(monitorFactory: @escaping MonitorFactory = { GitChangesMonitor(onRefresh: $0) }) {
        self.monitorFactory = monitorFactory
    }

    /// Drives the pool towards `repositories`, keyed by repo ID: repos that
    /// disappeared are stopped, new ones start a monitor, and surviving ones
    /// are re-watched (`GitChangesMonitor.watch` is idempotent).
    func sync(
        repositories: [String: GitRepositoryLocation],
        onRefresh: @escaping RefreshHandler
    ) async {
        await serialized { [weak self] in
            await self?.performSync(repositories: repositories, onRefresh: onRefresh)
        }
    }

    func stopAll() async {
        await serialized { [weak self] in
            await self?.performStopAll()
        }
    }

    private func serialized(_ body: @escaping @Sendable () async -> Void) async {
        let previous = work
        let task = Task {
            await previous?.value
            await body()
        }
        work = task
        await task.value
    }

    private func performSync(
        repositories: [String: GitRepositoryLocation],
        onRefresh: @escaping RefreshHandler
    ) async {
        refreshHandler = onRefresh
        families = Self.families(of: repositories)
        let targets = Self.watchTargets(for: repositories)

        let retiredIDs = monitors.keys.filter { repositories[$0] == nil }
        let retired = retiredIDs.compactMap { monitors.removeValue(forKey: $0) }

        var watches: [(monitor: GitChangesMonitor, target: GitChangesWatchTarget)] = []
        for (repoID, target) in targets {
            let monitor = monitors[repoID] ?? monitorFactory { [weak self] kind in
                await self?.deliver(from: repoID, kind: kind)
            }
            monitors[repoID] = monitor
            watches.append((monitor, target))
        }

        await withTaskGroup(of: Void.self) { group in
            for monitor in retired {
                group.addTask { await monitor.stop() }
            }
            for watch in watches {
                group.addTask {
                    do {
                        try await watch.monitor.watch(target: watch.target)
                    } catch {
                        logger.error(
                            "Failed to watch \(watch.target.repository.workTree, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    private func performStopAll() async {
        let running = Array(monitors.values)
        monitors.removeAll()
        families.removeAll()
        refreshHandler = nil
        await withTaskGroup(of: Void.self) { group in
            for monitor in running {
                group.addTask { await monitor.stop() }
            }
        }
    }

    private func deliver(from repoID: String, kind: GitChangesRefreshKind) async {
        // A stream can deliver an event it had already queued after its
        // section was retired, and that event has nothing left to refresh.
        guard let family = families[repoID], let refreshHandler else { return }

        let recipients: Set<String>
        switch kind {
        case .workingTree:
            recipients = [repoID]
        case .repositoryMetadata:
            // Index, ref, and object writes land in the Git directory the
            // whole family shares, so they belong to all of it.
            recipients = family
        }
        await refreshHandler(recipients, kind)
    }

    /// Every section mapped to the sections sharing its Git directory.
    static func families(of repositories: [String: GitRepositoryLocation]) -> [String: Set<String>] {
        var commonDirectoryByRepoID: [String: String] = [:]
        var repoIDsByCommonDirectory: [String: Set<String>] = [:]
        for (repoID, location) in repositories {
            let commonDirectory = GitRepositoryLocation.standardize(location.gitCommonDirectory)
            commonDirectoryByRepoID[repoID] = commonDirectory
            repoIDsByCommonDirectory[commonDirectory, default: []].insert(repoID)
        }
        return commonDirectoryByRepoID.compactMapValues { repoIDsByCommonDirectory[$0] }
    }

    /// What each section's monitor watches. Every section watches its own
    /// work tree, and a Git directory outside all of those work trees is
    /// assigned to exactly one section, so no directory is watched twice
    /// however many worktrees of one repository are displayed.
    static func watchTargets(
        for repositories: [String: GitRepositoryLocation]
    ) -> [String: GitChangesWatchTarget] {
        let standardized = repositories.mapValues(\.standardized)
        let workTrees = standardized.values.map(\.workTree)

        var claimed: Set<String> = []
        var targets: [String: GitChangesWatchTarget] = [:]
        // Sorted so the section that claims a shared directory is the same
        // one across syncs, which is what lets an unchanged section keep the
        // stream it already has.
        for (repoID, location) in standardized.sorted(by: { $0.key < $1.key }) {
            // The common directory contains the per-worktree one, so it is
            // considered first: claiming it covers both.
            var watchesExternal = false
            for directory in [location.gitCommonDirectory, location.gitDirectory] {
                guard !workTrees.contains(where: { isSameOrDescendant(directory, of: $0) }) else { continue }
                guard !claimed.contains(where: { isSameOrDescendant(directory, of: $0) }) else { continue }
                claimed.insert(directory)
                watchesExternal = true
            }
            targets[repoID] = GitChangesWatchTarget(
                repository: location,
                watchesExternalGitDirectories: watchesExternal
            )
        }
        return targets
    }

    private static func isSameOrDescendant(_ candidate: String, of root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
