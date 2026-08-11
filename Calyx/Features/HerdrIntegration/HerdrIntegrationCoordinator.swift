// HerdrIntegrationCoordinator.swift
// Calyx
//
// @MainActor lifecycle owner for the herdr Stage 2 connection: detects
// herdr, opens/subscribes/snapshots a `HerdrSocketSession`, keeps
// `HerdrAgentMirror` in sync with pushed events, and rebuilds or
// reconnects the connection as the pane set or transport health
// changes. Every dependency is injected (binary resolver, discovery, a
// session factory, the mirror) so this file's own tests never open a
// real socket -- see HerdrIntegrationCoordinatorTests.swift.
//
// LIFECYCLE: driven ENTIRELY by explicit calls to `start()` from
// outside (app launch / app became active / Agents sidebar became
// visible -- wiring those call sites into AppDelegate/
// CalyxWindowController/AgentStatusView is a later stage, out of this
// file's own scope). There is no polling timer anywhere in this type:
// `start()` is a no-op if herdr isn't currently detectable, and does
// nothing again on a second call while already connected -- nothing
// here loops or retries on its own initiative except the bounded
// reconnect described below, itself only ever triggered BY a
// transport-level EOF/failure, never by a clock.
//
// DETECTION (`start()` steps 1-2 below): `resolver.resolve()` and
// `discovery.discover()`/`discovery.isAlive(socketPath:)` all do
// blocking filesystem/socket work (PATH scans, a `connect()`/`poll()`
// probe per candidate). Because `start()` runs on every
// `applicationDidBecomeActive` and every Agents sidebar appearance,
// this whole detection step is dispatched as ONE unit onto
// `DispatchQueue.global()` behind a `withCheckedContinuation`, mirroring
// `HerdrCLISessionProvider.listSessions()`'s identical idiom, so it
// never blocks `@MainActor` -- see `detectLiveCandidate()`.
//
// START SEQUENCE (pinned by test -- this exact order, because herdr
// never replays agent-status events on (re)subscribe, only structural
// ones; `session.snapshot()` is the only way to learn CURRENT statuses,
// so it must run after subscribing, never before or instead of it):
//   1. `resolver.resolve()` -- nil means herdr isn't installed; bail,
//      touching NOTHING else (no session created).
//   2. `discovery.discover()` then `discovery.isAlive(socketPath:)` --
//      no live candidate means bail the same way.
//   3. `sessionFactory.makeSession()`, then `session.start(socketPath:)`.
//   4. `session.ping()` (handshake).
//   5. `session.subscribe(_:)` with the FULL set: the five structure
//      events herdr documents as type-only -- "pane.created",
//      "pane.closed", "pane.exited", "pane.agent_detected",
//      "layout.updated" -- PLUS one `.agentStatusChanged(paneID:)` per
//      pane THIS ATTEMPT already knows about (empty on this instance's
//      very first attempt, since nothing has been snapshotted yet;
//      populated from the previous snapshot on a reconnect/rebuild, or
//      -- see BOOTSTRAP REBUILD below -- from this same `start()`
//      call's own prior attempt).
//   6. `session.snapshot()`, then `mirror.applySnapshot(_:socketPath:)`
//      -- this is also where `knownPaneIDs` (the "currently known pane"
//      set step 5 reads) is (re)populated, from the snapshot's
//      `agents[].paneID`, matching what `HerdrAgentMirror` itself
//      treats as authoritative. Applied on EVERY attempt, even one
//      BOOTSTRAP REBUILD is about to discard -- the snapshot data
//      itself is accurate; only that attempt's subscription coverage
//      was stale.
//   7. Only THEN does this instance begin consuming the stream
//      `subscribe(_:)` returned, for as long as the connection lives --
//      see "ONGOING EVENT HANDLING" below, and ONLY for the attempt
//      that survives BOOTSTRAP REBUILD below. Deferring this until
//      after step 6 is deliberate: `subscribe(_:)` replays every
//      EXISTING pane as a `.paneCreated` event as soon as it is acked
//      (before step 6 even runs), and `AsyncThrowingStream` buffers
//      those unread elements rather than dropping them -- so by the
//      time this instance starts reading, `knownPaneIDs` has ALREADY
//      been populated by step 6, and the buffered replay burst's own
//      pane ids are (barring a pane created in the tiny window between
//      subscribe and snapshot) already all "known" -- see "REBUILD
//      TRIGGERS" below for why that dedup is what keeps this from
//      re-triggering a rebuild for every single one of its own replayed
//      panes.
//
// BOOTSTRAP REBUILD (A1): step 5 can only ever subscribe to panes THIS
// ATTEMPT already knows about before its own step 6 runs -- on a cold
// `start()` that is always the empty set, even though herdr may already
// have panes with running agents. Left unaddressed, those agents' LATER
// status transitions would never reach this instance until some
// unrelated pane creation happened to force a rebuild. So:
// `attemptConnect(socketPath:)` loops steps 3-6 (each iteration bounded
// by HANDSHAKE DEADLINE below): after step 6, if the pane set it
// revealed (`Set(snapshot.agents.map(\.paneID))`) differs from the pane
// set THIS iteration's own step 5 actually subscribed with, the
// session is dropped WITHOUT ever running step 7 (consuming its stream
// would risk a spurious REBUILD TRIGGER off its own replay burst for no
// benefit, since it is being discarded anyway), `knownPaneIDs` is
// updated to the revealed set, and steps 3-6 run again. This converges
// after exactly one retry in the overwhelmingly common case: the
// retry's own step 5 now subscribes with the just-revealed set, so its
// own step 6 snapshot matches unless the live pane set changed again in
// the tiny window between the two attempts -- structurally the same
// "vanishingly small window" this file already accepts for an ordinary
// REBUILD TRIGGER racing a concurrent pane creation. The
// retry-only-on-mismatch shape (never an unconditional second attempt)
// IS the storm guard: an iteration whose own revealed set matches what
// it just subscribed with never loops again.
//
// BOOTSTRAP REBUILD ITERATION CAP (A3): "exactly one retry in the
// overwhelmingly common case" above is exactly that -- common, not
// guaranteed. A pane set that keeps changing between every single
// retry's own subscribe and its own snapshot would otherwise spin
// `attemptConnect(socketPath:)`'s loop forever, each iteration paying
// for a full connect+ping+subscribe+snapshot round trip against a real
// herdr server. `maxBootstrapRebuildIterations` bounds the loop itself
// -- a SEPARATE axis from HANDSHAKE DEADLINE (A2) below, which only
// bounds ONE iteration's own wait, never the iteration count. Once
// exhausted without ever converging, `attemptConnect(socketPath:)`
// returns `false`, identical to an ordinary handshake failure -- every
// existing caller already handles that outcome, so exhausting this cap
// needs no dedicated handling of its own.
//
// HANDSHAKE DEADLINE (A2): steps 3-6 above (one loop iteration) are
// raced against `handshakeTimeout`, via two independent, unstructured
// `Task`s resuming a shared `CheckedContinuation` at most once (mirrors
// `SessionDaemonClient.bounded()`'s identical shape and its own doc
// comment's reasoning for why `withTaskGroup` cannot be used here: a
// stalled handshake -- the server accepted the connection but never
// answers -- never observes cancellation, so a `TaskGroup`'s implicit
// "await every child before returning" would hang exactly as long as
// the deadline exists to bound). `sleep` -- the same injected delay
// primitive DISCONNECT HANDLING's own backoff uses below -- is the
// timeout arm's wait primitive, so tests drive both deterministically.
// Expiry is handled EXACTLY like the handshake throwing: the iteration
// produces no result, and `attemptConnect(socketPath:)` returns
// `false` -- every existing caller (`start()`'s plain give-up,
// `rebuild(socketPath:)`'s `handleDisconnect(socketPath:)` + bounded
// reconnect, `reconnectLoop`'s own next attempt) already handles an
// ordinary connect failure correctly, so none of them need to change
// for this. A losing handshake that eventually completes ON ITS OWN
// (e.g. an ordinary RPC failure, or the transport EOFing/failing
// normally) needs no further help: nothing it produced was ever
// assigned to `currentSession`/`eventLoopTask` or applied to the
// mirror, so dropping the abandoned `HerdrSocketSession` reference,
// once its own `Task` closure actually returns, is, per that type's own
// "no ordinary close()" contract, its complete teardown. A losing
// handshake that is instead STUCK -- suspended forever inside some
// pending request's own `awaitEntry` continuation, e.g. `ping()` never
// getting a reply because herdr accepted the connection but never
// answers -- is a DIFFERENT case ARC alone cannot resolve: a
// `CheckedContinuation` never resumes itself on cancellation, so that
// closure (and every strong reference it holds -- the session, the
// socket fd, the `DispatchSourceRead` reading it) would otherwise never
// be released, no matter how many times the losing `Task` is
// `cancel()`ed. The TIMEOUT arm below, immediately after ACTUALLY
// WINNING `bridge.resume(with:)` (never on a losing/no-op resume -- the
// handshake arm may have already won and started using this exact
// session as `currentSession`), calls `session.abandon()` for exactly
// this reason -- see `HerdrSocketSession.abandon()`'s own doc comment
// for the mechanism.
//
// ONGOING EVENT HANDLING: every event read off the stream is forwarded
// to `mirror.apply(event:socketPath:)` (this instance's only source for
// that call), and separately inspected for a rebuild trigger. The FIRST
// event any given connection ever delivers also earns back DISCONNECT
// HANDLING's own lifetime reconnect budget -- see LIFETIME RECONNECT
// BUDGET below.
//
// REBUILD TRIGGERS: a "pane.created" event is a REBUILD trigger only
// when its pane id is NOT already in `knownPaneIDs` -- otherwise every
// (re)subscribe's own initial replay burst would rebuild once per
// replayed pane, which would itself resubscribe (replaying again),
// diverging. A `.paneClosed`/`.paneExited` event is ALWAYS a rebuild
// trigger, unconditionally: these are never replayed at subscribe time
// (only "pane_created" is), so there is no storm risk. Unlike
// `.paneCreated`, closing/exiting a pane also REMOVES its id from
// `knownPaneIDs` before rebuilding (A4) -- otherwise the rebuilt
// connection would resubscribe `.agentStatusChanged(paneID:)` for a
// pane id that no longer exists, which is unmeasured server behavior. A
// rebuild: drops this instance's reference to the current session (its
// only owner, per HerdrSocketSession.swift's own "no ordinary close()"
// contract -- deallocation IS its teardown path), drops this instance's
// own reference to its event-reading task (needing no explicit
// cancellation of its own -- `consumeEvents` IS that task's own body,
// already running; it simply `return`s right after this call and the
// task self-terminates), then re-runs `attemptConnect` against the SAME
// socket path, with `knownPaneIDs` still holding its pre-rebuild
// contents (so the resubscribe's own per-pane list is never simply
// empty) until that attempt's own snapshot refreshes it.
//
// DISCONNECT HANDLING: the event stream ending -- normally (a clean
// EOF) or by throwing (a transport failure; see HerdrTransport.swift's
// own EOF-vs-failure distinction) -- is handled identically: call
// `mirror.connectionLost()`, drop the session, then attempt a bounded
// reconnect, each attempt gated by `discovery.isAlive(socketPath:)`
// (checked before AND after its backoff delay -- the delay itself is
// exactly the window in which the socket could disappear): as soon as
// the socket no longer probes alive, stop entirely, no further retry.
// `reconnectDelays` bounds EACH CYCLE's own attempt count (its own
// `count`) and supplies each attempt's backoff duration; `sleep` is the
// injected delay primitive (defaults to real `Task.sleep`, overridden
// in tests to drive it deterministically).
//
// LIFETIME RECONNECT BUDGET (A5): `reconnectDelays` alone bounds only
// ONE disconnect-to-give-up cycle -- a server that repeatedly accepts a
// connection and then immediately drops it again starts a FRESH cycle
// every time, so bounding each cycle in isolation still allows
// unbounded reconnect churn (and visible sidebar flapping: rows cleared
// and repopulated every cycle) across many cycles. `totalReconnectAttempts`
// instead counts every `reconnectLoop`-driven attempt for as long as
// THIS INSTANCE exists, across every cycle, capped by
// `maxLifetimeReconnectAttempts`; once reached, `reconnectLoop` gives
// up permanently (`resetToIdle()`) without even trying the remaining
// attempt, same as running out of `reconnectDelays` entries.
// Deliberately NOT reset by `resetToIdle()`'s own full give-up -- a
// LATER `start()` call is still bound by the SAME lifetime total,
// otherwise a flapping server would simply be re-armed for a fresh full
// budget every time `applicationDidBecomeActive` fires again. The ONLY
// way to earn the budget back to zero is a connection proving itself
// HEALTHY, defined here as: it delivered at least one event AFTER its
// own handshake completed (the first iteration of `consumeEvents`'s own
// read loop for that connection actually running). A successful
// handshake ALONE is deliberately NOT enough -- a server that accepts,
// completes ping/subscribe/snapshot, and drops again before ever
// pushing anything would otherwise reset the budget every single cycle,
// reproducing the exact indefinite churn this budget exists to prevent.
// Known, accepted limitation: `subscribe(_:)`'s own replay burst (see
// START SEQUENCE step 7 above) counts as "at least one event" for a
// connection with 1+ existing panes, so a flapper that happens to
// survive just long enough to deliver that burst before dropping again
// would still earn the reset -- narrower than a wall-clock "stayed up N
// seconds" bar would be, but avoids a second timer/clock dependency for
// a bar this coordinator does not currently need to be that precise
// about.
//

import Foundation

// MARK: - HerdrSessionFactory

/// Constructs a fresh, not-yet-started `HerdrSocketSession` --
/// `HerdrIntegrationCoordinator`'s only session-construction seam, so
/// its own tests never open a real socket (a test conformer builds each
/// session over an `InMemoryHerdrTransport` it retains, mirroring
/// `LSPSessionFactory`'s identical transport-injection role for LSP).
/// `async`, not synchronous, purely to allow an actor-isolated test
/// double to conform directly (mirrors `LSPSessionFactory.makeClient`'s
/// own `async throws` shape) -- a production conformer need not
/// actually suspend.
protocol HerdrSessionFactory: Sendable {
    func makeSession() async -> HerdrSocketSession
}

// MARK: - LiveHerdrSessionFactory

/// Production `HerdrSessionFactory`: builds a fresh `HerdrSocketSession`
/// over a real `BSDHerdrTransport` -- `AppDelegate`'s own
/// `HerdrIntegrationCoordinator` instance is this type's only
/// production call site. Never suspends; `async` only to satisfy the
/// protocol (see its own doc comment for why the protocol itself is
/// `async`).
struct LiveHerdrSessionFactory: HerdrSessionFactory {
    func makeSession() async -> HerdrSocketSession {
        HerdrSocketSession(transport: BSDHerdrTransport())
    }
}

// MARK: - HerdrIntegrationCoordinator

@MainActor
final class HerdrIntegrationCoordinator {

    /// The five herdr structure events subscribed type-only on every
    /// (re)subscribe -- see this file's header, START SEQUENCE step 5.
    static let structureEventSubscriptionTypes = [
        "pane.created", "pane.closed", "pane.exited", "pane.agent_detected", "layout.updated",
    ]

    /// Default bounded backoff schedule for DISCONNECT HANDLING's
    /// reconnect attempts -- its `count` is the max attempt count PER
    /// CYCLE; see `maxLifetimeReconnectAttempts` for the cross-cycle
    /// bound (A5).
    static let defaultReconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Default HANDSHAKE DEADLINE (A2) -- generous enough that a merely
    /// slow (not hung) real herdr server is never mistaken for a stalled
    /// one, while still bounding the otherwise-unbounded wait a
    /// connection-accepted-then-silent server would impose.
    static let defaultHandshakeTimeout: Duration = .seconds(10)

    /// Default BOOTSTRAP REBUILD ITERATION CAP (A3) -- see this file's
    /// header. Deliberately small: the common case converges after
    /// exactly one retry (2 total iterations), so this leaves ample
    /// headroom before ever being reached by legitimate pane-set churn,
    /// while still bounding a snapshot that never stops revealing a
    /// freshly different pane set on every single retry.
    static let defaultMaxBootstrapRebuildIterations = 5

    /// Default LIFETIME RECONNECT BUDGET (A5) -- see this file's header.
    /// Deliberately larger than any single cycle's own `reconnectDelays
    /// .count` so ordinary transient blips (which settle and prove
    /// HEALTHY well before this total is reached) are never affected.
    static let defaultMaxLifetimeReconnectAttempts = 10

    private let resolver: any HerdrBinaryResolverProtocol
    private let discovery: any HerdrSessionDiscoveryProtocol
    private let sessionFactory: any HerdrSessionFactory
    private let mirror: HerdrAgentMirror
    private let reconnectDelays: [Duration]
    private let handshakeTimeout: Duration
    private let maxBootstrapRebuildIterations: Int
    private let maxLifetimeReconnectAttempts: Int
    private let sleep: @Sendable (Duration) async -> Void

    private var currentSession: HerdrSocketSession?
    private var knownPaneIDs: Set<String> = []
    private var eventLoopTask: Task<Void, Never>?

    /// LIFETIME RECONNECT BUDGET (A5) -- see this file's header. Counts
    /// every `reconnectLoop`-driven attempt across every disconnect
    /// cycle for as long as this instance exists; deliberately NOT
    /// touched by `resetToIdle()`. Only earning a connection HEALTHY
    /// (see `consumeEvents`) resets it back to zero.
    private var totalReconnectAttempts = 0

    /// `true` from the moment `start()` begins a real connection attempt
    /// (set SYNCHRONOUSLY, before this method's first `await` -- mirrors
    /// `HerdrSocketSession.subscribe(_:)`'s own reentrancy-window
    /// precedent) through until this instance is fully idle again --
    /// covers the in-flight START SEQUENCE, the established connection,
    /// and every bounded-reconnect attempt. This is what makes `start()`
    /// safe to call redundantly from its three independent production
    /// triggers (app launch, `applicationDidBecomeActive`, the Agents
    /// sidebar becoming visible) without risking two connections opened
    /// for the same socket by two overlapping `start()` calls racing
    /// each other across an `await`.
    private var isActive = false

    init(
        resolver: any HerdrBinaryResolverProtocol,
        discovery: any HerdrSessionDiscoveryProtocol,
        sessionFactory: any HerdrSessionFactory,
        mirror: HerdrAgentMirror,
        reconnectDelays: [Duration] = HerdrIntegrationCoordinator.defaultReconnectDelays,
        handshakeTimeout: Duration = HerdrIntegrationCoordinator.defaultHandshakeTimeout,
        maxBootstrapRebuildIterations: Int = HerdrIntegrationCoordinator.defaultMaxBootstrapRebuildIterations,
        maxLifetimeReconnectAttempts: Int = HerdrIntegrationCoordinator.defaultMaxLifetimeReconnectAttempts,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.resolver = resolver
        self.discovery = discovery
        self.sessionFactory = sessionFactory
        self.mirror = mirror
        self.reconnectDelays = reconnectDelays
        self.handshakeTimeout = handshakeTimeout
        self.maxBootstrapRebuildIterations = maxBootstrapRebuildIterations
        self.maxLifetimeReconnectAttempts = maxLifetimeReconnectAttempts
        self.sleep = sleep
    }

    /// Explicit lifecycle entry point -- see this file's header. Every
    /// production call site (app launch, app became active, Agents
    /// sidebar became visible) calls this SAME method; none of them are
    /// distinguished internally, since none of this file's behavior
    /// varies by which one fired.
    func start() async {
        guard !isActive else { return }
        isActive = true

        guard let candidate = await detectLiveCandidate() else {
            isActive = false
            return
        }

        guard await attemptConnect(socketPath: candidate.socketPath) else {
            // No prior connection ever existed for this attempt to have
            // "lost" -- a plain give-up, distinct from DISCONNECT
            // HANDLING's bounded reconnect (which only ever follows an
            // established connection's stream ending). A later `start()`
            // call re-attempts detection from scratch.
            isActive = false
            return
        }
    }

    // MARK: - Detection (START SEQUENCE steps 1-2, A7)

    /// Runs `resolver.resolve()` then, only if that succeeds,
    /// `discovery.discover()`/`discovery.isAlive(socketPath:)` as ONE
    /// unit on `DispatchQueue.global()`, off `@MainActor` -- see this
    /// file's header "DETECTION". `resolver`/`discovery` are both
    /// `Sendable` protocol existentials, so capturing them into the
    /// background closure is sound without any actor hop of their own.
    private func detectLiveCandidate() async -> HerdrSessionCandidate? {
        let resolver = self.resolver
        let discovery = self.discovery
        return await withCheckedContinuation { (continuation: CheckedContinuation<HerdrSessionCandidate?, Never>) in
            DispatchQueue.global().async {
                guard resolver.resolve() != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let candidate = discovery.discover().first { discovery.isAlive(socketPath: $0.socketPath) }
                continuation.resume(returning: candidate)
            }
        }
    }

    // MARK: - Connecting (START SEQUENCE steps 3-7)

    /// Runs the START SEQUENCE's steps 3-7 against `socketPath`, looping
    /// once more whenever BOOTSTRAP REBUILD (A1) applies -- see this
    /// file's header for both. Bounded at `maxBootstrapRebuildIterations`
    /// iterations (A3): a pane set that never stops changing between one
    /// iteration's own subscribe and its own snapshot would otherwise
    /// spin this loop forever. Returns `true` once `currentSession`/
    /// `eventLoopTask` are live, `false` once an iteration's handshake
    /// either fails or times out, OR once the iteration cap is exhausted
    /// without ever converging (nothing left half-set in any of these
    /// cases -- the caller decides what "this attempt failed" means).
    private func attemptConnect(socketPath: String) async -> Bool {
        for _ in 0..<maxBootstrapRebuildIterations {
            let subscribedPaneIDs = knownPaneIDs
            guard let result = await performHandshakeWithDeadline(
                socketPath: socketPath, subscribedPaneIDs: subscribedPaneIDs
            ) else {
                return false
            }

            mirror.applySnapshot(result.snapshot, socketPath: socketPath)
            let revealedPaneIDs = Set(result.snapshot.agents.map(\.paneID))
            knownPaneIDs = revealedPaneIDs

            guard revealedPaneIDs == subscribedPaneIDs else {
                // BOOTSTRAP REBUILD (A1): this attempt's own subscribe
                // did not cover every pane its own snapshot just
                // revealed -- discard it WITHOUT ever starting step 7
                // (see this file's header) and retry once with the
                // now-corrected `knownPaneIDs`. Converges: the retry's
                // own `subscribedPaneIDs` will equal `revealedPaneIDs`
                // set here, so its own snapshot matches unless the pane
                // set changes again in the tiny window between attempts.
                continue
            }

            currentSession = result.session
            eventLoopTask = Task { [weak self] in
                await self?.consumeEvents(result.stream, socketPath: socketPath)
            }
            return true
        }
        // BOOTSTRAP REBUILD ITERATION CAP (A3): every iteration mismatched
        // -- give up exactly like an ordinary handshake failure.
        return false
    }

    /// Races one `performHandshake(session:socketPath:subscribedPaneIDs:)`
    /// attempt against `handshakeTimeout` -- see this file's header
    /// "HANDSHAKE DEADLINE (A2)" for why this uses two independent,
    /// unstructured `Task`s racing to resume a shared continuation
    /// rather than a `TaskGroup`. `nil` on either a thrown error or
    /// expiry -- `attemptConnect` does not need to distinguish the two,
    /// mirroring the pre-A2 `catch { return false }` this replaces.
    ///
    /// BLOCKER fix: the TIMEOUT arm calls `session.abandon()` immediately
    /// after `bridge.resume(with:)`, but ONLY when that call actually WON
    /// the race (`resume(with:)` returns `true`) -- see this file's
    /// header "HANDSHAKE DEADLINE (A2)" for why a stuck handshake needs
    /// this at all. Gating on the return value matters: if the HANDSHAKE
    /// arm already won (e.g. it completed a hair before the deadline),
    /// `resume(with:)` here is a no-op and `session` may ALREADY be this
    /// attempt's `currentSession` -- calling `abandon()` on it regardless
    /// would tear down a connection `attemptConnect` just decided to
    /// keep, forcing a spurious disconnect/reconnect. The HANDSHAKE arm
    /// needs no symmetric guard: its own `catch` path only ever runs for
    /// an error `performHandshake` actually threw, which means it is by
    /// definition not stuck, so ARC teardown (dropping the reference)
    /// remains sufficient there.
    private func performHandshakeWithDeadline(
        socketPath: String, subscribedPaneIDs: Set<String>
    ) async -> HandshakeResult? {
        let session = await sessionFactory.makeSession()
        let bridge = HandshakeRaceBridge()

        return await withCheckedContinuation { (continuation: CheckedContinuation<HandshakeResult?, Never>) in
            let handshakeTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.performHandshake(
                        session: session, socketPath: socketPath, subscribedPaneIDs: subscribedPaneIDs
                    )
                    bridge.resume(with: result)
                } catch {
                    bridge.resume(with: nil)
                }
            }
            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                await self.sleep(self.handshakeTimeout)
                guard !Task.isCancelled else { return }
                if bridge.resume(with: nil) {
                    // Only reached when the HANDSHAKE arm had not already
                    // won -- see this method's own doc comment above.
                    await session.abandon()
                }
            }
            bridge.register(continuation: continuation, handshakeTask: handshakeTask, timeoutTask: timeoutTask)
        }
    }

    /// Steps 3-6 of the START SEQUENCE, run once, with no deadline of
    /// its own -- `performHandshakeWithDeadline(socketPath:subscribedPaneIDs:)`
    /// above is what bounds it (A2). Deliberately takes
    /// `subscribedPaneIDs` as a parameter rather than reading
    /// `knownPaneIDs` directly, so the exact pane set this attempt
    /// subscribed with is unambiguous to `attemptConnect`'s own
    /// BOOTSTRAP REBUILD (A1) comparison, independent of timing.
    private func performHandshake(
        session: HerdrSocketSession, socketPath: String, subscribedPaneIDs: Set<String>
    ) async throws -> HandshakeResult {
        try await session.start(socketPath: socketPath)
        _ = try await session.ping()

        let subscriptions = Self.structureEventSubscriptionTypes.map(HerdrSubscription.typeOnly)
            + subscribedPaneIDs.sorted().map { HerdrSubscription.agentStatusChanged(paneID: $0) }
        let stream = try await session.subscribe(subscriptions)

        let snapshot = try await session.snapshot()
        return HandshakeResult(session: session, stream: stream, snapshot: snapshot)
    }

    /// One completed handshake's payload -- see this file's header
    /// "HANDSHAKE DEADLINE (A2)". Deliberately side-effect free (no
    /// `mirror`/`knownPaneIDs` mutation): only `attemptConnect`, the
    /// sole caller of `performHandshakeWithDeadline`, decides whether an
    /// attempt's result is the one that actually gets published, so a
    /// handshake that completes AFTER already losing its own deadline
    /// race can be discarded without corrupting instance state.
    private struct HandshakeResult: Sendable {
        let session: HerdrSocketSession
        let stream: AsyncThrowingStream<HerdrEvent, Error>
        let snapshot: HerdrSessionSnapshot
    }

    /// Thread-safe, exactly-once bridge between
    /// `performHandshakeWithDeadline(socketPath:subscribedPaneIDs:)`'s
    /// two racing arms -- mirrors `SessionDaemonBoundedRaceBridge`
    /// (SessionDaemonClient.swift) trimmed to this file's single-result
    /// shape (no `onCancel`-driven third resumer: nothing here needs to
    /// react to the AWAITING task's own cancellation, unlike that
    /// type's `bounded(...)`). The first arm to call `resume(with:)`
    /// wins; cancelling both tasks afterward is a harmless no-op for
    /// whichever one already finished, and lets a real `Task.sleep`-
    /// backed `sleep` closure exit its wait promptly instead of running
    /// the losing arm's full duration. `@unchecked Sendable` is sound
    /// because every mutable stored property below is read/written ONLY
    /// while holding `lock` -- the same "single `NSLock` guards every
    /// mutation" justification `SessionDaemonBoundedRaceBridge` itself
    /// relies on.
    ///
    /// BLOCKER fix: `resume(with:)` also nils out `handshakeTask` /
    /// `timeoutTask` (under `lock`, alongside `continuation`) the moment
    /// it wins, not merely local-variable copies afterward -- both
    /// racing `Task` closures capture this bridge, and this bridge, in
    /// turn, held onto `Task` handles referencing those SAME closures
    /// (a retain cycle for as long as both remained set). This breaks
    /// that cycle unconditionally, independent of whether the LOSING
    /// arm's own closure ever actually finishes running (see
    /// `performHandshakeWithDeadline`'s own doc comment for what makes a
    /// STUCK handshake's closure finish at all).
    private final class HandshakeRaceBridge: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var handshakeTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var continuation: CheckedContinuation<HandshakeResult?, Never>?

        func register(
            continuation: CheckedContinuation<HandshakeResult?, Never>,
            handshakeTask: Task<Void, Never>,
            timeoutTask: Task<Void, Never>
        ) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
            self.handshakeTask = handshakeTask
            self.timeoutTask = timeoutTask
        }

        @discardableResult
        func resume(with result: HandshakeResult?) -> Bool {
            lock.lock()
            guard !resumed, let continuation else { lock.unlock(); return false }
            resumed = true
            self.continuation = nil
            let hTask = handshakeTask
            let tTask = timeoutTask
            handshakeTask = nil
            timeoutTask = nil
            lock.unlock()
            continuation.resume(returning: result)
            hTask?.cancel()
            tTask?.cancel()
            return true
        }
    }

    // MARK: - Ongoing event handling (START SEQUENCE step 7)

    /// Consumes `stream` for as long as the connection lives -- every
    /// event is forwarded to `mirror.apply(event:socketPath:)`, then
    /// separately inspected for a REBUILD TRIGGER (see this file's
    /// header). The FIRST event this call ever reads also earns back
    /// the LIFETIME RECONNECT BUDGET (A5) -- see this file's header
    /// "LIFETIME RECONNECT BUDGET". The stream ending -- normally (a
    /// clean EOF) or by throwing (a transport failure) -- is DISCONNECT
    /// HANDLING, shared with a failed rebuild attempt via
    /// `handleDisconnect(socketPath:)`.
    private func consumeEvents(_ stream: AsyncThrowingStream<HerdrEvent, Error>, socketPath: String) async {
        var hasEarnedHealthyReset = false
        do {
            for try await event in stream {
                if !hasEarnedHealthyReset {
                    hasEarnedHealthyReset = true
                    // HEALTHY (A5): this connection has delivered at
                    // least one event after its own handshake completed
                    // -- see this file's header for the known, accepted
                    // limitation this bar has (the subscribe-time replay
                    // burst counts).
                    totalReconnectAttempts = 0
                }
                mirror.apply(event: event, socketPath: socketPath)

                switch event {
                case .paneCreated(let pane) where !knownPaneIDs.contains(pane.paneID):
                    // A genuinely NEW pane -- record it immediately (not
                    // just at the next snapshot) so the rebuilt
                    // connection's own resubscribe below already
                    // includes it -- see this file's header.
                    knownPaneIDs.insert(pane.paneID)
                    eventLoopTask = nil
                    await rebuild(socketPath: socketPath)
                    return
                case .paneClosed(let paneID), .paneExited(let paneID):
                    // ALWAYS a rebuild trigger, unconditionally -- unlike
                    // `.paneCreated` above, neither event is ever
                    // replayed at subscribe time, so there is no storm
                    // risk to guard against here. A4: remove the id from
                    // `knownPaneIDs` BEFORE rebuilding, so the rebuilt
                    // connection's own resubscribe never lists a pane id
                    // herdr no longer knows about -- see this file's
                    // header.
                    knownPaneIDs.remove(paneID)
                    eventLoopTask = nil
                    await rebuild(socketPath: socketPath)
                    return
                default:
                    break
                }
            }
        } catch {
            // Falls through to the shared handling below -- a transport
            // failure is handled identically to a clean EOF (the `for
            // try await` loop above simply ending without throwing) --
            // see this file's header "DISCONNECT HANDLING".
        }

        eventLoopTask = nil
        await handleDisconnect(socketPath: socketPath)
    }

    // MARK: - Rebuild

    /// A REBUILD TRIGGER fired (see `consumeEvents`): drops the current
    /// session and re-runs the START SEQUENCE from step 3 against the
    /// SAME socket path, reusing `knownPaneIDs`. A failed reconnect
    /// attempt here is funnelled into the same `connectionLost()` +
    /// bounded-reconnect path a stream disconnect uses (untested by this
    /// stage's own suite, but a rebuild that cannot re-establish a
    /// session has, functionally, also just lost the connection).
    private func rebuild(socketPath: String) async {
        currentSession = nil
        guard await attemptConnect(socketPath: socketPath) else {
            await handleDisconnect(socketPath: socketPath)
            return
        }
    }

    // MARK: - Disconnect handling

    /// Shared tail for "the live connection is gone": a clean EOF, a
    /// transport failure, or a rebuild's own reconnect attempt failing.
    /// Notifies the mirror exactly once, drops the session, then
    /// attempts the bounded reconnect -- see this file's header
    /// "DISCONNECT HANDLING".
    private func handleDisconnect(socketPath: String) async {
        mirror.connectionLost()
        currentSession = nil
        await reconnectLoop(socketPath: socketPath)
    }

    /// Bounded reconnect: each attempt is gated by
    /// `discovery.isAlive(socketPath:)`, checked before AND after its
    /// own backoff delay -- the delay itself is exactly the window in
    /// which the socket could disappear -- AND by the LIFETIME RECONNECT
    /// BUDGET (A5, `totalReconnectAttempts` vs
    /// `maxLifetimeReconnectAttempts`) -- see this file's header for
    /// both. Stops (no further retry, no state left "active") the
    /// moment the socket no longer probes alive, once `reconnectDelays`
    /// is exhausted, or once the lifetime budget is exhausted --
    /// whichever comes first.
    private func reconnectLoop(socketPath: String) async {
        for delay in reconnectDelays {
            guard totalReconnectAttempts < maxLifetimeReconnectAttempts else {
                resetToIdle()
                return
            }
            guard discovery.isAlive(socketPath: socketPath) else {
                resetToIdle()
                return
            }
            await sleep(delay)
            guard discovery.isAlive(socketPath: socketPath) else {
                resetToIdle()
                return
            }
            totalReconnectAttempts += 1
            if await attemptConnect(socketPath: socketPath) {
                return
            }
        }
        resetToIdle()
    }

    /// Full give-up: resets every piece of per-connection state so a
    /// LATER `start()` call behaves exactly like this instance's very
    /// first one -- EXCEPT `totalReconnectAttempts` (A5's LIFETIME
    /// RECONNECT BUDGET), deliberately left untouched: see this file's
    /// header for why a later `start()` must stay bound by the SAME
    /// lifetime total rather than being re-armed with a fresh one.
    /// `knownPaneIDs` in particular must not survive a full give-up --
    /// a later-discovered herdr session may reuse pane ids the old one
    /// had, and resubscribing against it with stale per-pane ids is
    /// unmeasured server behavior.
    private func resetToIdle() {
        isActive = false
        knownPaneIDs.removeAll()
    }
}
