// HerdrSyncSnapshotFetch.swift
// Calyx
//
// Bounded, SYNCHRONOUS `session.snapshot` fetch used ONLY by
// AppDelegate's herdr-restore path (HerdrRestoreTerminalIDResolver.swift)
// to resolve a herdr-bridged leaf's TERMINAL id at restore time -- see
// HerdrRestoreCommandPolicy.swift's own header for why a fresh, live
// lookup (never a value persisted in an earlier launch's sessions.json)
// is what keeps HerdrPaneRef's identity honest across a herdr restart:
// terminal ids are NOT stable across one, so a stale persisted value
// could silently build a bridge command aimed at a terminal that no
// longer exists (or, astronomically unlikely but not provably
// impossible, now belongs to something else entirely) -- resolving
// fresh here means an unresolvable pane simply has no map entry, which
// HerdrRestoreCommandPolicy.decide already has a home for
// (.plainShellAndPrune via a nil terminalID), rather than a silently
// wrong attach.
//
// Deliberately NOT the existing async HerdrOneShotRequest/
// BSDHerdrTransport pair (HerdrConnection.swift/HerdrTransport.swift):
// AppDelegate's own snapshot-restore call graph (restoreSession ->
// restoreWindow -> restoreTabSurfaces -> createSurfaceWithPwd) is, by
// design, a synchronous, bounded call chain rooted in
// `applicationDidFinishLaunching`, a fixed-signature, non-`async`
// NSApplicationDelegate callback -- and `restoreWindow`'s own "nothing
// restored yet -> the safety net creates a blank window"
// fallback (`AppDelegate.applicationDidFinishLaunching`, the
// `windowControllers.isEmpty` check right after `restoreSession()`)
// depends on restoration having ALREADY happened, synchronously, by the
// time that check runs -- making any part of this call graph `async`
// (awaited from a `Task`) would let that safety net's own check run
// concurrently with (on most schedules, BEFORE) restoration ever
// finishes, spuriously creating a second, blank window alongside the
// real restored one. Mirrors HerdrSessionDiscovery.isAlive(socketPath:)'s
// own identical choice, and for the same reason (that file's own
// header): a raw, bounded Darwin BSD-socket call, not `async`/`await`.
//
// Reuses HerdrConnectionWire's own requestLine/decodeResult and
// HerdrEmptyParams -- see HerdrConnection.swift -- so the wire ENVELOPE
// shape (the request line's own {"id":..,"method":..,"params":{}}
// shape; the response's own "result"/"error" probe) is defined in
// exactly one place, never duplicated. The connect phase is
// HerdrUnixSocket.connect (HerdrUnixSocket.swift); only the write/read
// loop below is new, hand-rolled Darwin BSD socket code, since isAlive
// never sends or reads anything -- it only confirms accept().
//
// TIMEOUTS: `connectTimeoutMilliseconds` (50ms) is IDENTICAL to
// HerdrSessionDiscovery.isAlive's own `probeTimeoutMilliseconds`, and
// for the identical reason (that type's own doc comment): a local
// AF_UNIX SOCK_STREAM connect() resolves synchronously in practice, so
// this bound is a safety net for an EINPROGRESS that is not expected to
// ever actually happen, not a real budget. `readTimeoutMilliseconds`
// (500ms) bounds the write-then-read phase together as ONE hard
// monotonic deadline, enforced purely by a per-call poll(2) timeout on
// a socket kept non-blocking for its whole lifetime, never
// SO_SNDTIMEO/SO_RCVTIMEO. Measured: that socket option is an
// INACTIVITY timer restarted by every byte sent/received (man 2
// setsockopt), so a static value cannot bound a peer that trickles
// data forever. Also measured: once a peer has close()d, Darwin
// refuses setsockopt() on the still-open local end with EINVAL even
// though the peer's already-written bytes remain readable via
// recv(2), which would wrongly fail a fast peer that had already
// responded and closed. 500ms is a deliberately generous, unmeasured
// bound for that local round trip (a session.snapshot response is not
// expected to approach this on any real machine), chosen so a
// launch-time restore with herdr installed but genuinely unresponsive
// adds well under a second, never hangs indefinitely. This bounded
// timeout is exactly the "cannot resolve a terminal id for this ref"
// outcome HerdrRestoreCommandPolicy.decide already treats as
// .plainShellAndPrune -- not a new user-visible failure mode.
//
// SO_NOSIGPIPE (set by HerdrUnixSocket.connect): load-bearing, not
// decorative -- a write(2) to a peer that has already closed its end
// raises SIGPIPE on Darwin absent this option, which (uncaught)
// terminates the WHOLE host process, not just this one fetch.

import Darwin
import Foundation

enum HerdrSyncSnapshotFetch {

    /// See this file's header "TIMEOUTS".
    private static let connectTimeoutMilliseconds: Int32 = 50
    private static let readTimeoutMilliseconds: Int32 = 500

    /// Hostile/runaway-response safety cap on the accumulated read
    /// buffer -- never expected to trigger against a real herdr server
    /// (a session.snapshot response is not expected to approach this),
    /// purely defensive against a peer that never sends a terminating
    /// "\n" at all.
    private static let maxResponseBytes = 4 * 1024 * 1024

    /// Connects to `socketPath`, sends one `session.snapshot` request
    /// (`{"id":..,"method":"session.snapshot","params":{}}` -- see
    /// HerdrConnection.swift's own header, fact 1), and returns the
    /// decoded `HerdrSessionSnapshot` -- or `nil` on ANY failure (socket
    /// construction, connect (including a bounded timeout), write, read
    /// (including a bounded timeout), a malformed/non-UTF8 line, herdr's
    /// own RPC `error` response, or a decode failure). Every failure
    /// mode collapses to this same `nil` -- there is nothing more
    /// specific for this type's only caller
    /// (HerdrRestoreTerminalIDResolver) to react to differently; each
    /// already treats "could not resolve a terminal id for this ref"
    /// identically regardless of why.
    static func fetch(socketPath: String) -> HerdrSessionSnapshot? {
        guard let fd = HerdrUnixSocket.connect(socketPath: socketPath, timeoutMilliseconds: connectTimeoutMilliseconds) else {
            return nil
        }
        defer { close(fd) }

        // Single hard monotonic deadline for the write+read phase below
        // -- see this file's header "TIMEOUTS".
        let deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC) + UInt64(readTimeoutMilliseconds) * 1_000_000

        guard let requestLine = try? HerdrConnectionWire.requestLine(
            id: UUID().uuidString, method: "session.snapshot", params: HerdrEmptyParams()
        ) else {
            return nil
        }
        var payload = Data(requestLine.utf8)
        payload.append(UInt8(ascii: "\n"))
        guard writeAll(payload, to: fd, deadline: deadline) else { return nil }

        guard let line = readLine(from: fd, deadline: deadline) else { return nil }

        // Binds `result` to the concrete, non-optional
        // `HerdrSnapshotRPCResult` via do/catch, never `try?` returned
        // directly: `decodeResult<Result: Decodable>` is generic, and a
        // `try?`-flattened binding can let `Result` infer as
        // `HerdrSnapshotRPCResult?` instead (SE-0230) -- avoided by
        // naming the concrete type explicitly.
        do {
            let result: HerdrSnapshotRPCResult = try HerdrConnectionWire.decodeResult(from: line)
            return result.snapshot
        } catch {
            return nil
        }
    }

    /// Milliseconds remaining until `deadline` (a
    /// `clock_gettime_nsec_np(CLOCK_MONOTONIC)` timestamp), or `nil` once
    /// none remain -- recomputed before every `poll(2)` in `writeAll`/
    /// `readLine` so neither loop can outlive `deadline` (see this
    /// file's header "TIMEOUTS").
    private static func remainingMilliseconds(until deadline: UInt64) -> Int32? {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        guard now < deadline else { return nil }
        let remaining = (deadline - now) / 1_000_000
        return remaining > 0 ? Int32(remaining) : nil
    }

    /// Writes `payload` to `fd` in full, bounded overall by `deadline`:
    /// each `write(2)` is gated by a `poll(2)` timed to the time
    /// remaining until `deadline` (via `remainingMilliseconds`), so a
    /// peer that accepts only a few bytes at a time can never hold this
    /// loop open past it. `false` once `deadline` has passed, on a poll
    /// timeout/error, on `POLLERR`/`POLLNVAL`/`POLLHUP`, on a short
    /// write (0 bytes -- the peer closed its read side), or any errno
    /// other than EAGAIN/EWOULDBLOCK/EINTR (including SIGPIPE converted
    /// to EPIPE -- see this file's header "SO_NOSIGPIPE").
    private static func writeAll(_ payload: Data, to fd: Int32, deadline: UInt64) -> Bool {
        payload.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            var written = 0
            let total = payload.count
            while written < total {
                guard let timeoutMilliseconds = remainingMilliseconds(until: deadline) else { return false }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(&pfd, 1, timeoutMilliseconds)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard pollResult > 0, pfd.revents & Int16(POLLERR | POLLNVAL | POLLHUP) == 0 else { return false }
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n == 0 { return false }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Reads until a "\n"-terminated line arrives, bounded overall by
    /// `deadline`: each `recv(2)` is gated by a `poll(2)` timed to the
    /// time remaining until `deadline` (via `remainingMilliseconds`), so
    /// a peer that trickles a few bytes at a time and never sends a
    /// terminating "\n" can never hold this loop open past it.
    /// `POLLHUP` alone does not fail the poll -- a peer that wrote a
    /// response and closed sets it while the data is still readable --
    /// so only `POLLERR`/`POLLNVAL` do. Also bounded by
    /// `maxResponseBytes` overall (see this file's header). `nil` once
    /// `deadline` has passed, on a poll error, on a clean EOF before a
    /// full line arrives, any errno other than EAGAIN/EWOULDBLOCK/EINTR,
    /// or the accumulated buffer exceeding `maxResponseBytes` without
    /// ever finding "\n".
    private static func readLine(from fd: Int32, deadline: UInt64) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while buffer.count < maxResponseBytes {
            guard let timeoutMilliseconds = remainingMilliseconds(until: deadline) else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pfd, 1, timeoutMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard pollResult > 0, pfd.revents & Int16(POLLERR | POLLNVAL) == 0 else { return nil }
            let bytesRead = chunk.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if bytesRead > 0 {
                if let newlineIndex = chunk[0..<bytesRead].firstIndex(of: UInt8(ascii: "\n")) {
                    buffer.append(contentsOf: chunk[0..<newlineIndex])
                    return String(data: buffer, encoding: .utf8)
                }
                buffer.append(contentsOf: chunk[0..<bytesRead])
                continue
            }
            if bytesRead == 0 { return nil } // EOF before a full line arrived
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
            return nil
        }
        return nil
    }
}
