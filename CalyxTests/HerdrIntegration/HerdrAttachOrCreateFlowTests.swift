//
//  HerdrAttachOrCreateFlowTests.swift
//  CalyxTests
//
//  HerdrAttachOrCreateFlow.createAndOpen(socketPath:transportFactory:
//  logger:openWorkspace:): the herdr server row's own
//  "New" button (SessionBrowserWindowController.createHerdrWorkspace(_:))
//  -- unconditionally sends workspace.create, then opens the workspace that
//  creates. No snapshot fetch, and no create-versus-attach decision:
//  attaching an EXISTING workspace is a workspace row's own "Attach"
//  button's job, calling HerdrTabCoordinator.openWorkspace(workspaceID:
//  socketPath:) directly (SessionBrowserWindowController
//  .attachHerdrWorkspace(_:)), never through this file. `openWorkspace`
//  is a plain spy closure here, standing in for that same coordinator
//  entry point; this file never constructs a full coordinator. Every
//  transport is a fake -- mirrors HerdrTabCoordinatorTests.swift's own
//  SpyHerdrTransportFactory + InMemoryHerdrTransport style, and this
//  codebase's per-file fake-duplication convention.
//
//  Coverage:
//  - createAndOpen sends workspace.create (params EXACTLY {"focus":true},
//    decoded from a required-fields-only "workspace_created" response --
//    pinning that decode) as its first and ONLY request -- no
//    session.snapshot fetch beforehand -- then opens the created
//    workspace's own id through openWorkspace, and no other id
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
/// `@MainActor` since `HerdrAttachOrCreateFlow.createAndOpen` itself is.
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

    // MARK: - createAndOpen sends workspace.create with no snapshot fetch, then opens exactly the created id

    func test_createAndOpen_sendsWorkspaceCreateWithNoSnapshotFetch_thenOpensTheCreatedWorkspaceID() async {
        let factory = SpyHerdrTransportFactory()
        let spy = OpenWorkspaceSpy()

        let task = Task {
            await HerdrAttachOrCreateFlow.createAndOpen(
                socketPath: socketPath, transportFactory: factory, logger: logger,
                openWorkspace: { workspaceID, socketPath in await spy.open(workspaceID, socketPath) }
            )
        }

        guard let createTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected transport #0 to have been created for the workspace.create request")
            return
        }
        let createSent = await awaitSentMessages(createTransport, atLeast: 1)
        guard createSent.count == 1, let createID = requestID(inLine: createSent[0]) else {
            XCTFail("expected transport #0's only request to be workspace.create; got \(createSent)")
            return
        }
        XCTAssertEqual(
            requestMethod(inLine: createSent[0]), "workspace.create",
            "createAndOpen's first request must be workspace.create -- there is no session.snapshot fetch " +
            "before it"
        )
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
            "must open exactly the workspace workspace.create returned, nothing else"
        )
        XCTAssertEqual(spy.calls.map { $0.socketPath }, [socketPath])
        let totalTransports = await factory.callCount
        XCTAssertEqual(totalTransports, 1, "exactly one transport, for workspace.create -- no snapshot fetch")
    }

    // MARK: - Fixtures

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
