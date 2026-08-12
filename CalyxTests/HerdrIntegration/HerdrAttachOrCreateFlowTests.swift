//
//  HerdrAttachOrCreateFlowTests.swift
//  CalyxTests
//
//  HerdrAttachOrCreateFlow.run(socketPath:transportFactory:logger:
//  openWorkspace:): SessionBrowserWindowController.attachHerdr(_:)'s own
//  create-versus-attach decision, driven by a LIVE session.snapshot
//  fetched at call time -- never a row's own cached counts (those only
//  drive the Attach/New button title, SessionBrowserModelHerdrTests
//  .swift's own HerdrAttachGate coverage). `openWorkspace` is a plain
//  spy closure here, standing in for `HerdrTabCoordinator
//  .openWorkspace(workspaceID:socketPath:)` -- production wiring calls
//  that method directly, unchanged; this file never constructs a full
//  coordinator. Every transport is a fake -- mirrors
//  HerdrTabCoordinatorTests.swift's own SpyHerdrTransportFactory +
//  InMemoryHerdrTransport style, and this codebase's per-file
//  fake-duplication convention.
//
//  Coverage:
//  - a snapshot naming zero workspaces sends workspace.create (params
//    EXACTLY {"focus":true}, decoded from a required-fields-only
//    "workspace_created" response -- pinning that decode), then opens
//    the created workspace's own id through openWorkspace, and no other
//    id
//  - a snapshot naming at least one workspace never sends workspace
//    .create at all (only one transport is ever requested), opens every
//    workspace id in sorted order, then re-opens the focused one last so
//    it ends focused -- the unchanged existing-workspace attach path
//

import XCTest
import os
@testable import Calyx

// MARK: - Fakes

/// `HerdrTransportFactory` spy: mirrors `HerdrTabCoordinatorTests`' own
/// `SpyHerdrTransportFactory` (a fresh, file-scoped `private`
/// redeclaration, not a shared type).
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

/// Records every `openWorkspace` call, in order -- standing in for
/// `HerdrTabCoordinator.openWorkspace(workspaceID:socketPath:)`.
/// `@MainActor` since `HerdrAttachOrCreateFlow.run` itself is.
@MainActor
private final class OpenWorkspaceSpy {
    private(set) var calls: [(workspaceID: String, socketPath: String)] = []

    func open(_ workspaceID: String, _ socketPath: String) async -> Bool {
        calls.append((workspaceID: workspaceID, socketPath: socketPath))
        return true
    }
}

// MARK: - HerdrAttachOrCreateFlowTests

@MainActor
final class HerdrAttachOrCreateFlowTests: XCTestCase {

    private let socketPath = "/fixture/config/herdr/herdr.sock"
    private let logger = Logger(subsystem: "com.calyx.terminal.tests", category: "HerdrAttachOrCreateFlowTests")

    // MARK: - Zero workspaces: sends workspace.create, then opens exactly the created id

    func test_run_emptySnapshot_sendsWorkspaceCreate_thenOpensTheCreatedWorkspaceID() async {
        let factory = SpyHerdrTransportFactory()
        let spy = OpenWorkspaceSpy()

        let task = Task {
            await HerdrAttachOrCreateFlow.run(
                socketPath: socketPath, transportFactory: factory, logger: logger,
                openWorkspace: { workspaceID, socketPath in await spy.open(workspaceID, socketPath) }
            )
        }

        guard let snapshotTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected transport #0 to have been created for the session.snapshot request")
            return
        }
        _ = await awaitSentMessages(snapshotTransport, atLeast: 1)
        await snapshotTransport.simulateLine(emptySnapshotResponseLine(id: "1"))

        guard let createTransport = await awaitTransport(factory, at: 1) else {
            XCTFail("expected transport #1 to have been created for the workspace.create request")
            return
        }
        let createSent = await awaitSentMessages(createTransport, atLeast: 1)
        guard createSent.count == 1, let createID = requestID(inLine: createSent[0]) else {
            XCTFail("expected transport #1's only request to be workspace.create; got \(createSent)")
            return
        }
        XCTAssertEqual(requestMethod(inLine: createSent[0]), "workspace.create")
        let createParams = jsonObject(inLine: createSent[0])?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            createParams as NSDictionary, ["focus": true] as NSDictionary,
            "workspace.create's params must carry EXACTLY {\"focus\":true} -- WorkspaceCreateParams' own " +
            "schema shape, no cwd/env/label"
        )
        await createTransport.simulateLine(workspaceCreatedResponseLine(id: createID, workspaceID: "w-new"))

        await task.value

        XCTAssertEqual(
            spy.calls.map { $0.workspaceID }, ["w-new"],
            "an empty snapshot must open exactly the workspace workspace.create returned, nothing else"
        )
        XCTAssertEqual(spy.calls.map { $0.socketPath }, [socketPath])
        let totalTransports = await factory.callCount
        XCTAssertEqual(totalTransports, 2, "exactly session.snapshot then workspace.create, no more")
    }

    // MARK: - Non-empty snapshot: never sends workspace.create, opens each id then refocuses

    func test_run_nonEmptySnapshot_neverSendsWorkspaceCreate_opensEachIDThenRefocuses() async {
        let factory = SpyHerdrTransportFactory()
        let spy = OpenWorkspaceSpy()

        let task = Task {
            await HerdrAttachOrCreateFlow.run(
                socketPath: socketPath, transportFactory: factory, logger: logger,
                openWorkspace: { workspaceID, socketPath in await spy.open(workspaceID, socketPath) }
            )
        }

        guard let snapshotTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected transport #0 to have been created for the session.snapshot request")
            return
        }
        _ = await awaitSentMessages(snapshotTransport, atLeast: 1)
        await snapshotTransport.simulateLine(twoWorkspaceSnapshotResponseLine(id: "1", focusedWorkspaceID: "w2"))

        await task.value

        XCTAssertEqual(
            spy.calls.map { $0.workspaceID }, ["w1", "w2", "w2"],
            "must open every workspace id in sorted order, then re-open the focused one last so it ends " +
            "focused -- unchanged existing-workspace attach behavior"
        )
        XCTAssertEqual(spy.calls.map { $0.socketPath }, [socketPath, socketPath, socketPath])
        let totalTransports = await factory.callCount
        XCTAssertEqual(totalTransports, 1, "a non-empty snapshot must never send workspace.create")
    }

    // MARK: - Fixtures

    /// Required-fields-only `session.snapshot` result naming zero
    /// workspaces (`panes: []`) -- HerdrSessionSnapshot's own schema
    /// `required`: version, protocol, workspaces, tabs, panes, layouts,
    /// agents.
    private func emptySnapshotResponseLine(id: String) -> String {
        #"""
        {"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[]}}}
        """#
    }

    /// Two workspaces (w1, w2), one pane each, `focused_workspace_id`
    /// set to `focusedWorkspaceID` -- required-fields-only PaneInfo
    /// records, mirroring `HerdrSessionProviderTests`' own fixture style.
    private func twoWorkspaceSnapshotResponseLine(id: String, focusedWorkspaceID: String) -> String {
        #"""
        {"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"workspaces":[],"tabs":[],"panes":[{"terminal_id":"term-1","agent_status":"unknown","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":false,"revision":1},{"terminal_id":"term-2","agent_status":"unknown","workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","focused":true,"revision":1}],"layouts":[],"agents":[],"focused_workspace_id":"\#(focusedWorkspaceID)"}}}
        """#
    }

    /// `workspace.create`'s own required-fields-only response --
    /// WorkspaceInfo (8 required), TabInfo (7 required), PaneInfo (7
    /// required), `herdr api schema --json`. `tab`/`root_pane` are
    /// schema-required on this response but read by nothing in
    /// production; included only so this fixture is schema-valid,
    /// mirroring `HerdrTabCoordinatorTests.workspaceGetResponseLine`'s
    /// own precedent of including required fields neither side reads.
    private func workspaceCreatedResponseLine(id: String, workspaceID: String) -> String {
        #"""
        {"id":"\#(id)","result":{"type":"workspace_created","workspace":{"workspace_id":"\#(workspaceID)","number":1,"label":"demo","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"\#(workspaceID):t1","agent_status":"idle"},"tab":{"tab_id":"\#(workspaceID):t1","workspace_id":"\#(workspaceID)","number":1,"label":"demo","focused":true,"pane_count":1,"agent_status":"idle"},"root_pane":{"pane_id":"\#(workspaceID):p1","terminal_id":"term-new","workspace_id":"\#(workspaceID)","tab_id":"\#(workspaceID):t1","focused":true,"agent_status":"idle","revision":1}}}
        """#
    }

    // MARK: - Wire-line parsing helpers (mirrors HerdrTabCoordinatorTests.swift's own)

    private func jsonObject(inLine line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func requestMethod(inLine line: String) -> String? {
        jsonObject(inLine: line)?["method"] as? String
    }

    private func requestID(inLine line: String) -> String? {
        jsonObject(inLine: line)?["id"] as? String
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
