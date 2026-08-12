// HerdrUnixSocket.swift
// Calyx
//
// Shared AF_UNIX connect(2) sequence for HerdrSessionDiscovery.isAlive,
// BSDHerdrTransport.connect, and HerdrSyncSnapshotFetch.fetch.

import Darwin

enum HerdrUnixSocket {
    /// Connects to `socketPath`. The returned descriptor is non-blocking
    /// and has SO_NOSIGPIPE set; the caller owns it and must close it.
    /// `nil` on any failure, including a connect that does not complete
    /// within `timeoutMilliseconds`.
    static func connect(socketPath: String, timeoutMilliseconds: Int32) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var noSigPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd)
            return nil
        }

        let pathBytes = Array(socketPath.utf8)
        var addr = sockaddr_un()
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < sunPathCapacity else {
            Darwin.close(fd)
            return nil
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

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            Darwin.close(fd)
            return nil
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                Darwin.close(fd)
                return nil
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMilliseconds) > 0, pfd.revents & Int16(POLLOUT) != 0 else {
                Darwin.close(fd)
                return nil
            }
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0, socketError == 0 else {
                Darwin.close(fd)
                return nil
            }
        }

        return fd
    }
}
