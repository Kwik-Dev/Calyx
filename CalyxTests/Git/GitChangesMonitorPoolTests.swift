// GitChangesMonitorPoolTests.swift
// CalyxTests
//
// One file-system monitor per displayed repository: which paths are
// watched, which repository a refresh callback belongs to, and what a
// changed or emptied section set does to the running monitors.

import Foundation
import Testing
@testable import Calyx

private struct RecordedRefresh: Equatable {
    let repoIDs: Set<String>
    let kind: GitChangesRefreshKind
}

private actor RefreshRecorder {
    private var values: [RecordedRefresh] = []

    func record(_ value: RecordedRefresh) {
        values.append(value)
    }

    func snapshot() -> [RecordedRefresh] {
        values
    }
}

private actor PoolEventSource: FileSystemEventSource {
    private var handler: (@Sendable ([FileSystemEvent]) async -> Void)?
    private var path: URL?
    private var stops = 0
    private let startDelay: Duration

    init(startDelay: Duration = .zero) {
        self.startDelay = startDelay
    }

    func start(
        at path: URL,
        handler: @Sendable @escaping ([FileSystemEvent]) async -> Void
    ) async throws {
        if startDelay > .zero {
            try await Task.sleep(for: startDelay)
        }
        self.path = path
        self.handler = handler
    }

    func stop() async {
        stops += 1
        handler = nil
    }

    func emit(_ events: [FileSystemEvent]) async {
        guard let handler else { return }
        await handler(events)
    }

    func watchedPath() -> URL? {
        path
    }

    func stopCount() -> Int {
        stops
    }
}

private final class PoolEventSourceFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PoolEventSource] = []
    private var monitors = 0
    private let startDelay: Duration

    init(startDelay: Duration = .zero) {
        self.startDelay = startDelay
    }

    func makeSource() -> any FileSystemEventSource {
        let source = PoolEventSource(startDelay: startDelay)
        lock.lock()
        storage.append(source)
        lock.unlock()
        return source
    }

    func makeMonitor(
        onRefresh: @escaping @MainActor @Sendable (GitChangesRefreshKind) async -> Void
    ) -> GitChangesMonitor {
        lock.lock()
        monitors += 1
        lock.unlock()
        return GitChangesMonitor(
            debounceDuration: .milliseconds(20),
            eventSourceFactory: { self.makeSource() },
            onRefresh: onRefresh
        )
    }

    func sources() -> [PoolEventSource] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func monitorCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return monitors
    }
}

private let repoAID = "/repos/alpha"
private let repoBID = "/repos/beta"

private let repoA = GitRepositoryLocation(
    workTree: repoAID,
    gitDirectory: repoAID + "/.git",
    gitCommonDirectory: repoAID + "/.git"
)
private let repoB = GitRepositoryLocation(
    workTree: repoBID,
    gitDirectory: repoBID + "/.git",
    gitCommonDirectory: repoBID + "/.git"
)

private func watchedPaths(_ sources: [PoolEventSource]) async -> Set<String> {
    var paths: Set<String> = []
    for source in sources {
        if let path = await source.watchedPath()?.standardizedFileURL.path {
            paths.insert(path)
        }
    }
    return paths
}

private func source(
    watching path: String,
    in sources: [PoolEventSource]
) async -> PoolEventSource? {
    for source in sources {
        if await source.watchedPath()?.standardizedFileURL.path == path {
            return source
        }
    }
    return nil
}

private func refreshes(
    atLeast count: Int,
    from recorder: RefreshRecorder
) async throws -> [RecordedRefresh] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        let snapshot = await recorder.snapshot()
        if snapshot.count >= count {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    return await recorder.snapshot()
}

// A repository whose linked worktrees share its Git directory, which is
// the layout that decides how many streams the pool may open.
private let familyMainID = "/repos/family/main"
private let familyWorktreeOneID = "/repos/family/wt-1"
private let familyWorktreeTwoID = "/repos/family/wt-2"
private let familyCommonDirectory = familyMainID + "/.git"

private let familyMain = GitRepositoryLocation(
    workTree: familyMainID,
    gitDirectory: familyCommonDirectory,
    gitCommonDirectory: familyCommonDirectory
)
private let familyWorktreeOne = GitRepositoryLocation(
    workTree: familyWorktreeOneID,
    gitDirectory: familyCommonDirectory + "/worktrees/wt-1",
    gitCommonDirectory: familyCommonDirectory
)
private let familyWorktreeTwo = GitRepositoryLocation(
    workTree: familyWorktreeTwoID,
    gitDirectory: familyCommonDirectory + "/worktrees/wt-2",
    gitCommonDirectory: familyCommonDirectory
)
private let family = [
    familyMainID: familyMain,
    familyWorktreeOneID: familyWorktreeOne,
    familyWorktreeTwoID: familyWorktreeTwo,
]

// A bare repository has no work tree containing the shared Git directory,
// so one of its worktrees has to watch that directory.
private let bareCommonDirectory = "/repos/bare/shared.git"
private let bareWorktreeOneID = "/repos/bare/w-1"
private let bareWorktreeTwoID = "/repos/bare/w-2"
private let bareFamily = [
    bareWorktreeOneID: GitRepositoryLocation(
        workTree: bareWorktreeOneID,
        gitDirectory: bareCommonDirectory + "/worktrees/w-1",
        gitCommonDirectory: bareCommonDirectory
    ),
    bareWorktreeTwoID: GitRepositoryLocation(
        workTree: bareWorktreeTwoID,
        gitDirectory: bareCommonDirectory + "/worktrees/w-2",
        gitCommonDirectory: bareCommonDirectory
    ),
]

struct GitChangesMonitorPoolTests {
    @Test func test_sync_watchesEveryRequestedRepository() async throws {
        let factory = PoolEventSourceFactory()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(
            repositories: [repoAID: repoA, repoBID: repoB],
            onRefresh: { _, _ in }
        )

        let sources = factory.sources()
        try #require(sources.count == 2)
        #expect(await watchedPaths(sources) == [repoAID, repoBID])
    }

    @Test func test_sync_labelsRefreshesWithTheRepoIDThatProducedThem() async throws {
        let factory = PoolEventSourceFactory()
        let recorder = RefreshRecorder()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(
            repositories: [repoAID: repoA, repoBID: repoB],
            onRefresh: { repoIDs, kind in
                await recorder.record(RecordedRefresh(repoIDs: repoIDs, kind: kind))
            }
        )

        let sources = factory.sources()
        try #require(sources.count == 2)
        let sourceA = try #require(await source(watching: repoAID, in: sources))
        let sourceB = try #require(await source(watching: repoBID, in: sources))

        await sourceA.emit([
            FileSystemEvent(path: URL(fileURLWithPath: repoAID + "/Sources/App.swift"), kind: .modified)
        ])
        #expect(try await refreshes(atLeast: 1, from: recorder) == [
            RecordedRefresh(repoIDs: [repoAID], kind: .workingTree)
        ])

        await sourceB.emit([
            FileSystemEvent(path: URL(fileURLWithPath: repoBID + "/.git/index"), kind: .modified)
        ])
        #expect(try await refreshes(atLeast: 2, from: recorder) == [
            RecordedRefresh(repoIDs: [repoAID], kind: .workingTree),
            RecordedRefresh(repoIDs: [repoBID], kind: .repositoryMetadata),
        ])
    }

    @Test func test_sync_stopsOnlyTheMonitorsOfRemovedRepositories() async throws {
        let factory = PoolEventSourceFactory()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(
            repositories: [repoAID: repoA, repoBID: repoB],
            onRefresh: { _, _ in }
        )
        let sources = factory.sources()
        try #require(sources.count == 2)
        let sourceA = try #require(await source(watching: repoAID, in: sources))
        let sourceB = try #require(await source(watching: repoBID, in: sources))

        await pool.sync(repositories: [repoAID: repoA], onRefresh: { _, _ in })

        #expect(await sourceB.stopCount() == 1)
        #expect(await sourceA.stopCount() == 0)
        #expect(factory.sources().count == 2)
    }

    @Test func test_stopAll_stopsEveryMonitor() async throws {
        let factory = PoolEventSourceFactory()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(
            repositories: [repoAID: repoA, repoBID: repoB],
            onRefresh: { _, _ in }
        )
        let sources = factory.sources()
        try #require(sources.count == 2)

        await pool.stopAll()

        for source in sources {
            #expect(await source.stopCount() == 1)
        }
    }

    @Test func test_sync_reusesTheMonitorOfAnUnchangedRepository() async throws {
        let factory = PoolEventSourceFactory()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(
            repositories: [repoAID: repoA, repoBID: repoB],
            onRefresh: { _, _ in }
        )
        try #require(factory.sources().count == 2)

        await pool.sync(
            repositories: [repoAID: repoA, repoBID: repoB],
            onRefresh: { _, _ in }
        )

        #expect(factory.sources().count == 2)
        #expect(factory.monitorCount() == 2)
        for source in factory.sources() {
            #expect(await source.stopCount() == 0)
        }
    }

    // MARK: - Shared Git directories

    @Test func test_sync_opensOneStreamPerWatchedDirectory() async throws {
        let factory = PoolEventSourceFactory()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(repositories: family, onRefresh: { _, _ in })

        let sources = factory.sources()
        #expect(sources.count == 3)
        // The shared Git directory sits inside the main work tree, so
        // watching that tree is what watches it, once.
        #expect(await watchedPaths(sources) == [
            familyMainID, familyWorktreeOneID, familyWorktreeTwoID,
        ])
    }

    @Test func test_sync_opensOneStreamOnABareRepositorysSharedGitDirectory() async throws {
        let factory = PoolEventSourceFactory()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(repositories: bareFamily, onRefresh: { _, _ in })

        let sources = factory.sources()
        #expect(sources.count == 3)
        #expect(await watchedPaths(sources) == [
            bareCommonDirectory, bareWorktreeOneID, bareWorktreeTwoID,
        ])
    }

    @Test func test_sync_deliversASharedGitDirectoryWriteToEverySectionOfTheFamily() async throws {
        let factory = PoolEventSourceFactory()
        let recorder = RefreshRecorder()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(
            repositories: family,
            onRefresh: { repoIDs, kind in
                await recorder.record(RecordedRefresh(repoIDs: repoIDs, kind: kind))
            }
        )

        let sources = factory.sources()
        try #require(sources.count == 3)
        let sharedSource = try #require(await source(watching: familyMainID, in: sources))
        let worktreeSource = try #require(await source(watching: familyWorktreeOneID, in: sources))

        // A commit made in one worktree writes refs shared by all of them.
        await sharedSource.emit([
            FileSystemEvent(
                path: URL(fileURLWithPath: familyCommonDirectory + "/refs/heads/feature"),
                kind: .modified
            )
        ])
        #expect(try await refreshes(atLeast: 1, from: recorder) == [
            RecordedRefresh(
                repoIDs: [familyMainID, familyWorktreeOneID, familyWorktreeTwoID],
                kind: .repositoryMetadata
            )
        ])

        // An edit belongs to the one work tree it happened in.
        await worktreeSource.emit([
            FileSystemEvent(
                path: URL(fileURLWithPath: familyWorktreeOneID + "/Sources/App.swift"),
                kind: .modified
            )
        ])
        #expect(try await refreshes(atLeast: 2, from: recorder).last == RecordedRefresh(
            repoIDs: [familyWorktreeOneID], kind: .workingTree
        ))
    }

    @Test func test_sync_deliversABareRepositorysMetadataToEveryWorktree() async throws {
        let factory = PoolEventSourceFactory()
        let recorder = RefreshRecorder()
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        await pool.sync(
            repositories: bareFamily,
            onRefresh: { repoIDs, kind in
                await recorder.record(RecordedRefresh(repoIDs: repoIDs, kind: kind))
            }
        )

        let sources = factory.sources()
        try #require(sources.count == 3)
        let sharedSource = try #require(await source(watching: bareCommonDirectory, in: sources))

        await sharedSource.emit([
            FileSystemEvent(
                path: URL(fileURLWithPath: bareCommonDirectory + "/index"),
                kind: .modified
            )
        ])

        #expect(try await refreshes(atLeast: 1, from: recorder) == [
            RecordedRefresh(
                repoIDs: [bareWorktreeOneID, bareWorktreeTwoID],
                kind: .repositoryMetadata
            )
        ])
    }

    @Test func test_watchTargets_assignAnOutsideGitDirectoryToExactlyOneSection() {
        let inFamily = GitChangesMonitorPool.watchTargets(for: family)
        // Every one of these Git directories is inside the main work tree.
        #expect(inFamily.values.allSatisfy { !$0.watchesExternalGitDirectories })

        let inBareFamily = GitChangesMonitorPool.watchTargets(for: bareFamily)
        #expect(inBareFamily.values.filter(\.watchesExternalGitDirectories).count == 1)
    }

    // MARK: - Overlapping calls

    @Test func test_sync_leavesNoStreamRunningThatThePoolNoLongerHolds() async throws {
        // A stream that takes time to start is what lets a second sync
        // arrive while the first one is still installing monitors.
        let factory = PoolEventSourceFactory(startDelay: .milliseconds(50))
        let pool = GitChangesMonitorPool(monitorFactory: { factory.makeMonitor(onRefresh: $0) })

        let first = Task { await pool.sync(repositories: [repoAID: repoA], onRefresh: { _, _ in }) }
        try await Task.sleep(for: .milliseconds(10))
        await pool.sync(repositories: [:], onRefresh: { _, _ in })
        await first.value

        let sources = factory.sources()
        try #require(!sources.isEmpty)
        for source in sources {
            #expect(await source.stopCount() >= 1)
        }
    }
}
