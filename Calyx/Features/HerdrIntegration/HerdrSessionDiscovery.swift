// HerdrSessionDiscovery.swift
// Calyx
//
// Enumerates candidate herdr Unix-domain-socket locations and probes
// whether each is actually alive. A socket FILE surviving on disk does
// NOT mean a server is listening behind it -- a crashed herdr leaves
// the special file in place -- so liveness is ALWAYS a non-blocking
// BSD connect() probe, NEVER a bare stat()/fileExists() check.
// ECONNREFUSED (or any other connect failure) means dead.
//
// This is the first Swift-side Unix-domain-socket code in this
// codebase (CalyxMCPServer's own listener is AF_INET/loopback --
// there is no prior Unix-socket-client precedent anywhere else in
// this app).

import Darwin
import Foundation

/// One discovered (not yet liveness-checked) herdr socket location.
/// `name` is `"default"` for `<configRootDirectory>/herdr.sock` --
/// herdr's own term for this session: `herdr session list --json`
/// reports `"default":true,"name":"default"` for exactly this socket.
/// It is `nil` for the `HERDR_SOCKET_PATH` env-override candidate
/// (unless that override collides with an already-named candidate's
/// socket path, in which case dedup keeps the richer name -- see
/// `discover()`'s own doc comment), and the `sessions/` subdirectory's
/// own name for a named session.
struct HerdrSessionCandidate: Sendable, Equatable, Hashable {
    let name: String?
    let socketPath: String
}

protocol HerdrSessionDiscoveryProtocol: Sendable {
    /// Enumerates every candidate socket location. Does NOT check
    /// liveness -- a returned candidate may point at a dead or
    /// nonexistent socket; see `isAlive(socketPath:)`.
    func discover() -> [HerdrSessionCandidate]

    /// Non-blocking BSD `connect()` probe against `socketPath`. `true`
    /// only when a live listener actually accepts the connection.
    /// `false` for a missing path, a stale socket file with nothing
    /// listening (ECONNREFUSED), a path that isn't a socket at all, a
    /// caller whose surrounding `Task` was already cancelled before the
    /// probe ran, or any other connect failure. NEVER implemented via
    /// stat() / fileExists() -- see this file's header comment.
    func isAlive(socketPath: String) -> Bool
}

/// Production discovery.
///
/// `discover()`'s candidate set is the union of, ADDITIVELY (never one
/// replacing another):
///   1. The default session: `<configRootDirectory>/herdr.sock`
///      (`name: "default"`, herdr's own term for it -- see
///      `HerdrSessionCandidate`'s own doc comment) -- ALWAYS included,
///      even when `configRootDirectory` doesn't exist on disk.
///      `discover()` only constructs candidate PATHS; it never checks
///      existence itself (that would duplicate `isAlive`'s own job and
///      blur the two functions' separation of concerns) -- liveness
///      alone decides whether a candidate is ever surfaced to the user.
///   2. One candidate per existing subdirectory of
///      `<configRootDirectory>/sessions/` (`name:` the subdirectory's
///      own name, `socketPath:`
///      `<configRootDirectory>/sessions/<name>/herdr.sock`). Zero
///      candidates when `sessions/` doesn't exist. Non-directory
///      entries directly inside `sessions/` are skipped.
///   3. `environment["HERDR_SOCKET_PATH"]`, when present and
///      non-empty, as one more `name: nil` candidate alongside (not
///      instead of) the two sources above -- discovery's job is
///      finding every live session, and a replace-instead-of-add
///      semantics could hide real ones the directory scan already
///      found.
///
/// The union above is then deduped by `socketPath`, keeping the FIRST
/// occurrence in scan order (default candidate, then directory-scanned
/// named candidates, then the `HERDR_SOCKET_PATH` override last):
/// `HERDR_SOCKET_PATH` can legitimately coincide with either the
/// default candidate's own socket path or an already-discovered named
/// session's, and a later duplicate must never surface as a second row
/// for the same live session -- keeping the first occurrence also means
/// the default candidate's own `"default"` name, or a name from the
/// directory scan, is never overwritten by the override's own unnamed
/// (`nil`) shape.
///
/// `configRootDirectory` defaults to `~/.config/herdr` but is
/// injectable so tests never touch the real filesystem outside a
/// fixture temp directory (also never real system PATH-like defaults,
/// mirroring HerdrBinaryResolver's own reasoning).
struct HerdrSessionDiscovery: HerdrSessionDiscoveryProtocol {
    private let environment: [String: String]
    private let configRootDirectory: String

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configRootDirectory: String = NSHomeDirectory() + "/.config/herdr"
    ) {
        self.environment = environment
        self.configRootDirectory = configRootDirectory
    }

    func discover() -> [HerdrSessionCandidate] {
        var candidates: [HerdrSessionCandidate] = [
            HerdrSessionCandidate(name: "default", socketPath: configRootDirectory + "/herdr.sock"),
        ]

        let sessionsDirectory = configRootDirectory + "/sessions"
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: sessionsDirectory) {
            for entry in entries.sorted() {
                // Cooperative cancellation: a caller invoking discover()
                // directly from within a live Task (as
                // HerdrSessionDiscoveryTests does) needs its cancel() to
                // actually stop the scan, not just be ignored by a
                // plain synchronous loop. NOT observed by
                // HerdrCLISessionProvider.listSessions() in production:
                // that caller now runs discover() from
                // DispatchQueue.global() (see HerdrSessionProvider.swift's
                // own doc comment), off any ambient Task, so
                // Task.isCancelled always reads false there -- its own
                // explicit up-front Task.isCancelled guard, plus the
                // shared bounded-timeout race, are what keep that caller
                // safe instead.
                if Task.isCancelled { break }
                let entryPath = sessionsDirectory + "/" + entry
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: entryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                candidates.append(HerdrSessionCandidate(name: entry, socketPath: entryPath + "/herdr.sock"))
            }
        }

        if let override = environment["HERDR_SOCKET_PATH"], !override.isEmpty {
            candidates.append(HerdrSessionCandidate(name: nil, socketPath: override))
        }

        return Self.dedupBySocketPath(candidates)
    }

    /// Collapses `candidates` to at most one entry per `socketPath`,
    /// keeping the FIRST occurrence -- see `discover()`'s own doc
    /// comment above for why first-occurrence-wins is the right
    /// tie-break.
    private static func dedupBySocketPath(_ candidates: [HerdrSessionCandidate]) -> [HerdrSessionCandidate] {
        var seenSocketPaths = Set<String>()
        var deduped: [HerdrSessionCandidate] = []
        deduped.reserveCapacity(candidates.count)
        for candidate in candidates where seenSocketPaths.insert(candidate.socketPath).inserted {
            deduped.append(candidate)
        }
        return deduped
    }

    /// Bounded safety-net timeout (milliseconds) for
    /// `HerdrUnixSocket.connect`'s own `poll()`. A local AF_UNIX
    /// `SOCK_STREAM` `connect()` resolves synchronously in practice --
    /// either immediate success or an immediate failure errno
    /// (`ECONNREFUSED`/`ENOENT`/`ENOTSOCK`), verified empirically
    /// against real bound/listening, bound-only, regular-file, and
    /// missing-path fixtures -- so `EINPROGRESS` is not expected to ever
    /// actually happen here. This bound exists purely so a genuinely
    /// unexpected `EINPROGRESS` can never block `isAlive(socketPath:)`
    /// for more than a blink.
    private static let probeTimeoutMilliseconds: Int32 = 50

    func isAlive(socketPath: String) -> Bool {
        // Cooperative cancellation, checked before every probe: a
        // caller invoking isAlive(socketPath:) directly from within a
        // live Task (as HerdrSessionDiscoveryTests does) needs a
        // cancelled Task to make each remaining call return immediately
        // instead of still paying up to `probeTimeoutMilliseconds` per
        // candidate. NOT observed by HerdrCLISessionProvider
        // .listSessions() in production: that caller now runs this
        // filter from DispatchQueue.global() (see
        // HerdrSessionProvider.swift's own doc comment), off any
        // ambient Task, so Task.isCancelled always reads false there --
        // its own explicit up-front Task.isCancelled guard, plus the
        // shared bounded-timeout race, are what keep that caller safe
        // instead.
        guard !Task.isCancelled else { return false }

        guard let fd = HerdrUnixSocket.connect(socketPath: socketPath, timeoutMilliseconds: Self.probeTimeoutMilliseconds) else {
            return false
        }
        close(fd)
        return true
    }
}
