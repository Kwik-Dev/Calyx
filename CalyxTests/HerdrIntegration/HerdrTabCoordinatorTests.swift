//
//  HerdrTabCoordinatorTests.swift
//  CalyxTests
//
//  TDD Red Phase for HerdrTabCoordinator: centerpiece, owning
//  "open a herdr workspace as a native Calyx tab" plus live layout sync.
//  Every side-effectful dependency is injected (transportFactory,
//  surfaceFactory, attacher, registry, sleep) so this file never opens a
//  real socket or touches a real ghostty surface -- mirrors
//  HerdrIntegrationCoordinatorTests' own driving style (spy transport
//  factory, simulateLine, yield-based settling), adapted for a
//  one-shot-request-only wire flow (layout.export) instead of that
//  file's connect/subscribe pair.
//
//  OPEN DERIVATION CHOICE -- RESOLVED (was disclosed-but-unpinned; now
//  MEASURED against live herdr 0.8.0, protocol 19, and pinned exactly):
//  openWorkspace(workspaceID:socketPath:) is given only a bare workspace
//  id, but herdr's layout.export takes "pane_id" or "tab_id" in params,
//  never "workspace_id". A bare "<workspaceID>:t1" STRING DERIVATION
//  (this file's own prior implementation) is WRONG -- the workspace's
//  actual ACTIVE tab id must be resolved via a one-shot `workspace.get`
//  (params EXACTLY {"workspace_id": ...} -- WorkspaceTarget's own schema
//  shape, `herdr api schema --json`) FIRST, then used VERBATIM as
//  layout.export's own "tab_id" (never "pane_id") -- see
//  `driveOpenSequence` below, and
//  `test_openWorkspace_activeTabIDFromWorkspaceGet_notDerivedFromWorkspaceIDString_usedExactlyForLayoutExport`
//  for the test that specifically kills the string-derivation (a
//  deliberately non-"<workspaceID>:t1"-shaped active_tab_id, "wF:t3").
//  `driveLayoutExport` (the OLDER, narrower helper) is now used ONLY by
//  handleLayoutUpdated's own refresh-path tests below -- that method's
//  own tab-id sourcing is DELIBERATELY left unpinned by this pass (its
//  own tests' contract is unchanged): this correction fixes openWorkspace
//  only, per its own task brief; whether a later pass also routes
//  handleLayoutUpdated through workspace.get (or instead threads the
//  already-resolved tab id through from the open) is left for that pass
//  to decide.
//
//  Coverage:
//  - openWorkspace: single-pane happy path -- one workspace.get, one
//    session.snapshot resolving each wire pane id to its own terminal
//    id, one layout.export scoped to workspace.get's own active_tab_id,
//    one surface whose command is EXACTLY HerdrAttachBridgeCommand's own
//    output (built from the RESOLVED terminal id, never the pane id),
//    registered, attachTab called with a leaf-root plan
//  - openWorkspace: split happy path -- two surfaces created in wire
//    (first-then-second) order, a .horizontal split plan at the wire's
//    own ratio, focusedLeafID resolved from focused_pane_id (the SECOND
//    pane, deliberately, to catch a "always the first leaf" bug)
//  - openWorkspace: the active_tab_id workspace.get returns is used
//    VERBATIM as layout.export's own "tab_id" -- even when it does NOT
//    match the "<workspaceID>:t1" shape a string-derivation would
//    produce; this is the test that kills the string-derivation
//  - openWorkspace: second createSurface fails -> the first surface is
//    rolled back, nothing stays registered, attachTab never called
//  - openWorkspace: an invalid wire pane id -> zero surfaces created at
//    all (the bridge command's own nil is treated as total failure
//    BEFORE any createSurface call, never discovered only afterward)
//  - openWorkspace: a wire pane id absent from session.snapshot's own
//    terminal-id map -> the identical total-failure discipline as an
//    invalid wire pane id: zero surfaces created, zero registrations, no
//    attachTab call
//  - openWorkspace: an already-attached workspace (focusExistingTab
//    returns true) -> zero transport activity, zero surfaces, no
//    attachTab call
//  - openWorkspace: workspace.get's own transport failing before it ever
//    answers -> failure, zero surfaces, attachTab never called, and
//    neither session.snapshot nor layout.export is ever even attempted
//  - openWorkspace: workspace.get itself answering with an RPC error ->
//    same failure discipline
//  - openWorkspace: layout.export's own transport failing before it ever
//    answers, AFTER a successful workspace.get AND session.snapshot ->
//    same failure discipline
//  - handleLayoutUpdated: a re-export identical to what's already known
//    (same tree, same ratio) -> never calls the ratio-mutation seam
//  - handleLayoutUpdated: a re-export with ONLY a ratio change -> calls
//    the ratio-mutation seam exactly once, mapped to the REAL,
//    already-tracked leaf UUIDs (via the registry's paneID lookup), not
//    fresh import-time UUIDs
//  - handlePaneClosed: asks the attacher to close the tracked leaf,
//    prunes the registry in BOTH directions, and NEVER sends any request
//    to herdr (every transport's own sent lines stay byte-for-byte
//    unchanged)
//  - .calyxSurfaceDestroyed (a Calyx-side close): prunes the registry via
//    HerdrPaneRegistry's own existing observation mechanism, never calls
//    closeLeaf again, and sends no herdr request either
//  - handleWorkspaceKilled (the Session Browser's Kill action, called
//    after herdr already closed the workspace server-side): closes
//    every leaf still registered for that workspace through the same
//    close path handlePaneClosed uses, prunes the identical bookkeeping
//    once the last one closes, and sends no herdr request either
//  - handleWorkspaceKilled: a workspace with nothing registered (never
//    opened in this window, or already fully closed) is a no-op
//  - HerdrWorkspaceInfo decode: a minimal, required-fields-only payload
//    decodes both active_tab_id and label; the title-selection decision
//    itself (label present vs. absent/null/blank) is covered directly by
//    HerdrTabTitlePolicyTests, not here -- this file only pins that
//    workspace.get's own response feeds the coordinator a real label
//    (test_openWorkspace_singlePane_..., plan.title, "demo" fixture)
//

import XCTest
import Foundation
@testable import Calyx

// MARK: - Fakes

/// `HerdrTransportFactory` spy: each `makeTransport()` call hands out a
/// fresh `InMemoryHerdrTransport`, retaining it so tests can drive/
/// inspect it -- `transports.count` IS this spy's call count. Mirrors
/// `HerdrIntegrationCoordinatorTests`' own `SpyHerdrTransportFactory`
/// (a fresh, file-scoped `private` redeclaration here, not a shared
/// type -- `private` at file scope is not visible across files).
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

    /// Every line ever sent across every transport this factory has ever
    /// handed out, flattened in creation order -- lets a test prove "no
    /// request of a given shape was EVER sent," across the whole
    /// factory's lifetime, not merely "not on the one transport we
    /// happen to be looking at."
    func allSentLines() async -> [String] {
        var lines: [String] = []
        for transport in transports {
            lines += await transport.sentMessages()
        }
        return lines
    }
}

/// `HerdrNativeSurfaceFactory` fake: `results` is a queue consumed in
/// order, one entry per `createSurface(command:)` call -- lets a test
/// script exactly which pane's surface creation fails (e.g. "the SECOND
/// call returns nil"). Exhausting the queue (more calls than results
/// provided) returns nil, matching "a call this test never expected to
/// happen gets nothing useful back either."
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

/// `HerdrNativeTabAttacher` fake -- captures every call for later
/// inspection; `attachTabResult`/`focusExistingTabResult` let a test
/// script the two outcomes `openWorkspace` must react to (a rejected
/// attach; an already-open workspace).
@MainActor
private final class FakeHerdrNativeTabAttacher: HerdrNativeTabAttacher {
    private(set) var attachedPlans: [HerdrNativeTabPlan] = []
    private(set) var focusExistingTabCalls: [(workspaceID: String, socketPath: String)] = []
    private(set) var updateRatioCalls: [(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double)] = []
    private(set) var closeLeafCalls: [UUID] = []

    var attachTabResult = true
    var focusExistingTabResult = false

    func attachTab(plan: HerdrNativeTabPlan) -> Bool {
        attachedPlans.append(plan)
        return attachTabResult
    }

    func focusExistingTab(withWorkspaceID workspaceID: String, socketPath: String) -> Bool {
        focusExistingTabCalls.append((workspaceID: workspaceID, socketPath: socketPath))
        return focusExistingTabResult
    }

    func updateRatio(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double) {
        updateRatioCalls.append((leafA: leafA, leafB: leafB, direction: direction, ratio: ratio))
    }

    func closeLeaf(_ id: UUID) {
        closeLeafCalls.append(id)
    }
}

// File-scope, not instance properties: every `async let` below passes
// these as arguments to the child task's own initializer expression, and
// referencing an INSTANCE property there requires implicitly capturing
// `self` -- which Swift 6's region-based isolation checker flags
// ("sending 'self' risks causing data races"), since XCTestCase itself
// is not proven Sendable. A file-scope constant is neither a `self` nor
// a `Self.`-qualified member access, so it carries no such capture, and
// (unlike a `static let` on the class, which Swift requires an explicit
// `Self.` prefix to read from an instance method) needs no qualification
// at any call site either.
private let socketPath = "/tmp/herdr-tabcoordinator-test/herdr.sock"
private let herdrBinPath = "/opt/homebrew/bin/herdr"
/// Realistic, measured-shaped ("term_" + lowercase hex -- HerdrPaneRef
/// .isValidTerminalID's own header) terminal ids standing in for "wF:p1"/
/// "wF:p2"'s own session.snapshot-resolved terminal id, wherever a test
/// needs one -- see `driveOpenSequence`'s own `terminalIDByPaneID`
/// parameter below.
private let terminalIDP1 = "term_658cabe34ba1713"
private let terminalIDP2 = "term_9be2f0ac714dd6e"

// MARK: - HerdrTabCoordinatorTests

@MainActor
final class HerdrTabCoordinatorTests: XCTestCase {

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

    // MARK: - Coordinator construction helper

    private func makeCoordinator(
        factory: SpyHerdrTransportFactory,
        surfaceFactory: FakeHerdrNativeSurfaceFactory,
        attacher: FakeHerdrNativeTabAttacher,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> HerdrTabCoordinator {
        HerdrTabCoordinator(
            transportFactory: factory,
            herdrBinPath: herdrBinPath,
            registry: registry,
            surfaceFactory: surfaceFactory,
            attacher: attacher,
            sleep: sleep
        )
    }

    // MARK: - Wire drive helper: one layout.export request/response round trip

    /// REFRESH-PATH ONLY (see this file's header "OPEN DERIVATION CHOICE
    /// -- RESOLVED"): used exclusively by handleLayoutUpdated's own tests
    /// below, whose tab-id sourcing this pass deliberately leaves
    /// unpinned -- NOT used by any openWorkspace-triggering test, which
    /// use `driveOpenSequence` instead. Awaits transport `#index`,
    /// asserts its one and only request is a well-formed `layout.export`
    /// (method, and params carrying exactly one of "pane_id"/"tab_id" as
    /// a non-empty string scoped to `workspaceID`, prefix
    /// "<workspaceID>:" -- deliberately still just a prefix check here,
    /// since this method's own derivation is out of THIS pass's scope),
    /// then answers it with `responseRootJSON` as the layout's own
    /// "root". Returns the transport (already answered) for tests that
    /// need to inspect it further; `nil` (with an XCTFail already
    /// recorded) if the wire shape was not what was expected.
    @discardableResult
    private func driveLayoutExport(
        factory: SpyHerdrTransportFactory, index: Int, workspaceID: String, responseRootJSON: String, focusedPaneID: String
    ) async -> InMemoryHerdrTransport? {
        guard let transport = await awaitTransport(factory, at: index) else {
            XCTFail("expected transport #\(index) to have been created for the layout.export request")
            return nil
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard sent.count == 1, requestMethod(inLine: sent[0]) == "layout.export",
              let id = requestID(inLine: sent[0]) else {
            XCTFail("expected transport #\(index)'s only request to be layout.export; got \(sent)")
            return nil
        }
        guard let (key, value) = paneOrTabIDParam(inLine: sent[0]) else {
            XCTFail("expected params to contain a non-empty \"pane_id\" or \"tab_id\" string, got \(sent[0])")
            return nil
        }
        XCTAssertTrue(
            value.hasPrefix("\(workspaceID):"),
            "expected the layout.export params' \"\(key)\" value to be scoped to workspace " +
            "\(workspaceID.debugDescription) (prefix \((workspaceID + ":").debugDescription)), got \(value.debugDescription)"
        )
        await transport.simulateLine(layoutExportResponseLine(
            id: id, workspaceID: workspaceID, tabID: value, zoomed: false, focusedPaneID: focusedPaneID, root: responseRootJSON
        ))
        return transport
    }

    /// OPEN-PATH ONLY: drives the FULL corrected `openWorkspace` wire
    /// sequence -- see this file's header "OPEN DERIVATION CHOICE --
    /// RESOLVED". A one-shot `workspace.get` at transport `#baseIndex`
    /// (params EXACTLY `{"workspace_id": workspaceID}` -- WorkspaceTarget's
    /// own schema shape, `herdr api schema --json`'s own
    /// request.$defs.WorkspaceTarget: the ONLY required property),
    /// answered with a minimal, required-fields-only `workspace_info`
    /// result (WorkspaceInfo's own schema `required`: "workspace_id",
    /// "number", "label", "focused", "pane_count", "tab_count",
    /// "active_tab_id", "agent_status" -- "worktree"/"tokens" are
    /// optional and deliberately omitted) carrying `activeTabID` as
    /// "active_tab_id" -- THEN a one-shot `session.snapshot` at transport
    /// `#baseIndex + 1` (via `driveSessionSnapshot`, answered with a
    /// `panes[]` built from `terminalIDByPaneID`) -- THEN a one-shot
    /// `layout.export` at transport `#baseIndex + 2`, asserting its
    /// params carry "tab_id" (never "pane_id" -- a workspace's active tab
    /// is unambiguously a TAB, not a pane) EXACTLY `activeTabID`, never a
    /// "<workspaceID>:t1"-derived guess, then answered with
    /// `responseRootJSON` as the layout's own "root". Returns transport
    /// `#baseIndex + 2` (already answered) for tests that need to inspect
    /// it further; `nil` (with an XCTFail already recorded) if any of the
    /// three wire shapes was not what was expected -- in that case, the
    /// mismatched transport is ALSO failed via `simulateFailure` before
    /// returning, so `openWorkspace`'s own pending request unsticks
    /// (returns `false`) instead of hanging the calling test forever.
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
            // Unstick: whatever WAS sent still has `openWorkspace` awaiting
            // a response on this transport -- without this, the calling
            // test's own `await resultTask` would hang forever instead of
            // failing promptly.
            await workspaceGetTransport.simulateFailure("test: unexpected request shape")
            return nil
        }
        let workspaceGetParams = jsonObject(inLine: workspaceGetSent[0])?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            workspaceGetParams as NSDictionary, ["workspace_id": workspaceID] as NSDictionary,
            "workspace.get's params must carry EXACTLY {\"workspace_id\": ...} -- WorkspaceTarget's own schema " +
            "shape, no other key"
        )
        await workspaceGetTransport.simulateLine(
            workspaceGetResponseLine(id: workspaceGetID, workspaceID: workspaceID, activeTabID: activeTabID)
        )

        guard await driveSessionSnapshot(
            factory: factory, index: baseIndex + 1, terminalIDByPaneID: terminalIDByPaneID
        ) != nil else {
            return nil
        }

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
        guard let (key, value) = paneOrTabIDParam(inLine: layoutExportSent[0]) else {
            XCTFail("expected params to contain a non-empty \"pane_id\" or \"tab_id\" string, got \(layoutExportSent[0])")
            await layoutExportTransport.simulateFailure("test: unexpected request shape")
            return nil
        }
        XCTAssertEqual(
            key, "tab_id",
            "layout.export must scope by \"tab_id\" -- workspace.get's own active_tab_id names a TAB, never a pane"
        )
        XCTAssertEqual(
            value, activeTabID,
            "expected layout.export's \"tab_id\" to be EXACTLY the \"active_tab_id\" workspace.get returned " +
            "(\(activeTabID.debugDescription)), got \(value.debugDescription) -- the tab id must be READ from " +
            "workspace.get's response, never string-derived from the bare workspace id"
        )
        await layoutExportTransport.simulateLine(layoutExportResponseLine(
            id: layoutExportID, workspaceID: workspaceID, tabID: value, zoomed: false, focusedPaneID: focusedPaneID, root: responseRootJSON
        ))
        return layoutExportTransport
    }

    /// OPEN-PATH step 2 of 3, between `workspace.get` and `layout.export`
    /// -- see `driveOpenSequence`'s own doc comment above and this file's
    /// header "OPEN SEQUENCE". Awaits transport `#index`, asserts its one
    /// and only request is `session.snapshot`, then answers it with a
    /// minimal, required-fields-only snapshot (PaneInfo's own schema
    /// `required`: "pane_id", "terminal_id", "workspace_id", "tab_id",
    /// "focused", "agent_status", "revision" -- `herdr api schema --json`)
    /// whose `panes[]` carries exactly one entry per `terminalIDByPaneID`
    /// key, each entry's own "terminal_id" being that key's mapped value
    /// -- see `sessionSnapshotResponseLine`. Returns the transport
    /// (already answered) for tests that need to inspect it further;
    /// `nil` (with an XCTFail already recorded, and the transport already
    /// failed via `simulateFailure` to unstick the caller) if the wire
    /// shape was not what was expected.
    @discardableResult
    private func driveSessionSnapshot(
        factory: SpyHerdrTransportFactory, index: Int, terminalIDByPaneID: [String: String]
    ) async -> InMemoryHerdrTransport? {
        guard let transport = await awaitTransport(factory, at: index) else {
            XCTFail("expected transport #\(index) to have been created for the session.snapshot request")
            return nil
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard sent.count == 1, requestMethod(inLine: sent[0]) == "session.snapshot",
              let id = requestID(inLine: sent[0]) else {
            XCTFail("expected transport #\(index)'s only request to be session.snapshot; got \(sent)")
            await transport.simulateFailure("test: unexpected request shape")
            return nil
        }
        await transport.simulateLine(sessionSnapshotResponseLine(id: id, terminalIDByPaneID: terminalIDByPaneID))
        return transport
    }

    /// Opens a baseline 2-pane, herdr "right" (Calyx .horizontal), ratio
    /// 0.3 split workspace on transports #0 (workspace.get), #1
    /// (session.snapshot), and #2 (layout.export) -- shared setup for the
    /// layout-refresh tests below, which need two already-tracked leaves
    /// to compare ratios between. Active tab id "wF:t1" -- an ordinary,
    /// "<workspaceID>:t1"-shaped value is fine here: this helper's own
    /// job is setting up ratio-sync fixtures, not exercising the
    /// string-derivation kill test (see `driveOpenSequence`'s own doc
    /// comment, and this file's header, for the ONE test that
    /// deliberately uses a non-"<workspaceID>:t1" value for that
    /// purpose).
    @discardableResult
    private func openBaselineSplitWorkspace(factory: SpyHerdrTransportFactory, coordinator: HerdrTabCoordinator) async -> Bool {
        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1, "wF:p2": terminalIDP2],
            responseRootJSON: splitNodeJSON(
                direction: "right", ratio: 0.3,
                first: paneNodeJSON(paneID: "wF:p1"), second: paneNodeJSON(paneID: "wF:p2")
            ),
            focusedPaneID: "wF:p1"
        )
        return await resultTask
    }

    // MARK: - 1. Happy path, single pane

    func test_openWorkspace_singlePane_createsOneSurfaceWithExactBridgeCommand_registersAndAttachesLeafPlan() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        let result = await resultTask

        XCTAssertTrue(result, "expected openWorkspace to succeed for a well-formed single-pane layout")

        guard let expectedCommand = HerdrAttachBridgeCommand.build(herdrBin: herdrBinPath, socketPath: socketPath, terminalID: terminalIDP1) else {
            XCTFail("expected a valid bridge command for \(terminalIDP1)")
            return
        }
        XCTAssertEqual(surfaceFactory.createCommands, [expectedCommand], "the created surface's command must be EXACTLY HerdrAttachBridgeCommand's own output, built from the session.snapshot-resolved terminal id")

        XCTAssertEqual(registry.paneRef(forSurfaceID: fakeSurfaceID), HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1"))
        XCTAssertEqual(registry.surfaceID(forPaneID: "wF:p1", socketPath: socketPath), fakeSurfaceID)

        guard let plan = attacher.attachedPlans.first, attacher.attachedPlans.count == 1 else {
            XCTFail("expected exactly one attachTab call, got \(attacher.attachedPlans.count)")
            return
        }
        XCTAssertEqual(plan.root, .leaf(id: fakeSurfaceID), "a single-pane layout's plan root must be a leaf naming the REAL created surface id")
        XCTAssertEqual(plan.focusedLeafID, fakeSurfaceID)
        XCTAssertEqual(plan.paneRefs, [fakeSurfaceID: HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1")])
        XCTAssertEqual(
            plan.title, "demo",
            "the plan's title must be workspace.get's own \"label\" (this fixture's \"demo\"), not the bare " +
            "workspace id -- HerdrTabTitlePolicy.title prefers a present, non-blank label"
        )

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 3,
            "a single-pane open must use exactly three transports (workspace.get, session.snapshot, then layout.export)"
        )
        XCTAssertEqual(surfaceFactory.destroyedIDs, [], "a fully successful open must never roll back")
    }

    // MARK: - 2. Happy path, split layout

    func test_openWorkspace_splitLayout_createsTwoSurfacesInWireOrder_buildsHorizontalSplitPlan_resolvesFocusedLeafFromWire() async {
        let factory = SpyHerdrTransportFactory()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [firstSurfaceID, secondSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1, "wF:p2": terminalIDP2],
            responseRootJSON: splitNodeJSON(
                direction: "right", ratio: 0.3,
                first: paneNodeJSON(paneID: "wF:p1"), second: paneNodeJSON(paneID: "wF:p2")
            ),
            // Deliberately the SECOND pane -- catches an implementation
            // that defaults focusedLeafID to the root's first leaf
            // regardless of the wire's own focused_pane_id.
            focusedPaneID: "wF:p2"
        )
        let result = await resultTask

        XCTAssertTrue(result)

        guard let firstCommand = HerdrAttachBridgeCommand.build(herdrBin: herdrBinPath, socketPath: socketPath, terminalID: terminalIDP1),
              let secondCommand = HerdrAttachBridgeCommand.build(herdrBin: herdrBinPath, socketPath: socketPath, terminalID: terminalIDP2) else {
            XCTFail("expected valid bridge commands for both panes")
            return
        }
        XCTAssertEqual(
            surfaceFactory.createCommands, [firstCommand, secondCommand],
            "surfaces must be created in wire order: the split's FIRST child before its SECOND"
        )

        XCTAssertEqual(registry.paneRef(forSurfaceID: firstSurfaceID), HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1"))
        XCTAssertEqual(registry.paneRef(forSurfaceID: secondSurfaceID), HerdrPaneRef(socketPath: socketPath, paneID: "wF:p2"))

        guard let plan = attacher.attachedPlans.first, attacher.attachedPlans.count == 1 else {
            XCTFail("expected exactly one attachTab call, got \(attacher.attachedPlans.count)")
            return
        }
        guard case .split(let splitData) = plan.root else {
            XCTFail("expected plan.root to be a .split node, got \(plan.root)")
            return
        }
        XCTAssertEqual(splitData.direction, .horizontal, "herdr's \"right\" split direction must map to Calyx's .horizontal")
        XCTAssertEqual(splitData.ratio, 0.3, accuracy: 0.0001)
        XCTAssertEqual(splitData.first, .leaf(id: firstSurfaceID))
        XCTAssertEqual(splitData.second, .leaf(id: secondSurfaceID))
        XCTAssertEqual(
            plan.focusedLeafID, secondSurfaceID,
            "focusedLeafID must resolve from the wire's own focused_pane_id (wF:p2), not default to the first leaf"
        )
        XCTAssertEqual(plan.paneRefs, [
            firstSurfaceID: HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1"),
            secondSurfaceID: HerdrPaneRef(socketPath: socketPath, paneID: "wF:p2"),
        ])

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 3,
            "a split open must still use exactly three transports (workspace.get, session.snapshot, then a single layout.export)"
        )
    }

    // MARK: - 2b. active_tab_id read from workspace.get, never string-derived

    /// THE test that kills the "<workspaceID>:t1" string-derivation --
    /// see this file's header "OPEN DERIVATION CHOICE -- RESOLVED".
    /// `activeTabID` is deliberately "wF:t3", NOT "wF:t1": a
    /// string-derivation would send "wF:t1" regardless of what
    /// workspace.get actually returned; only reading `active_tab_id` FROM
    /// THE RESPONSE sends "wF:t3" here. `driveOpenSequence`'s own exact-
    /// match assertion (asserting layout.export's "tab_id" equals
    /// `activeTabID`) is what actually fails when this is violated.
    func test_openWorkspace_activeTabIDFromWorkspaceGet_notDerivedFromWorkspaceIDString_usedExactlyForLayoutExport() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t3",
            terminalIDByPaneID: ["wF:p1": terminalIDP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        let result = await resultTask

        XCTAssertTrue(
            result, "expected openWorkspace to succeed given a well-formed workspace.get + session.snapshot + " +
            "layout.export trio, even though the active_tab_id (\"wF:t3\") does not match the " +
            "\"<workspaceID>:t1\" shape a string-derivation would have produced"
        )
        XCTAssertEqual(
            registry.paneRef(forSurfaceID: fakeSurfaceID), HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1"),
            "the open must still succeed end-to-end -- registration is unaffected by which tab id layout.export used"
        )
    }

    // MARK: - 3. All-or-nothing rollback

    func test_openWorkspace_secondSurfaceCreationFails_rollsBackFirstSurface_registersNothing_neverAttaches_returnsFalse() async {
        let factory = SpyHerdrTransportFactory()
        let firstSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [firstSurfaceID, nil])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1, "wF:p2": terminalIDP2],
            responseRootJSON: splitNodeJSON(
                direction: "right", ratio: 0.5,
                first: paneNodeJSON(paneID: "wF:p1"), second: paneNodeJSON(paneID: "wF:p2")
            ),
            focusedPaneID: "wF:p1"
        )
        let result = await resultTask

        XCTAssertFalse(result, "expected openWorkspace to fail when any surface creation fails")

        guard let firstCommand = HerdrAttachBridgeCommand.build(herdrBin: herdrBinPath, socketPath: socketPath, terminalID: terminalIDP1),
              let secondCommand = HerdrAttachBridgeCommand.build(herdrBin: herdrBinPath, socketPath: socketPath, terminalID: terminalIDP2) else {
            XCTFail("expected valid bridge commands for both panes")
            return
        }
        XCTAssertEqual(
            surfaceFactory.createCommands, [firstCommand, secondCommand],
            "must attempt creation for both panes, in wire order, before giving up"
        )
        XCTAssertEqual(
            surfaceFactory.destroyedIDs, [firstSurfaceID],
            "the FIRST (already-created) surface must be rolled back when the SECOND creation fails"
        )

        XCTAssertFalse(registry.isBridgeSurface(firstSurfaceID), "nothing may remain registered after a rolled-back open")
        XCTAssertNil(registry.surfaceID(forPaneID: "wF:p1", socketPath: socketPath))
        XCTAssertNil(registry.surfaceID(forPaneID: "wF:p2", socketPath: socketPath))

        XCTAssertEqual(attacher.attachedPlans.count, 0, "attachTab must never be called when the open fails")
    }

    // MARK: - 4. Invalid pane id in export

    func test_openWorkspace_invalidWirePaneID_createsNoSurfacesAtAll_returnsFalse() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        let hostilePaneID = "wF:p1; rm"
        XCTAssertFalse(HerdrPaneRef.isValidPaneID(hostilePaneID), "Precondition: this fixture's pane id must actually be invalid")

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            // The hostile id IS present in session.snapshot's own
            // terminal-id map, with a valid terminal id -- isolates this
            // test to the isValidPaneID gate alone, so it stays
            // orthogonal to
            // test_openWorkspace_wirePaneIDAbsentFromSessionSnapshot_createsNoSurfacesAtAll_returnsFalse
            // below, which pins the SEPARATE "absent from the map" gate.
            terminalIDByPaneID: [hostilePaneID: terminalIDP1],
            responseRootJSON: paneNodeJSON(paneID: hostilePaneID), focusedPaneID: hostilePaneID
        )
        let result = await resultTask

        XCTAssertFalse(result, "expected openWorkspace to fail when the wire reveals an invalid pane id")
        XCTAssertEqual(
            surfaceFactory.createCommands, [],
            "a nil bridge command (invalid pane id) must be treated as TOTAL failure BEFORE creating any " +
            "surface -- never discovered only after createSurface is already called"
        )
        XCTAssertEqual(attacher.attachedPlans.count, 0)
    }

    // MARK: - 4b. Pane present in the layout, absent from session.snapshot's terminal-id map

    /// A wire pane id that is perfectly VALID (`HerdrPaneRef.isValidPaneID`
    /// accepts it) but has NO entry in session.snapshot's own
    /// paneID -> terminalID map -- e.g. the snapshot is stale relative to
    /// the layout it is paired with. `terminalIDByPaneID` below is
    /// deliberately NON-EMPTY (it carries an entry for a DIFFERENT pane,
    /// "wF:p9") so this test cannot be satisfied by an implementation
    /// that merely checks "is the map empty" -- only a genuine per-pane
    /// lookup miss reaches this outcome, orthogonal to the invalid-id
    /// test above (which keeps the map non-empty for its OWN pane, so
    /// only the isValidPaneID gate can fire there).
    func test_openWorkspace_wirePaneIDAbsentFromSessionSnapshot_createsNoSurfacesAtAll_returnsFalse() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p9": terminalIDP2],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        let result = await resultTask

        XCTAssertFalse(
            result, "expected openWorkspace to fail when a layout pane's id has no entry in session.snapshot's " +
            "own terminal-id map"
        )
        XCTAssertEqual(
            surfaceFactory.createCommands, [],
            "a paneID absent from session.snapshot's terminal-id map must be treated as TOTAL failure BEFORE " +
            "creating any surface -- identically to an invalid wire pane id"
        )
        XCTAssertEqual(attacher.attachedPlans.count, 0, "attachTab must never be called when the open fails")
        XCTAssertNil(
            registry.surfaceID(forPaneID: "wF:p1", socketPath: socketPath),
            "nothing may be registered for a pane whose terminal id could never be resolved"
        )

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 3,
            "the failure is discovered only AFTER all three wire requests succeed (workspace.get, " +
            "session.snapshot, layout.export) -- the local Phase 1 lookup runs after the full round trip, not " +
            "in place of it"
        )
    }

    // MARK: - 5. Duplicate open

    func test_openWorkspace_alreadyAttachedWorkspace_focusesExistingTab_touchesNoTransport_createsNoSurfaces() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        attacher.focusExistingTabResult = true
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        let result = await coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)

        XCTAssertTrue(result, "focusing an already-open workspace's tab counts as a successful open")
        XCTAssertEqual(attacher.focusExistingTabCalls.count, 1)
        XCTAssertEqual(attacher.focusExistingTabCalls.first?.workspaceID, "wF")
        XCTAssertEqual(attacher.focusExistingTabCalls.first?.socketPath, socketPath)

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 0, "a duplicate open must touch the transport factory zero times")
        XCTAssertEqual(surfaceFactory.createCommands, [], "a duplicate open must never create a surface")
        XCTAssertEqual(attacher.attachedPlans.count, 0, "a duplicate open must never call attachTab -- focusExistingTab already handled it")
    }

    // MARK: - 6a. Layout event, idempotent apply

    func test_handleLayoutUpdated_identicalTreeAndRatio_neverCallsUpdateRatio() async {
        let factory = SpyHerdrTransportFactory()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [firstSurfaceID, secondSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        // A guard, not a bare assertion: if the precondition open itself
        // failed (e.g. red-phase, before openWorkspace's own workspace.get
        // support exists), the open would have consumed a DIFFERENT
        // number of transports than this test's own refresh-driving call
        // below assumes -- proceeding anyway would drive
        // `driveLayoutExport` against the WRONG transport index, leaving
        // the REAL one it never touches awaiting a response forever.
        // Equivalent assertion, plus an early exit -- not a weakening.
        guard await openBaselineSplitWorkspace(factory: factory, coordinator: coordinator) else {
            XCTFail("Precondition: openBaselineSplitWorkspace must succeed")
            return
        }

        async let refreshTask: Bool = coordinator.handleLayoutUpdated(workspaceID: "wF", socketPath: socketPath)
        await driveLayoutExport(
            factory: factory, index: 3, workspaceID: "wF",
            responseRootJSON: splitNodeJSON(
                direction: "right", ratio: 0.3, // identical to the baseline
                first: paneNodeJSON(paneID: "wF:p1"), second: paneNodeJSON(paneID: "wF:p2")
            ),
            focusedPaneID: "wF:p1"
        )
        _ = await refreshTask

        XCTAssertEqual(
            attacher.updateRatioCalls.count, 0,
            "an identical re-export (same tree, same ratio) must never call the ratio-mutation seam"
        )
        XCTAssertEqual(attacher.attachedPlans.count, 1, "a no-op refresh must not re-attach the tab either")
        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 4,
            "the refresh performs its own one-shot layout.export, on top of the original open's own " +
            "workspace.get + session.snapshot + layout.export trio"
        )
    }

    // MARK: - 6b. Layout event, ratio-only change

    func test_handleLayoutUpdated_ratioChangedOnly_callsUpdateRatioExactlyOnce_withMappedLeafUUIDs() async {
        let factory = SpyHerdrTransportFactory()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [firstSurfaceID, secondSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        // See the sibling "identical tree" test above for why this is a
        // guard (early exit), not a bare assertion.
        guard await openBaselineSplitWorkspace(factory: factory, coordinator: coordinator) else {
            XCTFail("Precondition: openBaselineSplitWorkspace must succeed")
            return
        }

        async let refreshTask: Bool = coordinator.handleLayoutUpdated(workspaceID: "wF", socketPath: socketPath)
        await driveLayoutExport(
            factory: factory, index: 3, workspaceID: "wF",
            responseRootJSON: splitNodeJSON(
                direction: "right", ratio: 0.6, // CHANGED from the baseline's 0.3
                first: paneNodeJSON(paneID: "wF:p1"), second: paneNodeJSON(paneID: "wF:p2")
            ),
            focusedPaneID: "wF:p1"
        )
        _ = await refreshTask

        XCTAssertEqual(attacher.updateRatioCalls.count, 1, "a ratio-only change must call the mutation seam exactly once")
        guard let call = attacher.updateRatioCalls.first else { return }
        XCTAssertEqual(call.leafA, firstSurfaceID, "leafA must resolve to wF:p1's REAL, already-tracked surface id, not a fresh import-time UUID")
        XCTAssertEqual(call.leafB, secondSurfaceID, "leafB must resolve to wF:p2's REAL, already-tracked surface id")
        XCTAssertEqual(call.direction, .horizontal)
        XCTAssertEqual(call.ratio, 0.6, accuracy: 0.0001)
    }

    // MARK: - 7. pane.closed from herdr

    func test_handlePaneClosed_asksAttacherToCloseLeaf_prunesRegistryBothDirections_neverSendsAnyRequestToHerdr() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let openTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        let opened = await openTask
        XCTAssertTrue(opened, "Precondition")
        let baselineSentLines = await factory.allSentLines()

        await coordinator.handlePaneClosed(paneID: "wF:p1", socketPath: socketPath)

        XCTAssertEqual(
            attacher.closeLeafCalls, [fakeSurfaceID],
            "the attacher must be asked to close exactly the tracked leaf for the closed pane"
        )

        XCTAssertFalse(registry.isBridgeSurface(fakeSurfaceID), "the forward surfaceID -> ref mapping must be pruned")
        XCTAssertNil(registry.paneRef(forSurfaceID: fakeSurfaceID))
        XCTAssertNil(
            registry.surfaceID(forPaneID: "wF:p1", socketPath: socketPath),
            "the reverse (socketPath, paneID) -> surfaceID mapping must ALSO be pruned"
        )

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 3, "handling a herdr-initiated pane close must never open a new transport")
        let sentLinesAfter = await factory.allSentLines()
        XCTAssertEqual(
            sentLinesAfter, baselineSentLines,
            "the herdr-side pane must NEVER be sent any kill/close request -- every transport's own sent lines " +
            "must be byte-for-byte unchanged from before handlePaneClosed was called"
        )
    }

    // MARK: - 8. Calyx-side surface destroyed

    func test_calyxSurfaceDestroyedNotification_prunesRegistry_neverCallsCloseLeaf_sendsNoHerdrRequest() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let openTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        let opened = await openTask
        XCTAssertTrue(opened, "Precondition")
        XCTAssertTrue(registry.isBridgeSurface(fakeSurfaceID), "Precondition: the open must have registered the surface")
        let baselineSentLines = await factory.allSentLines()

        // Deliberately does NOT call registry.startObserving() itself --
        // wiring that up is the coordinator's own responsibility (via
        // init or openWorkspace), exactly what this test exists to pin.
        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": fakeSurfaceID])

        XCTAssertFalse(
            registry.isBridgeSurface(fakeSurfaceID),
            "a locally-destroyed surface must be pruned from the registry -- requires the coordinator to have " +
            "already enabled HerdrPaneRegistry's own .calyxSurfaceDestroyed observation"
        )
        XCTAssertEqual(
            attacher.closeLeafCalls, [],
            "a Calyx-initiated close must never re-invoke closeLeaf -- the pane is already gone locally"
        )

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 3, "a locally-destroyed surface must never open a new transport to tell herdr")
        let sentLinesAfter = await factory.allSentLines()
        XCTAssertEqual(
            sentLinesAfter, baselineSentLines,
            "the herdr-side pane survives a local close -- no request line may ever be sent for it"
        )
    }

    // MARK: - 9. Server dead at open (workspace.get's own transport fails)

    /// Transport #0 is now workspace.get's own transport (see this file's
    /// header "OPEN DERIVATION CHOICE -- RESOLVED") -- this is also the
    /// NEW required coverage "workspace.get fails -> openWorkspace
    /// returns false, zero surfaces (same failure discipline as export
    /// failure)". The explicit method assertion below is what makes this
    /// test actually discriminate against the OLD implementation (which
    /// sends layout.export directly on transport #0, with no workspace.get
    /// at all) -- without it, this test would pass unchanged either way,
    /// since it never inspected WHICH request failed, only THAT one did.
    func test_openWorkspace_workspaceGetTransportFailsBeforeAnswering_returnsFalse_createsNoSurfaces_neverAttaches() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)

        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected a transport to be created for the workspace.get attempt")
            return
        }
        let sent = await awaitSentMessages(transport, atLeast: 1) // the request is confirmed in flight
        if sent.count == 1 {
            XCTAssertEqual(
                requestMethod(inLine: sent[0]), "workspace.get",
                "expected openWorkspace's FIRST wire request to be workspace.get -- the active tab id must be " +
                "resolved via workspace.get, never string-derived from the bare workspace id -- got \(sent[0])"
            )
        } else {
            XCTFail("expected exactly one request line in flight on transport #0, got \(sent)")
        }
        await transport.simulateFailure("boom")

        let result = await resultTask
        XCTAssertFalse(result, "expected openWorkspace to fail when workspace.get's own transport fails before answering")

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 1,
            "Precondition: exactly one transport must have been attempted (workspace.get; layout.export must " +
            "never even be attempted when workspace.get itself never succeeds)"
        )
        XCTAssertEqual(surfaceFactory.createCommands, [], "no surface may be created when workspace.get itself never succeeds")
        XCTAssertEqual(attacher.attachedPlans.count, 0, "attachTab must never be called when the open fails")
    }

    // MARK: - 9b. workspace.get answers with an RPC error

    /// Companion to test 9 above -- "fails/errors" names TWO distinct
    /// failure modes (this file's own task brief): a raw transport
    /// failure (test 9), and an RPC-level `{"error":...}` response (this
    /// test). `HerdrOneShotRequest.send` documents throwing
    /// `HerdrConnectionError.rpc` for the latter (HerdrConnection.swift),
    /// which `openWorkspace`'s own `catch { return false }` must treat
    /// identically to any other `fetchLayout` failure.
    func test_openWorkspace_workspaceGetReturnsRPCError_returnsFalse_createsNoSurfaces_neverAttaches() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)

        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected a transport to be created for the workspace.get attempt")
            return
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard sent.count == 1, let id = requestID(inLine: sent[0]) else {
            XCTFail("expected exactly one request line carrying a request id, got \(sent)")
            await transport.simulateFailure("test: malformed request") // unstick regardless
            _ = await resultTask
            return
        }
        XCTAssertEqual(
            requestMethod(inLine: sent[0]), "workspace.get",
            "expected openWorkspace's FIRST wire request to be workspace.get -- got \(sent[0])"
        )
        await transport.simulateLine(errorResponseLine(id: id, code: "workspace_not_found", message: "workspace wF not found"))

        let result = await resultTask
        XCTAssertFalse(result, "expected openWorkspace to fail when workspace.get itself answers with an RPC error")

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 1,
            "Precondition: exactly one transport must have been attempted (workspace.get; layout.export must " +
            "never even be attempted when workspace.get itself never succeeds)"
        )
        XCTAssertEqual(surfaceFactory.createCommands, [], "no surface may be created when workspace.get itself never succeeds")
        XCTAssertEqual(attacher.attachedPlans.count, 0, "attachTab must never be called when the open fails")
    }

    // MARK: - 9c. layout.export's own transport fails, AFTER a successful workspace.get and session.snapshot

    /// The scenario test 9 covered before workspace.get existed --
    /// preserved here under its own name now that transport #0 belongs to
    /// workspace.get and transport #1 belongs to session.snapshot: both
    /// succeed, but layout.export's OWN, SEPARATE transport (#2) then
    /// fails before it ever answers. Same failure discipline as
    /// test 9/9b.
    func test_openWorkspace_layoutExportTransportFailsBeforeAnswering_afterSuccessfulWorkspaceGet_returnsFalse_createsNoSurfaces_neverAttaches() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let resultTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)

        guard let workspaceGetTransport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected a transport to be created for the workspace.get attempt")
            return
        }
        let workspaceGetSent = await awaitSentMessages(workspaceGetTransport, atLeast: 1)
        guard workspaceGetSent.count == 1, requestMethod(inLine: workspaceGetSent[0]) == "workspace.get",
              let workspaceGetID = requestID(inLine: workspaceGetSent[0]) else {
            XCTFail("expected transport #0's only request to be workspace.get; got \(workspaceGetSent)")
            await workspaceGetTransport.simulateFailure("test: unexpected request shape") // unstick regardless
            _ = await resultTask
            return
        }
        await workspaceGetTransport.simulateLine(
            workspaceGetResponseLine(id: workspaceGetID, workspaceID: "wF", activeTabID: "wF:t1")
        )

        // session.snapshot must ALSO succeed here -- this test isolates
        // layout.export's own transport failure, not session.snapshot's.
        guard await driveSessionSnapshot(factory: factory, index: 1, terminalIDByPaneID: [:]) != nil else {
            XCTFail("expected session.snapshot to be served successfully before layout.export is even attempted")
            _ = await resultTask
            return
        }

        guard let layoutExportTransport = await awaitTransport(factory, at: 2) else {
            XCTFail("expected a THIRD, separate transport to be created for the layout.export attempt")
            return
        }
        let layoutExportSent = await awaitSentMessages(layoutExportTransport, atLeast: 1) // confirmed in flight
        if layoutExportSent.count == 1 {
            XCTAssertEqual(requestMethod(inLine: layoutExportSent[0]), "layout.export")
        } else {
            XCTFail("expected exactly one request line in flight on transport #2, got \(layoutExportSent)")
        }
        await layoutExportTransport.simulateFailure("boom")

        let result = await resultTask
        XCTAssertFalse(result, "expected openWorkspace to fail when layout.export's own transport fails before answering")

        let callCount = await factory.callCount
        XCTAssertEqual(
            callCount, 3,
            "Precondition: exactly three transports must have been attempted (workspace.get and session.snapshot " +
            "succeeded, layout.export failed)"
        )
        XCTAssertEqual(surfaceFactory.createCommands, [], "no surface may be created when the export itself never succeeds")
        XCTAssertEqual(attacher.attachedPlans.count, 0, "attachTab must never be called when the open fails")
    }

    // MARK: - 10. Concurrent double-open

    /// Pins the in-flight-opens guard: a SECOND concurrent
    /// `openWorkspace` call for the SAME (workspaceID, socketPath),
    /// started while the FIRST is still mid-flight (its own
    /// workspace.get already sent, not yet answered -- the exact window
    /// a double-clicked "Attach" button opens, since `focusExistingTab`
    /// cannot see anything attached until the whole open sequence
    /// completes), must return `false` IMMEDIATELY, touching the
    /// transport factory, the surface factory, and the attacher not at
    /// all -- "the loser touches nothing". Without the guard, both calls
    /// would run the full open independently, producing TWO surfaces
    /// registered for the same herdr pane (see this file's own header
    /// for what `HerdrPaneRegistry`'s single-controller invariant does
    /// to the first one once that happens). Waits for the first call's
    /// own transport to exist (rather than racing two `async let`s
    /// blindly) so the guard is proven against a call GENUINELY still
    /// in flight, not merely scheduled.
    func test_openWorkspace_secondConcurrentCallForSameWorkspace_returnsFalseImmediately_touchesNothing_firstStillSucceeds() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let firstResult: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)

        guard await awaitTransport(factory, at: 0) != nil else {
            XCTFail("expected the first call's own workspace.get transport to have been created")
            return
        }

        let second = await coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        XCTAssertFalse(
            second, "a second concurrent openWorkspace call for the SAME (workspaceID, socketPath), started " +
            "while the first is still mid-flight, must return false immediately"
        )
        XCTAssertEqual(surfaceFactory.createCommands, [], "the loser must create zero surfaces")
        XCTAssertEqual(attacher.attachedPlans.count, 0, "the loser must never call attachTab")
        let callCountAfterLoser = await factory.callCount
        XCTAssertEqual(
            callCountAfterLoser, 1, "the loser must touch the transport factory zero times -- still only the " +
            "winner's own workspace.get transport"
        )

        // Let the WINNER's own open sequence complete normally.
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        let first = await firstResult

        XCTAssertTrue(first, "the winning (first) call must still succeed normally once its own open sequence completes")
        XCTAssertEqual(surfaceFactory.createCommands.count, 1, "exactly one surface total, created by the winner")
        XCTAssertEqual(attacher.attachedPlans.count, 1, "exactly one attachTab call total, from the winner")
        let finalCallCount = await factory.callCount
        XCTAssertEqual(
            finalCallCount, 3,
            "exactly one open sequence's worth of transports (workspace.get, session.snapshot, layout.export) " +
            "for the whole race -- the loser added none"
        )
    }

    // MARK: - 11. handlePaneClosed prunes activeTabIDs/lastAppliedLayouts on last pane

    /// Pins the pruning behavior: once `handlePaneClosed` closes a
    /// workspace's LAST tracked pane, `activeTabIDs` (and, transitively,
    /// `lastAppliedLayouts`) for that (workspaceID, socketPath) must be
    /// pruned -- observed indirectly via `handleLayoutUpdated`'s own
    /// documented contract ("Returns `false` (touching no transport at
    /// all) when this workspace has no stored active_tab_id -- i.e. it
    /// was never successfully opened on this socket"): a SUBSEQUENT
    /// `handleLayoutUpdated` call for the SAME workspace must now return
    /// `false` and touch the transport factory zero additional times,
    /// proving the stale entry is gone rather than still triggering a
    /// wasted `layout.export` round trip for a Calyx tab that no longer
    /// exists (this file's own header, "PRUNING ON LAST PANE CLOSE").
    func test_handlePaneClosed_closesWorkspacesLastPane_prunesActiveTabIDs_subsequentHandleLayoutUpdatedReturnsFalseWithNoNewTransport() async {
        let factory = SpyHerdrTransportFactory()
        let fakeSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [fakeSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        async let openTask: Bool = coordinator.openWorkspace(workspaceID: "wF", socketPath: socketPath)
        await driveOpenSequence(
            factory: factory, baseIndex: 0, workspaceID: "wF", activeTabID: "wF:t1",
            terminalIDByPaneID: ["wF:p1": terminalIDP1],
            responseRootJSON: paneNodeJSON(paneID: "wF:p1"), focusedPaneID: "wF:p1"
        )
        let opened = await openTask
        XCTAssertTrue(opened, "Precondition")
        let callCountAfterOpen = await factory.callCount
        XCTAssertEqual(callCountAfterOpen, 3, "Precondition: the open used exactly three transports")

        // The only pane closes -- this workspace's LAST tracked leaf.
        await coordinator.handlePaneClosed(paneID: "wF:p1", socketPath: socketPath)

        let refreshed = await coordinator.handleLayoutUpdated(workspaceID: "wF", socketPath: socketPath)
        XCTAssertFalse(
            refreshed, "a workspace with no stored active_tab_id must return false -- handlePaneClosed's own " +
            "pruning must have removed it once its last pane closed"
        )
        let callCountAfterRefreshAttempt = await factory.callCount
        XCTAssertEqual(
            callCountAfterRefreshAttempt, callCountAfterOpen,
            "a pruned workspace's handleLayoutUpdated must touch the transport factory zero additional times " +
            "-- no wasted layout.export round trip for a Calyx tab that no longer exists"
        )
    }

    // MARK: - 12. Workspace record decode: label required and non-nullable

    /// Pins `HerdrWorkspaceInfo`'s own decode against a payload carrying
    /// EXACTLY WorkspaceInfo's own schema `required` fields (`herdr api
    /// schema --json`'s own success_response.$defs.WorkspaceInfo:
    /// "workspace_id", "number", "label", "focused", "pane_count",
    /// "tab_count", "active_tab_id", "agent_status") -- "worktree"/
    /// "tokens" are optional and deliberately omitted. "label" decodes as
    /// a non-optional `String`: the schema marks it both required and
    /// non-nullable (`{"type":"string"}`, no `null` alternative), unlike
    /// "worktree" (`anyOf` with `{"type":"null"}`). "workspace_id" and
    /// "pane_count" are the two fields `HerdrSessionProvider.swift` reads
    /// from this SAME type for the session browser's per-workspace rows.
    func test_workspaceInfoDecode_minimalRequiredFieldsOnlyPayload_decodesEveryModeledField() throws {
        let json = "{\"workspace_id\":\"wJ\",\"number\":1,\"label\":\"Calyx\",\"focused\":true," +
        "\"pane_count\":1,\"tab_count\":1,\"active_tab_id\":\"wJ:t1\",\"agent_status\":\"idle\"}"

        let decoded = try JSONDecoder().decode(HerdrWorkspaceInfo.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.workspaceID, "wJ")
        XCTAssertEqual(decoded.activeTabID, "wJ:t1")
        XCTAssertEqual(decoded.label, "Calyx")
        XCTAssertEqual(decoded.paneCount, 1)
    }

    // MARK: - 13. Workspace killed from the Session Browser closes every registered leaf

    /// Pins `handleWorkspaceKilled(workspaceID:socketPath:)`: opens a
    /// baseline two-pane workspace (the same fixture the layout-refresh
    /// tests above share), kills it, and checks every angle this file's
    /// own task brief calls out -- both leaves closed through the
    /// attacher, the registry pruned in both directions for both panes,
    /// the coordinator's own `activeTabIDs`/`lastAppliedLayouts` bookkeeping
    /// pruned exactly like `handlePaneClosed` already leaves it (observed
    /// via `handleLayoutUpdated`'s own documented contract, mirroring
    /// test 11's technique above), and -- the CRITICAL constraint --
    /// zero bytes ever sent to herdr for this call, since the workspace
    /// is already gone server-side by the time it runs.
    func test_handleWorkspaceKilled_closesEveryRegisteredLeaf_prunesRegistryAndBookkeeping_sendsNoHerdrRequest() async {
        let factory = SpyHerdrTransportFactory()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [firstSurfaceID, secondSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        guard await openBaselineSplitWorkspace(factory: factory, coordinator: coordinator) else {
            XCTFail("Precondition: openBaselineSplitWorkspace must succeed")
            return
        }
        let baselineSentLines = await factory.allSentLines()

        coordinator.handleWorkspaceKilled(workspaceID: "wF", socketPath: socketPath)

        // remainingPaneIDs is a Set, so closeLeafCalls' own order across
        // the two panes is not guaranteed -- compare as a Set, and pin
        // the count separately, so a duplicate close (which a Set
        // equality check alone would hide) still fails this assertion.
        XCTAssertEqual(
            Set(attacher.closeLeafCalls), Set([firstSurfaceID, secondSurfaceID]),
            "every leaf still registered for the killed workspace must be closed through the attacher"
        )
        XCTAssertEqual(attacher.closeLeafCalls.count, 2, "each registered leaf must be closed exactly once")

        XCTAssertFalse(registry.isBridgeSurface(firstSurfaceID), "the forward surfaceID -> ref mapping must be pruned for every closed leaf")
        XCTAssertFalse(registry.isBridgeSurface(secondSurfaceID))
        XCTAssertNil(registry.surfaceID(forPaneID: "wF:p1", socketPath: socketPath), "the reverse mapping must ALSO be pruned for every closed leaf")
        XCTAssertNil(registry.surfaceID(forPaneID: "wF:p2", socketPath: socketPath))

        let refreshed = await coordinator.handleLayoutUpdated(workspaceID: "wF", socketPath: socketPath)
        XCTAssertFalse(
            refreshed, "the killed workspace must have no stored active_tab_id left -- handleWorkspaceKilled's " +
            "own pruning must have removed it, exactly like handlePaneClosed already does once a workspace's " +
            "last pane closes"
        )

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 3, "killing a workspace must never open a new transport")
        let sentLinesAfter = await factory.allSentLines()
        XCTAssertEqual(
            sentLinesAfter, baselineSentLines,
            "the herdr server must NEVER be sent any request when its own workspace is killed from the " +
            "Session Browser -- the workspace is already gone server-side by the time this runs"
        )
    }

    // MARK: - 14. Workspace killed with nothing registered is a no-op

    func test_handleWorkspaceKilled_noPanesRegisteredForWorkspace_isNoOp() async {
        let factory = SpyHerdrTransportFactory()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        coordinator.handleWorkspaceKilled(workspaceID: "wNeverOpened", socketPath: socketPath)

        XCTAssertEqual(attacher.closeLeafCalls, [], "nothing registered for this workspace means nothing to close")
        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 0, "a workspace with no pane tracked on this socket must touch the transport factory zero times")
    }

    // MARK: - 15. hasOpenTab query

    /// Pins `hasOpenTab(workspaceID:socketPath:)`'s full lifecycle: false
    /// before the workspace is ever opened, true once `openWorkspace`
    /// succeeds, STILL true after only one of its two panes closes (the
    /// tab itself is still open -- only the workspace's LAST tracked pane
    /// closing tears it down, mirroring `pruneIfLastPaneClosed`'s own
    /// rule), and false again once `handleWorkspaceKilled` closes what
    /// remains. Never touches the transport factory at any point.
    func test_hasOpenTab_falseBeforeOpen_trueOnceOpen_stillTrueWithOnePaneLeft_falseOnceTabGone() async {
        let factory = SpyHerdrTransportFactory()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let surfaceFactory = FakeHerdrNativeSurfaceFactory(results: [firstSurfaceID, secondSurfaceID])
        let attacher = FakeHerdrNativeTabAttacher()
        let coordinator = makeCoordinator(factory: factory, surfaceFactory: surfaceFactory, attacher: attacher)

        XCTAssertFalse(
            coordinator.hasOpenTab(workspaceID: "wF", socketPath: socketPath),
            "a workspace never opened in this window must report no open tab"
        )

        guard await openBaselineSplitWorkspace(factory: factory, coordinator: coordinator) else {
            XCTFail("Precondition: openBaselineSplitWorkspace must succeed")
            return
        }
        let callCountAfterOpen = await factory.callCount

        XCTAssertTrue(
            coordinator.hasOpenTab(workspaceID: "wF", socketPath: socketPath),
            "an opened workspace must report an open tab"
        )

        await coordinator.handlePaneClosed(paneID: "wF:p1", socketPath: socketPath)
        XCTAssertTrue(
            coordinator.hasOpenTab(workspaceID: "wF", socketPath: socketPath),
            "the workspace's tab is still open while its OTHER pane remains registered"
        )

        coordinator.handleWorkspaceKilled(workspaceID: "wF", socketPath: socketPath)
        XCTAssertFalse(
            coordinator.hasOpenTab(workspaceID: "wF", socketPath: socketPath),
            "once the workspace's last remaining pane is closed, it must report no open tab again"
        )

        let finalCallCount = await factory.callCount
        XCTAssertEqual(
            finalCallCount, callCountAfterOpen,
            "hasOpenTab must never touch the transport factory -- read-only, sends herdr nothing"
        )
    }

    // MARK: - Fixture builders (mirrors HerdrLayoutImporterTests' own shapes)

    /// {"id":..,"result":{"type":"workspace_info","workspace":{...}}} --
    /// herdr's measured `workspace.get` result shape (this file's own
    /// task brief: MEASURED against live herdr 0.8.0, protocol 19),
    /// confirmed against `herdr api schema --json`'s own
    /// success_response.$defs.ResponseResult "workspace_info" variant
    /// (required: "type", "workspace") wrapping WorkspaceInfo (required:
    /// "workspace_id", "number", "label", "focused", "pane_count",
    /// "tab_count", "active_tab_id", "agent_status" -- NOTE: "label" IS
    /// required by the schema, not optional as one might guess from the
    /// task brief's own hedge; it is included here for that reason).
    /// Required-fields-only, per this project's own fixture discipline --
    /// "worktree"/"tokens" are optional on WorkspaceInfo, deliberately
    /// omitted.
    private func workspaceGetResponseLine(id: String, workspaceID: String, activeTabID: String) -> String {
        "{\"id\":\"\(id)\",\"result\":{\"type\":\"workspace_info\",\"workspace\":{" +
        "\"workspace_id\":\"\(workspaceID)\",\"number\":1,\"label\":\"demo\",\"focused\":true," +
        "\"pane_count\":1,\"tab_count\":1,\"active_tab_id\":\"\(activeTabID)\",\"agent_status\":\"idle\"}}}"
    }

    /// {"id":..,"result":{"type":"session_snapshot","snapshot":{...}}} --
    /// herdr's measured `session.snapshot` result shape (mirrors
    /// HerdrConnectionTests' own `snapshotResponseLine`). `panes[]`
    /// carries exactly one PaneInfo entry per `terminalIDByPaneID` key,
    /// required-fields-only (PaneInfo's own schema `required`: "pane_id",
    /// "terminal_id", "workspace_id", "tab_id", "focused",
    /// "agent_status", "revision" -- `herdr api schema --json`);
    /// "workspace_id"/"tab_id" are filler values this file never reads
    /// back out (only "pane_id"/"terminal_id" feed `openWorkspace`'s own
    /// terminalIDByPaneID map). `workspaces`/`tabs`/`layouts`/`agents`
    /// stay empty -- HerdrSessionSnapshot's own other required fields,
    /// none of which this file's own coordinator reads.
    private func sessionSnapshotResponseLine(id: String, terminalIDByPaneID: [String: String]) -> String {
        let panesJSON = terminalIDByPaneID.map { paneID, terminalID in
            "{\"pane_id\":\"\(paneID)\",\"terminal_id\":\"\(terminalID)\",\"workspace_id\":\"wF\"," +
            "\"tab_id\":\"wF:t1\",\"focused\":false,\"agent_status\":\"idle\",\"revision\":0}"
        }.joined(separator: ",")
        return "{\"id\":\"\(id)\",\"result\":{\"type\":\"session_snapshot\",\"snapshot\":{\"version\":\"0.8.0\"," +
        "\"protocol\":19,\"workspaces\":[],\"tabs\":[],\"panes\":[\(panesJSON)],\"layouts\":[],\"agents\":[]}}}"
    }

    /// herdr's measured error response shape --
    /// {"id":"..","error":{"code":"..","message":".."}} -- mirrors
    /// HerdrIntegrationCoordinatorTests' own `errorResponseLine` builder
    /// (same wire shape, HerdrConnection.swift's own header).
    private func errorResponseLine(id: String, code: String, message: String) -> String {
        "{\"id\":\"\(id)\",\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}"
    }

    private func paneNodeJSON(paneID: String) -> String {
        "{\"type\":\"pane\",\"pane_id\":\"\(paneID)\"}"
    }

    private func splitNodeJSON(direction: String, ratio: Double, first: String, second: String) -> String {
        "{\"type\":\"split\",\"direction\":\"\(direction)\",\"ratio\":\(ratio),\"first\":\(first),\"second\":\(second)}"
    }

    /// {"id":..,"result":{"type":"layout_export","layout":{...}}} --
    /// herdr's measured `layout.export` result shape (schema documented
    /// in HerdrLayoutImporterTests.swift's own header; mirrors that
    /// file's own layoutExportResultJSON fixture shape).
    private func layoutExportResponseLine(
        id: String, workspaceID: String, tabID: String, zoomed: Bool, focusedPaneID: String, root: String
    ) -> String {
        "{\"id\":\"\(id)\",\"result\":{\"type\":\"layout_export\",\"layout\":{\"workspace_id\":\"\(workspaceID)\"," +
        "\"tab_id\":\"\(tabID)\",\"zoomed\":\(zoomed),\"focused_pane_id\":\"\(focusedPaneID)\",\"root\":\(root)}}}"
    }

    // MARK: - Wire-line parsing helpers (parse back to JSON -- never string comparison, JSONEncoder key order isn't stable)

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

    /// The single "pane_id"/"tab_id" entry inside `params`, whichever the
    /// coordinator chose to send -- see this file's header "OPEN
    /// DERIVATION CHOICE" for why the derivation itself is deliberately
    /// left open. `nil` if params is missing/not an object, or carries
    /// NEITHER key as a non-empty string.
    private func paneOrTabIDParam(inLine line: String) -> (key: String, value: String)? {
        guard let params = jsonObject(inLine: line)?["params"] as? [String: Any] else { return nil }
        if let value = params["tab_id"] as? String, !value.isEmpty { return ("tab_id", value) }
        if let value = params["pane_id"] as? String, !value.isEmpty { return ("pane_id", value) }
        return nil
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
