// GitChangesMonitorTests.swift
// CalyxTests
//
// Tests for the event-driven refresh coordinator used by the Changes sidebar.

import Foundation
import XCTest
@testable import Calyx

private actor GitRefreshRecorder {
    private var values: [GitChangesRefreshKind] = []

    func record(_ value: GitChangesRefreshKind) {
        values.append(value)
    }

    func snapshot() -> [GitChangesRefreshKind] {
        values
    }
}

private actor RecordingGitEventSource: FileSystemEventSource {
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

    /// Simulates an event already queued by FSEvents before `stop()`.
    func emitLate(_ events: [FileSystemEvent], handler oldHandler: @Sendable ([FileSystemEvent]) async -> Void) async {
        await oldHandler(events)
    }

    func capturedHandler() -> (@Sendable ([FileSystemEvent]) async -> Void)? {
        handler
    }

    func watchedPath() -> URL? {
        path
    }

    func stopCount() -> Int {
        stops
    }
}

private final class RecordingGitEventSourceFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordingGitEventSource] = []

    func make() -> any FileSystemEventSource {
        let source = RecordingGitEventSource()
        lock.lock()
        storage.append(source)
        lock.unlock()
        return source
    }

    func sources() -> [RecordingGitEventSource] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@MainActor
final class GitChangesMonitorTests: XCTestCase {
    private let debounceDuration = Duration.milliseconds(20)

    func testStandardRepositoryUsesOneWatcherAndClassifiesWorkingTreeAndGitMetadata() async throws {
        let factory = RecordingGitEventSourceFactory()
        let recorder = GitRefreshRecorder()
        let monitor = GitChangesMonitor(
            debounceDuration: debounceDuration,
            eventSourceFactory: { factory.make() },
            onRefresh: { kind in await recorder.record(kind) }
        )
        let location = GitRepositoryLocation(
            workTree: "/repo",
            gitDirectory: "/repo/.git",
            gitCommonDirectory: "/repo/.git"
        )

        try await monitor.watch(repository: location)
        try await monitor.watch(repository: location)

        let sources = factory.sources()
        XCTAssertEqual(sources.count, 1)
        let watchedPath = await sources[0].watchedPath()?.standardizedFileURL.path
        XCTAssertEqual(watchedPath, "/repo")

        await sources[0].emit([
            FileSystemEvent(path: URL(fileURLWithPath: "/repo/Sources/App.swift"), kind: .modified)
        ])
        try await waitForRefreshCount(1, recorder: recorder)

        var refreshes = await recorder.snapshot()
        XCTAssertEqual(refreshes, [.workingTree])

        await sources[0].emit([
            FileSystemEvent(path: URL(fileURLWithPath: "/repo/.git/index"), kind: .modified)
        ])
        try await waitForRefreshCount(2, recorder: recorder)

        refreshes = await recorder.snapshot()
        XCTAssertEqual(refreshes, [.workingTree, .repositoryMetadata])

        await sources[0].emit([
            FileSystemEvent(path: URL(fileURLWithPath: "/repo/.git/index.lock"), kind: .created)
        ])
        try await Task.sleep(for: .milliseconds(40))
        refreshes = await recorder.snapshot()
        XCTAssertEqual(refreshes, [.workingTree, .repositoryMetadata])

        await monitor.stop()
    }

    func testLinkedWorktreeWatchesSharedGitDirectoryAndCoalescesToMetadataRefresh() async throws {
        let factory = RecordingGitEventSourceFactory()
        let recorder = GitRefreshRecorder()
        let monitor = GitChangesMonitor(
            debounceDuration: debounceDuration,
            eventSourceFactory: { factory.make() },
            onRefresh: { kind in await recorder.record(kind) }
        )
        let location = GitRepositoryLocation(
            workTree: "/worktrees/feature",
            gitDirectory: "/repo/.git/worktrees/feature",
            gitCommonDirectory: "/repo/.git"
        )

        try await monitor.watch(repository: location)

        let sources = factory.sources()
        XCTAssertEqual(sources.count, 2)
        let paths = await watchedPaths(for: sources)
        XCTAssertEqual(Set(paths), Set(["/worktrees/feature", "/repo/.git"]))

        let workingSourceValue = await source(watching: "/worktrees/feature", in: sources)
        let metadataSourceValue = await source(watching: "/repo/.git", in: sources)
        let workingSource = try XCTUnwrap(workingSourceValue)
        let metadataSource = try XCTUnwrap(metadataSourceValue)

        await workingSource.emit([
            FileSystemEvent(path: URL(fileURLWithPath: "/worktrees/feature/file.txt"), kind: .modified)
        ])
        await metadataSource.emit([
            FileSystemEvent(path: URL(fileURLWithPath: "/repo/.git/refs/heads/feature"), kind: .modified)
        ])

        try await waitForRefreshCount(1, recorder: recorder)
        try await Task.sleep(for: .milliseconds(40))
        let refreshes = await recorder.snapshot()
        XCTAssertEqual(refreshes, [.repositoryMetadata])

        await monitor.stop()
    }

    func testRetargetStopsOldWatchersAndIgnoresTheirQueuedEvents() async throws {
        let factory = RecordingGitEventSourceFactory()
        let recorder = GitRefreshRecorder()
        let monitor = GitChangesMonitor(
            debounceDuration: debounceDuration,
            eventSourceFactory: { factory.make() },
            onRefresh: { kind in await recorder.record(kind) }
        )
        let first = GitRepositoryLocation(
            workTree: "/repo-a",
            gitDirectory: "/repo-a/.git",
            gitCommonDirectory: "/repo-a/.git"
        )
        let second = GitRepositoryLocation(
            workTree: "/repo-b",
            gitDirectory: "/repo-b/.git",
            gitCommonDirectory: "/repo-b/.git"
        )

        try await monitor.watch(repository: first)
        let firstSource = try XCTUnwrap(factory.sources().first)
        let queuedHandlerValue = await firstSource.capturedHandler()
        let queuedHandler = try XCTUnwrap(queuedHandlerValue)

        try await monitor.watch(repository: second)

        let firstStopCount = await firstSource.stopCount()
        XCTAssertEqual(firstStopCount, 1)
        await firstSource.emitLate([
            FileSystemEvent(path: URL(fileURLWithPath: "/repo-a/late.txt"), kind: .modified)
        ], handler: queuedHandler)
        try await Task.sleep(for: .milliseconds(40))
        var refreshes = await recorder.snapshot()
        XCTAssertTrue(refreshes.isEmpty)

        let secondSource = try XCTUnwrap(factory.sources().last)
        await secondSource.emit([
            FileSystemEvent(path: URL(fileURLWithPath: "/repo-b/current.txt"), kind: .modified)
        ])
        try await waitForRefreshCount(1, recorder: recorder)

        refreshes = await recorder.snapshot()
        XCTAssertEqual(refreshes, [.workingTree])
        await monitor.stop()
    }

    private func watchedPaths(for sources: [RecordingGitEventSource]) async -> [String] {
        var paths: [String] = []
        for source in sources {
            if let path = await source.watchedPath()?.standardizedFileURL.path {
                paths.append(path)
            }
        }
        return paths
    }

    private func source(
        watching path: String,
        in sources: [RecordingGitEventSource]
    ) async -> RecordingGitEventSource? {
        for source in sources {
            if await source.watchedPath()?.standardizedFileURL.path == path {
                return source
            }
        }
        return nil
    }

    private func waitForRefreshCount(
        _ expectedCount: Int,
        recorder: GitRefreshRecorder
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await recorder.snapshot().count >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(expectedCount) refresh callback(s)")
    }
}
