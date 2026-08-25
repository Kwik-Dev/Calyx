//
//  HerdrIntegrationCoordinatorPresenceTests.swift
//  CalyxTests
//
//  Covers HerdrIntegrationCoordinator as a HerdrSessionPresenceObserver:
//  the connection is a FUNCTION of herdr's own presence, driven purely
//  by HerdrSessionPresenceChange, never by an unrelated Calyx event.
//
//  Contract this file pins:
//  - .appeared while idle starts the connect sequence (a one-shot
//    session.snapshot, then a separate events.subscribe) against that
//    identity's own socket path.
//  - .appeared for a DIFFERENT socket path while already connected
//    opens no second connection.
//  - .replaced for the connected socket tears the current connection
//    down and connects again to the new identity -- the server behind
//    that path is a different one now, so the existing connection is
//    worthless.
//  - .disappeared for the connected socket tears the current connection
//    down and does NOT retry: presence says the session is gone, and
//    this coordinator mirrors that rather than second-guessing it (the
//    fake discovery here deliberately keeps reporting the path alive,
//    so a retry would be the coordinator's own doing).
//  - The lifetime reconnect budget belongs to an IDENTITY, not to this
//    process: once exhausted for one identity, a .replaced carrying a
//    NEW identity gets a bounded reconnect of its own again. Otherwise
//    one flapping session permanently deafens Calyx to every later one.
//
//  Every dependency is a fake/spy -- no real socket is ever opened. See
//  HerdrIntegrationCoordinatorTests.swift's own header for the
//  TRANSPORT ACCOUNTING every call-count assertion here is built from:
//  one successful connect attempt opens exactly TWO transports (an
//  even-indexed one-shot snapshot connection, then an odd-indexed,
//  long-lived subscribe connection).
//

import XCTest
import os
@testable import Calyx

// MARK: - Fakes

private final class FakeHerdrSessionDiscovery: HerdrSessionDiscoveryProtocol, Sendable {
    private let candidatesBox: OSAllocatedUnfairLock<[HerdrSessionCandidate]>
    private let aliveBox: OSAllocatedUnfairLock<Set<String>>

    init(candidates: [HerdrSessionCandidate], alive: Set<String>) {
        candidatesBox = OSAllocatedUnfairLock(initialState: candidates)
        aliveBox = OSAllocatedUnfairLock(initialState: alive)
    }

    func discover() -> [HerdrSessionCandidate] { candidatesBox.withLock { $0 } }
    func isAlive(socketPath: String) -> Bool { aliveBox.withLock { $0.contains(socketPath) } }

    func markDead(_ socketPath: String) {
        aliveBox.withLock { $0.remove(socketPath) }
    }
}

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

// MARK: - HerdrIntegrationCoordinatorPresenceTests

@MainActor
final class HerdrIntegrationCoordinatorPresenceTests: XCTestCase {

    private let socketPath = "/tmp/herdr-presence-test/herdr.sock"
    private let otherSocketPath = "/tmp/herdr-presence-other/herdr.sock"

    /// Identities are opaque to this coordinator -- only their
    /// `socketPath` selects a connection, and only their inequality
    /// distinguishes one session from the next -- so these device/inode
    /// values are arbitrary but distinct.
    private func identity(_ path: String, inode: UInt64) -> HerdrSocketIdentity {
        HerdrSocketIdentity(socketPath: path, deviceID: 16_777_232, inode: inode)
    }

    // MARK: - Coordinator construction

    /// `sleep` defaults to the SAME real-clock closure the coordinator's
    /// own initializer defaults to, for the reason
    /// HerdrIntegrationCoordinatorTests' own helper documents: the
    /// PER-STEP handshake deadline races every driven step against this
    /// closure, so a no-op default would resolve that race arm before a
    /// step this suite is actively driving could ever win.
    private func makeCoordinator(
        factory: SpyHerdrTransportFactory,
        discovery: FakeHerdrSessionDiscovery? = nil,
        mirror: HerdrAgentMirror? = nil,
        reconnectDelays: [Duration] = [],
        maxLifetimeReconnectAttempts: Int = HerdrIntegrationCoordinator.defaultMaxLifetimeReconnectAttempts
    ) -> HerdrIntegrationCoordinator {
        HerdrIntegrationCoordinator(
            discovery: discovery ?? FakeHerdrSessionDiscovery(
                candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)],
                alive: [socketPath, otherSocketPath]
            ),
            transportFactory: factory,
            mirror: mirror ?? HerdrAgentMirror(registry: AgentRegistry(), paneRegistry: HerdrPaneRegistry()),
            reconnectDelays: reconnectDelays,
            maxLifetimeReconnectAttempts: maxLifetimeReconnectAttempts
        )
    }

    // MARK: - .appeared starts a connection

    func test_presenceAppeared_whileIdle_startsConnectSequenceForThatIdentitysSocketPath() async {
        let factory = SpyHerdrTransportFactory()
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
        let coordinator = makeCoordinator(factory: factory, mirror: mirror)
        let expectedRowID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        coordinator.herdrSessionPresenceDidChange(.appeared(identity(socketPath, inode: 101)))

        guard let subscribeTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: ["w1:p1"]) else {
            XCTFail("a herdr session appearing must itself start the connect sequence -- nothing else is going to")
            return
        }

        let snapshotConnectedPath = await factory.transport(at: 0)?.lastConnectedSocketPath()
        let subscribeConnectedPath = await subscribeTransport.lastConnectedSocketPath()
        XCTAssertEqual(snapshotConnectedPath, socketPath, "the snapshot must be taken against the appeared identity's own socket path")
        XCTAssertEqual(subscribeConnectedPath, socketPath, "the event stream must subscribe against that same socket path")
        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 2, "one connect attempt must open exactly 2 transports: snapshot, then subscribe")
        XCTAssertNotNil(registry.externalEntries[expectedRowID], "the snapshot that appearance triggered must reach the mirror")
    }

    // MARK: - A second, unrelated appearance

    func test_presenceAppeared_forDifferentSocketPath_whileConnected_opensNoSecondConnection() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeCoordinator(factory: factory)

        coordinator.herdrSessionPresenceDidChange(.appeared(identity(socketPath, inode: 101)))
        guard await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) != nil else {
            XCTFail("Precondition: the coordinator must settle on a connection to the first identity")
            return
        }

        coordinator.herdrSessionPresenceDidChange(.appeared(identity(otherSocketPath, inode: 202)))
        await settle()

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 2,
            "a SECOND live herdr session appearing must not open a second connection -- this coordinator " +
            "mirrors exactly one session at a time"
        )
    }

    // MARK: - .replaced

    func test_presenceReplaced_forConnectedSocket_discardsCurrentConnectionAndConnectsToNewIdentity() async {
        let factory = SpyHerdrTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        let first = identity(socketPath, inode: 101)
        let second = identity(socketPath, inode: 202)

        coordinator.herdrSessionPresenceDidChange(.appeared(first))
        guard let firstSubscribeTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("Precondition: the coordinator must settle on a connection to the first identity")
            return
        }

        coordinator.herdrSessionPresenceDidChange(.replaced(previous: first, current: second))

        guard await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) != nil else {
            XCTFail("a replaced session must be connected to afresh -- the connection to the previous server is worthless")
            return
        }

        // The superseded event-stream transport must be explicitly
        // closed -- probed via a send() throwing .alreadyClosed, since
        // InMemoryHerdrTransport exposes no direct isClosed() accessor.
        do {
            try await firstSubscribeTransport.send(#"{"id":"probe","method":"probe","params":{}}"#)
            XCTFail("the connection to the REPLACED server must be closed, not left open alongside the new one")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(error, .alreadyClosed, "the superseded event-stream transport must be explicitly closed")
        } catch {
            XCTFail("expected HerdrTransportError.alreadyClosed, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - .disappeared

    func test_presenceDisappeared_forConnectedSocket_discardsConnectionAndNeverRetries() async {
        let factory = SpyHerdrTransportFactory()
        // Deliberately still "alive" to the probe: only presence gets to
        // say the session is gone, so any retry here would be the
        // coordinator's own initiative.
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)], alive: [socketPath]
        )
        let coordinator = makeCoordinator(factory: factory, discovery: discovery, reconnectDelays: [.zero, .zero])
        let live = identity(socketPath, inode: 101)

        coordinator.herdrSessionPresenceDidChange(.appeared(live))
        guard let subscribeTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("Precondition: the coordinator must settle on a connection")
            return
        }

        coordinator.herdrSessionPresenceDidChange(.disappeared(live))
        await settle()

        do {
            try await subscribeTransport.send(#"{"id":"probe","method":"probe","params":{}}"#)
            XCTFail("a session that is gone must have its connection closed")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(error, .alreadyClosed, "the event-stream transport of a gone session must be explicitly closed")
        } catch {
            XCTFail("expected HerdrTransportError.alreadyClosed, got \(type(of: error)): \(error)")
        }

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 2,
            "presence says the session is gone -- no reconnect attempt may follow, even though the injected " +
            "probe would still answer \"alive\""
        )
    }

    // MARK: - Reconnect budget belongs to an identity

    func test_reconnectBudget_exhaustedForOneIdentity_isGrantedAgainToAReplacementIdentity() async {
        let factory = SpyHerdrTransportFactory()
        // One lifetime reconnect attempt per identity: the first EOF
        // spends it, the second exhausts the budget.
        let coordinator = makeCoordinator(factory: factory, reconnectDelays: [.zero, .zero], maxLifetimeReconnectAttempts: 1)
        let first = identity(socketPath, inode: 101)
        let second = identity(socketPath, inode: 202)

        coordinator.herdrSessionPresenceDidChange(.appeared(first))
        guard let initialTransport = await driveConnectAttempt(factory: factory, baseIndex: 0, paneIDs: []) else {
            XCTFail("Precondition: the coordinator must settle on a connection to the first identity")
            return
        }

        // Spend the single lifetime attempt: this connection drops
        // before delivering any event, so it never earns the budget back.
        await initialTransport.simulateEOF()
        guard let reconnectedTransport = await driveConnectAttempt(factory: factory, baseIndex: 2, paneIDs: []) else {
            XCTFail("Precondition: the first EOF must be followed by exactly one bounded reconnect attempt")
            return
        }

        // Budget exhausted: this second EOF must give up entirely.
        await reconnectedTransport.simulateEOF()
        await settle()
        let callCountAfterGivingUp = await factory.callCount
        XCTAssertEqual(
            callCountAfterGivingUp, 4,
            "Precondition: the lifetime reconnect budget for this identity is spent -- no further attempt " +
            "may follow its second EOF"
        )

        // A REPLACEMENT server is a different session, not the flapping
        // one the budget was spent on.
        coordinator.herdrSessionPresenceDidChange(.replaced(previous: first, current: second))

        guard await driveConnectAttempt(factory: factory, baseIndex: 4, paneIDs: []) != nil else {
            XCTFail(
                "the reconnect budget belongs to an identity, not to this process: a NEW identity must be " +
                "connected to even after the previous identity's own budget was exhausted"
            )
            return
        }
    }

    // MARK: - Connect-sequence driver

    /// Drives ONE full connect attempt starting at transport
    /// `#baseIndex` -- see HerdrIntegrationCoordinatorTests.swift's own
    /// header, TRANSPORT ACCOUNTING. Returns transport `#baseIndex + 1`,
    /// the long-lived event-stream connection.
    @discardableResult
    private func driveConnectAttempt(
        factory: SpyHerdrTransportFactory, baseIndex: Int, paneIDs: [String]
    ) async -> InMemoryHerdrTransport? {
        guard let snapshotTransport = await awaitTransport(factory, at: baseIndex) else {
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

    // MARK: - Fixture builders (shapes measured against real herdr 0.8.0)

    private func subscribeAckLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    private func snapshotResponseLine(id: String, paneIDs: [String]) -> String {
        let agentsJSON = paneIDs.map { paneID in
            #"{"terminal_id":"term_\#(paneID)","agent":"claude","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"\#(paneID)","focused":false,"state_change_seq":0,"cwd":"/Users/dev/project","foreground_cwd":"/Users/dev/project","revision":0}"#
        }.joined(separator: ",")
        let panesJSON = paneIDs.map { paneID in
            #"{"terminal_id":"term_\#(paneID)","agent_status":"working","workspace_id":"w1","tab_id":"w1:t1","pane_id":"\#(paneID)","focused":false,"revision":0}"#
        }.joined(separator: ",")
        return #"{"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":null,"workspaces":[],"tabs":[],"panes":[\#(panesJSON)],"layouts":[],"agents":[\#(agentsJSON)]}}}"#
    }

    // MARK: - Wire-line parsing helpers

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

    // MARK: - Bounded async polling

    private func waitUntil(maxYields: Int = 2_000, _ condition: () async -> Bool) async {
        var iterations = 0
        while await !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    /// Lets any in-flight coordinator work land before a "nothing more
    /// happened" assertion, so that assertion is about the contract
    /// rather than about being early.
    private func settle() async {
        for _ in 0..<500 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0..<500 { await Task.yield() }
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
