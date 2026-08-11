// HerdrTransport.swift
// Calyx
//
// Abstract bidirectional line transport used by `HerdrOneShotRequest`
// and `HerdrEventStream` (HerdrConnection.swift) to talk to a herdr
// Unix-domain-socket server. Mirrors
// Calyx/Features/LSP/Transport/LSPTransport.swift's split between a
// protocol and an in-memory test double, with one deliberate
// difference: herdr's wire protocol is newline-delimited JSON (NDJSON)
// -- one complete JSON value per line -- so this transport moves whole
// decoded-to-`String` LINES, not raw byte chunks. Splitting bytes on
// "\n" is this transport's own job (done below, inside whichever type
// implements `HerdrTransport`), not something `HerdrOneShotRequest`/
// `HerdrEventStream` or `HerdrEvent` need to know about.
//
// EOF vs error: stopping a herdr server makes recv() return zero bytes
// on a subscribed BSD socket -- a reliably observable, CLEAN
// disconnect, distinct from a genuine transport-level failure (a
// recv() errno, or -- in this test double -- an injected failure).
// `HerdrTransportEvent` keeps these as separate cases so a consumer
// (`HerdrOneShotRequest`/`HerdrEventStream`) can react differently: a
// pending request/subscribe ack must fail either way (there is no more
// result coming), but a long-lived, already-subscribed event stream
// treats EOF as a graceful, expected end of stream and an actual
// failure as something worth surfacing as an error -- see
// `HerdrEventStream.subscribe(_:socketPath:)`'s own doc comment
// (HerdrConnection.swift).
//
// `BSDHerdrTransport` below is the production implementation: a BSD
// Unix-domain socket driven by `DispatchSourceRead`, NOT `NWConnection`
// -- `NWConnection` does not reliably report a peer's graceful FIN via
// `stateUpdateHandler` when no `receive()` is outstanding (see
// `CalyxMCPServer.swift`'s own `armApprovalRequestConnectionDropSentinel`
// doc comment for the empirically-verified detail), whereas a raw
// recv() returning zero bytes is a simple, reliable EOF signal.
//
// `InMemoryHerdrTransport` above is what `HerdrConnectionTests`/
// `HerdrIntegrationCoordinatorTests` drive. `BSDHerdrTransport` below
// has its own real-socket integration tests in HerdrTransportTests.swift,
// which bind and listen on a local Unix-domain socket the test itself
// owns and controls both ends of -- the same fixture approach
// `HerdrSessionDiscovery.isAlive(socketPath:)`'s own tests
// (HerdrSessionDiscoveryTests.swift) already established, and the
// direct precedent for the `sockaddr_un` construction below. There is
// no "no real sockets in unit tests" rule anywhere in this codebase --
// a real, locally-bound-and-listening socket the test itself owns is
// exactly how socket-facing code IS tested here, for both this type and
// `HerdrSessionDiscovery`.
//

import Darwin
import Foundation

// MARK: - HerdrTransportFailure

/// Reason `HerdrTransport.incoming` produced a terminal `.failure`
/// event instead of another `.line` -- carries only a diagnostic
/// message, never the underlying `any Error` (stream elements cross
/// actor isolation -- the real transport yields from a
/// `DispatchSourceRead` callback into whichever type is currently
/// consuming `incoming` (`HerdrOneShotRequest`/`HerdrEventStream`,
/// HerdrConnection.swift) -- and heterogeneous `Error` existentials are
/// not `Sendable`).
struct HerdrTransportFailure: Sendable, Equatable, Error {
    let message: String
}

// MARK: - HerdrTransportEvent

/// One element of `HerdrTransport.incoming`. `.line` is an inbound
/// NDJSON line with framing already resolved (no trailing "\n", no
/// partial lines). `.eof` and `.failure` are mutually exclusive
/// terminal events -- the stream yields at most one of them, always as
/// its LAST element, and never a `.line` after either. See this file's
/// header for why the two are kept distinct.
enum HerdrTransportEvent: Sendable, Equatable {
    case line(String)
    case eof
    case failure(HerdrTransportFailure)
}

// MARK: - HerdrTransport

/// Bidirectional line transport that connects `HerdrOneShotRequest`/
/// `HerdrEventStream` (HerdrConnection.swift) to a herdr server's
/// Unix-domain socket.
///
/// Implementations are responsible for moving NDJSON lines; they do
/// not parse request/response envelopes or anything above the line
/// layer -- that is `HerdrOneShotRequest`/`HerdrEventStream`'s job.
protocol HerdrTransport: Sendable {
    /// Opens the connection to the herdr server listening at
    /// `socketPath`. Throws if no listener accepts the connection.
    /// Implementations should treat a second `connect` call on an
    /// already-connected (or already-closed) instance as a
    /// conformer-defined error, never a silent no-op or a `fatalError`.
    func connect(socketPath: String) async throws

    /// Writes one NDJSON line -- a single already-serialized JSON
    /// value, WITHOUT a trailing newline; the transport owns newline
    /// framing, not the caller. Throws if the transport is not
    /// connected or has already closed.
    func send(_ line: String) async throws

    /// Stream of inbound transport events. Finishes immediately after
    /// yielding `.eof` or `.failure` -- see `HerdrTransportEvent`'s own
    /// doc comment.
    nonisolated var incoming: AsyncStream<HerdrTransportEvent> { get }

    /// Idempotent shutdown. Subsequent `send` calls must throw and
    /// `incoming` must finish (if not already finished).
    func close() async
}

// MARK: - InMemoryHerdrTransport

/// In-memory `HerdrTransport` test double. Captures every line
/// `HerdrOneShotRequest`/`HerdrEventStream` write (so tests can inspect
/// the exact request/subscribe envelopes sent) and lets tests inject
/// server-originated lines, EOF, or a failure via `simulateLine` /
/// `simulateEOF` / `simulateFailure`.
///
/// Mirrors `InMemoryLSPTransport`'s shape exactly (actor, continuation
/// captured at init, `nonisolated let incoming`, idempotent `close`);
/// the only difference is the element type (`HerdrTransportEvent`
/// carrying whole NDJSON lines, vs raw `Data` chunks there). This is
/// the test double `HerdrConnectionTests`/`HerdrIntegrationCoordinatorTests`
/// drive -- see `BSDHerdrTransport` below for the production conformer.
actor InMemoryHerdrTransport: HerdrTransport {

    // MARK: - State

    /// Every line passed to `send`, in order.
    private var captured: [String] = []

    /// The `socketPath` most recently passed to `connect`, or `nil` if
    /// `connect` was never called.
    private var connectedPath: String?

    /// Continuation for the `incoming` stream. Set in `init`.
    private let continuation: AsyncStream<HerdrTransportEvent>.Continuation

    /// Public stream of inbound transport events.
    nonisolated let incoming: AsyncStream<HerdrTransportEvent>

    private var isClosed = false

    /// B3 test seam: invoked at the very top of `send`, before the
    /// `isClosed` check -- lets a test deterministically interleave
    /// other concurrent actor work (e.g. a consumer fully processing a
    /// just-simulated terminal transport event) with an in-flight `send`
    /// call, reproducing a "send raced termination" race that would
    /// otherwise depend on incidental Task-scheduling order. `nil` (the
    /// default) is a complete no-op. Currently unused by any test in
    /// this codebase -- its only consumer lived in the now-deleted
    /// `HerdrSocketSessionTests.swift` (its own "racesSessionTermination"
    /// tests, against `HerdrSocketSession`'s multiplexed receive loop).
    /// Retained as a general-purpose seam: `HerdrOneShotRequest`/
    /// `HerdrEventStream` (HerdrConnection.swift) each still have exactly
    /// one in-flight outbound `send` (the request/subscribe line) that
    /// could in principle race a concurrent close/terminal-event path.
    private var beforeSend: (@Sendable () async -> Void)?

    // MARK: - Init

    init() {
        var capturedContinuation: AsyncStream<HerdrTransportEvent>.Continuation!
        self.incoming = AsyncStream<HerdrTransportEvent> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    // MARK: - HerdrTransport

    func connect(socketPath: String) async throws {
        connectedPath = socketPath
    }

    func send(_ line: String) async throws {
        if let beforeSend {
            await beforeSend()
        }
        guard !isClosed else {
            throw HerdrTransportError.alreadyClosed
        }
        captured.append(line)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        continuation.finish()
    }

    // MARK: - Test API

    /// Snapshot of every line `send` has received, in order.
    func sentMessages() -> [String] {
        captured
    }

    /// The `socketPath` most recently passed to `connect`, or `nil` if
    /// `connect` was never called on this instance.
    func lastConnectedSocketPath() -> String? {
        connectedPath
    }

    /// Sets (or, passing `nil`, clears) `beforeSend` -- see that
    /// property's own doc comment.
    func setBeforeSend(_ hook: (@Sendable () async -> Void)?) {
        beforeSend = hook
    }

    /// Push one line through `incoming` as if the server had sent it.
    /// A no-op once the transport is closed.
    func simulateLine(_ line: String) {
        guard !isClosed else { return }
        continuation.yield(.line(line))
    }

    /// Simulate the peer disconnecting cleanly (a real recv() returning
    /// zero bytes) -- yields `.eof`, then finishes the stream. A no-op
    /// once already closed.
    func simulateEOF() {
        guard !isClosed else { return }
        continuation.yield(.eof)
        continuation.finish()
        isClosed = true
    }

    /// Simulate a transport-level failure distinct from a clean EOF --
    /// yields `.failure(HerdrTransportFailure(message:))`, then
    /// finishes the stream. A no-op once already closed.
    func simulateFailure(_ message: String) {
        guard !isClosed else { return }
        continuation.yield(.failure(HerdrTransportFailure(message: message)))
        continuation.finish()
        isClosed = true
    }
}

// MARK: - HerdrTransportError

enum HerdrTransportError: Error, Sendable, Equatable {
    /// `send` called on a transport that has already been `close()`d
    /// (or, for `InMemoryHerdrTransport`, one that already delivered
    /// `.eof`/`.failure`).
    case alreadyClosed
    /// `send` called on a `BSDHerdrTransport` that was never
    /// successfully `connect`ed.
    case notConnected
    /// `connect(socketPath:)` called a second time on an already-
    /// connected `BSDHerdrTransport` -- see `HerdrTransport.connect(socketPath:)`'s
    /// own doc comment.
    case alreadyConnected
    /// `socketPath`'s UTF-8 byte length does not fit inside
    /// `sockaddr_un.sun_path` (104 bytes on Darwin, including the NUL
    /// terminator).
    case socketPathTooLong
    /// `socket(2)` / `connect(2)` / a post-connect `setsockopt(2)` or
    /// `fcntl(2)` call failed. Carries a human-readable `strerror(3)`
    /// message, not the raw `errno` -- see `HerdrTransportFailure`'s own
    /// doc comment for why this file never carries a raw `any Error`.
    case connectFailed(String)
    /// A `write(2)`/`send(2)` syscall failed for a reason other than
    /// the transport already being closed -- also used (B2 fix) when a
    /// write gives up waiting for a stalled peer to become writable
    /// because `close()` was called while it waited; see
    /// `BSDHerdrTransport.waitForWritability(fd:)`'s own doc comment.
    case sendFailed(String)
}

// MARK: - BSDHerdrTransport

/// Production `HerdrTransport` over a real BSD Unix-domain socket --
/// see this file's header for why `DispatchSourceRead`, never
/// `NWConnection`.
///
/// Every mutable stored property (`state`, `receiveBuffer`) is touched
/// ONLY from closures dispatched onto `queue`, a private serial
/// `DispatchQueue`: this type's own `connect`/`send`/`close` bodies
/// reach it via `queue.async` plus a checked continuation (never
/// `queue.sync`, so the calling Swift Concurrency thread is never
/// blocked -- mirrors `SystemCommandRunner.locate(_:)`'s own
/// `DispatchQueue.global().async` + `withCheckedContinuation` idiom),
/// and the `DispatchSourceRead` below is itself created WITH `queue` as
/// its target, so its event/cancel handlers run there too. A serial GCD
/// queue used this way is a standard, sound substitute for the
/// `NSLock` this codebase's other `@unchecked Sendable` types use (e.g.
/// `ProcessCancellationBridge`, `AwaitBridge`) -- both provide the same
/// "at most one mutator at a time" guarantee -- and is the natural
/// choice here since `DispatchSourceRead` already requires designating
/// a target queue.
final class BSDHerdrTransport: HerdrTransport, @unchecked Sendable {

    /// `readSource` is only present once `connect(socketPath:)` has
    /// fully succeeded; `close()`, a clean EOF, and a transport failure
    /// all transition to `.closed` and never back.
    private enum State {
        case notConnected
        case connected(fileDescriptor: Int32, readSource: any DispatchSourceRead)
        case closed
    }

    private let queue = DispatchQueue(label: "com.calyx.herdr.BSDHerdrTransport")

    /// Confined to `queue` -- see this type's own doc comment.
    private var state: State = .notConnected
    /// Confined to `queue`. Bytes received but not yet resolved into a
    /// complete NDJSON line.
    private var receiveBuffer = Data()

    /// B2 fix: `close()`'s signal to a write that may be blocked inside
    /// `waitForWritability(fd:)`'s poll loop, waiting for a stalled peer
    /// to become writable. Deliberately NOT `queue`-confined like
    /// `state` above -- `close()`'s own body also needs a turn on
    /// `queue` to flip `state`/cancel the read source, but `queue` is a
    /// single SERIAL queue also shared by `send`'s write path and the
    /// `DispatchSourceRead` read handler: while a write is stuck inside
    /// `poll(2)`, NOTHING queued behind it (including `close()`'s own
    /// `queue.async` block) can get a turn to run. Guarding this flag
    /// with its own `NSLock` (the same idiom
    /// `Calyx/Helpers/ProcessCancellationBridge.swift` uses for a
    /// cross-context signal) lets `close()` set it SYNCHRONOUSLY, before
    /// ever touching `queue`, so a write stuck on `queue` can still
    /// observe it on its very next bounded poll iteration and give up --
    /// see `close()` and `waitForWritability(fd:)` below.
    private let closeRequestedLock = NSLock()
    private var closeRequested = false

    private let continuation: AsyncStream<HerdrTransportEvent>.Continuation
    nonisolated let incoming: AsyncStream<HerdrTransportEvent>

    init() {
        var capturedContinuation: AsyncStream<HerdrTransportEvent>.Continuation!
        self.incoming = AsyncStream<HerdrTransportEvent> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    deinit {
        // Safety net mirroring `StdioLSPTransport.ProcessHandle.deinit`:
        // unlike `HerdrIntegrationCoordinator`'s own ordinary paths --
        // which now ALWAYS close explicitly (`HerdrOneShotRequest.send`
        // closes on every exit; `HerdrEventStream.subscribe` closes on
        // every failure path and otherwise hands the still-open
        // transport to the coordinator's own EXPLICIT TRANSPORT
        // TEARDOWN -- see HerdrIntegrationCoordinator.swift's own
        // header) -- this `deinit` is a BACKSTOP for whatever does NOT
        // go through one of those explicit paths (a bug, or a future
        // caller of this transport that forgets to), not the expected
        // teardown path itself. `continuation.finish()` is unconditional
        // and safe to call even when already finished (idempotent,
        // thread-safe per `AsyncStream`'s own contract) -- it is what
        // unblocks a still-running consumer `Task` (e.g.
        // `HerdrEventStream`'s own relay task, which holds its own copy
        // of `incoming`, independent of this instance's lifetime)
        // instead of leaving it suspended forever when this transport
        // disappears without `close()` ever running.
        //
        // Reading `state` directly here (rather than via `queue.async`)
        // is safe: by the time `deinit` runs, ARC guarantees no other
        // strong reference to `self` -- and therefore no other
        // `queue`-confined access reached through `self` -- can still be
        // in flight. The read/cancel handlers below only ever reach
        // `self` through a `weak` capture, and Swift's weak-reference
        // machinery serializes against `deinit`: a handler invocation
        // that manages to strengthen `self` first necessarily delays
        // this `deinit` until that strong reference is released again.
        if case .connected(_, let source) = state {
            source.cancel()
        }
        continuation.finish()
    }

    // MARK: - HerdrTransport

    func connect(socketPath: String) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                switch state {
                case .connected:
                    completion.resume(throwing: HerdrTransportError.alreadyConnected)
                    return
                case .closed:
                    completion.resume(throwing: HerdrTransportError.alreadyClosed)
                    return
                case .notConnected:
                    break
                }

                let pathBytes = Array(socketPath.utf8)
                var addr = sockaddr_un()
                let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
                guard pathBytes.count < sunPathCapacity else {
                    completion.resume(throwing: HerdrTransportError.socketPathTooLong)
                    return
                }

                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    completion.resume(throwing: HerdrTransportError.connectFailed(Self.errnoMessage(errno)))
                    return
                }

                addr.sun_family = sa_family_t(AF_UNIX)
                addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
                    let buffer = rawBuffer.bindMemory(to: UInt8.self)
                    for (index, byte) in pathBytes.enumerated() {
                        buffer[index] = byte
                    }
                    buffer[pathBytes.count] = 0
                }

                let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connectResult == 0 else {
                    let message = Self.errnoMessage(errno)
                    Darwin.close(fd)
                    completion.resume(throwing: HerdrTransportError.connectFailed(message))
                    return
                }

                // Prevent a write to a peer that has vanished from
                // raising SIGPIPE and taking the whole host process down
                // with it -- Darwin has no per-call MSG_NOSIGNAL, so this
                // socket option is the equivalent.
                var noSigPipe: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    let message = Self.errnoMessage(errno)
                    Darwin.close(fd)
                    completion.resume(throwing: HerdrTransportError.connectFailed(message))
                    return
                }

                // Non-blocking from here on so the read source below and
                // `send`'s write loop never park a thread on a stalled
                // peer.
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                    let message = Self.errnoMessage(errno)
                    Darwin.close(fd)
                    completion.resume(throwing: HerdrTransportError.connectFailed(message))
                    return
                }

                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in
                    self?.drainReadable()
                }
                // Captures `fd` by value, not `self` -- runs even after
                // `self` has been deallocated (see `deinit` above).
                source.setCancelHandler {
                    Darwin.close(fd)
                }
                state = .connected(fileDescriptor: fd, readSource: source)
                source.resume()

                completion.resume()
            }
        }
    }

    /// B2 fix: captures `self` WEAKLY (unlike `connect`/`close` above,
    /// whose own `queue.async` bodies always return promptly). Once
    /// `writeAll` can block on `queue` for a while (waiting for a
    /// stalled peer), a STRONG capture here would mean this one enqueued
    /// block -- by itself, independent of whatever else still (or no
    /// longer) references this transport -- keeps the whole instance
    /// alive for as long as it sits queued or blocked. A `nil` `self`
    /// (this instance already torn down by the time this block finally
    /// gets a turn on `queue`) resumes `completion` with
    /// `.alreadyClosed` rather than leaving the caller's continuation
    /// unresumed forever.
    func send(_ line: String) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    completion.resume(throwing: HerdrTransportError.alreadyClosed)
                    return
                }
                guard case .connected(let fd, _) = self.state else {
                    switch self.state {
                    case .closed:
                        completion.resume(throwing: HerdrTransportError.alreadyClosed)
                    case .notConnected:
                        completion.resume(throwing: HerdrTransportError.notConnected)
                    case .connected:
                        break // unreachable -- excluded by the guard above
                    }
                    return
                }

                var payload = Data(line.utf8)
                payload.append(UInt8(ascii: "\n"))

                do {
                    try self.writeAll(payload, to: fd)
                    completion.resume()
                } catch {
                    completion.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        // B2 fix: set BEFORE this method ever touches `queue` -- see
        // `closeRequestedLock`'s own doc comment for why a write stuck
        // inside `waitForWritability(fd:)` could otherwise never observe
        // a `close()` that is itself queued (and stuck waiting) behind
        // it. `withLock` (async-safe scoped locking), not a manual
        // `lock()`/`unlock()` pair -- plain `NSLock.lock()`/`unlock()`
        // are unavailable from an `async` function body.
        closeRequestedLock.withLock { closeRequested = true }

        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                switch state {
                case .closed:
                    break
                case .notConnected:
                    state = .closed
                    continuation.finish()
                case .connected(_, let source):
                    state = .closed
                    continuation.finish()
                    source.cancel() // cancel handler closes the fd asynchronously on `queue`
                }
                completion.resume()
            }
        }
    }

    // MARK: - TEST ONLY instrumentation

    /// TEST ONLY: the fd behind `.connected`, or `nil` for
    /// `.notConnected` / `.closed`. `HerdrTransportTests` uses this to
    /// capture the fd BEFORE calling `close()` (once closed, `state` is
    /// `.closed` and this returns `nil`, like any other caller reaching
    /// in after the fact would see), then independently probes that
    /// captured fd number with `fcntl(_:F_GETFD)` to confirm `close()`
    /// actually released the OS-level descriptor -- not merely flipped
    /// `state` -- which is otherwise unobservable from outside this
    /// file: `state`'s fd is deliberately never exposed to production
    /// callers (`HerdrOneShotRequest`/`HerdrEventStream` have no
    /// legitimate reason to reach the raw descriptor). Hops onto `queue`
    /// like every other `state`-touching entry point above, so this
    /// reads a consistent snapshot, never a torn value.
    internal func testOnlyConnectedFileDescriptor() async -> Int32? {
        await withCheckedContinuation { (completion: CheckedContinuation<Int32?, Never>) in
            queue.async { [self] in
                if case .connected(let fd, _) = state {
                    completion.resume(returning: fd)
                } else {
                    completion.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Reading (runs on `queue`, via the `DispatchSourceRead` event handler)

    /// Drains every byte currently available on the connected fd,
    /// splits complete NDJSON lines out of `receiveBuffer`, and yields
    /// each as `.line(...)`. Loops until `recv()` reports
    /// EAGAIN/EWOULDBLOCK (nothing left to read right now), a clean EOF
    /// (`recv() == 0`), or a hard error -- see this file's header for
    /// why EOF and failure are surfaced as distinct terminal
    /// `HerdrTransportEvent` cases.
    private func drainReadable() {
        guard case .connected(let fd, _) = state else { return }

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if bytesRead > 0 {
                receiveBuffer.append(contentsOf: chunk[0..<bytesRead])
                guard extractLines() else { return } // already terminated (malformed UTF-8 line)
                continue
            }
            if bytesRead == 0 {
                terminate(with: .eof)
                return
            }
            let readErrno = errno
            if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                return
            }
            if readErrno == EINTR {
                continue
            }
            terminate(with: .failure(HerdrTransportFailure(message: Self.errnoMessage(readErrno))))
            return
        }
    }

    /// Extracts and yields every complete "\n"-terminated line currently
    /// in `receiveBuffer`. Returns `false` if a line's bytes were not
    /// valid UTF-8 -- NDJSON is always UTF-8 by protocol, so this is a
    /// transport-integrity failure, not a routine "unexpected content"
    /// case; it is surfaced as `.failure`, already handled internally via
    /// `terminate(with:)`, rather than a caller having to notice a
    /// dropped, unaccounted-for line. Contrast a line that IS valid
    /// UTF-8 and valid JSON, but does not match a higher-level type's own
    /// expected shape (e.g. a malformed pushed event once already
    /// subscribed) -- that is `HerdrEventStream`'s own relay task's
    /// concern (HerdrConnection.swift), which finishes the returned
    /// stream BY THROWING rather than silently dropping the line; this
    /// method's own concern is strictly byte-level (valid UTF-8 or not),
    /// surfaced as `.failure` here regardless of which higher-level type
    /// ends up consuming it.
    @discardableResult
    private func extractLines() -> Bool {
        while let newlineIndex = receiveBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            // Materialize an independent copy BEFORE mutating
            // `receiveBuffer` below, so this decode never depends on
            // `Data` slice/COW subtleties surviving the subsequent
            // `removeSubrange`.
            let lineData = Data(receiveBuffer[receiveBuffer.startIndex..<newlineIndex])
            guard let line = String(data: lineData, encoding: .utf8) else {
                terminate(with: .failure(HerdrTransportFailure(message: "received a line that was not valid UTF-8")))
                return false
            }
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newlineIndex)
            continuation.yield(.line(line))
        }
        return true
    }

    /// Shared terminal path for a clean EOF or a hard read failure --
    /// yields the matching terminal event, finishes `incoming`, and
    /// cancels the read source (whose cancel handler closes the fd). A
    /// no-op once already `.closed` (via this method, or `close()`).
    private func terminate(with event: HerdrTransportEvent) {
        guard case .connected(_, let source) = state else { return }
        state = .closed
        continuation.yield(event)
        continuation.finish()
        source.cancel()
    }

    // MARK: - Writing

    /// Writes `payload` to `fd` in full using non-blocking `write(2)`,
    /// waiting for writability via `waitForWritability(fd:)` (rather
    /// than busy-spinning) whenever the kernel's socket buffer is
    /// momentarily full. Runs on `queue`, never the caller's thread. An
    /// instance method (not `static`, as before B2) so
    /// `waitForWritability(fd:)` below can reach `closeRequestedLock` /
    /// `closeRequested`.
    private func writeAll(_ payload: Data, to fd: Int32) throws {
        let total = payload.count
        try payload.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n == 0 {
                    throw HerdrTransportError.sendFailed("write returned 0")
                }
                let writeErrno = errno
                if writeErrno == EINTR {
                    continue
                }
                if writeErrno == EAGAIN || writeErrno == EWOULDBLOCK {
                    try waitForWritability(fd: fd)
                    continue
                }
                throw HerdrTransportError.sendFailed(Self.errnoMessage(writeErrno))
            }
        }
    }

    /// B2 fix: blocks (on `queue`) until `fd` becomes writable, using a
    /// FINITE, repeated `poll(2)` wait (`writePollTimeoutMilliseconds`
    /// per iteration) instead of one infinite `poll(..., -1)` call --
    /// re-checks `closeRequested` (see that property's own doc comment)
    /// both before the first poll and after every timed-out one, and
    /// throws as soon as it observes it set, rather than continuing to
    /// wait on a peer this transport has already been told to stop
    /// talking to.
    ///
    /// An infinite wait here would hold `queue` -- and with it, both the
    /// `DispatchSourceRead` read handler and `close()` -- hostage to a
    /// stalled peer indefinitely; this bounds that to at most one poll
    /// interval after `close()` sets `closeRequested`. It does NOT bound
    /// the write's TOTAL duration absent a `close()` call (e.g. nobody
    /// ever calls `close()` and the peer never resumes draining) --
    /// inventing a wall-clock give-up deadline for that case would add
    /// unrequested timeout behavior this codebase's own conventions rule
    /// out; this only makes the wait INTERRUPTIBLE, not bounded outright.
    private func waitForWritability(fd: Int32) throws {
        while true {
            if isCloseRequested() {
                throw HerdrTransportError.sendFailed("transport closed while waiting for the peer to become writable")
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pfd, 1, Self.writePollTimeoutMilliseconds)
            if pollResult < 0 {
                let pollErrno = errno
                if pollErrno == EINTR { continue }
                throw HerdrTransportError.sendFailed(Self.errnoMessage(pollErrno))
            }
            if pollResult == 0 {
                // Timed out with nothing ready -- loop back around to
                // re-check `closeRequested` above instead of waiting
                // another unbounded stretch.
                continue
            }
            guard pfd.revents & Int16(POLLOUT) != 0 else {
                // POLLHUP / POLLERR / POLLNVAL without POLLOUT:
                // the peer is gone.
                throw HerdrTransportError.sendFailed("peer became unwritable (POLLHUP/POLLERR)")
            }
            return
        }
    }

    /// Per-iteration `poll(2)` timeout for `waitForWritability(fd:)` --
    /// deliberately finite (never `-1`/infinite), so `closeRequested` is
    /// re-checked at least this often instead of never. 200ms is a
    /// pragmatic, unmeasured choice: short enough that a concurrent
    /// `close()` is never noticeably delayed, long enough to not
    /// busy-poll a merely-slow (not actually stuck) peer.
    private static let writePollTimeoutMilliseconds: Int32 = 200

    /// Reads `closeRequested` under `closeRequestedLock` -- see that
    /// property's own doc comment for why it is a separate,
    /// non-`queue`-confined flag.
    private func isCloseRequested() -> Bool {
        closeRequestedLock.withLock { closeRequested }
    }

    // MARK: - Errno formatting

    private static func errnoMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
