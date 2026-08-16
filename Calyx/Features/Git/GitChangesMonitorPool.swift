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

    private let monitorFactory: MonitorFactory
    private var monitors: [String: GitChangesMonitor] = [:]

    init(monitorFactory: @escaping MonitorFactory = { GitChangesMonitor(onRefresh: $0) }) {
        self.monitorFactory = monitorFactory
    }

    /// Drives the pool towards `repositories`, keyed by repo ID: repos that
    /// disappeared are stopped, new ones start a monitor, and surviving ones
    /// are re-watched (`GitChangesMonitor.watch` is idempotent). Refresh
    /// callbacks carry the repo ID that produced them.
    func sync(
        repositories: [String: GitRepositoryLocation],
        onRefresh: @escaping @MainActor @Sendable (String, GitChangesRefreshKind) async -> Void
    ) async {
        let retiredIDs = monitors.keys.filter { repositories[$0] == nil }
        let retired = retiredIDs.compactMap { monitors.removeValue(forKey: $0) }

        var watches: [(monitor: GitChangesMonitor, repository: GitRepositoryLocation)] = []
        for (repoID, repository) in repositories {
            let monitor = monitors[repoID] ?? monitorFactory { @MainActor kind in
                await onRefresh(repoID, kind)
            }
            monitors[repoID] = monitor
            watches.append((monitor, repository))
        }

        // The dictionary already holds the requested set, so a sync that
        // interleaves with this one sees the new state while the file-system
        // work below runs in parallel.
        await withTaskGroup(of: Void.self) { group in
            for monitor in retired {
                group.addTask { await monitor.stop() }
            }
            for watch in watches {
                group.addTask {
                    do {
                        try await watch.monitor.watch(repository: watch.repository)
                    } catch {
                        logger.error(
                            "Failed to watch \(watch.repository.workTree, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        }
    }

    func stopAll() async {
        let running = Array(monitors.values)
        monitors.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for monitor in running {
                group.addTask { await monitor.stop() }
            }
        }
    }
}
