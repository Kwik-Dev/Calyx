//
//  HerdrIntegrationCoordinatorTests.swift
//  CalyxTests
//
//  HerdrIntegrationCoordinator's detection gate, CONNECT SEQUENCE
//  ordering (a one-shot `session.snapshot` on its OWN transport, applied
//  to the mirror and used to build the per-pane subscribe list, BEFORE a
//  SEPARATE `events.subscribe` transport is ever opened), pane-set
//  REBUILD triggers (including the anti-storm dedup against a
//  (re)subscribe's own replay burst), the PER-STEP handshake deadline
//  (A2), and EOF/failure DISCONNECT HANDLING with a reconnect budget
//  bounded across cycles for this instance's whole lifetime (A5/A6). See
//  HerdrIntegrationCoordinator.swift's own header for the full frozen
//  contract, and HerdrConnection.swift's own header for the measured
//  wire facts this coordinator is built from.
//
//  Every dependency is a fake/spy -- no real socket is ever opened.
//  `SpyHerdrTransportFactory` hands out a fresh `InMemoryHerdrTransport`
//  per `makeTransport()` call, retaining each so tests can drive/inspect
//  it. `HerdrAgentMirror` and `AgentRegistry` are used as REAL, freshly-
//  constructed instances (never mocked) -- registry state is this file's
//  way of confirming the coordinator's snapshot/event/connectionLost
//  calls actually reached the mirror.
//
//  TRANSPORT ACCOUNTING: unlike the type this coordinator used to depend
//  on (one persistent, multiplexed connection per connect attempt), EVERY
//  successful connect attempt now opens exactly TWO transports -- an
//  even-indexed one-shot `session.snapshot` connection (which always
//  closes itself once answered) immediately followed by an odd-indexed,
//  long-lived `events.subscribe` connection (the only one any test ever
//  injects further events onto). `driveConnectAttempt(factory:baseIndex:
//  paneIDs:)` below drives exactly one such pair and is the base every
//  call-count assertion in this file is built from -- never hand-rolled
//  per test.
//
//  Coverage:
//  - herdr not detected (resolver nil, or no live socket) -> zero factory calls
//  - never calling start() -> zero factory calls, no background timer
//  - start(): a one-shot session.snapshot (its own transport) completes
//    BEFORE a separate events.subscribe transport is ever opened; the
//    fetched snapshot is applied to the mirror; the subscribe's own
//    per-pane list is exactly what that snapshot revealed, alongside the
//    six structure events (including "workspace.closed")
//  - start() while already connected is a no-op (repeated "app became active")
//  - a paneCreated event for a genuinely NEW pane rebuilds the connection
//    (a fresh snapshot + a fresh subscribe transport), and the rebuilt
//    subscribe list includes that new pane
//  - a paneCreated event for an ALREADY-known pane does NOT rebuild
//    (anti-storm: the (re)subscribe's own replay burst must not self-trigger)
//  - "pane_closed"/"pane_exited" events always rebuild unconditionally,
//    regardless of what is currently known
//  - a rebuild's own subscribe list is derived from THAT rebuild's OWN
//    fresh snapshot (never from separately-mutated bookkeeping) -- a
//    closed pane is excluded because the fresh snapshot no longer reveals
//    it, not because of any special-cased removal step; the superseded
//    event-stream transport is explicitly closed
//  - a paneAgentStatusChanged event reaches the mirror end-to-end
//  - EOF calls mirror.connectionLost(), then reconnects (a fresh 2-transport
//    connect attempt) while the socket still probes alive
//  - EOF stops entirely (no retry) once the socket no longer probes alive
//  - A5/A6: the reconnect budget is bounded ACROSS cycles (not just within
//    one), surviving a reconnect that completes its own connect sequence
//    and then drops again before any event is ever pushed
//  - A2, per step: a snapshot that hangs forever times out and gives up
//    plainly (no subscribe transport ever created), closing its own
//    transport (BLOCKER-analog: proof the stuck step is actually
//    unstuck, not merely abandoned) -- and a later start() still proceeds
//    fresh afterward; a subscribe that hangs forever times out the same way
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
/// (`OSAllocatedUnfairLock`-backed) -- `markDead(_:)` lets a test flip a
/// socket path from "alive" to "gone" mid-run, for the DISCONNECT
/// HANDLING tests.
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

/// `HerdrTransportFactory` spy: each `makeTransport()` call hands out a
/// fresh `InMemoryHerdrTransport`, retaining it so tests can drive/
/// inspect it -- `transports.count` IS this spy's call count.
private actor SpyHerdrTransportFactory: HerdrTransportFactory {
    private(set) var transports: [InMemoryHerdrTransport] = []

    func makeTransport() async -> any HerdrTransport {
        let transport = InMemoryHerdrTransport()
        transports.append(transport)
        return transport
    }

    var callCount: Int { transports.count }

    func transport(at index: Int) -> InMemoryHerdrTransport? {
        transports.indices.contains(index) ? transports[index] : nil
    }
}

// MARK: - HerdrIntegrationCoordinatorTests

@MainActor
final class HerdrIntegrationCoordinatorTests: XCTestCase {

    private let socketPath = "/tmp/herdr-coordinator-test/herdr.sock"

    // MARK: - Coordinator construction helper

    /// `sleep` defaults to the SAME real-clock closure the coordinator's
    /// own initializer defaults to (`Task.sleep(for:)`), not a no-op --
    /// A2's PER-STEP handshake deadline races every driven step against
    /// `handshakeTimeout` using this SAME closure, so a no-op default
    /// would resolve that race arm instantly, before a step this suite is
    /// actively driving (over several genuine actor hops) could ever win.
    /// `reconnectDelays` stay effectively instant in every test that sets
    /// them because every one of them uses `.zero`; `Task.sleep(for:
    /// .zero)` still suspends, but not for any real, test-slowing
    /// duration.
    private func makeDetectableCoordinator(
        factory: SpyHerdrTransportFactory,
        discovery: FakeHerdrSessionDiscovery? = nil,
        mirror: HerdrAgentMirror? = nil,
        reconnectDelays: [Duration] = [],
        maxLifetimeReconnectAttempts: Int = HerdrIntegrationCoordinator.defaultMaxLifetimeReconnectAttempts,
        replayBurstSettleWindow: Duration = HerdrIntegrationCoordinator.defaultReplayBurstSettleWindow,
        rebuildBackoffDelays: [Duration] = HerdrIntegrationCoordinator.defaultRebuildBackoffDelays,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> HerdrIntegrationCoordinator {
        HerdrIntegrationCoordinator(
            resolver: FakeHerdrBinaryResolver(result: "/opt/homebrew/bin/herdr"),
            discovery: discovery ?? FakeHerdrSessionDiscovery(
                candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
            ),
            transportFactory: factory,
            mirror: mirror ?? HerdrAgentMirror(registry: AgentRegistry()),
            reconnectDelays: reconnectDelays,
            maxLifetimeReconnectAttempts: maxLifetimeReconnectAttempts,
            replayBurstSettleWindow: replayBurstSettleWindow,
            rebuildBackoffDelays: rebuildBackoffDelays,
            sleep: sleep
        )
    }

    /// Drives ONE full CONNECT SEQUENCE attempt starting at transport
    /// `#baseIndex`: answers `#baseIndex`'s own (and ONLY) request --
    /// "session.snapshot" -- with a fixture revealing `paneIDs`; then
    /// waits for transport `#baseIndex + 1` (the events.subscribe
    /// connection, whose own per-pane list is therefore always exactly
    /// `paneIDs`) to be created, and answers ITS own (and only) request
    /// with the ack. Returns transport `#baseIndex + 1` -- the long-lived
    /// connection every subsequent event-injection/assertion in a test
    /// targets. `#baseIndex` itself needs no further attention: a
    /// one-shot request always closes its own transport once answered.
    @discardableResult
    private func driveConnectAttempt(
        factory: SpyHerdrTransportFactory, baseIndex: Int, paneIDs: [String]
    ) async -> InMemoryHerdrTransport? {
        guard let snapshotTransport = await awaitTransport(factory, at: baseIndex) else {
            XCTFail("expected transport #\(baseIndex) (the snapshot connection) to have been created")
            return nil
        }
        let snapshotSent = await awaitSentMessages(snapshotTransport, atLeast: 1)
        guard snapshotSent.count == 1, requestMethod(inLine: snapshotSent[0]) == "session.snapshot",
              let snapshotID = requestID(inLine: snapshotSent[0]) else {
            XCTFail("expected transport #\(baseIndex)'s only request to be 'session.snapshot'; got \(snapshotSent)")
            return nil
        }
        await snapshotTransport.simulateLine(snapshotResponseLine(id: snapshotID, paneIDs: paneIDs))

        guard let subscribeTransport = await awaitTransport(factory, at: baseIndex + 1) else {
            XCTFail("expected transport #\(baseIndex + 1) (the events.subscribe connection) to have been created")
            return nil
        }
        let subscribeSent = await awaitSentMessages(subscribeTransport, atLeast: 1)
        guard subscribeSent.count == 1, requestMethod(inLine: subscribeSent[0]) == "events.subscribe",
              let subscribeID = requestID(inLine: subscribeSent[0]) else {
            XCTFail("expected transport #\(baseIndex + 1)'s only request to be 'events.subscribe'; got \(subscribeSent)")
            return nil
        }
        await subscribeTransport.simulateLine(subscribeAckLine(id: subscribeID))

        return subscribeTransport
    }

    // MARK: - Detection gate

    func test_start_whenHerdrNotDetected_resolverReturnsNil_doesNothing() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = HerdrIntegrationCoordinator(
            resolver: FakeHerdrBinaryResolver(result: nil),
            discovery: FakeHerdrSessionDiscovery(candidates: [], alive: []),
            transportFactory: factory,
            mirror: HerdrAgentMirror(registry: AgentRegistry()),
            reconnectDelays: [],
            sleep: { _ in }
        )

        await coordinator.start()

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 0, "herdr not detected (resolver returns nil) must never touch the transport factory")
    }

    func test_start_whenNoLiveSocket_doesNothing() async {
        let factory = SpyHerdrTransportFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [] // none alive
        )
        let coordinator = makeDetectableCoordinator(factory: factory, discovery: discovery)

        await coordinator.start()

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 0, "no live socket candidate must never touch the transport factory")
    }

    func test_neverCallingStart_doesNoWork_noBackgroundTimer() async {
        let factory = SpyHerdrTransportFactory()
        _ = makeDetectableCoordinator(factory: factory)

        for _ in 0..<50 { await Task.yield() }

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 0,
            "constructing a coordinator must never itself start a connection or a timer -- only an explicit " +
            "start() call may"
        )
    }

    // MARK: - CONNECT SEQUENCE ordering

    func test_start_takesSnapshotBeforeSubscribing_appliesToMirror_subscribeListIsStructureEventsPlusRevealedPanes() async {
        let factory = SpyHerdrTransportFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let coordinator = makeDetectableCoordinator(factory: factory, mirror: mirror)
        let expectedID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        async let startTask: Void = coordinator.start()

        guard let snapshotTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected start() to create a transport for the one-shot session.snapshot request first")
            return
        }
        let snapshotSent = await awaitSentMessages(snapshotTransport, atLeast: 1)
        XCTAssertEqual(
            snapshotSent.compactMap { requestMethod(inLine: $0) }, ["session.snapshot"],
            "the FIRST transport's only request must be session.snapshot, sent before any subscribe transport exists"
        )
        let connectedPath = await snapshotTransport.lastConnectedSocketPath()
        XCTAssertEqual(connectedPath, socketPath, "start() must connect to the discovered live socket path")
        guard let firstSnapshotLine = snapshotSent.first, let snapshotID = requestID(inLine: firstSnapshotLine) else {
            XCTFail("expected exactly one sent line carrying a request id, got \(snapshotSent)")
            return
        }

        // No subscribe transport must exist yet -- the snapshot has not
        // even been answered.
        let callCountBeforeSnapshotAnswered = await factory.callCount
        XCTAssertEqual(callCountBeforeSnapshotAnswered, 1, "subscribing must never happen before the snapshot completes")

        await snapshotTransport.simulateLine(snapshotResponseLine(id: snapshotID, paneIDs: ["w1:p1"]))

        guard let subscribeTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected the snapshot response to trigger a SEPARATE transport for events.subscribe")
            return
        }
        let subscribeSent = await awaitSentMessages(subscribeTransport, atLeast: 1)
        guard subscribeSent.count == 1, requestMethod(inLine: subscribeSent[0]) == "events.subscribe",
              let subscribeID = requestID(inLine: subscribeSent[0]) else {
            XCTFail("expected the second transport's only request to be events.subscribe; got \(subscribeSent)")
            return
        }
        XCTAssertEqual(
            Set(subscriptionTypes(inLine: subscribeSent[0])), Set(HerdrIntegrationCoordinator.structureEventSubscriptionTypes),
            "the subscribe must include exactly the six type-only structure events"
        )
        XCTAssertEqual(
            agentStatusChangedPaneIDs(inLine: subscribeSent[0]), ["w1:p1"],
            "the subscribe's own per-pane list must be exactly what the snapshot -- taken BEFORE it -- revealed"
        )
        await subscribeTransport.simulateLine(subscribeAckLine(id: subscribeID))

        await startTask

        let finalCallCount = await factory.callCount
        XCTAssertEqual(finalCallCount, 2, "one connect attempt must open exactly 2 transports: snapshot, then subscribe")
        XCTAssertNotNil(registry.externalEntries[expectedID], "the fetched snapshot must be applied to the injected mirror")
    }

    /// Subscription: the "workspace.closed" entry must be included
    /// alongside the other five structure events on every (re)subscribe
    /// -- see HerdrIntegrationCoordinator.swift's own header
    /// "STRUCTURE EVENT OBSERVER" and `structureEventSubscriptionTypes`'s
    /// own doc comment. The broader set-equality assertion above already
    /// covers this incidentally; this test pins it explicitly and by name.
    func test_start_subscribePayload_includesWorkspaceClosedEntry() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        guard await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) != nil else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask

        guard let subscribeTransport = await factory.transport(at: 1) else {
            XCTFail("expected the subscribe transport (index 1) to have been created")
            return
        }
        let subscribeSent = await subscribeTransport.sentMessages()
        guard subscribeSent.count == 1 else {
            XCTFail("expected exactly one request line, got \(subscribeSent)")
            return
        }
        XCTAssertTrue(
            subscriptionTypes(inLine: subscribeSent[0]).contains("workspace.closed"),
            "the subscribe payload must include the \"workspace.closed\" entry alongside the other structure events"
        )
    }

    /// `panes[]` and `agents[]` are two SEPARATE schema arrays feeding two
    /// SEPARATE consumers (HerdrIntegrationCoordinator.swift's own
    /// header, CONNECT SEQUENCE step 3): this coordinator seeds its
    /// per-pane subscription list from `panes[]` alone, while
    /// `HerdrAgentMirror.applySnapshot` creates rows only from
    /// `agents[]`. Measured live: a pane with no agent detected yet is
    /// present in `panes[]` but absent from `agents[]` -- exactly
    /// `panes = [wB:p1, wC:p1]`, `agents = [wB:p1]` here.
    func test_snapshot_paneWithoutAgent_isStillSubscribed_butGetsNoMirrorRow() async {
        let factory = SpyHerdrTransportFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let coordinator = makeDetectableCoordinator(factory: factory, mirror: mirror)
        let subscribedWithAgentID = HerdrStableID.make(socketPath: socketPath, paneID: "wB:p1")
        let agentlessID = HerdrStableID.make(socketPath: socketPath, paneID: "wC:p1")

        async let startTask: Void = coordinator.start()
        guard let snapshotTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected start() to create a transport for the one-shot session.snapshot request")
            return
        }
        let snapshotSent = await awaitSentMessages(snapshotTransport, atLeast: 1)
        guard let snapshotID = requestID(inLine: snapshotSent[0]) else {
            XCTFail("expected a request id, got \(snapshotSent)")
            return
        }
        // panes = [wB:p1, wC:p1] (both open panes); agents = [wB:p1] only
        // -- "wC:p1" is a plain shell pane with no agent detected yet.
        await snapshotTransport.simulateLine(
            snapshotResponseLine(id: snapshotID, paneIDs: ["wB:p1", "wC:p1"], agentPaneIDs: ["wB:p1"])
        )

        guard let subscribeTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected the snapshot response to trigger the events.subscribe transport")
            return
        }
        let subscribeSent = await awaitSentMessages(subscribeTransport, atLeast: 1)
        guard let subscribeID = requestID(inLine: subscribeSent[0]) else {
            XCTFail("expected a request id, got \(subscribeSent)")
            return
        }
        XCTAssertEqual(
            Set(agentStatusChangedPaneIDs(inLine: subscribeSent[0])), Set(["wB:p1", "wC:p1"]),
            "an agent-less pane (\"wC:p1\", present in panes[] but absent from agents[]) must still be " +
            "subscribed -- otherwise an agent started there later is never noticed"
        )
        await subscribeTransport.simulateLine(subscribeAckLine(id: subscribeID))
        await startTask

        XCTAssertNotNil(registry.externalEntries[subscribedWithAgentID], "\"wB:p1\" has an agent -- it must get a mirror row")
        XCTAssertNil(
            registry.externalEntries[agentlessID],
            "\"wC:p1\" has NO agent (absent from agents[]) -- it must get NO mirror row, even though it IS subscribed"
        )
        XCTAssertEqual(registry.externalEntries.count, 1, "exactly ONE external row must exist -- for \"wB:p1\" only")
    }

    // MARK: - Already-connected guard

    func test_start_calledAgainWhileAlreadyConnected_doesNotOpenAnotherConnection() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: [])
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition: exactly 2 transports must exist after the first start()")

        await coordinator.start() // e.g. "app became active" firing again while already live

        let secondCallCount = await factory.callCount
        XCTAssertEqual(
            secondCallCount, 2,
            "start() must be a no-op while already connected -- \"app became active\" can fire repeatedly and " +
            "must never open a duplicate connection"
        )
    }

    // MARK: - Rebuild triggers

    func test_paneCreatedEvent_forNewPane_rebuildsConnection_freshSnapshotAndSubscribe_withNewPaneIncluded() async {
        let factory = SpyHerdrTransportFactory()
        // `.zero` -- real-clock but effectively instant, same idiom as
        // `reconnectDelays: [.zero]` elsewhere in this file -- so the
        // REPLAY BURST RECONCILIATION accumulating phase this connect's
        // own subscribe always opens with (HerdrIntegrationCoordinator
        // .swift's own header) settles almost immediately, without racing
        // `handshakeTimeout` (left at its real default, so the CONNECT
        // SEQUENCE steps below are unaffected).
        let coordinator = makeDetectableCoordinator(factory: factory, replayBurstSettleWindow: .zero)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        // This test's subject is the STEADY-STATE trigger (REBUILD
        // TRIGGERS, HerdrIntegrationCoordinator.swift's own header): a
        // "pane.created" for a pane id not already recognized, once this
        // connection's own accumulating replay-burst phase has already
        // settled. Injecting it WHILE still accumulating would only add
        // it to `pendingBurstPaneIDs` instead (REPLAY BURST
        // RECONCILIATION) -- a deliberately different, separately-fixed
        // code path, not what this test is named for. `testOnlyIsAccumulatingReplayBurst`
        // exists precisely for this synchronization -- see its own doc
        // comment.
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }

        await settledTransport.simulateLine(paneCreatedEventLine(paneID: "w1:p2"))

        guard let rebuiltTransport = await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: ["w1:p2"]) else {
            XCTFail(
                "expected a paneCreated event for a genuinely NEW pane to rebuild the connection (a fresh " +
                "snapshot + a fresh subscribe transport)"
            )
            return
        }
        let afterRebuildCallCount = await factory.callCount
        XCTAssertEqual(afterRebuildCallCount, 4, "a pane-set change must open exactly 2 new transports, not more")

        let rebuiltSent = await rebuiltTransport.sentMessages()
        XCTAssertTrue(
            agentStatusChangedPaneIDs(inLine: rebuiltSent[0]).contains("w1:p2"),
            "the rebuilt subscription must include a per-pane agentStatusChanged subscription for the NEW pane"
        )
    }

    func test_paneCreatedEvent_forAlreadyKnownPane_doesNotRebuild_antiStorm() async {
        let factory = SpyHerdrTransportFactory()
        // `.zero` -- same idiom as the "new pane" test above -- so this
        // connection's own accumulating replay-burst phase settles almost
        // immediately; `rebuildBackoffDelays: [.zero]` so a WRONGLY
        // triggered rebuild (the defect this test exists to catch) would
        // manifest within a handful of task hops, comfortably inside the
        // 200-yield window below, rather than sitting behind a real
        // (unmockable via this helper) 200ms default backoff.
        let coordinator = makeDetectableCoordinator(factory: factory, replayBurstSettleWindow: .zero, rebuildBackoffDelays: [.zero])

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        let callCountAfterSettling = await factory.callCount
        XCTAssertEqual(callCountAfterSettling, 2, "Precondition")

        // This test's subject is the STEADY-STATE dedup (REBUILD
        // TRIGGERS, HerdrIntegrationCoordinator.swift's own header): a
        // "pane.created" for an ALREADY-recognized pane id, once this
        // connection's own accumulating replay-burst phase has already
        // settled. Injecting it WHILE still accumulating would instead
        // land in the FIRST `paneCreated` switch case
        // (`where isAccumulatingReplayBurst`), which unconditionally
        // accumulates into `pendingBurstPaneIDs` without ever consulting
        // `recognizedPaneIDs` -- a different code path this test is not
        // named for. `testOnlyIsAccumulatingReplayBurst` exists precisely
        // for this synchronization -- see its own doc comment, and the
        // sibling "new pane" test above.
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }

        // Simulates a pane.created event re-announcing an ALREADY-known
        // pane (e.g. a stray duplicate push, or a late replay straggler)
        // -- must never itself trigger a rebuild, or every already-known
        // pane reappearing would immediately rebuild (an exploding
        // reconnect storm).
        await settledTransport.simulateLine(paneCreatedEventLine(paneID: "w1:p1"))
        for _ in 0..<200 { await Task.yield() }

        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 2, "a paneCreated event for an ALREADY-known pane id must never trigger a rebuild"
        )
    }

    func test_paneClosedEvent_alwaysRebuildsConnection_unconditionally() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        // "w1:neverKnown" was never revealed by any snapshot this
        // coordinator has taken -- deliberately, to prove this is truly
        // UNCONDITIONAL, not merely triggered because the pane happened
        // to already be known.
        await settledTransport.simulateLine(paneClosedEventLine(paneID: "w1:neverKnown"))

        guard await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) != nil else {
            XCTFail("expected the pane_closed event to rebuild the connection")
            return
        }
        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 4,
            "a \"pane_closed\" event must unconditionally rebuild the connection (2 new transports), even for a " +
            "pane id this connection never knew about"
        )
    }

    /// Companion to the test above -- identical shape, "pane_exited"
    /// instead of "pane_closed".
    func test_paneExitedEvent_alwaysRebuildsConnection_unconditionally() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        await settledTransport.simulateLine(paneExitedEventLine(paneID: "w1:neverKnown"))

        guard await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) != nil else {
            XCTFail("expected the pane_exited event to rebuild the connection")
            return
        }
        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 4,
            "a \"pane_exited\" event must unconditionally rebuild the connection (2 new transports), even for a " +
            "pane id this connection never knew about"
        )
    }

    // MARK: - REPLAY BURST RECONCILIATION (direct coverage)

    /// Direct coverage for REPLAY BURST RECONCILIATION
    /// (HerdrIntegrationCoordinator.swift's own header) -- the measured
    /// production defect this whole rewrite exists to fix: a fresh
    /// subscribe's own replay burst can be a strict SUPERSET of the
    /// snapshot (ghost panes from workspaces closed before either probe
    /// ever connected, which replay forever but never appear in any
    /// snapshot). Mirrors the task's own measured example exactly:
    /// snapshot `{wB:p1, wC:p1}`, replay burst `{w8:p1, w9:p1, wA:p1,
    /// wB:p1, wC:p1}`. Expected: EXACTLY one rebuild -- connection 1's
    /// burst reveals `{w8, w9, wA}` as newly recognized; connection 2's
    /// OWN fresh snapshot is unchanged, and its own replay burst (the
    /// IDENTICAL 5 ids) reveals nothing new, so it converges with no
    /// further rebuild.
    ///
    /// Deliberately does NOT follow the code-review sketch's
    /// `replayBurstSettleWindow: .zero` + real-clock approach: that races
    /// a zero-duration `Task.sleep` against genuine in-memory event
    /// delivery (transport actor hop -> `HerdrEventStream`'s own relay
    /// task, itself NOT `@MainActor` -- HerdrConnection.swift's own doc
    /// comment on `subscribe(...)` -- -> the `AsyncThrowingStream`
    /// `consumeEvents` reads). If the settle task's sleep happened to
    /// resolve before all 5 burst lines were relayed and processed,
    /// `pendingBurstPaneIDs` would be incomplete at settle time -- a
    /// premature, empty-or-partial settle that either drops burst ids
    /// entirely (never unioned into `recognizedPaneIDs`) or lets the
    /// STEADY-STATE trigger fire per-id instead, in EITHER case risking
    /// this test asserting a MISLEADING pass/count (or a genuinely
    /// flaky failure) that does not actually pin the accumulating-phase
    /// dedup this mechanism exists to prove. Instead, the settle
    /// window's sleep call is intercepted BY DURATION (matching only
    /// `burstSettleWindow` below) and blocked on an explicit gate; a
    /// trailing "sentinel" event whose effect on the mirror IS
    /// independently observable (unlike `paneCreated`, a pure no-op for
    /// `HerdrAgentMirror` -- see that file's own header) proves, via the
    /// SAME `AsyncStream`/`AsyncThrowingStream` FIFO-ordering guarantee
    /// this file's own `test_reconnect_connectionThatDeliversAnEvent_...`
    /// test already relies on, that every burst line queued before it on
    /// the SAME transport has already been fully absorbed into
    /// `pendingBurstPaneIDs` BEFORE the gate is opened. Every OTHER sleep
    /// in this flow (the A2 handshake-timeout arms, and the rebuild
    /// backoff) is left to resolve via real `Task.sleep`, exactly like
    /// every other test in this file that does not override `sleep`.
    func test_replayBurst_stalePanesBeyondSnapshot_rebuildsExactlyOnce_thenConverges() async {
        let factory = SpyHerdrTransportFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let burstSettleWindow = Duration.milliseconds(1)
        let settleGate = OSAllocatedUnfairLock(initialState: false)
        let coordinator = makeDetectableCoordinator(
            factory: factory,
            mirror: mirror,
            replayBurstSettleWindow: burstSettleWindow,
            rebuildBackoffDelays: [.zero],
            sleep: { duration in
                guard duration == burstSettleWindow else {
                    try? await Task.sleep(for: duration)
                    return
                }
                while !settleGate.withLock({ $0 }) {
                    if Task.isCancelled { return }
                    await Task.yield()
                }
            }
        )
        let sentinelID = HerdrStableID.make(socketPath: socketPath, paneID: "wB:p1")

        async let startTask: Void = coordinator.start()
        guard let firstSubscribe = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["wB:p1", "wC:p1"]) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        // Replay burst: a strict SUPERSET of the snapshot -- "w8:p1"/
        // "w9:p1"/"wA:p1" are ghost panes that replay forever but never
        // appear in any snapshot.
        await firstSubscribe.simulateLine(paneCreatedEventLine(paneID: "w8:p1"))
        await firstSubscribe.simulateLine(paneCreatedEventLine(paneID: "w9:p1"))
        await firstSubscribe.simulateLine(paneCreatedEventLine(paneID: "wA:p1"))
        await firstSubscribe.simulateLine(paneCreatedEventLine(paneID: "wB:p1"))
        await firstSubscribe.simulateLine(paneCreatedEventLine(paneID: "wC:p1"))
        // Sentinel -- see this test's own doc comment above for why this
        // (rather than a fixed real-clock margin) is what proves the 5
        // lines above are already fully absorbed into
        // `pendingBurstPaneIDs` at this point.
        await firstSubscribe.simulateLine(statusChangedEventLine(paneID: "wB:p1", status: "blocked"))
        await waitUntil { registry.externalEntries[sentinelID]?.state == .blocked }

        // Only NOW let the settle window "elapse".
        settleGate.withLock { $0 = true }
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }
        // Reset immediately: connection 2's OWN burstSettleTask (created
        // inside the rebuild this settle is about to trigger) must block
        // on the gate independently, not sail through because it was
        // left open from connection 1's use. Safe to reset here --
        // connection 2's `attemptConnect` cannot even begin until this
        // test drives its snapshot below, so nothing can have consulted
        // the gate again yet.
        settleGate.withLock { $0 = false }

        guard let rebuiltSubscribe = await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: ["wB:p1", "wC:p1"]) else {
            XCTFail("expected the burst-settle reconciliation to rebuild exactly once")
            return
        }
        let afterFirstRebuild = await factory.callCount
        XCTAssertEqual(
            afterFirstRebuild, 4,
            "the burst-settle reconciliation must rebuild exactly ONCE (2 connect sequences x 2 transports each " +
            "= 2 event-stream transports total, settling here, never climbing further)"
        )

        // Identical replay burst again on the REBUILT connection -- every
        // id is already in `recognizedPaneIDs` (unioned by the first
        // settle), so this repeat must converge with NO further rebuild.
        await rebuiltSubscribe.simulateLine(paneCreatedEventLine(paneID: "w8:p1"))
        await rebuiltSubscribe.simulateLine(paneCreatedEventLine(paneID: "w9:p1"))
        await rebuiltSubscribe.simulateLine(paneCreatedEventLine(paneID: "wA:p1"))
        await rebuiltSubscribe.simulateLine(paneCreatedEventLine(paneID: "wB:p1"))
        await rebuiltSubscribe.simulateLine(paneCreatedEventLine(paneID: "wC:p1"))
        await rebuiltSubscribe.simulateLine(statusChangedEventLine(paneID: "wB:p1", status: "idle"))
        await waitUntil { registry.externalEntries[sentinelID]?.state == .idle }

        settleGate.withLock { $0 = true }
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }

        let final = await factory.callCount
        XCTAssertEqual(
            final, 4,
            "a repeat of the SAME replay burst on the rebuilt connection must converge, not rebuild again -- " +
            "every id was already unioned into recognizedPaneIDs by the first settle"
        )
    }

    // MARK: - Rebuild's subscribe list comes from ITS OWN fresh snapshot; superseded transport is closed

    /// Settles a connection whose subscription covers "w1:p1", closes
    /// that pane, then asserts: (1) the REBUILT transport's own
    /// `events.subscribe` no longer lists it -- because the REBUILD's OWN
    /// fresh snapshot fixture no longer reveals it, not because of any
    /// separately-mutated bookkeeping (there is none anymore -- see
    /// HerdrIntegrationCoordinator.swift's own header "REBUILD TRIGGERS");
    /// and (2) the SUPERSEDED subscribe transport was explicitly closed
    /// (see that file's own header "EXPLICIT TRANSPORT TEARDOWN") --
    /// probed via a second `send()` throwing `.alreadyClosed`, since
    /// `InMemoryHerdrTransport` exposes no direct `isClosed()` accessor.
    func test_paneClosedEvent_rebuildSubscribeListComesFromItsOwnFreshSnapshot_andClosesSupersededTransport() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        let callCountAfterSettling = await factory.callCount
        XCTAssertEqual(callCountAfterSettling, 2, "Precondition")

        await settledTransport.simulateLine(paneClosedEventLine(paneID: "w1:p1"))

        // The rebuild's OWN fresh snapshot reveals an EMPTY pane set --
        // herdr no longer knows about "w1:p1" either, matching what just
        // closed.
        guard let rebuiltTransport = await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) else {
            XCTFail("expected the pane_closed event to open a fresh snapshot+subscribe connection")
            return
        }

        let rebuiltSent = await rebuiltTransport.sentMessages()
        XCTAssertTrue(
            agentStatusChangedPaneIDs(inLine: rebuiltSent[0]).isEmpty,
            "the rebuilt subscribe list must be derived from the rebuild's OWN fresh snapshot -- which no longer " +
            "reveals \"w1:p1\" -- not from any separately-mutated bookkeeping"
        )

        do {
            try await settledTransport.send(#"{"id":"probe","method":"probe","params":{}}"#)
            XCTFail("expected the superseded event-stream transport to already be closed")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(
                error, .alreadyClosed, "a rebuild must explicitly close the superseded event-stream transport"
            )
        } catch {
            XCTFail("expected HerdrTransportError.alreadyClosed, got \(type(of: error)): \(error)")
        }

        let finalCallCount = await factory.callCount
        XCTAssertEqual(finalCallCount, 4, "the rebuild must open exactly 2 new transports, no more")
    }

    // MARK: - paneAgentStatusChanged reaches the mirror end-to-end

    func test_paneAgentStatusChangedEvent_isForwardedToMirror() async {
        let factory = SpyHerdrTransportFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let coordinator = makeDetectableCoordinator(factory: factory, mirror: mirror)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        async let startTask: Void = coordinator.start()
        guard let transport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
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
        let factory = SpyHerdrTransportFactory()
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
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        XCTAssertNotNil(registry.externalEntries[id], "Precondition: the snapshot must have created a row")
        let callCountAfterSettling = await factory.callCount
        XCTAssertEqual(callCountAfterSettling, 2, "Precondition")

        await settledTransport.simulateEOF()

        guard await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) != nil else {
            XCTFail("expected a clean EOF to be followed by a bounded reconnect attempt while the socket still probes alive")
            return
        }
        let callCountAfterEOF = await factory.callCount
        XCTAssertEqual(callCountAfterEOF, 4, "the reconnect attempt must open exactly 2 new transports")
        await waitUntil { registry.externalEntries.isEmpty }
        XCTAssertTrue(registry.externalEntries.isEmpty, "an EOF must call mirror.connectionLost()")
    }

    func test_streamEOF_whenSocketNoLongerProbesAlive_stopsWithoutRetrying() async {
        let factory = SpyHerdrTransportFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        let coordinator = makeDetectableCoordinator(
            factory: factory, discovery: discovery, reconnectDelays: [.zero, .zero]
        )

        async let startTask: Void = coordinator.start()
        guard let firstTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        discovery.markDead(socketPath) // the socket is genuinely gone now
        await firstTransport.simulateEOF()

        for _ in 0..<200 { await Task.yield() }

        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 2,
            "once the socket no longer probes alive, the coordinator must stop entirely -- no reconnect attempt"
        )
    }

    // MARK: - A5/A6: lifetime reconnect budget survives a healthy-looking-but-flapping cycle

    func test_reconnect_isBoundedAcrossCycles_evenWhenEachAttemptCompletesItsConnectSequence_thenGivesUpPermanently() async {
        let factory = SpyHerdrTransportFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        // `reconnectDelays.count` (3) is deliberately LARGER than
        // `maxLifetimeReconnectAttempts` (2) -- what stops this must be
        // the CROSS-CYCLE lifetime budget, not any single cycle's own
        // per-cycle exhaustion.
        let coordinator = makeDetectableCoordinator(
            factory: factory, discovery: discovery, reconnectDelays: [.zero, .zero, .zero], maxLifetimeReconnectAttempts: 2
        )

        async let startTask: Void = coordinator.start()
        guard let firstTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        await firstTransport.simulateEOF()

        // Reconnect #1 (lifetime attempt 1 of 2): completes its FULL
        // connect sequence -- a real reconnect, not a bare connect
        // failure -- then drops again before any event is ever pushed,
        // so it never earns the HEALTHY reset (A5).
        guard let secondTransport = await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) else {
            XCTFail("expected reconnect attempt #1")
            return
        }
        await secondTransport.simulateEOF()

        // Reconnect #2 (lifetime attempt 2 of 2): same shape.
        guard let thirdTransport = await driveConnectAttempt(factory: factory, baseIndex: 4, paneIDs: []) else {
            XCTFail("expected reconnect attempt #2")
            return
        }
        await thirdTransport.simulateEOF()

        // The lifetime budget (2) is now exhausted -- no further attempt,
        // even though reconnectDelays' own per-cycle count (3) was never
        // exhausted and the socket still probes alive.
        for _ in 0..<200 { await Task.yield() }

        let finalCallCount = await factory.callCount
        XCTAssertEqual(
            finalCallCount, 6,
            "maxLifetimeReconnectAttempts (2) must bound reconnects ACROSS cycles even when every attempt " +
            "completes its own connect sequence before dropping again -- 3 connect sequences total " +
            "(original + 2 reconnects) x 2 transports each = 6, then a permanent give-up, never more"
        )
    }

    /// The other half of A5's "healthy" bar: a connection that DOES
    /// deliver at least one event after its subscribe ack completes must
    /// reset `totalReconnectAttempts` back to zero, so a later, unrelated
    /// cycle of disconnects gets a full fresh lifetime budget again. The
    /// sibling test above only proves a connect-sequence-only connection
    /// does NOT reset the budget -- this proves the positive case
    /// actually fires.
    func test_reconnect_connectionThatDeliversAnEvent_resetsLifetimeBudget_soLaterCyclesGetAFreshBudget() async {
        let factory = SpyHerdrTransportFactory()
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        let coordinator = makeDetectableCoordinator(
            factory: factory, discovery: discovery, reconnectDelays: [.zero, .zero, .zero], maxLifetimeReconnectAttempts: 2
        )

        async let startTask: Void = coordinator.start()
        guard let firstTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        await firstTransport.simulateEOF()

        // Reconnect #1 (lifetime attempt 1 of 2): completes its connect
        // sequence, THEN is pushed one event ("layout_updated", decoded
        // generically as `.unknown(eventType:)` -- not a rebuild trigger)
        // before it is dropped again. That pushed event is the ONLY thing
        // distinguishing this connection from the sibling test's
        // non-resetting ones. `simulateLine` then `simulateEOF`, called
        // back to back on the same actor, are delivered in that same
        // order (`AsyncStream` preserves FIFO order of yields), so the
        // event is guaranteed fully processed -- including its
        // `totalReconnectAttempts = 0` reset -- before the EOF ends this
        // connection's loop.
        guard let secondTransport = await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) else {
            XCTFail("expected reconnect attempt #1")
            return
        }
        await secondTransport.simulateLine(#"{"event":"layout_updated"}"#)
        await secondTransport.simulateEOF()

        // Reconnect #2 (lifetime attempt 1 of the RESET budget) and
        // reconnect #3 (lifetime attempt 2 of the reset budget): same
        // connect-sequence-only-then-drop shape as the sibling test's
        // cycles -- neither earns HEALTHY, so nothing resets the budget
        // again.
        guard let thirdTransport = await driveConnectAttempt(factory: factory, baseIndex: 4, paneIDs: []) else {
            XCTFail("expected reconnect attempt #2 -- the budget must have been reset by the event above")
            return
        }
        await thirdTransport.simulateEOF()

        guard let fourthTransport = await driveConnectAttempt(factory: factory, baseIndex: 6, paneIDs: []) else {
            XCTFail(
                "expected reconnect attempt #3 -- proves the reset granted a FULL fresh budget (2 more " +
                "attempts), not merely one bonus attempt"
            )
            return
        }
        await fourthTransport.simulateEOF()

        // The reset budget (2), consumed by reconnects #2 and #3, is now
        // exhausted again -- no further attempt.
        for _ in 0..<200 { await Task.yield() }

        let finalCallCount = await factory.callCount
        XCTAssertEqual(
            finalCallCount, 8,
            "a connection that delivered an event must reset the lifetime budget -- 4 connect sequences total " +
            "(original + the reconnect that earned the reset + 2 more reconnects consuming a FRESH budget) x 2 " +
            "transports each = 8, then a permanent give-up. Without the reset this would stop at 6, identical to " +
            "the sibling non-resetting test above."
        )
    }

    // MARK: - A2: PER-STEP handshake deadline

    func test_attemptConnect_snapshotHangsForever_timesOutAndGivesUpPlainly_closesItsTransport_thenAllowsFreshStart() async {
        let factory = SpyHerdrTransportFactory()
        // Gated, NOT an instant no-op -- an instant no-op `sleep` could
        // let the timeout arm win BEFORE the snapshot's own request is
        // even sent, closing the transport out from under it and making
        // this test's own precondition check flaky. Gating on an
        // explicit flag, opened only once the request is confirmed in
        // flight, keeps this test's actual subject (a request that hangs
        // forever AFTER being sent, never getting a reply) deterministic.
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
            XCTFail("expected start() to create a snapshot transport before its request hangs")
            return
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        XCTAssertEqual(
            sent.compactMap { requestMethod(inLine: $0) }, ["session.snapshot"],
            "Precondition: session.snapshot must have been sent before this test leaves it unanswered forever"
        )
        timeoutGate.withLock { $0 = true } // the request is confirmed in flight -- now let the timeout arm resolve

        // Deliberately never respond -- the step hangs forever awaiting
        // its response. `await startTask` below must still return (never
        // hang the TEST itself) because of the A2 per-step deadline.
        await startTask

        let callCountAfterTimeout = await factory.callCount
        XCTAssertEqual(
            callCountAfterTimeout, 1,
            "a hung snapshot must give up plainly once its deadline expires -- no subscribe transport is ever " +
            "created, and no retry"
        )

        // BLOCKER-analog: the timed-out step's own transport must
        // actually be closed (not merely abandoned) -- probed via a
        // second send() throwing .alreadyClosed, since
        // InMemoryHerdrTransport exposes no direct isClosed() accessor.
        // This is what lets the still-suspended session.snapshot() call
        // actually throw and its own Task release every reference it
        // captured, instead of leaking forever.
        do {
            try await transport.send(#"{"id":"probe","method":"probe","params":{}}"#)
            XCTFail("expected the timed-out transport to already be closed")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(error, .alreadyClosed, "a timed-out step must close its own transport")
        } catch {
            XCTFail("expected HerdrTransportError.alreadyClosed, got \(type(of: error)): \(error)")
        }

        // A later start() must behave like a fresh attempt, proving
        // `isActive` was reset rather than left stuck "connecting"
        // forever.
        await coordinator.start()
        let callCountAfterFreshStart = await factory.callCount
        XCTAssertEqual(
            callCountAfterFreshStart, 2,
            "start() after a timed-out snapshot must attempt a fresh connection, not stay stuck"
        )
    }

    func test_attemptConnect_subscribeHangsForever_timesOutAndGivesUpPlainly_afterASuccessfulSnapshot() async {
        let factory = SpyHerdrTransportFactory()
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

        guard let snapshotTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected start() to create a snapshot transport")
            return
        }
        let snapshotSent = await awaitSentMessages(snapshotTransport, atLeast: 1)
        guard let firstSnapshotLine = snapshotSent.first, let snapshotID = requestID(inLine: firstSnapshotLine) else {
            XCTFail("expected exactly one sent line carrying a request id, got \(snapshotSent)")
            return
        }
        await snapshotTransport.simulateLine(snapshotResponseLine(id: snapshotID, paneIDs: []))

        guard let subscribeTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected the successful snapshot to trigger a subscribe transport before it hangs")
            return
        }
        let subscribeSent = await awaitSentMessages(subscribeTransport, atLeast: 1)
        XCTAssertEqual(
            subscribeSent.compactMap { requestMethod(inLine: $0) }, ["events.subscribe"],
            "Precondition: events.subscribe must have been sent before this test leaves it unanswered forever"
        )
        timeoutGate.withLock { $0 = true }

        await startTask

        let callCountAfterTimeout = await factory.callCount
        XCTAssertEqual(
            callCountAfterTimeout, 2,
            "a hung subscribe must give up plainly after exactly 2 transports (the completed snapshot plus the " +
            "hung subscribe), no retry"
        )
    }

    // MARK: - Failed connect attempt leaves no state behind

    /// CRITICAL + WARNING: `attemptConnect`'s snapshot step (which upserts
    /// rows into the mirror and unions pane ids into `recognizedPaneIDs`)
    /// can succeed before its OWN, independently-fallible subscribe step
    /// then fails -- `start()`'s failure branch must not leave either
    /// behind. Two halves, both pinned here:
    ///   1. the mirror must not keep a ghost row with no live connection
    ///      behind it (`resetToIdle()` must call `mirror.connectionLost()`)
    ///   2. a LATER, successful `start()` must build its subscribe list
    ///      AND its "is this pane genuinely new" judgment purely from ITS
    ///      OWN state, never `recognizedPaneIDs` left over from the
    ///      abandoned attempt -- `resetToIdle()`'s own doc comment: a
    ///      later-discovered session may reuse pane ids the old one had.
    func test_failedStart_clearsMirrorGhostRow_andRecognizedPaneIDs_soTheNextSuccessfulStartIsClean() async {
        let factory = SpyHerdrTransportFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let coordinator = makeDetectableCoordinator(
            factory: factory, mirror: mirror, replayBurstSettleWindow: .zero, rebuildBackoffDelays: [.zero]
        )
        let staleID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:stale")

        // First attempt: the snapshot succeeds, revealing "w1:stale"
        // (upserting a mirror row and unioning it into
        // `recognizedPaneIDs`) -- but the subscribe step is then rejected
        // outright, herdr's own measured "pane_not_found" shape (this
        // file's own header CONNECT SEQUENCE step 4), so `attemptConnect`
        // returns `false`.
        async let firstStartTask: Void = coordinator.start()
        guard let firstSnapshotTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected start() to create a snapshot transport")
            return
        }
        let firstSnapshotSent = await awaitSentMessages(firstSnapshotTransport, atLeast: 1)
        guard let firstSnapshotID = requestID(inLine: firstSnapshotSent[0]) else {
            XCTFail("expected a request id, got \(firstSnapshotSent)")
            return
        }
        await firstSnapshotTransport.simulateLine(snapshotResponseLine(id: firstSnapshotID, paneIDs: ["w1:stale"]))

        guard let firstSubscribeTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected the successful snapshot to trigger a subscribe transport")
            return
        }
        // Precondition: `mirror.applySnapshot` runs synchronously, before
        // the subscribe transport is even requested from the factory --
        // by the time transport #1 exists, the row below is guaranteed to
        // already be there. Proves the later `isEmpty` check is not
        // trivially true because no row was ever created in the first
        // place.
        XCTAssertNotNil(registry.externalEntries[staleID], "Precondition: the snapshot step must have upserted a mirror row")

        let firstSubscribeSent = await awaitSentMessages(firstSubscribeTransport, atLeast: 1)
        guard let firstSubscribeID = requestID(inLine: firstSubscribeSent[0]) else {
            XCTFail("expected a request id, got \(firstSubscribeSent)")
            return
        }
        await firstSubscribeTransport.simulateLine(
            errorResponseLine(id: firstSubscribeID, code: "pane_not_found", message: "pane w1:stale not found")
        )
        await firstStartTask

        let callCountAfterFailedStart = await factory.callCount
        XCTAssertEqual(callCountAfterFailedStart, 2, "Precondition: the failed attempt opened exactly 2 transports, no retry")
        XCTAssertTrue(
            registry.externalEntries.isEmpty,
            "a failed start() must not leave a ghost mirror row behind -- resetToIdle() must call mirror.connectionLost()"
        )

        // Second, successful start(): a FRESH snapshot reveals a
        // DIFFERENT pane, "w1:p9" -- deliberately NOT "w1:stale".
        async let secondStartTask: Void = coordinator.start()
        guard let secondSubscribeTransport = await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: ["w1:p9"]) else {
            XCTFail("expected the second start() to connect fresh")
            return
        }
        await secondStartTask

        let secondSubscribeSent = await secondSubscribeTransport.sentMessages()
        XCTAssertEqual(
            agentStatusChangedPaneIDs(inLine: secondSubscribeSent[0]), ["w1:p9"],
            "the second attempt's subscribe list must be built purely from ITS OWN fresh snapshot"
        )
        XCTAssertFalse(
            agentStatusChangedPaneIDs(inLine: secondSubscribeSent[0]).contains("w1:stale"),
            "a pane id from the ABANDONED first attempt must not leak into the second attempt's subscribe list"
        )

        // Discriminating probe: "w1:stale" -- the id the FIRST, abandoned
        // attempt's own snapshot revealed -- reappears as a "pane_created"
        // event on the SECOND connection, once it has settled past its own
        // accumulating phase (so this is judged by the STEADY-STATE
        // `!recognizedPaneIDs.contains(...)` check, HerdrIntegrationCoordinator
        // .swift's own header "REBUILD TRIGGERS"). If `recognizedPaneIDs`
        // had survived the failed first attempt (the leak this test
        // pins), this would be silently treated as "already recognized"
        // -- no rebuild, and `driveConnectAttempt` below would time out.
        // `resetToIdle()` clearing `recognizedPaneIDs` means it must
        // instead be judged genuinely NEW.
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }
        await secondSubscribeTransport.simulateLine(paneCreatedEventLine(paneID: "w1:stale"))

        guard await driveConnectAttempt(factory: factory, baseIndex: 4, paneIDs: ["w1:p9"]) != nil else {
            XCTFail(
                "expected \"w1:stale\" to be treated as a genuinely NEW pane and rebuild the connection -- a " +
                "timeout here means recognizedPaneIDs leaked across the failed first attempt"
            )
            return
        }
        let finalCallCount = await factory.callCount
        XCTAssertEqual(finalCallCount, 6, "the rebuild triggered by \"w1:stale\" must open exactly 2 new transports")
    }

    // MARK: - Item 2: HerdrStructureEventObserver routing

    /// `HerdrStructureEventObserver` spy: records every call for later
    /// inspection. Plain strong-reference spy -- see
    /// `DeinitTrackingStructureEventObserverSpy` below for the SEPARATE,
    /// more specialized type the weak-storage test needs.
    @MainActor
    private final class RecordingStructureEventObserverSpy: HerdrStructureEventObserver {
        private(set) var layoutUpdatedCalls: [String] = []
        private(set) var paneClosedCalls: [(paneID: String, socketPath: String)] = []
        private(set) var workspaceClosedCalls: [(workspaceID: String, socketPath: String)] = []

        func herdrLayoutUpdated(socketPath: String) {
            layoutUpdatedCalls.append(socketPath)
        }

        func herdrPaneClosed(paneID: String, socketPath: String) {
            paneClosedCalls.append((paneID: paneID, socketPath: socketPath))
        }

        func herdrWorkspaceClosed(workspaceID: String, socketPath: String) {
            workspaceClosedCalls.append((workspaceID: workspaceID, socketPath: socketPath))
        }
    }

    /// Deinit-tracking `HerdrStructureEventObserver` spy -- proves
    /// `setStructureEventObserver` stores its argument WEAKLY, not
    /// strongly. `deinitFlag` is an `OSAllocatedUnfairLock`-backed box
    /// (mirrors this file's own `FakeHerdrSessionDiscovery` precedent for
    /// a genuinely `Sendable` mutable box, above), set exactly once from
    /// `deinit` -- `deinit` on a `@MainActor` class is not itself
    /// actor-isolated, but reading/locking a `let`-bound, independently
    /// `Sendable` `OSAllocatedUnfairLock` is sound regardless of
    /// isolation. A test constructs this inside a narrow scope, drops its
    /// own only strong reference, then polls `deinitFlag` to know
    /// precisely when ARC has actually collected it -- never a fixed
    /// `sleep`.
    @MainActor
    private final class DeinitTrackingStructureEventObserverSpy: HerdrStructureEventObserver {
        private let deinitFlag: OSAllocatedUnfairLock<Bool>

        init(deinitFlag: OSAllocatedUnfairLock<Bool>) {
            self.deinitFlag = deinitFlag
        }

        deinit {
            deinitFlag.withLock { $0 = true }
        }

        func herdrLayoutUpdated(socketPath: String) {
            // Unused by this spy's own test -- present only to satisfy
            // the protocol.
        }

        func herdrPaneClosed(paneID: String, socketPath: String) {
            // Unused by this spy's own test -- present only to satisfy
            // the protocol.
        }

        func herdrWorkspaceClosed(workspaceID: String, socketPath: String) {
            // Unused by this spy's own test -- present only to satisfy
            // the protocol.
        }
    }

    /// {"event":"layout_updated"} -- the MEASURED wire shape this same
    /// suite's own `test_reconnect_connectionThatDeliversAnEvent_...` test
    /// above already uses inline (kept there untouched; factored out here
    /// only for reuse across this section's own NEW tests). No "data" key
    /// is required for `HerdrEvent.init(from:)` to decode this to
    /// `.unknown(eventType: "layout_updated")` -- only the top-level
    /// "event" key (present on every envelope shape) is read to dispatch
    /// (HerdrEvent.swift's own header) -- so this shape, not the richer
    /// `{"data":{"type":"layout_updated"},...}` guess, is what this file
    /// actually verifies against.
    private func layoutUpdatedEventLine() -> String {
        #"{"event":"layout_updated"}"#
    }

    /// STEADY STATE: after a connection has settled past its own
    /// accumulating replay-burst phase, each pushed `layout_updated` event
    /// must invoke `herdrLayoutUpdated(socketPath:)` on the registered
    /// observer EXACTLY once -- proven by pushing TWO events and asserting
    /// an EXACT two-element result (not merely "at least two"), mirroring
    /// this file's own anti-storm test's settle-then-recount idiom.
    func test_layoutUpdatedEvent_steadyState_invokesObserverExactlyOncePerEvent() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory, replayBurstSettleWindow: .zero)
        let observer = RecordingStructureEventObserverSpy()
        coordinator.setStructureEventObserver(observer)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask

        // Steady state only -- see
        // test_layoutUpdatedEvent_duringReplayBurst_notForwarded_thenForwardedOnceSettled
        // below for why injecting before this point lands in a
        // DIFFERENT, deliberately-suppressed code path.
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }

        await settledTransport.simulateLine(layoutUpdatedEventLine())
        await waitUntil { observer.layoutUpdatedCalls.count >= 1 }
        await settledTransport.simulateLine(layoutUpdatedEventLine())
        await waitUntil { observer.layoutUpdatedCalls.count >= 2 }

        // Bounded settle, then a STRICT recount -- proves "exactly two",
        // not merely "at least two".
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(
            observer.layoutUpdatedCalls, [socketPath, socketPath],
            "each pushed layout_updated event must invoke herdrLayoutUpdated(socketPath:) EXACTLY once, with " +
            "the connection's own socketPath"
        )
    }

    /// A `pane_closed` event for a KNOWN pane must invoke
    /// `herdrPaneClosed(paneID:socketPath:)` on the observer AND still
    /// perform the pre-existing rebuild behavior (this file's own
    /// `test_paneClosedEvent_alwaysRebuildsConnection_unconditionally`
    /// above) -- adding the observer seam must never replace or skip the
    /// existing rebuild.
    func test_paneClosedEvent_knownPane_invokesObserver_andStillPerformsExistingRebuild() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)
        let observer = RecordingStructureEventObserverSpy()
        coordinator.setStructureEventObserver(observer)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        let firstCallCount = await factory.callCount
        XCTAssertEqual(firstCallCount, 2, "Precondition")

        await settledTransport.simulateLine(paneClosedEventLine(paneID: "w1:p1"))

        guard await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) != nil else {
            XCTFail("expected the pane_closed event to still rebuild the connection (existing behavior, unchanged)")
            return
        }
        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 4,
            "the existing rebuild behavior must still fire (2 new transports) even with an observer attached"
        )

        XCTAssertEqual(
            observer.paneClosedCalls.map { $0.paneID }, ["w1:p1"],
            "a pane_closed event for a KNOWN pane must invoke herdrPaneClosed(paneID:socketPath:) exactly once"
        )
        XCTAssertEqual(observer.paneClosedCalls.map { $0.socketPath }, [socketPath])
    }

    /// A `workspace_closed` event must invoke
    /// `herdrWorkspaceClosed(workspaceID:socketPath:)` on the observer
    /// exactly once, and -- unlike `pane_closed` above -- must NEVER
    /// rebuild the connection: freezes HerdrIntegrationCoordinator.swift's
    /// own header "STRUCTURE EVENT OBSERVER" contract (`workspace_closed`
    /// touches neither `knownPaneIDs`/`recognizedPaneIDs` nor
    /// `triggerRebuild`) as a regression pin, not just an implicit
    /// property of the implementation.
    func test_workspaceClosedEvent_invokesObserver_neverRebuildsConnection() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory)
        let observer = RecordingStructureEventObserverSpy()
        coordinator.setStructureEventObserver(observer)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on a connection with \"w1:p1\" known")
            return
        }
        await startTask
        let settledCallCount = await factory.callCount
        XCTAssertEqual(settledCallCount, 2, "Precondition")

        await settledTransport.simulateLine(workspaceClosedEventLine(workspaceID: "w1"))
        await waitUntil { observer.workspaceClosedCalls.count >= 1 }

        // Bounded settle, then a STRICT recount -- proves no rebuild ever
        // fires, not merely "hasn't yet".
        for _ in 0..<200 { await Task.yield() }
        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, settledCallCount,
            "a workspace_closed event must NEVER rebuild the connection (no new transports) -- unlike pane_closed"
        )

        XCTAssertEqual(
            observer.workspaceClosedCalls.map { $0.workspaceID }, ["w1"],
            "a workspace_closed event must invoke herdrWorkspaceClosed(workspaceID:socketPath:) exactly once"
        )
        XCTAssertEqual(observer.workspaceClosedCalls.map { $0.socketPath }, [socketPath])
    }

    /// Cheap regression pin: with NO observer ever registered, existing
    /// behavior (no crash, the pane_closed rebuild still firing) must
    /// survive this whole feature's addition untouched. Also pushes a
    /// layout_updated event first, proving that code path tolerates an
    /// absent observer too.
    func test_noObserverSet_layoutUpdatedAndPaneClosedEvents_stillProcessedAsToday_noCrash() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory, replayBurstSettleWindow: .zero)
        // Deliberately never calls setStructureEventObserver.

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }

        await settledTransport.simulateLine(layoutUpdatedEventLine()) // must not crash
        for _ in 0..<50 { await Task.yield() }

        await settledTransport.simulateLine(paneClosedEventLine(paneID: "w1:neverKnown"))

        guard await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) != nil else {
            XCTFail("expected the pane_closed event to still rebuild the connection with no observer ever set")
            return
        }
        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, 4,
            "a pane_closed event must still unconditionally rebuild the connection with no observer set -- " +
            "adding the observer seam must never regress pre-existing behavior"
        )
    }

    /// The observer is not retained strongly: once the test's own only
    /// strong reference goes out of scope, the spy actually deallocates
    /// (proven by polling `deinitFlag`, never a fixed `sleep`) -- and a
    /// LATER event neither crashes nor invokes anything on it (there is
    /// nothing left to invoke), while pre-existing behavior (the
    /// pane_closed rebuild) continues to work normally.
    func test_structureEventObserver_isNotRetainedStrongly_deallocatesAfterLocalReferenceDrops_laterEventDoesNotCrash() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeDetectableCoordinator(factory: factory, replayBurstSettleWindow: .zero)
        let deinitFlag = OSAllocatedUnfairLock(initialState: false)

        async let startTask: Void = coordinator.start()
        guard let settledTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }

        do {
            let observer = DeinitTrackingStructureEventObserverSpy(deinitFlag: deinitFlag)
            coordinator.setStructureEventObserver(observer)
            // `observer`'s only strong reference is this local -- goes out
            // of scope at the end of this `do` block.
        }

        await waitUntil { deinitFlag.withLock { $0 } }
        XCTAssertTrue(
            deinitFlag.withLock { $0 },
            "expected the observer to have been deallocated after its only strong reference (this test's own " +
            "local) went out of scope -- setStructureEventObserver must store its argument WEAKLY, not strongly"
        )

        await settledTransport.simulateLine(layoutUpdatedEventLine()) // must not crash
        for _ in 0..<50 { await Task.yield() }

        // Pre-existing behavior must still work with a now-nil observer
        // reference.
        await settledTransport.simulateLine(paneClosedEventLine(paneID: "w1:neverKnown"))
        guard await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) != nil else {
            XCTFail("expected the pane_closed event to still rebuild the connection after the observer deallocated")
            return
        }
        let callCountAfter = await factory.callCount
        XCTAssertEqual(callCountAfter, 4, "existing behavior must survive a deallocated (weakly-held) observer")
    }

    /// REPLAY BURST caveat (this section's own task brief): a replayed
    /// `layout_updated` arriving WHILE this connection's own accumulating
    /// phase is still open must NOT be forwarded to the observer --
    /// forwarding every replayed layout_updated on every fresh
    /// (re)subscribe would trigger a re-export per replayed event on
    /// every reconnect. Once the burst settles (steady state), forwarding
    /// resumes normally. Uses the SAME gated-sleep interception as
    /// `test_replayBurst_stalePanesBeyondSnapshot_rebuildsExactlyOnce_thenConverges`
    /// above (see that test's own doc comment for why a real-clock
    /// `.zero` window cannot deterministically catch the "still
    /// accumulating" instant this test needs to hold open on demand).
    func test_layoutUpdatedEvent_duringReplayBurst_notForwarded_thenForwardedOnceSettled() async {
        let factory = SpyHerdrTransportFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let burstSettleWindow = Duration.milliseconds(1)
        let settleGate = OSAllocatedUnfairLock(initialState: false)
        let coordinator = makeDetectableCoordinator(
            factory: factory,
            mirror: mirror,
            replayBurstSettleWindow: burstSettleWindow,
            rebuildBackoffDelays: [.zero],
            sleep: { duration in
                guard duration == burstSettleWindow else {
                    try? await Task.sleep(for: duration)
                    return
                }
                while !settleGate.withLock({ $0 }) {
                    if Task.isCancelled { return }
                    await Task.yield()
                }
            }
        )
        let observer = RecordingStructureEventObserverSpy()
        coordinator.setStructureEventObserver(observer)
        let sentinelID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        async let startTask: Void = coordinator.start()
        guard let subscribeTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("expected the coordinator to settle on an initial connection")
            return
        }
        await startTask
        XCTAssertTrue(
            coordinator.testOnlyIsAccumulatingReplayBurst, "Precondition: still accumulating -- the gate has not been opened yet"
        )

        // Pushed WHILE still accumulating -- must NOT be forwarded.
        await subscribeTransport.simulateLine(layoutUpdatedEventLine())
        // Sentinel -- an independently observable event (mirrors
        // test_replayBurst_stalePanesBeyondSnapshot's own technique)
        // proving the layout_updated line above has already been fully
        // consumed by consumeEvents' own read loop before the assertion
        // below runs.
        await subscribeTransport.simulateLine(statusChangedEventLine(paneID: "w1:p1", status: "blocked"))
        await waitUntil { registry.externalEntries[sentinelID]?.state == .blocked }

        XCTAssertEqual(
            observer.layoutUpdatedCalls.count, 0,
            "a layout_updated event replayed WHILE still accumulating the burst must NOT be forwarded to the " +
            "observer -- forwarding every replay on every reconnect would trigger a re-export storm"
        )

        // Now let the burst settle.
        settleGate.withLock { $0 = true }
        await waitUntil { !coordinator.testOnlyIsAccumulatingReplayBurst }

        // Pushed in STEADY STATE -- must be forwarded.
        await subscribeTransport.simulateLine(layoutUpdatedEventLine())
        await waitUntil { observer.layoutUpdatedCalls.count >= 1 }

        XCTAssertEqual(
            observer.layoutUpdatedCalls, [socketPath],
            "once the replay burst has settled (steady state), a layout_updated event must be forwarded normally"
        )
    }

    // MARK: - Fixture builders (exact shapes measured against real herdr 0.8.0)

    private func subscribeAckLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    /// herdr's measured error response shape --
    /// {"id":"..","error":{"code":"..","message":".."}} -- see
    /// HerdrConnection.swift's own header. Used to fail a step
    /// deterministically (e.g. an `events.subscribe` rejected with
    /// "pane_not_found", this file's own header CONNECT SEQUENCE step 4)
    /// without needing a hung-request/timeout-gate rig.
    private func errorResponseLine(id: String, code: String, message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    /// `panes[]` is always exactly `paneIDs` -- required-fields-only per
    /// pane (see this file's own project-level fixture rule: a fixture
    /// must carry only what the schema requires) -- and is what
    /// `HerdrIntegrationCoordinator` itself seeds `knownPaneIDs` from
    /// (its own header, CONNECT SEQUENCE step 3: "Deliberately NOT
    /// `agents[]`"), so it alone drives the subscribe's own per-pane
    /// list, regardless of `agentPaneIDs` below.
    ///
    /// `agentPaneIDs` independently controls `agents[]` -- `nil` (every
    /// existing call site) defaults to `paneIDs`, matching every pane
    /// having a detected agent, the fixture's original behavior. Passing
    /// a STRICT SUBSET of `paneIDs` models the real, measured shape
    /// `panes[] ⊋ agents[]` -- a pane with no agent detected yet is still
    /// a pane (still subscribed), but gets no row from `HerdrAgentMirror
    /// .applySnapshot`, which reads `agents[]` alone.
    private func snapshotResponseLine(id: String, paneIDs: [String], agentPaneIDs: [String]? = nil) -> String {
        let agentsJSON = (agentPaneIDs ?? paneIDs).map { paneID in
            #"{"terminal_id":"term_\#(paneID)","agent":"claude","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"\#(paneID)","focused":false,"state_change_seq":0,"cwd":"/Users/dev/project","foreground_cwd":"/Users/dev/project","revision":0}"#
        }.joined(separator: ",")
        let panesJSON = paneIDs.map { paneID in
            #"{"terminal_id":"term_\#(paneID)","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"\#(paneID)","focused":false,"revision":0}"#
        }.joined(separator: ",")
        return #"{"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":null,"workspaces":[],"tabs":[],"panes":[\#(panesJSON)],"layouts":[],"agents":[\#(agentsJSON)]}}}"#
    }

    private func paneCreatedEventLine(paneID: String, workspaceID: String = "w1") -> String {
        #"{"data":{"pane":{"terminal_id":"term_\#(paneID)","agent":null,"agent_status":"unknown","workspace_id":"\#(workspaceID)","tab_id":"\#(workspaceID):t1","pane_id":"\#(paneID)","focused":false,"cwd":null,"foreground_cwd":null,"revision":0},"type":"pane_created"},"event":"pane_created"}"#
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

    /// Schema-minimal "workspace_closed" shape (HerdrEventTests' own
    /// decode tests already pin the richer measured shape exhaustively)
    /// -- only that it decodes to `.workspaceClosed(workspaceID:)` is
    /// load-bearing here.
    private func workspaceClosedEventLine(workspaceID: String) -> String {
        #"{"event":"workspace_closed","data":{"type":"workspace_closed","workspace_id":"\#(workspaceID)"}}"#
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

    /// Type-only (structure) entries only -- excludes per-pane entries
    /// (e.g. pane.agent_status_changed), which always carry a pane_id
    /// alongside their type. Wire shape is a single flat array mixing
    /// both kinds (see HerdrConnectionTests
    /// .test_subscribe_sendsExactlyOneEventsSubscribeLine_withFullSubscriptionList),
    /// so callers wanting just the six structure-event types must filter
    /// out the per-pane ones first.
    private func subscriptionTypes(inLine line: String) -> [String] {
        subscriptionEntries(inLine: line).filter { $0["pane_id"] == nil }.compactMap { $0["type"] as? String }
    }

    private func agentStatusChangedPaneIDs(inLine line: String) -> [String] {
        subscriptionEntries(inLine: line)
            .filter { ($0["type"] as? String) == "pane.agent_status_changed" }
            .compactMap { $0["pane_id"] as? String }
    }

    // MARK: - Bounded async polling

    private func waitUntil(maxYields: Int = 10_000, _ condition: () async -> Bool) async {
        var iterations = 0
        while await !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    private func awaitTransport(_ factory: SpyHerdrTransportFactory, at index: Int) async -> InMemoryHerdrTransport? {
        await waitUntil { await factory.callCount > index }
        return await factory.transport(at: index)
    }

    private func awaitSentMessages(_ transport: InMemoryHerdrTransport, atLeast count: Int) async -> [String] {
        await waitUntil { await transport.sentMessages().count >= count }
        return await transport.sentMessages()
    }
}
