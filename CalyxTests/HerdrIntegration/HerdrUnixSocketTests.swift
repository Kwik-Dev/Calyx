//  HerdrUnixSocketTests.swift
//  CalyxTests
//
//  Coverage for HerdrUnixSocket.connect against real AF_UNIX fixtures.

import Darwin
import XCTest
@testable import Calyx

final class HerdrUnixSocketTests: XCTestCase {

    private enum FixtureError: Error, CustomStringConvertible {
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

    private let fixtureConnectTimeoutMilliseconds: Int32 = 200

    /// A short `/tmp`-rooted directory, far under sockaddr_un.sun_path's 104-byte limit.
    private func shortSocketFixtureRoot() -> String {
        let suffix = String(UUID().uuidString.prefix(8))
        let path = "/tmp/hus-\(suffix)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Binds (and, when `listenBacklog` is non-nil, listens on) an
    /// AF_UNIX socket at `path` (caller closes the fd); nil simulates a crashed server.
    @discardableResult
    private func bindUnixSocketFixture(at path: String, listenBacklog: Int32?) throws -> Int32 {
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

        if let listenBacklog {
            guard listen(fd, listenBacklog) == 0 else {
                let listenErrno = errno
                Darwin.close(fd)
                throw FixtureError.listenFailed(listenErrno)
            }
        }

        return fd
    }

    // MARK: - Live listener

    func test_connect_toLiveListener_returnsDescriptor() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        defer { Darwin.close(listenerFD) }

        let fd = HerdrUnixSocket.connect(socketPath: socketPath, timeoutMilliseconds: fixtureConnectTimeoutMilliseconds)

        let resolved = try XCTUnwrap(fd, "connect() to a live bound-and-listening socket must return a descriptor")
        Darwin.close(resolved)
    }

    func test_connect_toLiveListener_returnsNonBlockingDescriptorWithSONOSIGPIPESet() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        defer { Darwin.close(listenerFD) }

        let fd = try XCTUnwrap(
            HerdrUnixSocket.connect(socketPath: socketPath, timeoutMilliseconds: fixtureConnectTimeoutMilliseconds)
        )
        defer { Darwin.close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        XCTAssertGreaterThanOrEqual(flags, 0, "fcntl(F_GETFL) must succeed on the returned descriptor")
        XCTAssertNotEqual(flags & O_NONBLOCK, 0, "the returned descriptor must be non-blocking")

        var noSigPipe: Int32 = 0
        var noSigPipeLength = socklen_t(MemoryLayout<Int32>.size)
        let getResult = getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &noSigPipeLength)
        XCTAssertEqual(getResult, 0, "getsockopt(SO_NOSIGPIPE) must succeed on the returned descriptor")
        XCTAssertNotEqual(noSigPipe, 0, "the returned descriptor must have SO_NOSIGPIPE set")
    }

    // MARK: - Failure paths

    func test_connect_nonexistentSocketPath_returnsNil() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/never-created.sock"

        let fd = HerdrUnixSocket.connect(socketPath: socketPath, timeoutMilliseconds: fixtureConnectTimeoutMilliseconds)

        XCTAssertNil(fd, "connect() to a path with no socket file at all must return nil")
    }

    func test_connect_staleSocketFileWithNoListener_returnsNil() throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let boundFD = try bindUnixSocketFixture(at: socketPath, listenBacklog: nil)
        Darwin.close(boundFD) // simulate the server dying: fd closed, socket special file left behind

        let fd = HerdrUnixSocket.connect(socketPath: socketPath, timeoutMilliseconds: fixtureConnectTimeoutMilliseconds)

        XCTAssertNil(fd, "connect() to a stale socket file with nothing listening (ECONNREFUSED) must return nil")
    }

    func test_connect_pathLongerThanSunPathCanHold_returnsNil() {
        let overlong = "/tmp/" + String(repeating: "x", count: 200) + "/herdr.sock"

        let fd = HerdrUnixSocket.connect(socketPath: overlong, timeoutMilliseconds: fixtureConnectTimeoutMilliseconds)

        XCTAssertNil(fd, "connect() to a path longer than sockaddr_un.sun_path can hold must return nil")
    }
}
