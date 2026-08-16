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
    let repoID: String
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

    func start(
        at path: URL,
        handler: @Sendable @escaping ([FileSystemEvent]) async -> Void
    ) async throws {
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

    func makeSource() -> any FileSystemEventSource {
        let source = PoolEventSource()
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
            onRefresh: { repoID, kind in
                await recorder.record(RecordedRefresh(repoID: repoID, kind: kind))
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
            RecordedRefresh(repoID: repoAID, kind: .workingTree)
        ])

        await sourceB.emit([
            FileSystemEvent(path: URL(fileURLWithPath: repoBID + "/.git/index"), kind: .modified)
        ])
        #expect(try await refreshes(atLeast: 2, from: recorder) == [
            RecordedRefresh(repoID: repoAID, kind: .workingTree),
            RecordedRefresh(repoID: repoBID, kind: .repositoryMetadata),
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
}
