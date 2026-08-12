//
//  HerdrTabCoordinatorObserverConformanceTests.swift
//  CalyxTests
//
//  Tests for HerdrTabCoordinator's HerdrStructureEventObserver
//  conformance (app-layer wiring): wires HerdrIntegrationCoordinator's
//  pane.closed/layout.updated/workspace.closed events
//  (HerdrIntegrationCoordinator.swift's own HerdrStructureEventObserver
//  protocol) into HerdrTabCoordinator's own handleLayoutUpdated/
//  handlePaneClosed/handleWorkspaceKilled methods.
//
//  Mirrors HerdrTabCoordinatorTests' own driving style exactly -- this
//  file re-declares its own private copies of the same spy/fake types
//  and wire-driving helpers, per that file's own header ("a fresh,
//  file-scoped private redeclaration here, not a shared type -- private
//  at file scope is not visible across files").
//
//  Every HerdrStructureEventObserver method is synchronous per the
//  protocol (HerdrIntegrationCoordinator.swift). herdrLayoutUpdated/
//  herdrPaneClosed delegate to the ASYNC handleLayoutUpdated/
//  handlePaneClosed, so those two fan out via an internally-spawned
//  Task, and their own tests below poll (bounded yield loop, mirroring
//  HerdrTabCoordinatorTests' own "yield-based settling") for the
//  resulting wire activity / attacher calls rather than awaiting a
//  returned value directly. herdrWorkspaceClosed instead delegates to
//  the already-SYNCHRONOUS handleWorkspaceKilled directly, with no Task
//  -- its own tests below assert immediately after calling it, no
//  polling needed.
//
//  Coverage:
//  - herdrLayoutUpdated(socketPath:) triggers handleLayoutUpdated for
//    EVERY workspace previously opened on that socketPath: opening two
//    workspaces on ONE socket, then firing the observer method, produces
//    exactly two NEW layout.export requests, one scoped to each
//    workspace's own resolved active tab id (order-independent: matched
//    by content, not by transport index, since the two workspaces' own
//    async work is not required to interleave in a fixed order).
//  - ...leaves a workspace opened on a DIFFERENT socketPath completely
//    untouched (zero requests for it).
//  - herdrPaneClosed(paneID:socketPath:) delegates to handlePaneClosed:
//    the attacher's closeLeaf hook fires for the mapped surface.
//  - herdrWorkspaceClosed(workspaceID:socketPath:) delegates to
//    handleWorkspaceKilled: every leaf still registered for the
//    workspace is closed through the attacher, the registry is pruned,
//    and herdr is sent no request; a no-op (zero transport activity, no
//    attacher calls) for a workspaceID with nothing registered.
//  - HerdrTabCoordinator actually CONFORMS to HerdrStructureEventObserver
//    (not merely "happens to have matching method names") -- proven in
//    every test below by assigning a coordinator instance to an `any
//    HerdrStructureEventObserver` typed variable, a real compile-time
//    conformance check.
//

import XCTest
import Foundation
@testable import Calyx

// MARK: - Fakes (re-declared per HerdrTabCoordinatorTests.swift's own precedent)

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

@MainActor
private final class FakeHerdrNativeSurfaceFactory: HerdrNativeSurfaceFactory {
    private(set) var createCommands: [String] = []
    private(set) var destroyedIDs: [UUID] = []
    private var resultQueue: [UUID?]

    init(results: [UUID?]) {
        self.resultQueue = results
    }

    func createSurface(command: String) -> UUID? {
        createCommands.append(command)
        guard !resultQueue.isEmpty else { return nil }
        return resultQueue.removeFirst()
    }

    func destroySurface(_ id: UUID) {
        destroyedIDs.append(id)
    }
}

@MainActor
private final class FakeHerdrNativeTabAttacher: HerdrNativeTabAttacher {
    private(set) var attachedPlans: [HerdrNativeTabPlan] = []
    private(set) var closeLeafCalls: [UUID] = []

    func attachTab(plan: HerdrNativeTabPlan) -> Bool {
        attachedPlans.append(plan)
        return true
    }

    func focusExistingTab(withWorkspaceID workspaceID: String, socketPath: String) -> Bool {
        false
    }

    func updateRatio(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double) {}

    func closeLeaf(_ id: UUID) {
        closeLeafCalls.append(id)
    }
}

private let socketPath = "/tmp/herdr-observer-conformance-test/herdr.sock"
private let herdrBinPath = "/opt/homebrew/bin/herdr"
/// Realistic, measured-shaped ("term_" + lowercase hex --
/// HerdrPaneRef.isValidTerminalID's own header) terminal ids -- never a
/// "term_" + pane-id-with-a-colon shape, which isValidTerminalID rejects
/// outright (HerdrPaneRef.swift's own byte-walk gate: only alnum/
/// underscore is accepted after the "term_" prefix).
private let terminalIDWFP1 = "term_658cabe34ba1713"
private let terminalIDWGP1 = "term_9be2f0ac714dd6e"
private let terminalIDWHP1 = "term_2f7c04ab19e6d38"

// MARK: - HerdrTabCoordinatorObserverConformanceTests

@MainActor
final class HerdrTabCoordinatorObserverConformanceTests: XCTestCase {

    private var registry: HerdrPaneRegistry!

    override func setUp() {
        super.setUp()
        registry = HerdrPaneRegistry()
    }

    override func tearDown() {
        registry._stopObserving()
        registry = nil
        super.tearDown()
    }

    private func makeCoordinator(
        factory: SpyHerdrTransportFactory, surfaceFactory: FakeHerdrNativeSurfaceFactory, attacher: FakeHerdrNativeTabAttacher
    ) -> HerdrTabCoordinator {
        HerdrTabCoordinator(
            transportFactory: factory, herdrBinPath: herdrBinPath, registry: registry,
            surfaceFactory: surfaceFactory, attacher: attacher
        )
    }

    // MARK: - 1. herdrLayoutUpdated re-exports every workspace opened on that socket

    func test_herdrLayoutUpdated_reExportsEveryWorkspaceOpenedOnThatSocket_onePerWorkspaceTabID() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [UUID(), UUID()])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let openF: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t2",
            terminalIDByPaneID: ["wF:p1": terminalIDWFP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        guard await openF else { XCTFail("Precondition: opening wF must succeed"); return }

        async let openG: Bool = coordinator.openWorkspace(workspaceID: "wG", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 3, workspaceID: "wG", activeTabID: "wG:t7",
            terminalIDByPaneID: ["wG:p1": terminalIDWGP1],
            responseRootJSON: paneNodeJSON(paneID: "wG:p1"), focusedPaneID: "wG:p1"
        )
        guard await openG else { XCTFail("Precondition: opening wG must succeed"); return }

        let baselineCount = await factory.callCount
        XCTAssertEqual(baselineCount, 6, "Precondition: two single-pane opens must use exactly six transports")

        let observer: any HerdrStructureEventObserver = coordinator
        observer.herdrLayoutUpdated(socketPath: socketPath)

        guard let firstNew = await awaitTransport(factory, at: 6), let secondNew = await awaitTransport(factory, at: 7) else {
            XCTFail("expected exactly two new transports (one re-export per opened workspace)")
            return
        }
        let firstSent = await awaitSentMessages(firstNew, atLeast: 1)
        let secondSent = await awaitSentMessages(secondNew, atLeast: 1)

        guard firstSent.count == 1, secondSent.count == 1 else {
            XCTFail("expected exactly one request line on each new transport, got \(firstSent) / \(secondSent)")
            return
        }
        XCTAssertEqual(requestMethod(inLine: firstSent[0]), "layout.export")
        XCTAssertEqual(requestMethod(inLine: secondSent[0]), "layout.export")

        let tabIDs = Set([firstSent[0], secondSent[0]].compactMap { paneOrTabIDParam(inLine: $0)?.value })
        XCTAssertEqual(
            tabIDs, Set(["wF:t2", "wG:t7"]),
            "expected exactly one re-export request per opened workspace, each scoped to that workspace's own " +
            "resolved active tab id -- order-independent, since the two workspaces' own refreshes need not " +
            "interleave in a fixed order"
        )

        let settledCount = await confirmSettledTransportCount(factory)
        XCTAssertEqual(settledCount, 8, "expected exactly two new transports total, no third")

        // Answer both so neither internal refresh Task is left hanging.
        if let id = requestID(inLine: firstSent[0]) {
            await firstNew.simulateLine(layoutExportResponseLine(
                id: id, workspaceID: "wF", tabID: "wF:t2", zoomed: false, focusedPaneID: "wF:p1",
                root: paneNodeJSON(paneID: "wF:p1")
            ))
        }
        if let id = requestID(inLine: secondSent[0]) {
            await secondNew.simulateLine(layoutExportResponseLine(
                id: id, workspaceID: "wG", tabID: "wG:t7", zoomed: false, focusedPaneID: "wG:p1",
                root: paneNodeJSON(paneID: "wG:p1")
            ))
        }
    }

    // MARK: - 2. herdrLayoutUpdated leaves a different socketPath's workspace untouched

    func test_herdrLayoutUpdated_leavesADifferentSocketPathsWorkspaceUntouched() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [UUID(), UUID()])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)
        let otherSocketPath = "/tmp/herdr-observer-conformance-test/other.sock"

        async let openF: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t2",
            terminalIDByPaneID: ["wF:p1": terminalIDWFP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        guard await openF else { XCTFail("Precondition: opening wF must succeed"); return }

        async let openH: Bool = coordinator.openWorkspace(workspaceID: "wH", socketPath: otherSocketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 3, workspaceID: "wH", activeTabID: "wH:t9",
            terminalIDByPaneID: ["wH:p1": terminalIDWHP1],
            responseRootJSON: paneNodeJSON(paneID: "wH:p1"), focusedPaneID: "wH:p1"
        )
        guard await openH else { XCTFail("Precondition: opening wH must succeed"); return }

        let observer: any HerdrStructureEventObserver = coordinator
        observer.herdrLayoutUpdated(socketPath: otherSocketPath)

        guard let onlyNew = await awaitTransport(factory, at: 6) else {
            XCTFail("expected exactly one new transport (wH's own re-export)")
            return
        }
        let sent = await awaitSentMessages(onlyNew, atLeast: 1)
        guard sent.count == 1 else {
            XCTFail("expected exactly one request line, got \(sent)")
            return
        }
        XCTAssertEqual(requestMethod(inLine: sent[0]), "layout.export")
        XCTAssertEqual(
            paneOrTabIDParam(inLine: sent[0])?.value, "wH:t9",
            "the only re-export must be scoped to wH -- the workspace opened on the socketPath the event fired for"
        )

        let settledCount = await confirmSettledTransportCount(factory)
        XCTAssertEqual(settledCount, 7, "wF (opened on a different socketPath) must never be re-exported")

        if let id = requestID(inLine: sent[0]) {
            await onlyNew.simulateLine(layoutExportResponseLine(
                id: id, workspaceID: "wH", tabID: "wH:t9", zoomed: false, focusedPaneID: "wH:p1",
                root: paneNodeJSON(paneID: "wH:p1")
            ))
        }
    }

    // MARK: - 3. herdrPaneClosed delegates to handlePaneClosed

    func test_herdrPaneClosed_delegatesToHandlePaneClosed_closesTheMappedSurface() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let openTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDWFP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        guard await openTask else { XCTFail("Precondition: opening wF must succeed"); return }

        let observer: any HerdrStructureEventObserver = coordinator
        observer.herdrPaneClosed(paneID: "wF:p1", socketPath: socketPath)

        await waitUntil { attacher.closeLeafCalls.contains(fakeSurfaceID) }
        XCTAssertEqual(
            attacher.closeLeafCalls, [fakeSurfaceID],
            "herdrPaneClosed must delegate to handlePaneClosed, which asks the attacher to close exactly the " +
            "tracked leaf for the closed pane"
        )
    }

    // MARK: - 4. herdrWorkspaceClosed delegates to handleWorkspaceKilled

    /// Synchronous, no Task (this file's own header) -- asserted
    /// immediately after calling `herdrWorkspaceClosed`, no polling.
    func test_herdrWorkspaceClosed_delegatesToHandleWorkspaceKilled_closesEveryRegisteredLeaf_sendsNoHerdrRequest() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let openTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDWFP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        guard await openTask else { XCTFail("Precondition: opening wF must succeed"); return }
        let callCountAfterOpen = await factory.callCount

        let observer: any HerdrStructureEventObserver = coordinator
        observer.herdrWorkspaceClosed(workspaceID: "wF", socketPath: socketPath)

        XCTAssertEqual(
            attacher.closeLeafCalls, [fakeSurfaceID],
            "herdrWorkspaceClosed must delegate to handleWorkspaceKilled, which closes every leaf still " +
            "registered for the workspace through the attacher"
        )
        XCTAssertFalse(registry.isBridgeSurface(fakeSurfaceID), "the registry must be pruned for the closed leaf")

        let callCountAfter = await factory.callCount
        XCTAssertEqual(
            callCountAfter, callCountAfterOpen,
            "herdrWorkspaceClosed must send herdr no request of its own -- herdr already closed this workspace"
        )
    }

    // MARK: - 5. herdrWorkspaceClosed is a no-op for an unknown workspace

    func test_herdrWorkspaceClosed_unknownWorkspace_isNoOp() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        let observer: any HerdrStructureEventObserver = coordinator
        observer.herdrWorkspaceClosed(workspaceID: "wNeverOpened", socketPath: socketPath)

        XCTAssertEqual(attacher.closeLeafCalls, [], "nothing registered for this workspace means nothing to close")
        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 0, "a workspace with no pane tracked on this socket must touch the transport factory zero times")
    }

    // MARK: - Fixture builders (mirrors HerdrTabCoordinatorTests' own shapes)

    private func workspaceGetResponseLine(id: String, workspaceID: String, activeTabID: String) -> String {
        "{\"id\":\"\(id)\",\"result\":{\"type\":\"workspace_info\",\"workspace\":{" +
        "\"workspace_id\":\"\(workspaceID)\",\"number\":1,\"label\":\"demo\",\"focused\":true," +
        "\"pane_count\":1,\"tab_count\":1,\"active_tab_id\":\"\(activeTabID)\",\"agent_status\":\"idle\"}}}"
    }

    private func paneNodeJSON(paneID: String) -> String {
        "{\"type\":\"pane\",\"pane_id\":\"\(paneID)\"}"
    }

    /// {"id":..,"result":{"type":"session_snapshot","snapshot":{...}}} --
    /// mirrors HerdrTabCoordinatorTests' own `sessionSnapshotResponseLine`.
    /// `panes[]` carries exactly one required-fields-only PaneInfo entry
    /// per `terminalIDByPaneID` key (PaneInfo's own schema `required`:
    /// "pane_id", "terminal_id", "workspace_id", "tab_id", "focused",
    /// "agent_status", "revision" -- `herdr api schema --json`).
    private func sessionSnapshotResponseLine(id: String, terminalIDByPaneID: [String: String]) -> String {
        let panesJSON = terminalIDByPaneID.map { paneID, terminalID in
            "{\"pane_id\":\"\(paneID)\",\"terminal_id\":\"\(terminalID)\",\"workspace_id\":\"wF\"," +
            "\"tab_id\":\"wF:t1\",\"focused\":false,\"agent_status\":\"idle\",\"revision\":0}"
        }.joined(separator: ",")
        return "{\"id\":\"\(id)\",\"result\":{\"type\":\"session_snapshot\",\"snapshot\":{\"version\":\"0.8.0\"," +
        "\"protocol\":19,\"workspaces\":[],\"tabs\":[],\"panes\":[\(panesJSON)],\"layouts\":[],\"agents\":[]}}}"
    }

    private func layoutExportResponseLine(
        id: String, workspaceID: String, tabID: String, zoomed: Bool, focusedPaneID: String, root: String
    ) -> String {
        "{\"id\":\"\(id)\",\"result\":{\"type\":\"layout_export\",\"layout\":{\"workspace_id\":\"\(workspaceID)\"," +
        "\"tab_id\":\"\(tabID)\",\"zoomed\":\(zoomed),\"focused_pane_id\":\"\(focusedPaneID)\",\"root\":\(root)}}}"
    }

    // MARK: - Wire drive helper: full open sequence (workspace.get, session.snapshot, then layout.export)
    // Mirrors HerdrTabCoordinatorTests.driveOpenSequence.

    @discardableResult
    private func driveOpenSequence(
        factory: SpyHerdrTransportFactory, baseIndex: Int, workspaceID: String, activeTabID: String,
        terminalIDByPaneID: [String: String], responseRootJSON: String, focusedPaneID: String
    ) async -> InMemoryHerdrTransport? {
        guard let workspaceGetTransport = await awaitTransport(factory, at: baseIndex) else {
            XCTFail("expected transport #\(baseIndex) to have been created for the workspace.get request")
            return nil
        }
        let workspaceGetSent = await awaitSentMessages(workspaceGetTransport, atLeast: 1)
        guard workspaceGetSent.count == 1, requestMethod(inLine: workspaceGetSent[0]) == "workspace.get",
              let workspaceGetID = requestID(inLine: workspaceGetSent[0]) else {
            XCTFail("expected transport #\(baseIndex)'s only request to be workspace.get; got \(workspaceGetSent)")
            await workspaceGetTransport.simulateFailure("test: unexpected request shape")
            return nil
        }
        await workspaceGetTransport.simulateLine(
            workspaceGetResponseLine(id: workspaceGetID, workspaceID: workspaceID, activeTabID: activeTabID)
        )

        guard let snapshotTransport = await awaitTransport(factory, at: baseIndex + 1) else {
            XCTFail("expected transport #\(baseIndex + 1) to have been created for the session.snapshot request")
            return nil
        }
        let snapshotSent = await awaitSentMessages(snapshotTransport, atLeast: 1)
        guard snapshotSent.count == 1, requestMethod(inLine: snapshotSent[0]) == "session.snapshot",
              let snapshotID = requestID(inLine: snapshotSent[0]) else {
            XCTFail("expected transport #\(baseIndex + 1)'s only request to be session.snapshot; got \(snapshotSent)")
            await snapshotTransport.simulateFailure("test: unexpected request shape")
            return nil
        }
        await snapshotTransport.simulateLine(sessionSnapshotResponseLine(id: snapshotID, terminalIDByPaneID: terminalIDByPaneID))

        guard let layoutExportTransport = await awaitTransport(factory, at: baseIndex + 2) else {
            XCTFail("expected transport #\(baseIndex + 2) to have been created for the layout.export request")
            return nil
        }
        let layoutExportSent = await awaitSentMessages(layoutExportTransport, atLeast: 1)
        guard layoutExportSent.count == 1, requestMethod(inLine: layoutExportSent[0]) == "layout.export",
              let layoutExportID = requestID(inLine: layoutExportSent[0]) else {
            XCTFail("expected transport #\(baseIndex + 2)'s only request to be layout.export; got \(layoutExportSent)")
            await layoutExportTransport.simulateFailure("test: unexpected request shape")
            return nil
        }
        await layoutExportTransport.simulateLine(layoutExportResponseLine(
            id: layoutExportID, workspaceID: workspaceID, tabID: activeTabID, zoomed: false,
            focusedPaneID: focusedPaneID, root: responseRootJSON
        ))
        return layoutExportTransport
    }

    // MARK: - Wire-line parsing helpers (mirrors HerdrTabCoordinatorTests' own shapes)

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

    private func paneOrTabIDParam(inLine line: String) -> (key: String, value: String)? {
        guard let params = jsonObject(inLine: line)?["params"] as? [String: Any] else { return nil }
        if let value = params["tab_id"] as? String, !value.isEmpty { return ("tab_id", value) }
        if let value = params["pane_id"] as? String, !value.isEmpty { return ("pane_id", value) }
        return nil
    }

    // MARK: - Bounded async polling (mirrors HerdrTabCoordinatorTests' own shapes)

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

    /// Gives any (buggy) additional in-flight request a fair chance to appear, then
    /// returns the settled transport count -- mirrors this file's sibling suite's
    /// "wait-based settling" style (HerdrTabCoordinatorTests.swift's own header).
    private func confirmSettledTransportCount(_ factory: SpyHerdrTransportFactory, extraYields: Int = 500) async -> Int {
        for _ in 0..<extraYields {
            await Task.yield()
        }
        return await factory.callCount
    }
}
