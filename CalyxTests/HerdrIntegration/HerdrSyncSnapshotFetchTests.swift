//
//  HerdrSyncSnapshotFetchTests.swift
//  CalyxTests
//
//  Regression coverage for HerdrSyncSnapshotFetch.fetch(socketPath:)
//  against a real, test-owned AF_UNIX fixture socket -- reproducing the
//  exact wire behavior measured against a live herdr 0.8.0 server: one
//  NDJSON response line, immediately followed by the peer closing the
//  connection (EOF), with no further bytes ever sent. `fetch` is
//  synchronous, so the fixture's own accept/read/write/close sequence
//  runs on a dedicated background thread while `fetch` blocks the
//  test's own thread, exactly like it blocks its real caller
//  (HerdrRestoreTerminalIDResolver, itself called synchronously from
//  AppDelegate's restore path).
//
//  Socket fixture helpers mirror HerdrTransportTests' own
//  bind-and-listen precedent verbatim (short /tmp-rooted path,
//  poll()-bounded accept/read, never a fixed sleep).
//

import Darwin
import XCTest
@testable import Calyx

final class HerdrSyncSnapshotFetchTests: XCTestCase {

    private enum FixtureError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pollFailed(Int32)
        case acceptFailed(Int32)
        case acceptTimedOut
        case readFailed(Int32)
        case readTimedOut
        case writeFailed(Int32)
        case setsockoptFailed(Int32)

        var description: String {
            switch self {
            case .pathTooLong(let detail): return "fixture socket path too long: \(detail)"
            case .socketCreateFailed(let e): return "socket() failed: errno \(e)"
            case .bindFailed(let e): return "bind() failed: errno \(e)"
            case .listenFailed(let e): return "listen() failed: errno \(e)"
            case .pollFailed(let e): return "poll() failed: errno \(e)"
            case .acceptFailed(let e): return "accept() failed: errno \(e)"
            case .acceptTimedOut: return "accept() saw no pending connection within the fixture deadline"
            case .readFailed(let e): return "recv() failed: errno \(e)"
            case .readTimedOut: return "did not see a full request line within the fixture deadline"
            case .writeFailed(let e): return "write() failed: errno \(e)"
            case .setsockoptFailed(let e): return "setsockopt() failed: errno \(e)"
            }
        }
    }

    /// Mirrors HerdrTransportTests' own `shortSocketFixtureRoot()`.
    private func shortSocketFixtureRoot() -> String {
        let suffix = String(UUID().uuidString.prefix(8))
        let path = "/tmp/hssf-\(suffix)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Mirrors HerdrTransportTests' own `bindAndListenUnixSocketFixture(at:backlog:)`.
    private func bindAndListenUnixSocketFixture(at path: String, backlog: Int32 = 1) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 100 else {
            throw FixtureError.pathTooLong(
                "\(pathBytes.count) bytes (limit ~100 to stay under sockaddr_un's 104-byte sun_path): \(path)"
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.socketCreateFailed(errno) }

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
            Darwin.close(fd)
            throw FixtureError.bindFailed(bindErrno)
        }

        guard listen(fd, backlog) == 0 else {
            let listenErrno = errno
            Darwin.close(fd)
            throw FixtureError.listenFailed(listenErrno)
        }

        return fd
    }

    private func pollReadable(fd: Int32, timeoutMilliseconds: Int32) throws -> Bool {
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&pfd, 1, timeoutMilliseconds)
            if result < 0 {
                let pollErrno = errno
                if pollErrno == EINTR { continue }
                throw FixtureError.pollFailed(pollErrno)
            }
            return result > 0 && (pfd.revents & Int16(POLLIN) != 0)
        }
    }

    private func acceptOnePeer(listenerFD: Int32, deadlineSeconds: Double = 5.0) throws -> Int32 {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            if try pollReadable(fd: listenerFD, timeoutMilliseconds: 100) {
                let peerFD = accept(listenerFD, nil, nil)
                if peerFD >= 0 { return peerFD }
                let acceptErrno = errno
                if acceptErrno == EINTR || acceptErrno == EAGAIN || acceptErrno == EWOULDBLOCK { continue }
                throw FixtureError.acceptFailed(acceptErrno)
            }
        }
        throw FixtureError.acceptTimedOut
    }

    /// Reads from `fd` via a bounded, repeated `poll(2)` + `recv(2)` loop
    /// until a "\n"-terminated line has arrived, returning it WITHOUT the
    /// trailing newline. Only used to drain `fetch`'s own request line
    /// before the fixture writes its response.
    private func readRequestLine(from fd: Int32, deadlineSeconds: Double = 5.0) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            guard try pollReadable(fd: fd, timeoutMilliseconds: 100) else { continue }
            let bytesRead = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if bytesRead > 0 {
                collected.append(contentsOf: buffer[0..<bytesRead])
                if let newlineIndex = collected.firstIndex(of: UInt8(ascii: "\n")) {
                    return String(data: collected[collected.startIndex..<newlineIndex], encoding: .utf8) ?? ""
                }
                continue
            }
            if bytesRead == 0 { break } // peer closed before a full line arrived
            let readErrno = errno
            if readErrno == EINTR || readErrno == EAGAIN || readErrno == EWOULDBLOCK { continue }
            throw FixtureError.readFailed(readErrno)
        }
        throw FixtureError.readTimedOut
    }

    /// Mirrors HerdrTransportTests' own `writeAll(_:to:)`.
    @discardableResult
    private func writeAll(_ data: Data, to fd: Int32) throws -> Int {
        var written = 0
        let total = data.count
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n > 0 {
                    written += n
                    continue
                }
                let writeErrno = errno
                if n < 0, writeErrno == EINTR { continue }
                throw FixtureError.writeFailed(n == 0 ? 0 : writeErrno)
            }
        }
        return written
    }

    /// Guards an `Error?` set from the fixture's background queue and
    /// read from the test's own thread after `fetch` returns -- mirrors
    /// HerdrSessionDiscoveryTests' own `ContinuationGate` reasoning for
    /// why a small NSLock-guarded box, not actor isolation, is the right
    /// tool for state crossing a bare `DispatchQueue` closure boundary.
    private final class FixtureOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?

        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            self.error = error
        }

        var failure: Error? {
            lock.lock(); defer { lock.unlock() }
            return error
        }
    }

    // MARK: - Regression: one response line, then the peer closes immediately

    /// Pins the exact defect measured against a live herdr 0.8.0 server:
    /// `fetch` returned `nil` on every call because the RPC envelope's
    /// own `snapshot` wrapper was never stripped. This fixture reproduces
    /// the real server's own framing exactly (one NDJSON line, then the
    /// peer closes with no further bytes), so a regression that only
    /// breaks against a live herdr process fails here too. A readiness
    /// handshake gates the call to `fetch` until the fixture thread is
    /// already polling for a connection, so the client's own deadline
    /// never has to absorb the fixture thread's startup latency.
    func test_fetch_decodesSnapshot_whenPeerSendsOneLineThenClosesImmediately() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        // Only the schema's REQUIRED fields for HerdrSessionSnapshot
        // (version, protocol, workspaces, tabs, panes, layouts, agents)
        // and HerdrPaneRecord (terminal_id, agent_status, workspace_id,
        // tab_id, pane_id, focused, revision).
        let responseLine = #"{"id":"1","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"workspaces":[],"tabs":[],"panes":[{"terminal_id":"term_abc123","agent_status":"unknown","workspace_id":"wA","tab_id":"wA:t1","pane_id":"wA:p1","focused":true,"revision":1}],"layouts":[],"agents":[]}}}"#

        let outcome = FixtureOutcome()
        let readySemaphore = DispatchSemaphore(value: 0)
        let semaphore = DispatchSemaphore(value: 0)
        let peerThread = Thread {
            readySemaphore.signal()
            defer { semaphore.signal() }
            do {
                let peerFD = try self.acceptOnePeer(listenerFD: listenerFD)
                defer { Darwin.close(peerFD) } // closes right after writing -- see this test's own doc comment
                _ = try self.readRequestLine(from: peerFD)
                try self.writeAll(Data((responseLine + "\n").utf8), to: peerFD)
            } catch {
                outcome.fail(error)
            }
        }
        peerThread.name = "HerdrSyncSnapshotFetchTests.oneLineThenClosePeer"
        peerThread.qualityOfService = .userInitiated
        peerThread.start()

        XCTAssertEqual(
            readySemaphore.wait(timeout: .now() + 5), .success,
            "fixture peer thread did not signal readiness before starting its accept poll"
        )

        let snapshot = HerdrSyncSnapshotFetch.fetch(socketPath: socketPath)

        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success, "fixture peer did not finish within the deadline")
        if let failure = outcome.failure {
            XCTFail("fixture peer failed: \(failure)")
        }

        let resolved = try XCTUnwrap(
            snapshot,
            "fetch(socketPath:) must decode a real snapshot from a single NDJSON response line immediately " +
            "followed by the peer closing the connection -- exactly what a real herdr server does"
        )
        XCTAssertEqual(resolved.version, "0.8.0")
        XCTAssertEqual(resolved.panes.count, 1)
        XCTAssertEqual(resolved.panes.first?.paneID, "wA:p1")
        XCTAssertEqual(resolved.panes.first?.terminalID, "term_abc123")
    }

    // MARK: - Regression: a trickling peer must never hold fetch open past its own deadline

    /// A peer that accepts the connection, drains the request, then
    /// trickles response bytes one at a time and NEVER sends a
    /// terminating "\n" is exactly what SO_SNDTIMEO/SO_RCVTIMEO alone
    /// cannot bound on Darwin: `man 2 setsockopt` documents that timer
    /// as an INACTIVITY timer, restarted by every byte received, so a
    /// fixed per-call value lets such a peer hold a read open
    /// indefinitely. Pins `fetch`'s own hard write+read deadline (see
    /// HerdrSyncSnapshotFetch.swift's own header "TIMEOUTS"): `fetch`
    /// must return `nil` in well under 2 seconds regardless of how long
    /// the peer keeps trickling. A readiness handshake gates both the
    /// call to `fetch` and the start of this test's own elapsed-time
    /// measurement until the fixture thread is already polling for a
    /// connection, so neither absorbs the fixture thread's startup
    /// latency.
    func test_fetch_returnsNilWithinBound_whenPeerTricklesBytesWithoutNewlineOrClose() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let outcome = FixtureOutcome()
        let readySemaphore = DispatchSemaphore(value: 0)
        let semaphore = DispatchSemaphore(value: 0)
        let peerThread = Thread {
            readySemaphore.signal()
            defer { semaphore.signal() }
            do {
                let peerFD = try self.acceptOnePeer(listenerFD: listenerFD)
                defer { Darwin.close(peerFD) }
                // This fixture keeps writing after `fetch` is expected
                // to have already closed its end (see
                // trickleWithoutNewlineOrClose's own doc comment):
                // without SO_NOSIGPIPE, that write raises SIGPIPE and
                // kills the whole test process, not just this one call.
                var noSigPipe: Int32 = 1
                guard setsockopt(peerFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw FixtureError.setsockoptFailed(errno)
                }
                _ = try self.readRequestLine(from: peerFD)
                self.trickleWithoutNewlineOrClose(to: peerFD)
            } catch {
                outcome.fail(error)
            }
        }
        peerThread.name = "HerdrSyncSnapshotFetchTests.tricklingPeer"
        peerThread.qualityOfService = .userInitiated
        peerThread.start()

        XCTAssertEqual(
            readySemaphore.wait(timeout: .now() + 5), .success,
            "fixture peer thread did not signal readiness before starting its accept poll"
        )

        let start = DispatchTime.now()
        let snapshot = HerdrSyncSnapshotFetch.fetch(socketPath: socketPath)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success, "fixture peer did not finish within the deadline")
        if let failure = outcome.failure {
            XCTFail("fixture peer failed: \(failure)")
        }

        XCTAssertNil(snapshot, "a peer that never terminates a line must resolve to fetch's own nil failure contract")
        XCTAssertLessThan(
            elapsedSeconds, 2.0,
            "fetch(socketPath:) must respect its own hard write+read deadline regardless of how long the peer " +
            "keeps trickling data without a terminating newline; got \(elapsedSeconds)s"
        )
    }

    /// Writes one byte at a time, 50ms apart, never a "\n" -- see this
    /// test's own doc comment. Hard-capped at 60 iterations (3s),
    /// comfortably past the 2s bound that test asserts on `fetch`'s own
    /// elapsed time: purely a test-hygiene safety net so this fixture
    /// thread cannot itself run forever if `fetch`'s own deadline is not
    /// actually enforced. `fetch` is expected to return and close its
    /// end in well under 1 second; the next write here then fails and
    /// this loop exits immediately, long before the cap is ever reached.
    private func trickleWithoutNewlineOrClose(to fd: Int32) {
        let hardStopIterationCount = 60
        let byte: [UInt8] = [UInt8(ascii: "x")]
        for _ in 0..<hardStopIterationCount {
            let wrote = byte.withUnsafeBytes { raw -> Bool in
                while true {
                    let n = Darwin.write(fd, raw.baseAddress, 1)
                    if n > 0 { return true }
                    if n < 0, errno == EINTR { continue }
                    return false // fetch already closed its end, or a genuine write error
                }
            }
            guard wrote else { return }
            usleep(50_000)
        }
    }
}
