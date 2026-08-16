// GitSectionRefreshScheduler.swift
// Calyx
//
// Serializes the git fetches of one Changes sidebar section.

import Foundation

/// Runs one fetch at a time per section. A request that arrives while that
/// section is fetching is merged into the next run rather than replacing the
/// one in flight, so a working-tree event asking only for `git status` can
/// never discard the commit history another request had already started
/// fetching, and the two writers of a section's commit list (a refresh and
/// a load-more) can never overlap.
@MainActor
final class GitSectionRefreshScheduler {
    typealias Fetch = @MainActor (String, GitSectionFetchScope) async -> Void

    private let fetch: Fetch
    private var runs: [String: Task<Void, Never>] = [:]
    private var pending: [String: GitSectionFetchScope] = [:]

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// Requests `scope` for `repoID` and returns the run that will cover it.
    @discardableResult
    func schedule(repoID: String, scope: GitSectionFetchScope) -> Task<Void, Never>? {
        guard !scope.isEmpty else { return runs[repoID] }

        pending[repoID] = pending[repoID]?.merged(with: scope) ?? scope
        if let running = runs[repoID] {
            return running
        }

        let task = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                // Reading the queue and clearing the slot happen without an
                // await between them, so a request made from the main actor
                // either lands in this loop or starts a new one.
                guard let next = self.pending.removeValue(forKey: repoID) else {
                    self.runs.removeValue(forKey: repoID)
                    return
                }
                await self.fetch(repoID, next)
            }
        }
        runs[repoID] = task
        return task
    }

    /// Cancels every section's work and forgets what was queued, for when
    /// the sidebar showing it is no longer on screen.
    func cancelAll() {
        pending.removeAll()
        for task in runs.values {
            task.cancel()
        }
        runs.removeAll()
    }
}
