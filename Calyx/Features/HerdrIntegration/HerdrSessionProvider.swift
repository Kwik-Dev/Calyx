// HerdrSessionProvider.swift
// Calyx
//
// Abstraction over listing herdr sessions, so `SessionBrowserModel` can
// be tested with a fake instead of touching real PATH/socket state --
// mirrors `SessionDaemonClientProtocol`'s own injectable-dependency
// shape. The production conformer below, `HerdrCLISessionProvider`,
// composes `HerdrSessionDiscovery`'s socket enumeration + non-blocking
// connect probe (that type's own file, called here through its frozen
// protocol, never reimplemented) for identity and liveness, then one
// `session.snapshot` request per alive socket (`HerdrConnection.swift`'s
// one-shot request path) for workspace/pane/agent counts -- the same
// request `SessionBrowserWindowController.attachHerdr(_:)` already sends
// to learn a row's live workspaces. herdr also exposes a JSON
// session-list subcommand (`herdr session list --json`, verified against
// real herdr 0.8.0); this provider still never shells out to it.

import Foundation

protocol HerdrSessionProviderProtocol: Sendable {
    func listSessions() async -> [HerdrSessionInfo]
}

/// One herdr session as `SessionBrowserModel` needs it. `id` is the
/// session's Unix domain socket path -- herdr assigns no separate
/// session ID of its own to key rows on, so the socket path itself IS
/// the identity (mirrors `SessionInfo.id` being the calyx-session ULID,
/// just a different kind of stable string). `name` is optional because
/// the `HERDR_SOCKET_PATH` env-override candidate carries none of its
/// own (see `HerdrSessionDiscovery`'s own doc comment).
///
/// `workspaceCount`/`paneCount`/`agentCount` come from one
/// `session.snapshot` request per socket
/// (`HerdrCLISessionProvider.fetchCounts(socketPath:)`) and are always
/// populated together, or left `nil` together when that request fails or
/// never answers -- a socket `discovery.isAlive(socketPath:)` already
/// confirmed alive still produces a row in that case, just with unknown
/// counts: a degraded row is always a valid `HerdrSessionInfo`, never an
/// error.
struct HerdrSessionInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let workspaceCount: Int?
    let paneCount: Int?
    let agentCount: Int?
}

/// One socket's workspace/pane/agent counts, derived from a single
/// `session.snapshot` -- see `HerdrCLISessionProvider.fetchCounts(socketPath:)`.
private struct HerdrSessionCounts: Equatable {
    let workspaceCount: Int
    let paneCount: Int
    let agentCount: Int
}

/// Production `HerdrSessionProviderProtocol`.
///
/// `listSessions()` runs in two phases.
///
/// Phase 1: `discovery.discover()`'s candidates, kept only when
/// `discovery.isAlive(socketPath:)`. Neither throws, so "a degraded row
/// beats an error" (`HerdrSessionInfo`'s own doc comment) holds
/// structurally: a config directory that doesn't exist yields `[]` from
/// `discover()`, and a stale/crashed socket file yields `false` from
/// `isAlive(socketPath:)`, each flowing straight through to an empty or
/// shorter candidate list -- never a thrown error to swallow. Both are
/// blocking calls, run on `DispatchQueue.global()` behind a
/// `withCheckedContinuation`, mirroring `SystemCommandRunner.locate(_:)`'s
/// identical shape, so the caller's Task never parks a Swift Concurrency
/// cooperative-pool thread inside `discover()`'s `FileManager` scan or
/// `isAlive(socketPath:)`'s blocking `connect()`/`poll()` (up to 50ms per
/// candidate). Once this phase is running on that background queue there
/// is no ambient `Task`, so `discover()`'s and `isAlive(socketPath:)`'s
/// own internal `Task.isCancelled` checks (see `HerdrSessionDiscovery.swift`)
/// are inert on this path -- a caller cancelled mid-sweep no longer stops
/// the sweep early, it just discards the result once it arrives. That is
/// acceptable here: candidate counts are realistically 0-3, and each
/// probe is hard-capped at `HerdrSessionDiscovery`'s own
/// `probeTimeoutMilliseconds` (50ms). The explicit `Task.isCancelled`
/// guards in `listSessions()` below (before ever dispatching to the
/// background queue, and again once phase 1 returns) keep the cheap part
/// of the contract -- an ALREADY cancelled caller does zero work --
/// without needing to reach into that inert internal check.
///
/// Phase 2: one `session.snapshot` request per candidate phase 1 kept
/// (`fetchCounts(socketPath:)`), sequentially. Unlike phase 1, this needs
/// no manual `DispatchQueue` hop -- `HerdrOneShotRequest`/
/// `BSDHerdrTransport` are already non-blocking Swift Concurrency
/// (`BSDHerdrTransport`'s own doc comment). Sequential, not concurrent:
/// simpler, and fine at these candidate counts -- even three stalled
/// sockets, each eating `fetchCounts(socketPath:)`'s own `snapshotTimeout`
/// bound in full, still land under the 5s `daemonQueryBoundTimeoutSeconds`
/// that `SessionBrowserModel.boundedHerdrListSessions()` races this whole
/// call against. A candidate whose snapshot fails or times out still
/// becomes a row -- see `HerdrSessionInfo`'s own doc comment -- only its
/// counts stay `nil`.
///
/// `discovery`/`transportFactory` are injectable (production defaults:
/// `HerdrSessionDiscovery()` / `LiveHerdrTransportFactory()`), so tests
/// can drive both phases with fakes -- see `HerdrSessionProviderTests.swift`.
final class HerdrCLISessionProvider: HerdrSessionProviderProtocol, Sendable {
    private let discovery: any HerdrSessionDiscoveryProtocol
    private let transportFactory: any HerdrTransportFactory

    init(
        discovery: any HerdrSessionDiscoveryProtocol = HerdrSessionDiscovery(),
        transportFactory: any HerdrTransportFactory = LiveHerdrTransportFactory()
    ) {
        self.discovery = discovery
        self.transportFactory = transportFactory
    }

    func listSessions() async -> [HerdrSessionInfo] {
        guard !Task.isCancelled else { return [] }
        let discovery = self.discovery
        let candidates: [HerdrSessionCandidate] = await withCheckedContinuation { (continuation: CheckedContinuation<[HerdrSessionCandidate], Never>) in
            DispatchQueue.global().async {
                let alive = discovery.discover().filter { discovery.isAlive(socketPath: $0.socketPath) }
                continuation.resume(returning: alive)
            }
        }
        guard !Task.isCancelled else { return [] }

        var sessions: [HerdrSessionInfo] = []
        sessions.reserveCapacity(candidates.count)
        for candidate in candidates {
            let counts = await fetchCounts(socketPath: candidate.socketPath)
            sessions.append(
                HerdrSessionInfo(
                    id: candidate.socketPath,
                    name: candidate.name,
                    workspaceCount: counts?.workspaceCount,
                    paneCount: counts?.paneCount,
                    agentCount: counts?.agentCount
                )
            )
        }
        return sessions
    }

    /// One socket's counts, or `nil` on any failure -- an RPC error or a
    /// transport EOF/failure, both via the `do`/`catch` below (the same
    /// shape `SessionBrowserWindowController.attachHerdr(_:)` uses for
    /// this identical request), or `snapshotTimeout` expiry.
    ///
    /// `HerdrOneShotRequest.send` itself has no timeout (see
    /// HerdrConnection.swift): a server that accepts the connection and
    /// then never answers would hang this call forever without
    /// `watchdog`. Closing `transport` on expiry unblocks whichever read
    /// `send` is suspended in -- a clean `.eof`, landing in the same
    /// `catch` as any other failure -- exactly like
    /// `HerdrIntegrationCoordinator`'s own per-step handshake deadline
    /// (`runWithDeadline(transport:operation:)`). `close()` is idempotent
    /// and `send` already closes the transport on every exit path, so
    /// `watchdog` firing after `send` already finished (the common case
    /// -- cancelled by `defer` below before that can happen) is
    /// harmless.
    private func fetchCounts(socketPath: String) async -> HerdrSessionCounts? {
        let transport = await transportFactory.makeTransport()
        let watchdog = Task {
            try? await Task.sleep(for: Self.snapshotTimeout)
            guard !Task.isCancelled else { return }
            await transport.close()
        }
        defer { watchdog.cancel() }

        let snapshotResult: HerdrSnapshotRPCResult
        do {
            let request = HerdrOneShotRequest(transport: transport)
            snapshotResult = try await request.send(method: "session.snapshot", socketPath: socketPath)
        } catch {
            return nil
        }

        let panes = snapshotResult.snapshot.panes
        return HerdrSessionCounts(
            workspaceCount: Set(panes.map(\.workspaceID)).count,
            paneCount: panes.count,
            agentCount: snapshotResult.snapshot.agents.count
        )
    }

    /// Per-socket bound for `fetchCounts(socketPath:)` -- see that
    /// method's own doc comment. 1s: a local Unix-socket
    /// `session.snapshot` measures well under 100ms against a healthy
    /// server (comparable to `HerdrIntegrationCoordinator`'s own measured
    /// replay-burst timing), so this only ever matters against a
    /// genuinely stalled server, and stays well inside the sequential
    /// sweep's own budget described above.
    private static let snapshotTimeout: Duration = .seconds(1)
}
