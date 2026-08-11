//
//  HerdrIntegrationCoordinatorTests.swift
//  CalyxTests
//
//  HerdrIntegrationCoordinator's detection gate, START SEQUENCE
//  ordering, A1's bootstrap rebuild (a cold connect's own subscribe
//  cannot cover panes it hasn't snapshotted yet), pane-set REBUILD
//  triggers (including the anti-storm dedup against a (re)subscribe's
//  own replay burst), A2's bounded handshake deadline, and EOF/failure
//  DISCONNECT HANDLING with a reconnect budget bounded across cycles for
//  this instance's whole lifetime (A5/A6). See
//  HerdrIntegrationCoordinator.swift's own header for the full frozen
//  contract.
//
//  Every dependency is a fake/spy -- no real socket is ever opened.
//  `SpyHerdrSessionFactory` builds each session over a real
//  `InMemoryHerdrTransport` it retains (mirrors HerdrSocketSessionTests'
//  own transport-driving style exactly: this file exercises
//  HerdrSocketSession's REAL wire protocol, just reached indirectly
//  through the coordinator, only the factory/discovery/resolver
//  boundary is faked). `HerdrAgentMirror` and `AgentRegistry` are used
//  as REAL, freshly-constructed instances (never mocked) -- registry
//  state is this file's way of confirming the coordinator's snapshot/
//  event/connectionLost calls actually reached the mirror.
//
//  A1 note: a cold `start()`'s very first attempt always subscribes with
//  an empty per-pane set (nothing snapshotted yet), so most tests below
//  that need N already-known, SETTLED panes go through
//  `driveToSettledConnection(factory:baseIndex:paneIDs:)`, which drives
//  the unavoidable one-time bootstrap rebuild for them, returning the
//  transport that actually stays live; a bare `driveInitialSequence`
//  with an EMPTY pane list is used instead wherever a test's own point
//  is orthogonal to pane content, to avoid that extra hop entirely.
//
//  A2 note: `makeDetectableCoordinator`'s own `sleep` defaults to a REAL
//  `Task.sleep(for:)`-backed closure (matching the coordinator's own
//  production default), not a no-op -- see that helper's own doc comment
//  for why a shared no-op default would make A2's handshake-timeout race
//  arm resolve before a genuinely multi-hop driven handshake could ever
//  win it.
//
//  Coverage:
//  - herdr not detected (resolver nil, or no live socket) -> zero factory calls
//  - never calling start() -> zero factory calls, no background timer
//  - start(): connect -> ping -> subscribe -> snapshot, in that exact order
//  - A1: a cold connect's first subscribe carries the 5 structure events and
//    zero per-pane subscriptions; its own snapshot revealing an unsubscribed
//    pane triggers exactly one bootstrap rebuild, never a storm
//  - the fetched snapshot is applied to the injected mirror
//  - start() while already connected is a no-op (repeated "app became active")
//  - a paneCreated event for a genuinely NEW pane rebuilds the connection,
//    and the rebuilt subscribe list includes that new pane
//  - a paneCreated event for an ALREADY-known pane does NOT rebuild
//    (anti-storm: the (re)subscribe's own replay burst must not self-trigger)
//  - "pane_closed"/"pane_exited" events (.paneClosed(paneID:)/
//    .paneExited(paneID:) on the wire, per HerdrEvent.swift's B1 rule)
//    always rebuild unconditionally, regardless of knownPaneIDs
//  - A4: closing/exiting a pane removes its id from knownPaneIDs BEFORE
//    rebuilding, so the rebuilt connection's own resubscribe never lists
//    a pane id herdr no longer knows about
//  - a paneAgentStatusChanged event reaches the mirror end-to-end
//  - EOF calls mirror.connectionLost(), then reconnects while the socket
//    still probes alive
//  - EOF stops entirely (no retry) once the socket no longer probes alive
//  - A5/A6: the reconnect budget is bounded ACROSS cycles (not just within
//    one), surviving a reconnect that completes its own handshake and then
//    drops again before any event is ever pushed
//  - A2: a handshake that hangs forever times out and gives up plainly,
//    and a later start() still proceeds fresh afterward
//  - BLOCKER regression: a handshake stuck forever inside a pending
//    request's own continuation (herdr accepted the connection but
//    never answers `ping`) must, once A2's deadline fires, actually
//    terminate that session (via `HerdrSocketSession.abandon()`) and
//    let it be released -- not merely time out `start()` while leaking
//    the session, its socket fd, and its `DispatchSourceRead` forever
//  - A3 (SHOULD-FIX): a pane set that never stops revealing a freshly
//    different set on every single BOOTSTRAP REBUILD (A1) retry must
//    stop at a bounded iteration cap, never spin `attemptConnect`
//    forever
//
//  NOTE ON XCTAssert + actor-isolated values: `XCTAssertEqual`/etc. take
//  `@autoclosure` (non-async) parameters, so `await factory.callCount`
//  cannot be written directly inside one -- every such check below
//  resolves it to a local `let` first, then asserts on the local.
//

import XCTest
import os
@testable import Calyx

// MARK: - Fakes

private struct FakeHerdrBinaryResolver: HerdrBinaryResolverProtocol {
    let result: String?
    func resolve() -> String? { result }
}

/// Mutable-but-genuinely-`Sendable` `HerdrSessionDiscoveryProtocol` fake
/// (`OSAllocatedUnfairLock`-backed, mirrors `HerdrBinaryResolver`'s own
/// cache precedent) -- `markDead(_:)` lets a test flip a socket path
/// from "alive" to "gone" mid-run, for the DISCONNECT HANDLING tests.
private final class FakeHerdrSessionDiscovery: HerdrSessionDiscoveryProtocol, Sendable {
    private let candidatesBox: OSAllocatedUnfairLock<[HerdrSessionCandidate]>
    private let aliveBox: OSAllocatedUnfairLock<Set<String>>

    init(candidates: [HerdrSessionCandidate], alive: Set<String>) {
        candidatesBox = OSAllocatedUnfairLock(initialState: candidates)
        aliveBox = OSAllocatedUnfairLock(initialState: alive)
    }

    func discover() -> [HerdrSessionCandidate] { candidatesBox.withLock { $0 } }
    func isAlive(socketPath: String) -> Bool { aliveBox.withLock { $0.contains(socketPath) } }

    /// Test control: makes subsequent `isAlive(socketPath:)` calls for
    /// this path report `false`.
    func markDead(_ socketPath: String) {
        aliveBox.withLock { $0.remove(socketPath) }
    }
}

/// `HerdrSessionFactory` spy: each `makeSession()` call builds a fresh
/// `HerdrSocketSession` over a NEW `InMemoryHerdrTransport`, retaining
/// the transport so tests can drive/inspect it -- `transports.count` IS
/// this spy's call count. Also tracks each created session via a WEAK
/// reference (`WeakSessionBox`) -- see `isSessionAlive(at:)`'s own doc
/// comment for why: this spy must never itself become an unaccounted-for
/// strong retainer of a session, or a BLOCKER-class leak regression
/// (HerdrIntegrationCoordinator.swift's own HANDSHAKE DEADLINE (A2)
/// timeout arm) could pass by accident.
private actor SpyHerdrSessionFactory: HerdrSessionFactory {
    private(set) var transports: [InMemoryHerdrTransport] = []
    private var sessionBoxes: [WeakSessionBox] = []

    func makeSession() async -> HerdrSocketSession {
        let transport = InMemoryHerdrTransport()
        transports.append(transport)
        let session = HerdrSocketSession(transport: transport)
        sessionBoxes.append(WeakSessionBox(session))
        return session
    }

    var callCount: Int { transports.count }

    func transport(at index: Int) -> InMemoryHerdrTransport? {
        transports.indices.contains(index) ? transports[index] : nil
    }

    /// TEST ONLY (BLOCKER regression coverage): `true` while the session
    /// created by call `#index` is still retained SOMEWHERE OUTSIDE this
    /// factory -- see `WeakSessionBox`'s own doc comment for why this
    /// factory itself never counts as that somewhere.
    func isSessionAlive(at index: Int) -> Bool {
        guard sessionBoxes.indices.contains(index) else { return false }
        return sessionBoxes[index].session != nil
    }
}

/// TEST ONLY: holds a WEAK reference to a `HerdrSocketSession` so
/// `SpyHerdrSessionFactory.isSessionAlive(at:)` can observe whether the
/// coordinator (the only INTENDED owner of a session it creates) still
/// retains it, without the factory itself holding a strong reference
/// that would mask a real leak.
private final class WeakSessionBox {
    weak var session: HerdrSocketSession?
    init(_ session: HerdrSocketSession) {
        self.session = session
    }
}

// MARK: - HerdrIntegrationCoordinatorTests

@MainActor
final class HerdrIntegrationCoordinatorTests: XCTestCase {

    private let socketPath = "/tmp/herdr-coordinator-test/herdr.sock"

    // MARK: - Coordinator construction helper

    /// `sleep` defaults to the SAME real-clock closure the coordinator's
    /// own initializer defaults to (`Task.sleep(for:)`), not a no-op --
    /// A2's HANDSHAKE DEADLINE races every driven handshake against
    /// `handshakeTimeout` using this SAME closure, so a no-op default
    /// would resolve that race arm instantly, before a handshake this
    /// suite is actively driving (over several genuine actor hops) could
    /// ever win -- see A2's own coverage note below. `reconnectDelays`
    /// stay effectively instant in every test that sets them because
    /// every one of them uses `.zero`; `Task.sleep(for: .zero)` still
    /// suspends, but not for any real, test-slowing duration.
    private func makeDetectableCoordinator(
        factory: SpyHerdrSessionFactory,
        discovery: FakeHerdrSessionDiscovery? = nil,
        mirror: HerdrAgentMirror? = nil,
        reconnectDelays: [Duration] = [],
        maxBootstrapRebuildIterations: Int = HerdrIntegrationCoordinator.defaultMaxBootstrapRebuildIterations,
        maxLifetimeReconnectAttempts: Int = HerdrIntegrationCoordinator.defaultMaxLifetimeReconnectAttempts,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> HerdrIntegrationCoordinator {
        HerdrIntegrationCoordinator(
            resolver: FakeHerdrBinaryResolver(result: "/opt/homebrew/bin/herdr"),
            discovery: discovery ?? FakeHerdrSessionDiscovery(
                candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
            ),
            sessionFactory: factory,
            mirror: mirror ?? HerdrAgentMirror(registry: AgentRegistry()),
            reconnectDelays: reconnectDelays,
            maxBootstrapRebuildIterations: maxBootstrapRebuildIterations,
            maxLifetimeReconnectAttempts: maxLifetimeReconnectAttempts,
            sleep: sleep
        )
    }

    /// Drives a coordinator's very first `start()` (or a rebuild/
    /// reconnect attempt already in flight) all the way to a SETTLED
    /// connection when `paneIDs` is non-empty -- see A1's own
    /// BOOTSTRAP REBUILD: a cold attempt's subscribedPaneIDs is always
    /// empty, so its own snapshot revealing `paneIDs` unconditionally
    /// triggers exactly one A1 rebuild before settling. Transport
    /// `#baseIndex` is that transient, discarded bootstrap attempt;
    /// transport `#baseIndex + 1` (driven with the SAME `paneIDs`, so
    /// its own revealed set matches what it just subscribed) is the one
    /// that actually settles -- returned so callers assert against the
    /// LIVE connection, not the transient one. `paneIDs: []` never
    /// triggers a rebuild (an empty revealed set trivially matches the
    /// empty subscribedPaneIDs every cold attempt starts with), so it
    /// shortcuts to a single connection, returning transport
    /// `#baseIndex` itself. Tests that don't care about A1's own
    /// mechanics (most of this file) use this helper to reach "N known,
    /// settled panes" without duplicating the bootstrap dance; A1's own
    /// dedicated tests above drive it out by hand instead.
    private func driveToSettledConnection(
        factory: SpyHerdrSessionFactory, baseIndex: Int, paneIDs: [String]
    ) async -> InMemoryHerdrTransport? {
        await driveInitialSequence(factory: factory, transportIndex: baseIndex, snapshotPaneIDs: paneIDs)
        guard !paneIDs.isEmpty else {
            return await factory.transport(at: baseIndex)
        }
        await driveInitialSequence(factory: factory, transportIndex: baseIndex + 1, snapshotPaneIDs: paneIDs)
        return await factory.transport(at: baseIndex + 1)
    }

    // MARK: - Detection gate

    func test_start_whenHerdrNotDetected_resolverReturnsNil_doesNothing() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = HerdrIntegrationCoordinator(
            resolver: FakeHerdrBinaryResolver(result: nil),
            discovery: FakeHerdrSessionDiscovery(candidates: [], alive: []),
            sessionFactory: factory,
            mirror: HerdrAgentMirror(registry: AgentRegistry()),
            reconnectDelays: [],
            sleep: { _ in }
        )

        await coordinator.start()

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 0, "herdr not detected (resolver returns nil) must never touch the session factory")
    }

    func test_start_whenNoLiveSocket_doesNothing() async {
        let factory = SpyHerdrSessionFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [] // none alive
        )
        let coordinator = makeDetectableCoordinator(factory: factory, discovery: discovery)

        await coordinator.start()

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 0, "no live socket candidate must never touch the session factory")
    }

    func test_neverCallingStart_doesNoWork_noBackgroundTimer() async {
        let factory = SpyHerdrSessionFactory()
        _ = makeDetectableCoordinator(factory: factory)

        // Bounded cooperative yielding, not a real sleep -- gives any
        // (hypothetical, wrongly-implemented) stray background task a
        // chance to reveal itself without this test depending on
        // wall-clock time.
        for _ in 0..<50 { await Task.yield() }

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 0,
            "constructing a coordinator must never itself start a connection or a timer -- only an explicit " +
            "start() call may"
        )
    }

    // MARK: - START SEQUENCE ordering

    func test_start_connectsPingsSubscribesThenSnapshots_inOrder() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()

        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected start() to create exactly one session via the factory")
            return
        }

        // Empty snapshot -- deliberately no panes, so this attempt's own
        // (empty) subscribedPaneIDs trivially matches its own (empty)
        // revealed set and settles without an A1 BOOTSTRAP REBUILD; this
        // test is only about the wire ORDER of one handshake, not pane
        // content -- see `test_start_bootstrapRebuild_...` below for A1
        // itself.
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask

        // Checked only AFTER the handshake is fully driven: A2's
        // HANDSHAKE DEADLINE races the handshake on its own unstructured
        // `Task`, so `connect(socketPath:)` is not guaranteed to have
        // run yet at the instant `awaitTransport` above first observes
        // `factory.callCount` -- only "ping" having been sent (which
        // `driveInitialSequence` already waited for) proves it did.
        let connectedPath = await transport.lastConnectedSocketPath()
        XCTAssertEqual(connectedPath, socketPath, "start() must connect the session to the discovered live socket path")

        let sent = await transport.sentMessages()
        XCTAssertEqual(
            sent.compactMap { requestMethod(inLine: $0) }, ["ping", "events.subscribe", "session.snapshot"],
            "start() must send exactly ping, then events.subscribe, then session.snapshot, in that order -- " +
            "subscribing before snapshotting matters because herdr never replays agent-status events"
        )
    }

    // MARK: - A1: bootstrap rebuild (first subscribe cannot cover panes it hasn't snapshotted yet)

    func test_start_bootstrapRebuild_firstSubscribeHasNoPerPaneSubs_thenRebuildsToIncludeRevealedPane() async {
        let factory = SpyHerdrSessionFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let coordinator = makeDetectableCoordinator(factory: factory, mirror: mirror)
        let expectedID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        async let startTask: Void = coordinator.start()

        // Transport #0: the cold bootstrap attempt -- nothing is known
        // yet, so its own subscribe must carry zero per-pane
        // subscriptions, exactly the PRE-A1 behaviour this test replaces
        // (see this file's own coverage note). Its own snapshot reveals
        // a pane ("w1:p1") that subscribe never covered -- an A1
        // BOOTSTRAP REBUILD trigger: transport #0 is discarded and
        // transport #1 opened, WITHOUT transport #0 ever reaching
        // events.subscribe's replay burst being consumed. Driven fully
        // (not inspected mid-handshake): `sentMessages()` retains every
        // line ever sent regardless of whether it has been acked yet, so
        // inspecting it AFTER the fact is equivalent and avoids needing
        // to hand-roll ping's own ack here too.
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: ["w1:p1"])

        guard let firstTransport = await factory.transport(at: 0) else {
            XCTFail("expected transport #0 to exist")
            return
        }
        let firstSent = await firstTransport.sentMessages()
        guard let firstSubscribeLine = firstSent.first(where: { requestMethod(inLine: $0) == "events.subscribe" }) else {
            XCTFail("expected transport #0 to send events.subscribe; got \(firstSent)")
            return
        }
        XCTAssertEqual(
            Set(subscriptionTypes(inLine: firstSubscribeLine)), Set(HerdrIntegrationCoordinator.structureEventSubscriptionTypes),
            "the cold bootstrap subscribe must still include exactly the five type-only structure events"
        )
        XCTAssertTrue(
            agentStatusChangedPaneIDs(inLine: firstSubscribeLine).isEmpty,
            "the cold bootstrap subscribe must carry zero per-pane agentStatusChanged subscriptions -- nothing " +
            "is known yet, by construction"
        )

        guard let secondTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected the snapshot revealing an unsubscribed pane to trigger exactly one A1 rebuild")
            return
        }
        let callCountAfterBootstrapRebuild = await factory.callCount
        XCTAssertEqual(callCountAfterBootstrapRebuild, 2, "A1 must open exactly one replacement session, not more")

        // Its own snapshot matches what it just subscribed with, so this
        // settles here -- no third session.
        await driveInitialSequence(factory: factory, transportIndex: 1, snapshotPaneIDs: ["w1:p1"])
        await startTask

        let secondSent = await secondTransport.sentMessages()
        guard let secondSubscribeLine = secondSent.first(where: { requestMethod(inLine: $0) == "events.subscribe" }) else {
            XCTFail("expected the rebuilt session to send its own events.subscribe request; got \(secondSent)")
            return
        }
        XCTAssertEqual(
            agentStatusChangedPaneIDs(inLine: secondSubscribeLine), ["w1:p1"],
            "the rebuilt subscribe must now include the pane the cold bootstrap's own snapshot revealed"
        )

        let finalCallCount = await factory.callCount
        XCTAssertEqual(finalCallCount, 2, "a matching revealed set must settle immediately -- no further rebuild")
        XCTAssertNotNil(
            registry.externalEntries[expectedID],
            "the settled connection's own snapshot must still reach the mirror"
        )
    }

    func test_start_bootstrapRebuild_stablePaneSet_neverRebuildsAgain_noStorm() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: ["w1:p1"])
        _ = await awaitTransport(factory, at: 1)
        await driveInitialSequence(factory: factory, transportIndex: 1, snapshotPaneIDs: ["w1:p1"])
        await startTask

        let callCountAfterSettling = await factory.callCount
        XCTAssertEqual(callCountAfterSettling, 2, "Precondition: settles after exactly one A1 rebuild")

        // Bounded cooperative yielding: a stable, already-matching pane
        // set must never trigger a THIRD session on its own -- this is
        // the storm guard itself (A1's retry-only-on-mismatch shape).
        for _ in 0..<200 { await Task.yield() }

        let callCountAfterWaiting = await factory.callCount
        XCTAssertEqual(
            callCountAfterWaiting, 2,
            "a stable pane set (revealed == subscribed) must never trigger a rebuild storm"
        )
    }

    func test_start_appliesFetchedSnapshotToMirror() async {
        let factory = SpyHerdrSessionFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let coordinator = makeDetectableCoordinator(factory: factory, mirror: mirror)
        let expectedID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        async let startTask: Void = coordinator.start()
        guard await driveToSettledConnection(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) != nil else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask

        XCTAssertNotNil(
            registry.externalEntries[expectedID],
            "start() must apply the fetched snapshot to the injected mirror, producing an external row"
        )
    }

    // MARK: - Already-connected guard

    func test_start_calledAgainWhileAlreadyConnected_doesNotOpenASecondSession() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        // Empty snapshot -- avoids an A1 bootstrap rebuild so "exactly
        // one session so far" stays true; this test is only about the
        // already-connected guard, not pane content.
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 1, "Precondition: exactly one session must exist after the first start()")

        await coordinator.start() // e.g. "app became active" firing again while already live

        let secondCallCount = await factory.callCount
        XCTAssertEqual(
            secondCallCount, 1,
            "start() must be a no-op while already connected -- \"app became active\" can fire repeatedly and " +
            "must never open a duplicate connection"
        )
    }

    // MARK: - Rebuild triggers

    func test_paneCreatedEvent_forNewPane_rebuildsConnection_andSubscribesWithNewPaneIncluded() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        // Empty snapshot -- avoids an A1 bootstrap rebuild, keeping this
        // test's own transport #0/#1 numbering focused on the
        // EVENT-driven rebuild trigger it actually exercises.
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask
        guard let firstTransport = await factory.transport(at: 0) else {
            XCTFail("expected transport #0 to exist")
            return
        }
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 1, "Precondition")

        await firstTransport.simulateLine(paneCreatedEventLine(paneID: "w1:p2"))

        guard let secondTransport = await awaitTransport(factory, at: 1) else {
            XCTFail(
                "expected a paneCreated event for a genuinely NEW pane to rebuild the connection " +
                "(open a second session)"
            )
            return
        }
        let afterRebuildCallCount = await factory.callCount
        XCTAssertEqual(afterRebuildCallCount, 2, "a pane-set change must tear down and open exactly one new session")

        await driveInitialSequence(factory: factory, transportIndex: 1, snapshotPaneIDs: ["w1:p2"])

        let sentOnSecond = await secondTransport.sentMessages()
        guard let subscribeLine = sentOnSecond.first(where: { requestMethod(inLine: $0) == "events.subscribe" }) else {
            XCTFail("expected the rebuilt session to send its own events.subscribe request; got \(sentOnSecond)")
            return
        }
        XCTAssertTrue(
            agentStatusChangedPaneIDs(inLine: subscribeLine).contains("w1:p2"),
            "the rebuilt subscription must include a per-pane agentStatusChanged subscription for the NEW pane"
        )
    }

    func test_paneCreatedEvent_forAlreadyKnownPane_doesNotRebuild_antiStorm() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveToSettledConnection(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        let callCountAfterSettling = await factory.callCount
        XCTAssertEqual(callCountAfterSettling, 2, "Precondition: settles after exactly one A1 bootstrap rebuild")

        // Simulates a (re)subscribe's own replay burst re-announcing an
        // ALREADY-snapshotted pane -- must never itself trigger a
        // rebuild, or every (re)subscribe would immediately rebuild
        // once per replayed pane (an exploding reconnect storm).
        await settledTransport.simulateLine(paneCreatedEventLine(paneID: "w1:p1"))
        for _ in 0..<200 { await Task.yield() }

        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 2, "a paneCreated event for an ALREADY-known pane id must never trigger a rebuild"
        )
    }

    func test_paneClosedEvent_alwaysRebuildsConnection_unconditionally() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        // Empty snapshot -- pane_closed/pane_exited rebuild
        // unconditionally regardless of `knownPaneIDs` (see this file's
        // own header), so no pre-existing pane is needed to exercise it.
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask
        guard let firstTransport = await factory.transport(at: 0) else {
            XCTFail("expected transport #0 to exist")
            return
        }
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 1, "Precondition")

        // "w1:neverKnown" was never in knownPaneIDs (this attempt's own
        // snapshot above was empty) -- deliberately, to prove this is
        // truly UNCONDITIONAL, not merely triggered because the pane
        // happened to already be known.
        await firstTransport.simulateLine(paneClosedEventLine(paneID: "w1:neverKnown"))

        _ = await awaitTransport(factory, at: 1)
        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 2,
            "a \"pane_closed\" event (decoded to .paneClosed(paneID:), per HerdrEvent.swift's own B1 rule) must " +
            "unconditionally rebuild the connection, even for a pane id this connection never knew about"
        )
    }

    /// Companion to the test above -- identical shape, "pane_exited" /
    /// `.paneExited(paneID:)` instead of "pane_closed" / `.paneClosed(paneID:)`.
    func test_paneExitedEvent_alwaysRebuildsConnection_unconditionally() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask
        guard let firstTransport = await factory.transport(at: 0) else {
            XCTFail("expected transport #0 to exist")
            return
        }
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 1, "Precondition")

        await firstTransport.simulateLine(paneExitedEventLine(paneID: "w1:neverKnown"))

        _ = await awaitTransport(factory, at: 1)
        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 2,
            "a \"pane_exited\" event (decoded to .paneExited(paneID:), per HerdrEvent.swift's own B1 rule) must " +
            "unconditionally rebuild the connection, even for a pane id this connection never knew about"
        )
    }

    // MARK: - A4: closing/exiting a pane removes it from knownPaneIDs before rebuilding

    /// Settles a connection whose subscription covers "w1:p1", closes
    /// that pane, then asserts the REBUILT transport's own
    /// `events.subscribe` no longer lists it -- see this file's header
    /// "A4" and `HerdrIntegrationCoordinator.swift`'s own "REBUILD
    /// TRIGGERS" section. Without A4, the rebuilt subscribe would still
    /// carry a `.agentStatusChanged(paneID: "w1:p1")` entry for a pane
    /// herdr just said is gone -- unmeasured server behavior this fix
    /// exists to avoid.
    func test_paneClosedEvent_removesPaneFromKnownPaneIDs_beforeRebuilding_soRebuiltSubscribeExcludesIt() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveToSettledConnection(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        let callCountAfterSettling = await factory.callCount
        XCTAssertEqual(callCountAfterSettling, 2, "Precondition: settles after exactly one A1 bootstrap rebuild")

        await settledTransport.simulateLine(paneClosedEventLine(paneID: "w1:p1"))

        guard let rebuiltTransport = await awaitTransport(factory, at: 2) else {
            XCTFail("expected the pane_closed event to rebuild the connection")
            return
        }
        let callCountAfterRebuild = await factory.callCount
        XCTAssertEqual(callCountAfterRebuild, 3, "the pane_closed event must open exactly one replacement session")

        // The rebuilt attempt's own snapshot also reveals an empty pane
        // set -- herdr no longer knows about "w1:p1" either, matching
        // what just closed, so this settles without a further A1 rebuild.
        await driveInitialSequence(factory: factory, transportIndex: 2, snapshotPaneIDs: [])

        let rebuiltSent = await rebuiltTransport.sentMessages()
        guard let subscribeLine = rebuiltSent.first(where: { requestMethod(inLine: $0) == "events.subscribe" }) else {
            XCTFail("expected the rebuilt session to send its own events.subscribe request; got \(rebuiltSent)")
            return
        }
        XCTAssertTrue(
            agentStatusChangedPaneIDs(inLine: subscribeLine).isEmpty,
            "A4: closing a pane must remove its id from knownPaneIDs BEFORE rebuilding, so the rebuilt " +
            "connection's own subscribe must not resubscribe an agentStatusChanged for a pane herdr no longer " +
            "knows about"
        )

        let finalCallCount = await factory.callCount
        XCTAssertEqual(finalCallCount, 3, "a matching (empty) revealed set must settle immediately -- no further rebuild")
    }

    // MARK: - paneAgentStatusChanged reaches the mirror end-to-end

    func test_paneAgentStatusChangedEvent_isForwardedToMirror() async {
        let factory = SpyHerdrSessionFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let coordinator = makeDetectableCoordinator(factory: factory, mirror: mirror)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        async let startTask: Void = coordinator.start()
        guard let transport = await driveToSettledConnection(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        XCTAssertEqual(registry.externalEntries[id]?.state, .working, "Precondition: initial snapshot state")

        await transport.simulateLine(statusChangedEventLine(paneID: "w1:p1", status: "blocked"))
        await waitUntil { registry.externalEntries[id]?.state == .blocked }

        XCTAssertEqual(
            registry.externalEntries[id]?.state, .blocked,
            "a pushed pane.agent_status_changed event must reach the mirror and update the row's state"
        )
    }

    // MARK: - DISCONNECT HANDLING

    func test_streamEOF_callsConnectionLost_thenReconnectsWhileSocketStillAlive() async {
        let factory = SpyHerdrSessionFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        let coordinator = makeDetectableCoordinator(
            factory: factory, discovery: discovery, mirror: mirror, reconnectDelays: [.zero]
        )
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveToSettledConnection(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        XCTAssertNotNil(registry.externalEntries[id], "Precondition: the snapshot must have created a row")
        let callCountAfterSettling = await factory.callCount
        XCTAssertEqual(callCountAfterSettling, 2, "Precondition: settled after exactly one A1 bootstrap rebuild")

        await settledTransport.simulateEOF()

        _ = await awaitTransport(factory, at: 2)
        let callCountAfterEOF = await factory.callCount
        XCTAssertEqual(
            callCountAfterEOF, 3,
            "a clean EOF must be followed by a bounded reconnect attempt while the socket still probes alive"
        )
        await waitUntil { registry.externalEntries.isEmpty }
        XCTAssertTrue(registry.externalEntries.isEmpty, "an EOF must call mirror.connectionLost()")
    }

    func test_streamEOF_whenSocketNoLongerProbesAlive_stopsWithoutRetrying() async {
        let factory = SpyHerdrSessionFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        let coordinator = makeDetectableCoordinator(
            factory: factory, discovery: discovery, reconnectDelays: [.zero, .zero]
        )

        async let startTask: Void = coordinator.start()
        // Empty snapshot -- avoids an A1 bootstrap rebuild; this test
        // only cares about the reconnect-vs-dead-socket gate.
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask
        guard let firstTransport = await factory.transport(at: 0) else {
            XCTFail("expected transport #0 to exist")
            return
        }
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 1, "Precondition")

        discovery.markDead(socketPath) // the socket is genuinely gone now
        await firstTransport.simulateEOF()

        for _ in 0..<200 { await Task.yield() }

        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 1,
            "once the socket no longer probes alive, the coordinator must stop entirely -- no reconnect attempt"
        )
    }

    // MARK: - A5/A6: lifetime reconnect budget survives a healthy-looking-but-flapping cycle

    /// Replaces the old `test_reconnect_isBoundedByReconnectDelaysCount_thenGivesUp`,
    /// which EOFed reconnect sessions immediately after creation without
    /// ever driving them through a handshake -- it never exercised a
    /// successful reconnect, so it provided no protection for A5's own
    /// cross-cycle budget (a fresh `[1s,2s,4s]`-style budget handed out
    /// on every disconnect). This version drives every reconnect all the
    /// way through a completed handshake, then drops it again before any
    /// event is ever pushed, proving `maxLifetimeReconnectAttempts`
    /// bounds the TOTAL across cycles even when each individual cycle's
    /// own first attempt "succeeds".
    func test_reconnect_isBoundedAcrossCycles_evenWhenEachAttemptCompletesItsHandshake_thenGivesUpPermanently() async {
        let factory = SpyHerdrSessionFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        // `reconnectDelays.count` (3) is deliberately LARGER than
        // `maxLifetimeReconnectAttempts` (2) -- what stops this must be
        // the CROSS-CYCLE lifetime budget, not any single cycle's own
        // per-cycle exhaustion (which never gets the chance to fire
        // here: every attempt below succeeds, so each cycle only ever
        // consumes its own first delay before handing off to
        // `consumeEvents` again).
        let coordinator = makeDetectableCoordinator(
            factory: factory, discovery: discovery, reconnectDelays: [.zero, .zero, .zero], maxLifetimeReconnectAttempts: 2
        )

        async let startTask: Void = coordinator.start()
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask
        guard let firstTransport = await factory.transport(at: 0) else {
            XCTFail("expected transport #0 to exist")
            return
        }
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 1, "Precondition")

        await firstTransport.simulateEOF()

        // Reconnect #1 (lifetime attempt 1 of 2): completes its FULL
        // handshake -- a real reconnect, not a bare connect failure --
        // then drops again before any event is ever pushed, so it never
        // earns the HEALTHY reset (A5).
        guard let secondTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected reconnect attempt #1 (session #2)")
            return
        }
        await driveInitialSequence(factory: factory, transportIndex: 1, snapshotPaneIDs: [])
        await secondTransport.simulateEOF()

        // Reconnect #2 (lifetime attempt 2 of 2): same shape.
        guard let thirdTransport = await awaitTransport(factory, at: 2) else {
            XCTFail("expected reconnect attempt #2 (session #3)")
            return
        }
        await driveInitialSequence(factory: factory, transportIndex: 2, snapshotPaneIDs: [])
        await thirdTransport.simulateEOF()

        // The lifetime budget (2) is now exhausted -- no further
        // attempt, even though reconnectDelays' own per-cycle count (3)
        // was never exhausted and the socket still probes alive.
        for _ in 0..<200 { await Task.yield() }

        let finalCallCount = await factory.callCount
        XCTAssertEqual(
            finalCallCount, 3,
            "maxLifetimeReconnectAttempts (2) must bound reconnects ACROSS cycles even when every attempt " +
            "completes its own handshake before dropping again -- 3 sessions total (original + 2 reconnects), " +
            "then a permanent give-up, never a 4th"
        )
    }

    /// The other half of A5's "healthy" bar (see `consumeEvents`'s own
    /// `hasEarnedHealthyReset` comment): a connection that DOES deliver at
    /// least one event after its handshake completes must reset
    /// `totalReconnectAttempts` back to zero, so a later, unrelated cycle of
    /// disconnects gets a full fresh lifetime budget again. The sibling
    /// test above only proves a handshake-only connection does NOT reset
    /// the budget -- this proves the positive case actually fires, which is
    /// the load-bearing half of A5 (it is what separates a transient blip
    /// from a permanent give-up).
    func test_reconnect_connectionThatDeliversAnEvent_resetsLifetimeBudget_soLaterCyclesGetAFreshBudget() async {
        let factory = SpyHerdrSessionFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        let coordinator = makeDetectableCoordinator(
            factory: factory, discovery: discovery, reconnectDelays: [.zero, .zero, .zero], maxLifetimeReconnectAttempts: 2
        )

        async let startTask: Void = coordinator.start()
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: [])
        await startTask
        guard let firstTransport = await factory.transport(at: 0) else {
            XCTFail("expected transport #0 to exist")
            return
        }
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 1, "Precondition")

        await firstTransport.simulateEOF()

        // Reconnect #1 (lifetime attempt 1 of 2): completes its handshake,
        // THEN is pushed one event ("layout_updated", decoded generically
        // as `.unknown(eventType:)` -- not a rebuild trigger) before it is
        // dropped again. That pushed event is the ONLY thing distinguishing
        // this connection from the sibling test's non-resetting ones.
        // `simulateLine` then `simulateEOF`, called back to back on the
        // same actor, are delivered into the coordinator's event stream in
        // that same order (`AsyncStream` preserves FIFO order of yields),
        // so the event is guaranteed to be fully processed by
        // `consumeEvents` -- including its `totalReconnectAttempts = 0`
        // reset -- before the EOF ends this connection's loop.
        guard let secondTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected reconnect attempt #1 (session #2)")
            return
        }
        await driveInitialSequence(factory: factory, transportIndex: 1, snapshotPaneIDs: [])
        await secondTransport.simulateLine(#"{"event":"layout_updated"}"#)
        await secondTransport.simulateEOF()

        // Reconnect #2 (lifetime attempt 1 of the RESET budget) and
        // reconnect #3 (lifetime attempt 2 of the reset budget): same
        // handshake-only-then-drop shape as the sibling test's cycles --
        // neither earns HEALTHY, so nothing resets the budget again.
        guard let thirdTransport = await awaitTransport(factory, at: 2) else {
            XCTFail("expected reconnect attempt #2 (session #3) -- the budget must have been reset by the event above")
            return
        }
        await driveInitialSequence(factory: factory, transportIndex: 2, snapshotPaneIDs: [])
        await thirdTransport.simulateEOF()

        guard let fourthTransport = await awaitTransport(factory, at: 3) else {
            XCTFail(
                "expected reconnect attempt #3 (session #4) -- proves the reset granted a FULL fresh budget " +
                "(2 more attempts), not merely one bonus attempt"
            )
            return
        }
        await driveInitialSequence(factory: factory, transportIndex: 3, snapshotPaneIDs: [])
        await fourthTransport.simulateEOF()

        // The reset budget (2), consumed by reconnects #2 and #3, is now
        // exhausted again -- no further attempt.
        for _ in 0..<200 { await Task.yield() }

        let finalCallCount = await factory.callCount
        XCTAssertEqual(
            finalCallCount, 4,
            "a connection that delivered an event must reset the lifetime budget -- 4 sessions total (original + " +
            "the reconnect that earned the reset + 2 more reconnects consuming a FRESH budget), then a permanent " +
            "give-up. Without the reset this would stop at 3, identical to the sibling non-resetting test above."
        )
    }

    // MARK: - A2: handshake deadline

    func test_attemptConnect_handshakeHangsForever_timesOutAndGivesUpPlainly_thenAllowsFreshStart() async {
        let factory = SpyHerdrSessionFactory()
        // Gated, NOT an instant no-op -- BLOCKER fix note: the TIMEOUT
        // arm now calls `session.abandon()` (closing the transport) the
        // moment it actually wins the race, so an instant no-op `sleep`
        // could let it win BEFORE the handshake arm ever reaches
        // `transport.send("ping")`, closing the transport out from under
        // it and making "ping" never actually get sent -- turning this
        // test's own precondition check below flaky. Gating on an
        // explicit flag, opened only once "ping" is confirmed in flight,
        // keeps this test's actual subject (a handshake that hangs
        // forever AFTER sending ping, never getting a reply)
        // deterministic -- mirrors the identical gate (and its own doc
        // comment) in the BLOCKER regression test below.
        let timeoutGate = OSAllocatedUnfairLock(initialState: false)
        let coordinator = makeDetectableCoordinator(
            factory: factory,
            sleep: { _ in
                while !timeoutGate.withLock({ $0 }) {
                    if Task.isCancelled { return }
                    await Task.yield()
                }
            }
        )

        async let startTask: Void = coordinator.start()

        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected start() to create a session before its handshake hangs")
            return
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        XCTAssertEqual(
            sent.compactMap { requestMethod(inLine: $0) }, ["ping"],
            "Precondition: ping must have been sent before this test leaves it unanswered forever"
        )
        timeoutGate.withLock { $0 = true } // ping is confirmed in flight -- now let the timeout arm resolve

        // Deliberately never respond to "ping" -- the handshake hangs
        // forever awaiting its response. `await startTask` below must
        // still return (never hang the TEST itself) because of the A2
        // bounded handshake deadline.
        await startTask

        let callCountAfterTimeout = await factory.callCount
        XCTAssertEqual(
            callCountAfterTimeout, 1,
            "a hung FIRST connect must give up plainly once its deadline expires -- no retry, mirrors an " +
            "ordinary connect failure"
        )

        // A later start() must behave like a fresh attempt, proving
        // `isActive` was reset rather than left stuck "connecting"
        // forever.
        await coordinator.start()
        let callCountAfterFreshStart = await factory.callCount
        XCTAssertEqual(
            callCountAfterFreshStart, 2,
            "start() after a timed-out handshake must attempt a fresh connection, not stay stuck"
        )
    }

    // MARK: - BLOCKER regression: a timed-out handshake must not leak its session/socket/task

    /// Traces the exact mechanism the BLOCKER report described: herdr
    /// accepts the connection but never answers `ping()`, so
    /// `performHandshake` is suspended forever inside
    /// `HerdrSocketSession.awaitEntry`'s own
    /// `withCheckedThrowingContinuation` -- a `CheckedContinuation` that
    /// does not resume itself on cancellation. Unlike the sibling A2
    /// test above (which can safely use an instant no-op `sleep` because
    /// its handshake is NEVER driven to completion at all), this test's
    /// own `sleep` closure is gated on an explicit flag, opened only
    /// once `ping` is confirmed actually in flight -- otherwise the
    /// timeout arm could fire before `ping` is even sent, and this test
    /// would pass by accident via a different, unrelated race (the send
    /// path) instead of actually pinning the STUCK-CONTINUATION
    /// mechanism the BLOCKER report traced.
    func test_attemptConnect_handshakeHangsForever_timesOut_abandonsSession_releasingItWithoutLeaking() async {
        let factory = SpyHerdrSessionFactory()
        let timeoutGate = OSAllocatedUnfairLock(initialState: false)
        let coordinator = makeDetectableCoordinator(
            factory: factory,
            sleep: { _ in
                while !timeoutGate.withLock({ $0 }) {
                    if Task.isCancelled { return }
                    await Task.yield()
                }
            }
        )

        async let startTask: Void = coordinator.start()

        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected start() to create a session before its handshake hangs")
            return
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        XCTAssertEqual(
            sent.compactMap { requestMethod(inLine: $0) }, ["ping"],
            "Precondition: ping must be in flight -- and deliberately never answered -- before the timeout arm opens"
        )

        // Only NOW let the timeout arm's `sleep` resolve: ping is
        // confirmed stuck inside `awaitEntry`, exactly the mechanism the
        // BLOCKER report traced.
        timeoutGate.withLock { $0 = true }

        // (1) resolve the awaiting caller -- same as the sibling A2 test.
        await startTask

        // (3) not retain the session -- assert release with a weak
        // reference, once the timeout path completes. This necessarily
        // also proves (2) (the session actually terminated its pending
        // request): the session can only become releasable once its own
        // stuck `ping()` continuation actually resolved and let
        // `performHandshake`'s `Task` closure unwind and drop its
        // captures.
        await waitUntil { await factory.isSessionAlive(at: 0) == false }
        let sessionAlive = await factory.isSessionAlive(at: 0)
        XCTAssertFalse(
            sessionAlive,
            "BLOCKER: a timed-out handshake must not leak its HerdrSocketSession -- abandon() must let the " +
            "stuck ping() throw, unwind performHandshake's Task, and release every strong reference to it"
        )

        // (2) actually terminate the session -- probed AFTER the release
        // poll above, so `abandon()` (and therefore `transport.close()`)
        // is guaranteed to have already fully run: a new send must now
        // be rejected, proving `abandon()` reached `transport.close()`,
        // not merely `Task.cancel()`, which would have left the
        // transport, its fd, and its `DispatchSourceRead` all still open.
        do {
            try await transport.send(#"{"id":"probe","method":"ping"}"#)
            XCTFail("expected the abandoned transport to already be closed")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(
                error, .alreadyClosed, "abandon() must actually close() the transport, not merely cancel the Task"
            )
        } catch {
            XCTFail("expected HerdrTransportError.alreadyClosed, got \(type(of: error)): \(error)")
        }

        let callCountAfterTimeout = await factory.callCount
        XCTAssertEqual(callCountAfterTimeout, 1, "a hung FIRST connect must give up plainly -- no retry")
    }

    // MARK: - A3 (SHOULD-FIX): bootstrap rebuild iteration cap

    /// A pane set that never stops revealing a freshly different set on
    /// every single BOOTSTRAP REBUILD (A1) retry would otherwise spin
    /// `attemptConnect`'s own loop forever -- see this file's header and
    /// HerdrIntegrationCoordinator.swift's own "A3". Caps at 3 (well
    /// below the production default of 5) so this test does not need to
    /// drive an impractical number of full handshake round trips; the
    /// real-clock default `sleep` is fine here since every one of those
    /// round trips completes well under `handshakeTimeout`.
    func test_attemptConnect_bootstrapRebuild_neverConverges_stopsAtIterationCap_ratherThanSpinningForever() async {
        let factory = SpyHerdrSessionFactory()
        let coordinator = makeDetectableCoordinator(factory: factory, maxBootstrapRebuildIterations: 3)

        async let startTask: Void = coordinator.start()

        // Transport #0 subscribes {} but reveals {"p0"}; transport #1
        // subscribes {"p0"} but reveals {"p1"}; transport #2 subscribes
        // {"p1"} but reveals {"p2"} -- A1's own mismatch-triggers-retry
        // rule never lets this converge.
        await driveInitialSequence(factory: factory, transportIndex: 0, snapshotPaneIDs: ["p0"])
        await driveInitialSequence(factory: factory, transportIndex: 1, snapshotPaneIDs: ["p1"])
        await driveInitialSequence(factory: factory, transportIndex: 2, snapshotPaneIDs: ["p2"])

        await startTask

        let callCountAtCap = await factory.callCount
        XCTAssertEqual(
            callCountAtCap, 3,
            "SHOULD-FIX: a never-converging pane set must stop at the injected iteration cap (3), never open a " +
            "4th session"
        )

        // Bounded cooperative yielding: proves this is a genuine STOP,
        // not merely "hasn't gotten to a 4th iteration yet".
        for _ in 0..<200 { await Task.yield() }

        let callCountAfterWaiting = await factory.callCount
        XCTAssertEqual(callCountAfterWaiting, 3, "must not spin past the cap even after waiting")
    }

    // MARK: - Fixture builders (exact shapes measured against real herdr 0.8.0)

    private func pingResponseLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"pong","version":"0.8.0","protocol":19,"capabilities":{"live_handoff":true,"detached_server_daemon":false}}}"#
    }

    private func subscribeAckLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    private func snapshotResponseLine(id: String, paneIDs: [String]) -> String {
        let agentsJSON = paneIDs.map { paneID in
            #"{"terminal_id":"term_\#(paneID)","agent":"claude","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"\#(paneID)","focused":false,"state_change_seq":0,"cwd":"/Users/dev/project","foreground_cwd":"/Users/dev/project","revision":0}"#
        }.joined(separator: ",")
        return #"{"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":null,"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[\#(agentsJSON)]}}}"#
    }

    private func paneCreatedEventLine(paneID: String, workspaceID: String = "w1") -> String {
        #"{"data":{"pane":{"terminal_id":"term_\#(paneID)","agent":null,"agent_status":"unknown","workspace_id":"\#(workspaceID)","tab_id":"\#(workspaceID):t1","pane_id":"\#(paneID)","focused":false,"state_change_seq":0,"cwd":null,"foreground_cwd":null,"revision":0},"type":"pane_created"},"event":"pane_created"}"#
    }

    /// Real B1 shape (flat `data.pane_id`) -- see HerdrEvent.swift's own
    /// header "B1 rule"; the exact shape isn't load-bearing here (both
    /// the nested and flat shapes are already pinned exhaustively by
    /// HerdrEventTests), only that it decodes to `.paneClosed(paneID:)`.
    private func paneClosedEventLine(paneID: String) -> String {
        #"{"event":"pane_closed","data":{"pane_id":"\#(paneID)"}}"#
    }

    /// Companion to `paneClosedEventLine(paneID:)` above, same flat B1
    /// shape, for `.paneExited(paneID:)`.
    private func paneExitedEventLine(paneID: String) -> String {
        #"{"event":"pane_exited","data":{"pane_id":"\#(paneID)"}}"#
    }

    private func statusChangedEventLine(paneID: String, status: String, workspaceID: String = "w1") -> String {
        #"{"event":"pane.agent_status_changed","data":{"pane_id":"\#(paneID)","workspace_id":"\#(workspaceID)","agent_status":"\#(status)","agent":"claude","display_agent":null,"title":null,"state_labels":{}}}"#
    }

    // MARK: - Wire-line parsing helpers (parse back to JSON -- never string comparison, JSONEncoder key order isn't stable)

    private func jsonObject(inLine line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func requestID(inLine line: String) -> String? {
        jsonObject(inLine: line)?["id"] as? String
    }

    private func requestMethod(inLine line: String) -> String? {
        jsonObject(inLine: line)?["method"] as? String
    }

    private func subscriptionEntries(inLine line: String) -> [[String: Any]] {
        guard let params = jsonObject(inLine: line)?["params"] as? [String: Any] else { return [] }
        return params["subscriptions"] as? [[String: Any]] ?? []
    }

    private func subscriptionTypes(inLine line: String) -> [String] {
        subscriptionEntries(inLine: line).compactMap { $0["type"] as? String }
    }

    private func agentStatusChangedPaneIDs(inLine line: String) -> [String] {
        subscriptionEntries(inLine: line)
            .filter { ($0["type"] as? String) == "pane.agent_status_changed" }
            .compactMap { $0["pane_id"] as? String }
    }

    // MARK: - Bounded async polling (mirrors HerdrSocketSessionTests' own waitUntil precedent)

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve -- a regression that leaves
    /// `condition()` permanently false (e.g. a session/transport that
    /// never gets created, or one that leaks instead of being released)
    /// exhausts this bound instead of hanging the test; the subsequent
    /// `guard ... else { XCTFail }` / `XCTAssert...` in each test above
    /// is what turns that into a clean, informative failure.
    private func waitUntil(maxYields: Int = 10_000, _ condition: () async -> Bool) async {
        var iterations = 0
        while await !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    private func awaitTransport(_ factory: SpyHerdrSessionFactory, at index: Int) async -> InMemoryHerdrTransport? {
        await waitUntil { await factory.callCount > index }
        return await factory.transport(at: index)
    }

    private func awaitSentMessages(_ transport: InMemoryHerdrTransport, atLeast count: Int) async -> [String] {
        await waitUntil { await transport.sentMessages().count >= count }
        return await transport.sentMessages()
    }

    /// Drives transport #`index` through ping -> subscribe -> snapshot,
    /// in that STRICT order (position 0/1/2 in `sentMessages()`),
    /// replying to each as soon as it is sent. Returns once the
    /// snapshot response has been handed to the transport; callers still
    /// `await` their own `start()`/reconnect task afterward.
    private func driveInitialSequence(
        factory: SpyHerdrSessionFactory, transportIndex: Int, snapshotPaneIDs: [String]
    ) async {
        guard let transport = await awaitTransport(factory, at: transportIndex) else {
            XCTFail("expected transport #\(transportIndex) to have been created")
            return
        }

        let afterPing = await awaitSentMessages(transport, atLeast: 1)
        guard afterPing.count >= 1, requestMethod(inLine: afterPing[0]) == "ping",
              let pingID = requestID(inLine: afterPing[0]) else {
            XCTFail("expected the FIRST request on transport #\(transportIndex) to be 'ping'; got \(afterPing)")
            return
        }
        await transport.simulateLine(pingResponseLine(id: pingID))

        let afterSubscribe = await awaitSentMessages(transport, atLeast: 2)
        guard afterSubscribe.count >= 2, requestMethod(inLine: afterSubscribe[1]) == "events.subscribe",
              let subscribeID = requestID(inLine: afterSubscribe[1]) else {
            XCTFail(
                "expected the SECOND request on transport #\(transportIndex) to be 'events.subscribe'; " +
                "got \(afterSubscribe)"
            )
            return
        }
        await transport.simulateLine(subscribeAckLine(id: subscribeID))

        let afterSnapshot = await awaitSentMessages(transport, atLeast: 3)
        guard afterSnapshot.count >= 3, requestMethod(inLine: afterSnapshot[2]) == "session.snapshot",
              let snapshotID = requestID(inLine: afterSnapshot[2]) else {
            XCTFail(
                "expected the THIRD request on transport #\(transportIndex) to be 'session.snapshot'; " +
                "got \(afterSnapshot)"
            )
            return
        }
        await transport.simulateLine(snapshotResponseLine(id: snapshotID, paneIDs: snapshotPaneIDs))
    }
}
