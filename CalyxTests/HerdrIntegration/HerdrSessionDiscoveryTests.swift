//
//  HerdrSessionDiscoveryTests.swift
//  CalyxTests
//
//  TDD Red Phase for HerdrSessionDiscovery: enumerating candidate herdr
//  socket locations (discover()) and probing whether each is actually
//  alive (isAlive(socketPath:)).
//
//  Contract this file pins for Stage 1-C (deliberate design decisions
//  not otherwise specified elsewhere):
//  - discover()'s default-session candidate is ALWAYS present, even
//    when configRootDirectory doesn't exist on disk at all --
//    existence/liveness is isAlive()'s job, not discover()'s.
//  - HERDR_SOCKET_PATH is ADDITIVE: it contributes one more candidate
//    alongside whatever the directory scan already found, never a
//    replacement for it (a replace semantics could hide real sessions
//    the scan already discovered).
//
//  isAlive() coverage requires binding REAL AF_UNIX sockets. Darwin's
//  sockaddr_un.sun_path is only 104 bytes, so every socket fixture in
//  this file is rooted at a short /tmp/<8-hex-chars> directory --
//  deliberately NOT FileManager.default.temporaryDirectory, which
//  alone is already 50-70+ bytes on macOS before any fixture-specific
//  suffix. bindUnixSocketFixture(at:) additionally guards this with an
//  explicit length precondition so a future refactor that lengthens
//  the path fails with a clear message instead of a cryptic bind()
//  errno.
//
//  Coverage:
//  - discover(): default candidate present even with no config root on
//    disk; named candidates from sessions/ subdirectories (skipping a
//    stray non-directory entry); HERDR_SOCKET_PATH override is
//    additive alongside the directory-scan candidates (asserts BOTH
//    are present, not just the override -- otherwise an
//    override-REPLACES implementation would also satisfy a weaker
//    assertion)
//  - isAlive(): a real bound-and-listening socket is alive; a stale
//    socket file with no listener (ECONNREFUSED) is dead; a plain
//    regular file left at the socket path is dead (the core
//    anti-stat() regression pin -- a stat()/fileExists()-based
//    implementation would incorrectly call this "alive"); a
//    nonexistent path is dead
//  - discover() dedup: a HERDR_SOCKET_PATH override colliding with the
//    default candidate's own socket path, or with an already-discovered
//    named session's socket path, must never produce a second,
//    duplicate candidate for the same socket
//  - Task.isCancelled cooperative checks: a cancelled Task stops
//    discover()'s directory-scan loop from contributing further named
//    candidates, and makes isAlive() return false immediately without
//    performing its connect() probe, when either method is invoked
//    directly from within a live Task (as this file's own tests do
//    below). HerdrCLISessionProvider.listSessions() no longer benefits
//    from this fine-grained check in production -- it now runs
//    discover()/isAlive() from DispatchQueue.global() to avoid blocking
//    a Swift Concurrency executor thread (see HerdrSessionProvider
//    .swift's own doc comment) -- but a cancelled bounded-race sweep
//    (SessionBrowserModel.boundedHerdrListSessions()) still degrades to
//    [] via the shared daemonQueryBoundTimeoutSeconds bound regardless.
//

import XCTest
@testable import Calyx

final class HerdrSessionDiscoveryTests: XCTestCase {

    // MARK: - discover() fixtures (ordinary temp dirs -- no socket binding)

    private func uniqueConfigRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-config-\(UUID().uuidString)").path
    }

    private func makeDirectory(_ path: String) {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    // MARK: - discover()

    func test_discover_defaultCandidateIsAlwaysPresent_evenWhenConfigRootDoesNotExistOnDisk() {
        let configRoot = uniqueConfigRoot() // never created on disk

        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: configRoot)
        let candidates = discovery.discover()

        let expectedDefault = HerdrSessionCandidate(name: nil, socketPath: configRoot + "/herdr.sock")
        XCTAssertTrue(candidates.contains(expectedDefault),
                      "The default-session candidate must always be present -- discover() only " +
                      "constructs candidate paths, it never checks existence itself (that's " +
                      "isAlive()'s job)")
    }

    func test_discover_namedSessionSubdirectories_becomeNamedCandidates_skippingStrayNonDirectoryFile() {
        let configRoot = uniqueConfigRoot()
        defer { try? FileManager.default.removeItem(atPath: configRoot) }
        makeDirectory(configRoot + "/sessions/work")
        makeDirectory(configRoot + "/sessions/personal")
        // A stray regular file directly inside sessions/ (not a
        // subdirectory) must never be treated as a named session.
        FileManager.default.createFile(atPath: configRoot + "/sessions/.DS_Store", contents: Data())

        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: configRoot)
        let candidates = discovery.discover()

        let expectedWork = HerdrSessionCandidate(name: "work", socketPath: configRoot + "/sessions/work/herdr.sock")
        let expectedPersonal = HerdrSessionCandidate(name: "personal", socketPath: configRoot + "/sessions/personal/herdr.sock")
        XCTAssertTrue(candidates.contains(expectedWork))
        XCTAssertTrue(candidates.contains(expectedPersonal))
        XCTAssertFalse(candidates.contains { $0.name == ".DS_Store" },
                       "A stray non-directory file directly inside sessions/ must never become a " +
                       "named-session candidate")
    }

    func test_discover_herdrSocketPathOverride_isAdditiveAlongsideDirectoryScanCandidates() {
        let configRoot = uniqueConfigRoot()
        defer { try? FileManager.default.removeItem(atPath: configRoot) }
        makeDirectory(configRoot + "/sessions/personal")
        let overridePath = configRoot + "-env-override/herdr.sock"

        let discovery = HerdrSessionDiscovery(
            environment: ["HERDR_SOCKET_PATH": overridePath],
            configRootDirectory: configRoot
        )
        let candidates = discovery.discover()

        // Deliberately asserts ALL THREE are present together (default
        // + directory-scanned + env override), not just the override
        // alone -- a "the override REPLACES the whole scan" reading
        // would also make a weaker assertion pass, so the directory-
        // scan candidates must be checked here too to actually pin
        // additive semantics.
        let expectedDefault = HerdrSessionCandidate(name: nil, socketPath: configRoot + "/herdr.sock")
        let expectedPersonal = HerdrSessionCandidate(name: "personal", socketPath: configRoot + "/sessions/personal/herdr.sock")
        let expectedOverride = HerdrSessionCandidate(name: nil, socketPath: overridePath)

        XCTAssertTrue(candidates.contains(expectedDefault), "The default candidate must survive alongside the env override")
        XCTAssertTrue(candidates.contains(expectedPersonal), "The directory-scanned named candidate must survive alongside the env override")
        XCTAssertTrue(candidates.contains(expectedOverride), "HERDR_SOCKET_PATH must contribute its own additional candidate")
    }

    // MARK: - discover() dedup by socketPath (HERDR_SOCKET_PATH can collide with a scanned default)

    func test_discover_herdrSocketPathOverride_collidingWithDefaultSocketPath_dedupedToSingleCandidate() {
        let configRoot = uniqueConfigRoot()
        defer { try? FileManager.default.removeItem(atPath: configRoot) }
        let defaultSocketPath = configRoot + "/herdr.sock"

        let discovery = HerdrSessionDiscovery(
            environment: ["HERDR_SOCKET_PATH": defaultSocketPath],
            configRootDirectory: configRoot
        )
        let candidates = discovery.discover()

        XCTAssertEqual(candidates.filter { $0.socketPath == defaultSocketPath }.count, 1,
                       "HERDR_SOCKET_PATH exactly matching the default candidate's own socket path must " +
                       "not produce a second, duplicate candidate for the same socket")
    }

    func test_discover_herdrSocketPathOverride_collidingWithNamedSessionSocketPath_keepsNamedCandidateOnly() {
        let configRoot = uniqueConfigRoot()
        defer { try? FileManager.default.removeItem(atPath: configRoot) }
        makeDirectory(configRoot + "/sessions/work")
        let workSocketPath = configRoot + "/sessions/work/herdr.sock"

        let discovery = HerdrSessionDiscovery(
            environment: ["HERDR_SOCKET_PATH": workSocketPath],
            configRootDirectory: configRoot
        )
        let candidates = discovery.discover()

        let matches = candidates.filter { $0.socketPath == workSocketPath }
        XCTAssertEqual(matches.count, 1,
                       "HERDR_SOCKET_PATH colliding with an already-discovered named session's own socket " +
                       "path must not produce a duplicate candidate for the same socket")
        XCTAssertEqual(matches.first?.name, "work",
                       "The surviving candidate must keep the richer name from the directory scan, not be " +
                       "overwritten by the override's own unnamed (nil) shape")
    }

    // MARK: - Task.isCancelled cooperative checks (a cancelled bounded-race sweep must actually stop)

    /// Holds at most one continuation so a `Task`'s synchronous body can
    /// be cancelled BEFORE it starts running, with no scheduling race:
    /// the test cancels the `Task` while it is still suspended here,
    /// then resumes it -- so `Task.isCancelled` reads `true` from the
    /// very first check the cancellable code performs. Mirrors
    /// `SessionBrowserModelRefreshCancellationGuardTests`'
    /// `SuspendingSessionDaemonClient` continuation-box pattern (a bare
    /// captured `var` can't be mutated from a `@Sendable` closure under
    /// Swift 6 strict concurrency).
    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        var isWaiting: Bool {
            lock.lock(); defer { lock.unlock() }
            return continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
            }
        }

        func proceed() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve, mirroring
    /// `SessionBrowserModelRefreshCancellationGuardTests`'s own
    /// `waitUntil` helper -- a broken gate hangs an assertion, never the
    /// test host.
    private func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    func test_discover_stopsScanningSessionsSubdirectories_onceTaskIsCancelled() async {
        let configRoot = uniqueConfigRoot()
        defer { try? FileManager.default.removeItem(atPath: configRoot) }
        for index in 0..<20 {
            makeDirectory(configRoot + "/sessions/session-\(index)")
        }
        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: configRoot)
        let gate = ContinuationGate()

        let task = Task {
            await gate.wait()
            return discovery.discover()
        }
        await waitUntil { gate.isWaiting }
        task.cancel() // deterministic: lands while the task is still suspended at the gate, strictly before discover()'s loop ever runs
        gate.proceed()
        let candidates = await task.value

        XCTAssertFalse(candidates.contains { $0.name != nil },
                       "Once the surrounding Task is cancelled, discover()'s directory-scan loop must stop " +
                       "contributing named candidates -- a cancelled bounded-race sweep " +
                       "(SessionBrowserModel.boundedHerdrListSessions()) must not keep scanning after its " +
                       "caller has already given up")
        XCTAssertTrue(candidates.contains { $0.name == nil },
                      "The always-present default candidate, added before the cancellable loop, must " +
                      "still be there")
    }

    // MARK: - isAlive() fixtures (real AF_UNIX sockets -- short-path roots)

    private enum UnixSocketFixtureError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)

        var description: String {
            switch self {
            case .pathTooLong(let detail): return "fixture socket path too long: \(detail)"
            case .socketCreateFailed(let e): return "socket() failed: errno \(e)"
            case .bindFailed(let e): return "bind() failed: errno \(e)"
            case .listenFailed(let e): return "listen() failed: errno \(e)"
            }
        }
    }

    /// A short `/tmp`-rooted directory (8 hex characters, NOT a full
    /// UUID, and deliberately NOT FileManager.default.temporaryDirectory)
    /// so every socket path built under it stays far under Darwin's
    /// 104-byte sockaddr_un.sun_path limit.
    private func shortSocketFixtureRoot() -> String {
        let suffix = String(UUID().uuidString.prefix(8))
        let path = "/tmp/hsd-\(suffix)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Binds (and, when `listenBacklog` is non-nil, listens on) a real
    /// AF_UNIX SOCK_STREAM socket at `path`, returning the raw fd
    /// (caller closes it). `listenBacklog` non-nil simulates a live
    /// herdr server; nil (bind only, no listen) simulates a
    /// crashed-server's leftover socket file -- either way the socket
    /// special FILE is left behind on disk once the fd closes, exactly
    /// like a real herdr crash would.
    @discardableResult
    private func bindUnixSocketFixture(at path: String, listenBacklog: Int32?) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 100 else {
            throw UnixSocketFixtureError.pathTooLong(
                "\(pathBytes.count) bytes (limit ~100 to stay under sockaddr_un's 104-byte sun_path): \(path)"
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketFixtureError.socketCreateFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
            buffer[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            close(fd)
            throw UnixSocketFixtureError.bindFailed(bindErrno)
        }

        if let listenBacklog {
            guard listen(fd, listenBacklog) == 0 else {
                let listenErrno = errno
                close(fd)
                throw UnixSocketFixtureError.listenFailed(listenErrno)
            }
        }

        return fd
    }

    // MARK: - isAlive()

    func test_isAlive_realBoundAndListeningSocket_returnsTrue() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let fd = try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        defer { close(fd) }

        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: root)

        XCTAssertTrue(discovery.isAlive(socketPath: socketPath),
                      "A real bound-and-listening AF_UNIX socket (bind+listen leaves the backlog able to " +
                      "accept a connect() with no accept() loop needed) must read as alive")
    }

    func test_isAlive_staleSocketFileWithNoListener_returnsFalse() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let fd = try bindUnixSocketFixture(at: socketPath, listenBacklog: nil)
        close(fd) // simulate the server dying: fd closed, socket special file left behind

        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: root)

        XCTAssertFalse(discovery.isAlive(socketPath: socketPath),
                       "A socket special file left behind with nothing listening (ECONNREFUSED on " +
                       "connect) must read as dead")
    }

    func test_isAlive_regularFileLeftBehindAtSocketPath_returnsFalse_neverUseStatOnly() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        // An ORDINARY regular file, not a socket at all -- this is the
        // core anti-stat()/fileExists() regression pin: a liveness
        // check implemented as a mere existence check would incorrectly
        // call this "alive" because the path does exist on disk.
        FileManager.default.createFile(atPath: socketPath, contents: Data("not a socket".utf8))

        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: root)

        XCTAssertFalse(discovery.isAlive(socketPath: socketPath),
                       "A plain regular file left behind at the socket path must read as dead -- " +
                       "liveness must be a connect() probe, never stat()/fileExists()")
    }

    func test_isAlive_nonexistentSocketPath_returnsFalse() {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/never-created.sock"

        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: root)

        XCTAssertFalse(discovery.isAlive(socketPath: socketPath))
    }

    // MARK: - isAlive() Task.isCancelled cooperative check

    func test_isAlive_returnsFalse_onceTaskIsCancelled_evenForARealListeningSocket() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let fd = try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        defer { close(fd) }

        let discovery = HerdrSessionDiscovery(environment: [:], configRootDirectory: root)
        let gate = ContinuationGate()

        let task = Task {
            await gate.wait()
            return discovery.isAlive(socketPath: socketPath)
        }
        await waitUntil { gate.isWaiting }
        task.cancel() // deterministic, see test_discover_stopsScanningSessionsSubdirectories_onceTaskIsCancelled above
        gate.proceed()
        let isAlive = await task.value

        XCTAssertFalse(isAlive,
                       "Once cancelled, isAlive() must return false immediately without performing its " +
                       "connect() probe -- even though the fixture socket genuinely IS alive " +
                       "(bound+listening), proving the cancellation short-circuit actually fired rather " +
                       "than coincidentally returning false")
    }
}
