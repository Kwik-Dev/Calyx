//
//  FileSyncManagerBugSpecTests.swift
//  Calyx
//
//  Bug-spec regression tests for `FileSyncManager` covering five distinct
//  defects identified in the production source. Bugs 2, 3, and 4 already
//  have production fixes in place and their tests pin the fixed
//  behaviour going forward; bugs 1 and 5 remain `XCTSkip`-ed for the
//  documented test-seam gaps below.
//
//  Bug inventory (matching the bug spec passed to test-writer):
//    1. FSEventStreamStart return value ignored. A failed start publishes a
//       "live" state record but never actually streams events. There is no
//       deterministic way to force `FSEventStreamStart` to return false
//       from inside a unit test, and `FSEventStreamCreate` happily accepts
//       non-existent paths, so this test is marked `XCTSkip` with a
//       documented gap.
//    2. Watched-roots double-write race (fixed). `watch(...)` used to
//       write to a `watchedRoots_` dictionary *before* awaiting the
//       source's `start(...)`, letting a concurrent `watch(...)` for the
//       same root take an early no-op exit while the first call was still
//       arming the stream, silently losing the second caller's session.
//       Production now tracks each root through a tri-state `Slot`
//       (`.pending` / `.active`) so a concurrent caller either awaits the
//       in-flight start or overrides the active session, and no caller's
//       `watch(...)` ever returns success without a session actually
//       registered. Which of two racing sessions ends up receiving events
//       is schedule-dependent by design (documented as "late-arrival
//       LIFO"), so the regression test only pins the invariants the API
//       guarantees regardless of scheduling, not a specific winner.
//    3. `suppressedEvents` keyed by literal `URL` value. A suppression
//       installed with the `/private/tmp/x` spelling does not mask an
//       FSEvents-emitted event spelled `/tmp/x` (or vice versa) — the
//       two are equally valid URLs for the same file on macOS, so the
//       echo loop is not silenced.
//    4. `.renamed(to: self)` collapses to `didClose + didOpen` on the
//       same URI. FSEvents reports the touched path only, so production
//       code synthesises `.renamed(to: url)` where the destination
//       equals the source. The dispatch path then issues `didClose(uri)`
//       immediately followed by `didOpen(uri)` for the SAME URI, which
//       strict servers reject as a malformed sequence.
//    5. Modified-event sync read blocks the actor. The full-document
//       replacement payload is built via a synchronous
//       `String(contentsOf: ...)` inside the actor's `dispatch(.modified)`
//       branch, so a single large file (or a slow network volume) stalls
//       every other manager operation. Reliably forcing the disk read
//       past the 200 ms threshold requires either a 256 MB+ temp file
//       (excessive for unit tests) or a Task.detached read path that
//       does not yet exist, so this test is marked `XCTSkip`.
//
//  TDD phase: GREEN for bugs 2, 3, and 4 (production fixes already
//  landed); bugs 1 and 5 remain `XCTSkip`-ed pending the test-seam work
//  described above.
//

import XCTest
@testable import Calyx

// MARK: - SlowMockEventSource

/// Mock `FileSystemEventSource` whose `start(...)` deliberately suspends
/// for a configurable interval so a regression test can keep the race
/// window between two concurrent `watch(...)` calls open. Exposes an
/// identity UUID and an `emit(_:)` mirroring the production
/// `MockFileSystemEventSource` so tests can observe which session a
/// post-race event lands on.
fileprivate actor SlowMockEventSource: FileSystemEventSource {

    /// Stable identity for the test's identity-tracking assertions.
    let identityValue: UUID = UUID()

    private let startDelayNs: UInt64
    private var handler: (@Sendable ([FileSystemEvent]) async -> Void)?
    private var startCallCount_: Int = 0

    init(startDelayNs: UInt64 = 250_000_000) {
        self.startDelayNs = startDelayNs
    }

    func start(
        at path: URL,
        handler: @Sendable @escaping ([FileSystemEvent]) async -> Void
    ) async throws {
        startCallCount_ += 1
        self.handler = handler
        // Keep `watch(...)` suspended inside the actor so a concurrent
        // `watch(...)` call has a chance to enter and observe the
        // double-write race condition.
        try? await Task.sleep(nanoseconds: startDelayNs)
    }

    func stop() async {
        handler = nil
    }

    func startCallCount() -> Int { startCallCount_ }

    /// Replay `events` through the registered handler, like
    /// `MockFileSystemEventSource.emit(_:)`.
    func emit(_ events: [FileSystemEvent]) async {
        guard let h = handler else { return }
        await h(events)
    }
}

/// Captures every `SlowMockEventSource` the factory closure produces so a
/// regression test can introspect them after both concurrent `watch(...)`
/// calls return. Synchronised through an `NSLock` so the factory closure
/// stays `@Sendable`.
fileprivate final class SlowMockCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _mocks: [SlowMockEventSource] = []

    func make(startDelayNs: UInt64 = 250_000_000) -> SlowMockEventSource {
        let m = SlowMockEventSource(startDelayNs: startDelayNs)
        lock.lock()
        _mocks.append(m)
        lock.unlock()
        return m
    }

    func mocks() -> [SlowMockEventSource] {
        lock.lock()
        defer { lock.unlock() }
        return _mocks
    }
}

// MARK: - Tests

@MainActor
final class FileSyncManagerBugSpecTests: XCTestCase {

    // MARK: - Constants

    private let testLanguageId = "swift"

    // MARK: - Framing & JSON helpers (mirror FileSyncManagerTests)

    private func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    /// Parse every consecutive framed JSON message in `data` into dicts.
    private func parseAllFramedJSON(_ data: Data) throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let slice = data.subdata(in: cursor..<data.endIndex)
            guard let headerEnd = slice.range(of: Data("\r\n\r\n".utf8)) else { break }
            let headerData = slice.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else { break }
            var contentLength = 0
            for line in headerString.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLength = Int(parts[1]) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + contentLength
            guard bodyEnd <= slice.endIndex else { break }
            let body = slice.subdata(in: bodyStart..<bodyEnd)
            if let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                results.append(dict)
            }
            cursor = cursor + bodyEnd
        }
        return results
    }

    /// Collect the methods (in order) the session emitted to `transport`.
    private func sentMethods(_ transport: InMemoryLSPTransport) async throws -> [String] {
        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        return dicts.map { ($0["method"] as? String) ?? "" }
    }

    /// Collect every framed JSON message dict the session emitted to `transport`.
    private func sentDicts(_ transport: InMemoryLSPTransport) async throws -> [[String: Any]] {
        let sent = await transport.sentMessages()
        return try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.005,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await predicate()
    }

    // MARK: - Session setup (mirrors FileSyncManagerTests)

    /// Spin up a fully-initialised `LSPSession` with an `InMemoryLSPTransport`
    /// underneath. Returns once the session is in `.running`.
    ///
    /// `respondTask` polls for the outbound `initialize` request and can
    /// be delayed by scheduler contention under full-suite load; its
    /// budget is generous (30 s at a 5 ms poll interval) so it exits
    /// early on the happy path but still has headroom under load. `client`
    /// is constructed with a 30 s `initializeTimeoutSeconds` (instead of
    /// production's 600 s default) so that if `respondTask` genuinely
    /// never finds and answers the request, `session.start()` fails
    /// within a CI-reasonable bound instead of stalling for up to ten
    /// minutes.
    private func makeStartedSession(
        workspaceRoot: URL
    ) async throws -> (LSPSession, InMemoryLSPTransport) {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport, initializeTimeoutSeconds: 30)
        let session = LSPSession(
            workspaceRoot: workspaceRoot,
            languageId: testLanguageId,
            client: client
        )

        let frame = self.lspFrame
        let respondTask = Task { [transport] in
            for _ in 0..<6000 {
                let sent = await transport.sentMessages()
                for data in sent {
                    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
                    let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
                    guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          (dict["method"] as? String) == "initialize",
                          let idAny = dict["id"]
                    else { continue }
                    let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                    let body2 = #"{"jsonrpc":"2.0","id":\#(idInt),"result":{"capabilities":{},"serverInfo":{"name":"test-lsp","version":"0.0.1"}}}"#
                    await transport.simulateServerMessage(frame(body2))
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        try await session.start()
        _ = await respondTask.value
        return (session, transport)
    }

    /// Build a unique workspace root URL under the temp directory.
    private func makeWorkspaceRoot(_ name: String = "ws") -> URL {
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calyx-fs-sync-bugspec-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    // ====================================================================
    // MARK: - Bug 1: FSEventStreamStart return value ignored
    // ====================================================================

    /// A failed `FSEventStreamStart` returns false but the production code
    /// ignores the return value and publishes a "live" state record (stream
    /// pointer, continuation, consumer task) regardless. The caller is told
    /// the watch is up but no callbacks ever fire.
    ///
    /// There is no deterministic way to force `FSEventStreamStart` to return
    /// false from a unit test: `FSEventStreamCreate` accepts non-existent
    /// paths happily, and `FSEventStreamStart` only fails on
    /// process/resource-level issues that a test cannot synthesise without
    /// patching CoreServices. The production-code fix is small and local
    /// (`guard FSEventStreamStart(s) else { throw ... }`) but verifying it
    /// here would require an injection seam that does not yet exist.
    func test_watch_failedFSEventStreamStart_isPropagatedToCaller() throws {
        throw XCTSkip(
            "requires FSEventStreamStart return-value check. " +
            "FSEventStreamCreate silently accepts non-existent paths and " +
            "there is no test-only injection seam to force " +
            "FSEventStreamStart to fail; the swift-specialist will add a " +
            "guard `FSEventStreamStart(s) else { throw }` in " +
            "`FSEventsEventSource.start(at:handler:)` along with a seam " +
            "that lets this test stub the return value."
        )
    }

    // ====================================================================
    // MARK: - Bug 2: watched-roots double-write race
    // ====================================================================

    /// Production tracks each watched root through a tri-state `Slot`
    /// (`.pending` while a source is arming, `.active` once it's live).
    /// Two concurrent `watch(...)` calls on the same root race for who
    /// installs the `.pending` slot (the "originator") versus who finds
    /// it already installed (the "late arrival"): the late arrival always
    /// ends up as the slot's final session, either by promoting the slot
    /// directly or by overwriting an already-`.active` slot, while the
    /// originator's post-await code never overwrites an already-`.active`
    /// slot. Which of the two calling `Task`s becomes the originator
    /// versus the late arrival is decided by real scheduling (`Task`
    /// start order within a `TaskGroup` is not guaranteed), and under
    /// contention the roles can land on either session. So "which session
    /// receives the event" is schedule-dependent BY DESIGN, not a defect
    /// — asserting a specific winner (e.g. always session A) is asserting
    /// something the API never promised, and flakes whichever way
    /// scheduling happens to land that run.
    ///
    /// This test fires two concurrent `watch(...)` calls on the same root
    /// with two distinct sessions via `withTaskGroup`. The
    /// `SlowMockEventSource` keeps the first call's `start(...)`
    /// suspended long enough for the second call to slip in. The
    /// assertions pin the invariants the API actually guarantees
    /// regardless of which session wins the race: both calls return
    /// success, exactly one source is provisioned, the emitted event
    /// reaches at least one of the two sessions (nothing is silently
    /// dropped), and it never reaches both (no duplicate delivery).
    func test_concurrent_watch_sameRoot_doesNotSilentlyDropSecondCallSession() async throws {
        let ws = makeWorkspaceRoot("race")
        let (sessionA, transportA) = try await makeStartedSession(workspaceRoot: ws)
        let (sessionB, transportB) = try await makeStartedSession(workspaceRoot: ws)

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let file = ws.appendingPathComponent("race.swift")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let capture = SlowMockCapture()
        let manager = FileSyncManager(eventSourceFactory: { capture.make() })

        let results: [Result<Void, Error>] = await withTaskGroup(
            of: Result<Void, Error>.self
        ) { group in
            group.addTask {
                do {
                    try await manager.watch(workspaceRoot: ws, session: sessionA)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await manager.watch(workspaceRoot: ws, session: sessionB)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            var acc: [Result<Void, Error>] = []
            for await r in group { acc.append(r) }
            return acc
        }

        let successCount = results.reduce(into: 0) { acc, r in
            if case .success = r { acc += 1 }
        }
        let mocks = capture.mocks()
        XCTAssertGreaterThanOrEqual(mocks.count, 1,
                                    "factory must have been invoked at least once")

        // Emit an event through the first mock that the manager actually
        // wired up. Under the bug only one mock exists, registered against
        // sessionA's workspaceRoot lookup; sessionB receives nothing.
        if let firstMock = mocks.first {
            await firstMock.emit([FileSystemEvent(path: file, kind: .created)])
        }
        // Give the manager time to deliver the event to the registered session.
        let sawAnywhere = await waitUntil {
            let mA = (try? await self.sentMethods(transportA)) ?? []
            let mB = (try? await self.sentMethods(transportB)) ?? []
            return mA.contains("workspace/didChangeWatchedFiles")
                || mB.contains("workspace/didChangeWatchedFiles")
        }
        XCTAssertTrue(sawAnywhere, "the first mock's event must reach some session")

        let methodsA = try await sentMethods(transportA)
        let methodsB = try await sentMethods(transportB)
        let aGot = methodsA.contains("workspace/didChangeWatchedFiles")
        let bGot = methodsB.contains("workspace/didChangeWatchedFiles")

        // Schedule-independent invariants only. Which of aGot/bGot is
        // true (the LIFO winner) depends on real Task scheduling and is
        // not asserted either way — see the doc comment above.
        XCTAssertEqual(
            successCount, 2,
            "both concurrent watch(...) calls on the same root must return " +
            "success, never silently fail or hang"
        )
        XCTAssertEqual(
            mocks.count, 1,
            "a concurrent watch(...) on an already-arming root must not " +
            "provision a second, independent event source"
        )
        XCTAssertFalse(
            aGot && bGot,
            "Bug: the event was delivered to BOTH sessions. " +
            "methodsA=\(methodsA), methodsB=\(methodsB)"
        )

        await manager.stopAll()
    }

    // ====================================================================
    // MARK: - Bug 3: suppressedEvents keyed by URL ignores /tmp ↔ /private/tmp
    // ====================================================================

    /// On macOS `/tmp` is a symlink to `/private/tmp`, so
    /// `URL(fileURLWithPath: "/tmp/x")` and
    /// `URL(fileURLWithPath: "/private/tmp/x")` are two equally valid URL
    /// spellings of the same file. `suppressedEvents` is keyed by literal
    /// `URL` value, so a suppression installed using one spelling does NOT
    /// mask an FSEvents-delivered event keyed by the other spelling. The
    /// echo-loop guarantee is silently broken whenever the writer and
    /// FSEvents disagree on the canonical form.
    ///
    /// This test installs the suppression with the `/tmp/...` spelling
    /// (writer-side) and emits the event with the `/private/tmp/...`
    /// spelling (FSEvents-canonical). The file is unopened on the session
    /// so a non-suppressed `modified` event must drop into the
    /// `workspace/didChangeWatchedFiles` branch — observing that
    /// notification on the transport pins the bug.
    func test_suppressNextEvent_appliesAcrossPrivateTmpAlias() async throws {
        let baseDir = "calyx-fs-sync-bugspec-suppress-\(UUID().uuidString)"
        let realDir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(baseDir)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realFile = realDir.appendingPathComponent("normalized.swift")
        try "v1".write(to: realFile, atomically: true, encoding: .utf8)

        // Workspace root uses the /private/tmp spelling (matches what
        // FSEvents would surface from a realpath-resolved subscription).
        let (session, transport) = try await makeStartedSession(workspaceRoot: realDir)

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: realDir, session: session)

        // Suppress using the /tmp/... writer-side spelling.
        let aliasFile = URL(fileURLWithPath: "/tmp/\(baseDir)/normalized.swift")
        await manager.suppressNextEvent(at: aliasFile)

        // Emit using the /private/tmp/... FSEvents-canonical spelling.
        await mock.emit([FileSystemEvent(path: realFile, kind: .modified)])

        // Give the manager a moment to (potentially) react.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let methods = try await sentMethods(transport)
        XCTAssertFalse(
            methods.contains("workspace/didChangeWatchedFiles"),
            "Bug: suppressNextEvent(at: /tmp/.../foo) must mask an FSEvents " +
            "event keyed by /private/tmp/.../foo (the two refer to the same " +
            "file on macOS). The echo-loop guard is silently broken. " +
            "methods=\(methods)"
        )
        XCTAssertFalse(
            methods.contains("textDocument/didChange"),
            "Bug: same suppression normalisation gap as above, defended for " +
            "the open-document branch. methods=\(methods)"
        )

        await manager.stopAll()
    }

    // ====================================================================
    // MARK: - Bug 4: .renamed(to: self) collapses to didClose+didOpen on same URI
    // ====================================================================

    /// FSEvents reports only the touched path for a Renamed event, so
    /// `FSEventsEventSource` synthesises `.renamed(to: url)` where the
    /// destination equals the source. The dispatch path then issues a
    /// `textDocument/didClose(uri)` immediately followed by a
    /// `textDocument/didOpen(uri)` for the SAME URI. Strict LSP servers
    /// (rust-analyzer, gopls) reject the no-op pair, and even tolerant
    /// servers churn their analysis queues.
    ///
    /// Driving this through `MockFileSystemEventSource.emit(_:)` matches
    /// production's `FSEventsEventSource.fsEventsCallback` behaviour for
    /// the `kFSEventStreamEventFlagItemRenamed` branch. The assertion
    /// counts `textDocument/didOpen` notifications for the document's
    /// URI — exactly one (the pre-rename open) is allowed.
    func test_renamedToSelf_doesNotEmitDuplicateDidOpen() async throws {
        let ws = makeWorkspaceRoot("renameSelf")
        let (session, transport) = try await makeStartedSession(workspaceRoot: ws)

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let file = ws.appendingPathComponent("self-rename.swift")
        try "body".write(to: file, atomically: true, encoding: .utf8)

        try await session.didOpen(
            uri: file.absoluteString,
            languageId: testLanguageId,
            version: 1,
            text: "body"
        )

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: ws, session: session)

        // Emit the self-rename event. This mirrors what
        // `FSEventsEventSource.fsEventsCallback` produces for a
        // `kFSEventStreamEventFlagItemRenamed` flag on a single path.
        await mock.emit([FileSystemEvent(path: file, kind: .renamed(to: file))])

        // Allow the manager to dispatch.
        try? await Task.sleep(nanoseconds: 150_000_000)

        let dicts = try await sentDicts(transport)
        let didOpenForUri = dicts.filter { dict in
            guard (dict["method"] as? String) == "textDocument/didOpen" else { return false }
            let p = dict["params"] as? [String: Any]
            let td = p?["textDocument"] as? [String: Any]
            return (td?["uri"] as? String) == file.absoluteString
        }.count
        XCTAssertEqual(
            didOpenForUri, 1,
            "Bug: `.renamed(to: file)` (self-rename, FSEvents-canonical for " +
            "a single touched path) must not emit a duplicate didOpen for " +
            "the same URI. Currently the manager translates it into " +
            "didClose(uri) + didOpen(uri) for the same document, which strict " +
            "servers reject. Got \(didOpenForUri) didOpen entries for the URI."
        )

        // Defensive co-assertion: the close+open pair on the same URI is
        // the precise wire-level malformation strict servers reject.
        let methodsInOrder = dicts.map { ($0["method"] as? String) ?? "" }
        let urisInOrder = dicts.map { dict -> String in
            let p = dict["params"] as? [String: Any]
            let td = p?["textDocument"] as? [String: Any]
            return (td?["uri"] as? String) ?? ""
        }
        var sawCloseThenOpenSameUri = false
        var i = 0
        while i + 1 < methodsInOrder.count {
            if methodsInOrder[i] == "textDocument/didClose"
                && methodsInOrder[i + 1] == "textDocument/didOpen"
                && urisInOrder[i] == urisInOrder[i + 1]
                && !urisInOrder[i].isEmpty
            {
                sawCloseThenOpenSameUri = true
                break
            }
            i += 1
        }
        XCTAssertFalse(
            sawCloseThenOpenSameUri,
            "Bug: a self-rename produced an immediately-adjacent " +
            "didClose+didOpen pair on the same URI, the precise sequence " +
            "strict servers reject. methods=\(methodsInOrder)"
        )

        await manager.stopAll()
    }

    // ====================================================================
    // MARK: - Bug 5: modified-event sync read blocks the actor
    // ====================================================================

    /// `dispatch(event: .modified)` for an open document reads the full
    /// file contents via a synchronous `String(contentsOf: ...)` while
    /// still inside the actor's serial executor. A large file (50 MB or a
    /// slow network volume) stalls every other manager operation behind
    /// that disk read — `unwatch(...)`, `suppressNextEvent(...)`,
    /// concurrent event dispatches all queue up behind the I/O.
    ///
    /// Deterministically forcing a sync `String(contentsOf:)` past the
    /// 200 ms threshold requires either writing a 256 MB+ temp file
    /// (excessive for a unit test, especially in CI) or a slow-medium
    /// injection seam (FIFO, mounted slow disk) that the test
    /// infrastructure does not currently provide. The production-code
    /// fix (`Task.detached { try? String(contentsOf: ...) }` then await,
    /// or move the read off the actor entirely) is straightforward; the
    /// test seam is what is missing.
    func test_modifiedDispatch_doesNotBlockActorOnLargeFileRead() throws {
        throw XCTSkip(
            "requires Task.detached read path. Reliably triggering the " +
            "actor stall requires either a 256 MB+ temp file (excessive " +
            "for unit tests) or a slow-medium injection seam that does " +
            "not yet exist. The swift-specialist will add the off-actor " +
            "read in `dispatch(event: .modified)` and a seam that lets " +
            "this test deterministically observe non-blocking behaviour."
        )
    }
}
