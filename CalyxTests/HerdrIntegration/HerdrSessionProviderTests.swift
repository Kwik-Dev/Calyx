//
//  HerdrSessionProviderTests.swift
//  CalyxTests
//
//  HerdrCLISessionProvider.listSessions()'s snapshot-driven counts:
//  phase 2 (HerdrSessionProvider.swift's own doc comment) fetches one
//  session.snapshot per socket phase 1's discovery+liveness sweep kept,
//  and derives HerdrSessionInfo's workspaceCount/paneCount/agentCount
//  from it. Every dependency is a fake/spy -- no real socket or herdr
//  binary is ever touched, mirroring
//  HerdrIntegrationCoordinatorTests.swift's own SpyHerdrTransportFactory
//  + InMemoryHerdrTransport style, and its own per-file fake-duplication
//  convention.
//
//  Coverage:
//  - a snapshot with multiple panes across multiple workspaces maps onto
//    HerdrSessionInfo's workspaceCount (distinct workspace_id count),
//    paneCount, and agentCount
//  - a snapshot that fails (transport EOF before answering) leaves all
//    three counts nil, and the row still appears -- a live socket whose
//    snapshot failed is still a live herdr
//

import XCTest
@testable import Calyx

// MARK: - Fakes

/// Fixed candidate/alive set -- neither test below mutates either
/// mid-run, so this stays an immutable struct (simpler than
/// HerdrIntegrationCoordinatorTests's own lock-guarded
/// FakeHerdrSessionDiscovery, built for that file's own need to flip a
/// socket from alive to dead mid-run).
private struct FakeHerdrSessionDiscovery: HerdrSessionDiscoveryProtocol {
    let candidates: [HerdrSessionCandidate]
    let aliveSocketPaths: Set<String>

    func discover() -> [HerdrSessionCandidate] { candidates }
    func isAlive(socketPath: String) -> Bool { aliveSocketPaths.contains(socketPath) }
}

/// `HerdrTransportFactory` spy: each `makeTransport()` call hands out a
/// fresh `InMemoryHerdrTransport`, retaining it so tests can drive it --
/// mirrors `HerdrIntegrationCoordinatorTests.SpyHerdrTransportFactory`.
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

// MARK: - HerdrSessionProviderTests

final class HerdrSessionProviderTests: XCTestCase {

    private let socketPath = "/fixture/config/herdr/herdr.sock"

    // MARK: - listSessions() maps a snapshot's panes/workspaces/agents onto HerdrSessionInfo's counts

    func test_listSessions_snapshotWithMultipleWorkspacesAndPanes_populatesRowCounts() async {
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)],
            aliveSocketPaths: [socketPath]
        )
        let factory = SpyHerdrTransportFactory()
        let provider = HerdrCLISessionProvider(discovery: discovery, transportFactory: factory)

        let task = Task { await provider.listSessions() }
        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected listSessions() to request a transport for the one alive candidate")
            return
        }
        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateLine(snapshotResponseLineWithTwoWorkspaces(id: "1"))

        let sessions = await task.value

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 1, "one alive candidate must request exactly one transport")
        XCTAssertEqual(sessions.count, 1)
        guard let session = sessions.first else { return }
        XCTAssertEqual(session.id, socketPath)
        XCTAssertEqual(session.name, "default")
        XCTAssertEqual(session.workspaceCount, 2, "3 panes across w1/w2 must count as 2 distinct workspaces")
        XCTAssertEqual(session.paneCount, 3)
        XCTAssertEqual(session.agentCount, 2)
    }

    // MARK: - listSessions() leaves counts nil, without dropping the row, when a snapshot fails

    func test_listSessions_snapshotFails_leavesCountsNil_stillYieldsTheRow() async {
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)],
            aliveSocketPaths: [socketPath]
        )
        let factory = SpyHerdrTransportFactory()
        let provider = HerdrCLISessionProvider(discovery: discovery, transportFactory: factory)

        let task = Task { await provider.listSessions() }
        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected listSessions() to request a transport for the one alive candidate")
            return
        }
        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateEOF()

        let sessions = await task.value

        XCTAssertEqual(
            sessions.count, 1,
            "a live socket whose snapshot failed must still yield a row, just with unknown counts"
        )
        guard let session = sessions.first else { return }
        XCTAssertEqual(session.id, socketPath)
        XCTAssertEqual(session.name, "default")
        XCTAssertNil(session.workspaceCount)
        XCTAssertNil(session.paneCount)
        XCTAssertNil(session.agentCount)
    }

    // MARK: - Fixtures

    /// `session.snapshot` result with 3 panes across 2 distinct
    /// workspaces (`w1`: two panes, `w2`: one) and 2 agents --
    /// required-fields-only PaneInfo/AgentInfo records (see
    /// HerdrEvent.swift's own header), matching
    /// `HerdrConnectionTests.snapshotResponseLineWithOneMinimalPane`'s
    /// own minimal-fixture style.
    private func snapshotResponseLineWithTwoWorkspaces(id: String) -> String {
        #"""
        {"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"workspaces":[],"tabs":[],"panes":[{"terminal_id":"term-1","agent_status":"unknown","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"revision":1},{"terminal_id":"term-2","agent_status":"unknown","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p2","focused":false,"revision":1},{"terminal_id":"term-3","agent_status":"working","workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","focused":false,"revision":1}],"layouts":[],"agents":[{"terminal_id":"term-1","agent_status":"unknown","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"revision":1},{"terminal_id":"term-3","agent_status":"working","workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","focused":false,"revision":1}]}}}
        """#
    }

    // MARK: - Bounded async polling (mirrors HerdrConnectionTests.swift's own helpers)

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
