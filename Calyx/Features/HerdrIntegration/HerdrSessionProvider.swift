// HerdrSessionProvider.swift
// Calyx
//
// Abstraction over listing herdr sessions, so `SessionBrowserModel` can
// be tested with a fake instead of touching real PATH/socket state --
// mirrors `SessionDaemonClientProtocol`'s own injectable-dependency
// shape. The production conformer below, `HerdrCLISessionProvider`,
// composes `HerdrSessionDiscovery`'s socket enumeration + non-blocking
// connect probe (that type's own file, called here through its frozen
// protocol, never reimplemented). Optional CLI JSON enrichment stays
// out of Stage 1 entirely -- it depends on herdr exposing a JSON
// session-list subcommand, which hasn't been verified yet (see
// `HerdrCLISessionProvider`'s own doc comment).

import Foundation

protocol HerdrSessionProviderProtocol: Sendable {
    func listSessions() async -> [HerdrSessionInfo]
}

/// One herdr session as `SessionBrowserModel` needs it. `id` is the
/// session's Unix domain socket path -- herdr assigns no separate
/// session ID of its own to key rows on, so the socket path itself IS
/// the identity (mirrors `SessionInfo.id` being the calyx-session ULID,
/// just a different kind of stable string). `name`/`paneCount`/
/// `agentCount` are optional because Stage 1-C's own CLI JSON
/// enrichment is itself optional and not yet verified as available: a
/// degraded row (bare socket path, no enrichment) is always a valid
/// `HerdrSessionInfo`, never an error.
struct HerdrSessionInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let paneCount: Int?
    let agentCount: Int?
}

/// Production `HerdrSessionProviderProtocol`.
///
/// Stage 1: bare discovery + liveness only -- `discovery.discover()`'s
/// candidates, kept only when `discovery.isAlive(socketPath:)`, mapped
/// 1:1 onto `HerdrSessionInfo` (`id`/`name` straight from the
/// candidate; `paneCount`/`agentCount` always `nil` -- the optional CLI
/// JSON enrichment depends on herdr exposing a JSON session-list
/// subcommand, which hasn't been verified yet, so it isn't wired in
/// this stage). Neither `discover()` nor `isAlive(socketPath:)` throws,
/// so "a degraded row beats an error" (this type's own doc comment
/// above) holds structurally: a config directory that doesn't exist
/// yields `[]` from `discover()`, and a stale/crashed socket file
/// yields `false` from `isAlive(socketPath:)`, each flowing straight
/// through to an empty or shorter result -- never a thrown error to
/// swallow.
///
/// `listSessions()` runs the actual discover-then-filter-then-map work
/// on `DispatchQueue.global()` behind a `withCheckedContinuation`,
/// mirroring `SystemCommandRunner.locate(_:)`'s identical shape (a
/// short, bounded, non-throwing blocking probe with a
/// degrade-gracefully contract) -- so the caller's Task, which reaches
/// here through `SessionDaemonClientProtocol.bounded()`'s nonisolated
/// `operation` closure, never parks a Swift Concurrency cooperative-pool
/// thread inside `discover()`'s `FileManager` scan or
/// `isAlive(socketPath:)`'s blocking `connect()`/`poll()` (up to 50ms
/// per candidate). This is a deliberate trade: once the work is running
/// on that background queue there is no ambient `Task`, so
/// `discover()`'s and `isAlive(socketPath:)`'s own internal
/// `Task.isCancelled` checks (see `HerdrSessionDiscovery.swift`) are
/// inert on this path -- a caller cancelled mid-sweep no longer stops
/// the sweep early, it just discards the result once it arrives. That
/// is acceptable here: candidate counts are realistically 0-3, each
/// probe is hard-capped at `HerdrSessionDiscovery`'s own
/// `probeTimeoutMilliseconds` (50ms), and the whole call is already
/// raced against `SessionDaemonClientProtocol
/// .daemonQueryBoundTimeoutSeconds` by `SessionBrowserModel
/// .boundedHerdrListSessions()` -- a slow-to-cancel sweep degrades to
/// `[]` on that bound regardless. The cheap, still-live-Task part of the
/// contract -- an ALREADY cancelled caller does zero work -- is kept via
/// the explicit `Task.isCancelled` guard below, checked before ever
/// dispatching to the background queue.
///
/// `discovery` is a fixed `private let`, not an injectable init
/// parameter: no Stage 1 test exercises this type directly (its
/// correctness is a manual-smoke-test item, run against a real
/// `brew install`ed herdr, not a unit fixture), so adding a DI seam
/// here would be speculative surface no test needs.
final class HerdrCLISessionProvider: HerdrSessionProviderProtocol, Sendable {
    private let discovery: HerdrSessionDiscoveryProtocol = HerdrSessionDiscovery()

    init() {}

    func listSessions() async -> [HerdrSessionInfo] {
        guard !Task.isCancelled else { return [] }
        let discovery = self.discovery
        return await withCheckedContinuation { (continuation: CheckedContinuation<[HerdrSessionInfo], Never>) in
            DispatchQueue.global().async {
                let sessions = discovery.discover()
                    .filter { discovery.isAlive(socketPath: $0.socketPath) }
                    .map { candidate in
                        HerdrSessionInfo(id: candidate.socketPath, name: candidate.name, paneCount: nil, agentCount: nil)
                    }
                continuation.resume(returning: sessions)
            }
        }
    }
}
