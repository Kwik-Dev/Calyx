//
//  ApprovalBannerModelTests.swift
//  CalyxTests
//
//  Covers ApprovalBannerModel: the per-window view-model
//  behind the Cockpit approval banner, deciding which single pending
//  ApprovalRequest (if any) this window should show, and forwarding
//  Allow/Deny/Always Allow to ApprovalInboxStore.decide(id:_:) /
//  CockpitSettings.autoApproveEnabled.
//
//  Coverage:
//  - current is the OLDEST pending request this window owns
//    (targetSurfaceID resolves true via the injected ownsSurface
//    closure); a request targeting a surface this window doesn't own
//    is invisible to it
//  - a request with a nil targetSurfaceID (window-agnostic, e.g. a
//    palette-level tool call) is shown only while this window is key,
//    so every open window doesn't surface the same banner at once
//  - allow(id:)/deny(id:) decide the id the caller explicitly passed
//    (the request actually rendered), never a re-read of `current` --
//    a stale id (no longer pending) is a safe no-op that never touches
//    whatever request `current` has since advanced to
//  - alwaysAllow(id:) turns on CockpitSettings.autoApproveEnabled,
//    decides the clicked id .allowed, AND drains every other request
//    already visible to this window in the same action -- for an
//    `.mcpTool`-sourced request (unchanged, Stage E), but NEVER a queued
//    `.agentHook`-sourced request on that same drain, even targeting the
//    same surface (source-scoped, see
//    test_alwaysAllow_mcpToolSource_doesNotDrainQueuedAgentHookRequest_onSameSurface).
//    For an `.agentHook`-sourced request (Stage E, NEW), alwaysAllow(id:)
//    instead records PANE Always-Allow memory (surfaceID, kind,
//    toolName) via the injected `memory`, batch-allows only pending
//    requests sharing that EXACT tuple, and never touches
//    CockpitSettings.autoApproveEnabled at all
//  - allowAllPending() (Stage E, NEW) decides EVERY pending request in
//    the store .allowed, store-wide, with no window/ownership filter at
//    all -- leaves no Always-Allow memory behind and never touches any
//    setting
//  - alwaysAllowAcrossPanes(id:) (Stage E, NEW; only meaningful for an
//    `.agentHook`-sourced request) records CROSS Always-Allow memory
//    (kind, toolName only -- no surfaceID) via the injected `memory`,
//    then batch-allows every pending request store-wide sharing that
//    (kind, toolName), regardless of window/pane, leaving a
//    different-tool request pending and never touching any setting
//  - pendingCountForWindow counts only requests this window owns
//    (mirrors current's ownership filter; the view's queue navigator
//    now gates on positionInfo.count instead, see that property's own
//    doc comment, but pendingCountForWindow remains its own
//    model-level contract, asserted directly below)
//
//  Stage E init change: ApprovalBannerModel's initializer gains a new
//  `memory: AgentHookApprovalMemory` parameter, defaulted to `.shared`
//  (mirrors this codebase's `= .shared`-defaulted seam convention, e.g.
//  `CalyxMCPServer.approvalInbox`/`agentRegistry`) -- every PRE-EXISTING
//  test below that never mentions `.agentHook` or the new actions
//  continues to construct `ApprovalBannerModel(store:ownsSurface:isKeyWindow:)`
//  unchanged and is unaffected; only the new tests below inject an
//  isolated `AgentHookApprovalMemory()` instance explicitly, so no test
//  leaks Always-Allow memory into another via the shared singleton.
//

import XCTest
@testable import Calyx

@MainActor
final class ApprovalBannerModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(targetSurfaceID: UUID?, payload: String = "ls", createdAt: Date = Date()) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: targetSurfaceID, payload: payload, createdAt: createdAt)
    }

    /// Stage E helper: an `.agentHook`-sourced request, the source
    /// variant `alwaysAllow(id:)`/`alwaysAllowAcrossPanes(id:)` key their
    /// new memory-recording behavior off of.
    private func makeAgentHookRequest(
        targetSurfaceID: UUID?,
        kind: String = AgentEntry.claudeCodeKind,
        toolName: String = "Bash",
        createdAt: Date = Date(),
        offers: AgentHookOffers = .none
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID(),
            source: .agentHook(toolName: toolName, kind: kind, summary: "ls -la /tmp", offers: offers),
            targetSurfaceID: targetSurfaceID,
            payload: "{\"command\":\"ls -la /tmp\"}",
            createdAt: createdAt
        )
    }

    /// Compact JSON `Data` for an `AgentHookToolCall.decode(from:)`
    /// fixture -- mirrors AgentHookToolCallTests.swift's own `json(_:)`
    /// helper.
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// Realistic `.agentHook`-sourced fixture for the `previewLine` tests
    /// below: routes through the REAL `AgentHookToolCall.decode(from:)`
    /// rather than hand-writing a summary string, mirroring exactly how
    /// `CalyxMCPServer` builds an `.agentHook` `ApprovalRequest` from a
    /// decoded `AgentHookToolCall` (`source: .agentHook(toolName:
    /// call.toolName, kind: kind, summary: call.summary)`).
    private func agentHookRequest(_ toolInput: [String: Any], toolName: String) throws -> ApprovalRequest {
        let call = try XCTUnwrap(AgentHookToolCall.decode(
            from: json(["tool_name": toolName, "tool_input": toolInput]), kind: AgentEntry.claudeCodeKind
        ))
        return ApprovalRequest(
            id: UUID(), source: .agentHook(toolName: call.toolName, kind: AgentEntry.claudeCodeKind, summary: call.summary, offers: .none),
            targetSurfaceID: nil, payload: call.payload, createdAt: Date()
        )
    }

    /// Bounded scheduler-yield loop, so a concurrently-spawned `Task`
    /// awaiting `store.awaitDecision` has every reasonable opportunity
    /// to actually reach its suspension point before the test proceeds
    /// to trigger a decision -- same pattern as
    /// ApprovalInboxStoreTests.yieldToScheduler / CommandLogStoreTests's.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    /// An `.agentQuestion`-sourced request: the source variant
    /// `answer(id:answers:)`/`skip(id:)`/`answerInPane(id:)` operate on,
    /// and the one every allow-family action (`allow`/`deny`/
    /// `alwaysAllow`/`alwaysAllowAcrossPanes`/`allowAllPending`) must
    /// leave untouched.
    private func makeAgentQuestionRequest(
        targetSurfaceID: UUID?,
        kind: String = AgentEntry.claudeCodeKind,
        createdAt: Date = Date()
    ) -> ApprovalRequest {
        let toolInput: [String: Any] = ["questions": [["question": "Which shell?", "options": [["label": "zsh"], ["label": "bash"]]]]]
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [
                    AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil),
                    AgentQuestionPrompt.Option(label: "bash", description: nil, preview: nil),
                ],
                multiSelect: false
            )],
            originalToolInputJSON: try! JSONSerialization.data(withJSONObject: toolInput)
        )
        return ApprovalRequest(
            id: UUID(), source: .agentQuestion(kind: kind, prompt: prompt),
            targetSurfaceID: targetSurfaceID, payload: "", createdAt: createdAt
        )
    }

    /// Counts invocations of the injected `restoreTerminalFocus` closure
    /// -- a plain reference-type box rather than a captured `var`, so it
    /// can be read after being handed to `ApprovalBannerModel`'s
    /// `@escaping` init parameter.
    private final class RestoreFocusSpy {
        private(set) var callCount = 0
        func call() { callCount += 1 }
    }

    // MARK: - current: ownership filter, oldest-first

    func test_current_isOldestPendingRequestOwnedByThisWindow() {
        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        let older = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "older", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(older)
        store.submit(newer)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        XCTAssertEqual(model.current?.id, older.id,
                       "current must be the oldest pending request this window owns, ignoring a foreign-surface request even if newer")

        let foreignOnlyStore = ApprovalInboxStore()
        foreignOnlyStore.submit(makeRequest(targetSurfaceID: foreignSurfaceID))
        let foreignOnlyModel = ApprovalBannerModel(store: foreignOnlyStore, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        XCTAssertNil(foreignOnlyModel.current,
                     "a window that owns none of the pending requests' target surfaces must show nothing")
    }

    // MARK: - current: nil targetSurfaceID gated by key-window

    func test_current_nilTargetSurface_shownOnlyInKeyWindow() {
        let store = ApprovalInboxStore()
        store.submit(makeRequest(targetSurfaceID: nil))

        var isKey = true
        let model = ApprovalBannerModel(store: store, ownsSurface: { _ in false }, isKeyWindow: { isKey })

        XCTAssertNotNil(model.current,
                        "a window-agnostic (nil targetSurfaceID) request must show in the key window")

        isKey = false
        XCTAssertNil(model.current,
                     "a window-agnostic request must not show in a non-key window, to avoid every open window surfacing it at once")
    }

    // MARK: - allow / deny

    func test_allow_decidesAllowed_andBannerClears() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.allow(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "allow(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "allow(id:) must resolve the in-flight awaitDecision with .allowed")
    }

    func test_deny_decidesDenied() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.deny(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "deny(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")

        let result = await waiter.value
        XCTAssertEqual(result, .denied(.userRejected), "deny(id:) must resolve the in-flight awaitDecision with .denied(.userRejected)")
    }

    /// F5: the id threaded through must be the one the caller actually
    /// rendered, never a silent re-read of `current` -- proven by
    /// resolving A out from under the model via a raw `store.decide`
    /// call (simulating some other path deciding it first), then
    /// clicking Deny with A's now-stale id and confirming B (which
    /// `current` has since advanced to) is completely untouched.
    func test_deny_staleID_afterCurrentAdvanced_isNoOp_doesNotAffectNewCurrent() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let requestA = makeRequest(targetSurfaceID: surfaceID, payload: "A", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let requestB = makeRequest(targetSurfaceID: surfaceID, payload: "B", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(requestA)
        store.submit(requestB)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        XCTAssertEqual(model.current?.id, requestA.id, "precondition: A is the oldest, currently-displayed request")

        let waiterB = Task { @MainActor in
            await store.awaitDecision(id: requestB.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        // Some other path resolves A while the view still holds A's id
        // from its last render.
        store.decide(id: requestA.id, .allowed)
        XCTAssertEqual(model.current?.id, requestB.id, "current must have advanced to B once A left pending")

        model.deny(id: requestA.id)

        XCTAssertEqual(store.pending.map(\.id), [requestB.id],
                       "a stale deny(id: A) must not touch B, which is still pending")

        store.decide(id: requestB.id, .denied(.userRejected))
        let result = await waiterB.value
        XCTAssertEqual(result, .denied(.userRejected),
                       "B must remain independently decidable after the stale deny(id: A) no-op")
    }

    // MARK: - alwaysAllow

    func test_alwaysAllow_enablesAutoApproveSetting_andAllows() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllow"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.alwaysAllow(id: request.id)

        XCTAssertTrue(CockpitSettings.autoApproveEnabled, "alwaysAllow(id:) must turn on the auto-approve setting")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "alwaysAllow(id:) must also resolve the clicked request as allowed")
    }

    /// F4: alwaysAllow(id:) must drain the WHOLE backlog visible to this
    /// window, not just the one request that was clicked.
    func test_alwaysAllow_drainsAllVisiblePendingRequests_forThisWindow() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowDrain"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let requestA = makeRequest(targetSurfaceID: surfaceID, payload: "A")
        let requestB = makeRequest(targetSurfaceID: surfaceID, payload: "B")
        let requestC = makeRequest(targetSurfaceID: surfaceID, payload: "C")
        store.submit(requestA)
        store.submit(requestB)
        store.submit(requestC)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiterA = Task { @MainActor in await store.awaitDecision(id: requestA.id, timeoutMs: 5_000) }
        let waiterB = Task { @MainActor in await store.awaitDecision(id: requestB.id, timeoutMs: 5_000) }
        let waiterC = Task { @MainActor in await store.awaitDecision(id: requestC.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        let notifyCountBeforeDrain = store._testNotifyCount

        model.alwaysAllow(id: requestA.id)

        XCTAssertTrue(store.pending.isEmpty,
                      "alwaysAllow(id:) must drain every request visible to this window, not just the clicked one")
        XCTAssertEqual(store._testNotifyCount - notifyCountBeforeDrain, 1,
                       "W6: draining 3 requests in one alwaysAllow(id:) action must post exactly one change " +
                       "notification, not one per drained request (which would trigger N full-window " +
                       "rebuilds per open window)")

        let resultA = await waiterA.value
        let resultB = await waiterB.value
        let resultC = await waiterC.value
        XCTAssertEqual(resultA, .allowed)
        XCTAssertEqual(resultB, .allowed, "the backlog drain must resolve B allowed even though only A was clicked")
        XCTAssertEqual(resultC, .allowed, "the backlog drain must resolve C allowed even though only A was clicked")
    }

    /// F4's cross-window scope: a pending request owned by a DIFFERENT
    /// window must be left alone by this window's alwaysAllow(id:) drain.
    func test_alwaysAllow_doesNotDrainRequestsOwnedByAnotherWindow() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowCrossWindow"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        let ownedRequest = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "owned")
        let foreignRequest = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "foreign")
        store.submit(ownedRequest)
        store.submit(foreignRequest)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        model.alwaysAllow(id: ownedRequest.id)

        XCTAssertEqual(store.pending.map(\.id), [foreignRequest.id],
                       "alwaysAllow(id:) must leave a request targeting a surface this window doesn't own pending")
    }

    /// R2 fix-pin: the `.mcpTool` branch of `alwaysAllow(id:)` drains
    /// every OTHER pending request visible to this window with NO source
    /// filter -- so a queued `.agentHook` request targeting the SAME
    /// surface must NOT be swept up in an mcpTool click's drain. Only
    /// that agentHook request's own (separate) always-allow action may
    /// ever decide it -- see the `.agentHook` branch below, which records
    /// its own pane/cross memory instead of touching the global setting.
    func test_alwaysAllow_mcpToolSource_doesNotDrainQueuedAgentHookRequest_onSameSurface() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowMcpToolDoesNotDrainAgentHook"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let mcpToolRequest = makeRequest(
            targetSurfaceID: surfaceID, payload: "pane_run", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let agentHookRequest = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        store.submit(mcpToolRequest)
        store.submit(agentHookRequest)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        let waiterMcp = Task { @MainActor in await store.awaitDecision(id: mcpToolRequest.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: mcpToolRequest.id)

        XCTAssertTrue(CockpitSettings.autoApproveEnabled,
                      "the mcpTool branch must still flip global auto-approve, unchanged")
        XCTAssertEqual(store.pending.map(\.id), [agentHookRequest.id],
                       "alwaysAllow(id:) on an .mcpTool request must decide only that request, leaving a " +
                       "queued .agentHook request on the SAME surface pending -- it has its own, separate " +
                       "always-allow action")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "the mcpTool branch must never record agent-hook Always-Allow memory as a side effect")

        let resultMcp = await waiterMcp.value
        XCTAssertEqual(resultMcp, .allowed)

        // Drain the still-pending agentHook request so this test doesn't
        // leak a suspended awaitDecision waiter.
        store.decide(id: agentHookRequest.id, .allowed)
    }

    // MARK: - pendingCountForWindow

    func test_pendingCountForWindow_countsOnlyOwnedRequests() {
        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        store.submit(makeRequest(targetSurfaceID: ownedSurfaceID, payload: "one"))
        store.submit(makeRequest(targetSurfaceID: ownedSurfaceID, payload: "two"))
        store.submit(makeRequest(targetSurfaceID: foreignSurfaceID, payload: "three"))

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        XCTAssertEqual(model.pendingCountForWindow, 2,
                       "pendingCountForWindow must count only requests targeting a surface this window owns")
    }

    // MARK: - alwaysAllow(id:) for an .agentHook-sourced request (Stage E)

    /// Distinguishes the NEW agentHook branch from the existing mcpTool
    /// branch above: instead of flipping the global auto-approve
    /// setting, it must record PANE memory scoped to the clicked
    /// request's own (targetSurfaceID, kind, toolName).
    func test_alwaysAllow_agentHookSource_recordsPaneMemory_neverTouchesGlobalAutoApprove() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowAgentHookPaneMemory"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let foreignSurfaceID = UUID()
        let clicked = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Bash")
        store.submit(clicked)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        let waiter = Task { @MainActor in await store.awaitDecision(id: clicked.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: clicked.id)

        XCTAssertTrue(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                     "alwaysAllow(id:) for an agentHook request must record PANE memory for the clicked " +
                     "request's own (targetSurfaceID, kind, toolName)")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: foreignSurfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "the recorded memory must be scoped to the clicked request's own surface, not every surface")
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "an agentHook alwaysAllow(id:) must NOT flip the global auto-approve toggle -- it only " +
                       "records scoped Always-Allow memory")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "alwaysAllow(id:) must still resolve the clicked request as allowed")
    }

    /// The batch-drain half of the same behavior: only a pending request
    /// sharing the clicked request's EXACT (targetSurfaceID, kind,
    /// toolName) is drained -- a different tool on the SAME pane, and
    /// the SAME tool on a DIFFERENT pane, are each independently left
    /// pending.
    func test_alwaysAllow_agentHookSource_drainsOnlySamePaneSameToolPending() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowAgentHookDrain"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let foreignSurfaceID = UUID()

        let clicked = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let samePaneSameTool = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let samePaneDifferentTool = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Write", createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let differentPaneSameTool = makeAgentHookRequest(
            targetSurfaceID: foreignSurfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        store.submit(clicked)
        store.submit(samePaneSameTool)
        store.submit(samePaneDifferentTool)
        store.submit(differentPaneSameTool)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        let waiterClicked = Task { @MainActor in await store.awaitDecision(id: clicked.id, timeoutMs: 5_000) }
        let waiterSamePane = Task { @MainActor in await store.awaitDecision(id: samePaneSameTool.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: clicked.id)

        XCTAssertEqual(Set(store.pending.map(\.id)), Set([samePaneDifferentTool.id, differentPaneSameTool.id]),
                       "alwaysAllow(id:) must drain only pending requests sharing the clicked request's exact " +
                       "(targetSurfaceID, kind, toolName) -- a different tool on the same pane, and the same " +
                       "tool on a different pane, must both stay pending")

        let resultClicked = await waiterClicked.value
        let resultSamePane = await waiterSamePane.value
        XCTAssertEqual(resultClicked, .allowed)
        XCTAssertEqual(resultSamePane, .allowed, "the same-pane-same-tool backlog match must also be drained allowed")
    }

    // MARK: - allowAllPending() (Stage E, NEW)

    func test_allowAllPending_drainsEveryPendingRequestStoreWide_leavesNoMemory_neverTouchesSettings() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.allowAllPending"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()

        let ownedMcp = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "owned-mcp")
        let foreignMcp = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "foreign-mcp")
        let foreignAgentHook = makeAgentHookRequest(targetSurfaceID: foreignSurfaceID, toolName: "Bash")
        let windowAgnostic = makeRequest(targetSurfaceID: nil, payload: "agnostic")
        store.submit(ownedMcp)
        store.submit(foreignMcp)
        store.submit(foreignAgentHook)
        store.submit(windowAgnostic)

        // isKeyWindow is false, so the window-agnostic request would
        // normally be invisible to this window too -- proving
        // allowAllPending() applies NO visibility filter at all.
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { false }, memory: memory)

        let requests = [ownedMcp, foreignMcp, foreignAgentHook, windowAgnostic]
        let waiters = requests.map { request in
            Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        }
        await yieldToScheduler()

        model.allowAllPending()

        XCTAssertTrue(store.pending.isEmpty,
                      "allowAllPending() must drain EVERY pending request store-wide, including ones this " +
                      "window neither owns nor could otherwise see")

        for waiter in waiters {
            let result = await waiter.value
            XCTAssertEqual(result, .allowed)
        }

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: foreignSurfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "allowAllPending() must leave no Always-Allow memory behind")
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "allowAllPending() must never touch the global auto-approve setting")
    }

    // MARK: - alwaysAllowAcrossPanes(id:) (Stage E, NEW)

    func test_alwaysAllowAcrossPanes_recordsCrossMemory_drainsSameToolStoreWide_leavesDifferentToolPending() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowAcrossPanes"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceA = UUID()
        let surfaceB = UUID()

        let clicked = makeAgentHookRequest(
            targetSurfaceID: surfaceA, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let sameToolOtherPane = makeAgentHookRequest(
            targetSurfaceID: surfaceB, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let differentTool = makeAgentHookRequest(
            targetSurfaceID: surfaceA, toolName: "Write", createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        store.submit(clicked)
        store.submit(sameToolOtherPane)
        store.submit(differentTool)

        // This window owns only surfaceA -- surfaceB is a pane it does
        // NOT own, proving alwaysAllowAcrossPanes(id:) applies no window
        // filter at all.
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceA }, isKeyWindow: { true }, memory: memory)

        let waiterClicked = Task { @MainActor in await store.awaitDecision(id: clicked.id, timeoutMs: 5_000) }
        let waiterOtherPane = Task { @MainActor in await store.awaitDecision(id: sameToolOtherPane.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllowAcrossPanes(id: clicked.id)

        XCTAssertTrue(memory.isAutoAllowed(surfaceID: UUID(), kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                     "alwaysAllowAcrossPanes(id:) must record CROSS memory for (kind, toolName), auto-allowing " +
                     "an arbitrary surface it has never seen before")
        XCTAssertEqual(store.pending.map(\.id), [differentTool.id],
                       "alwaysAllowAcrossPanes(id:) must drain every pending request sharing the clicked " +
                       "request's (kind, toolName) store-wide, regardless of window ownership, leaving a " +
                       "different tool pending")
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "alwaysAllowAcrossPanes(id:) must never touch the global auto-approve setting")

        let resultClicked = await waiterClicked.value
        let resultOtherPane = await waiterOtherPane.value
        XCTAssertEqual(resultClicked, .allowed)
        XCTAssertEqual(resultOtherPane, .allowed,
                       "a same-tool request on a pane this window doesn't own must still be drained")
    }

    // MARK: - Queue navigation (prev/next cursor)
    //
    // A stored, private `selectedRequestID: UUID?` cursor lets a window
    // step through every request VISIBLE to it (same ownsSurface/
    // isKeyWindow filter `current`/`pendingCountForWindow` already use),
    // instead of only ever showing the oldest one. `current` returns the
    // selected request while it's still pending+visible, else falls back
    // to the oldest visible request (mirrors today's behavior when
    // nothing has been explicitly selected yet, or the selection has
    // been resolved out from under it). `positionInfo` is this window's
    // 1-based (index, count) of `current` within that same visible
    // queue, nil exactly when `current` is nil. Deciding the DISPLAYED
    // request (the id `current` actually returned at the time of the
    // call) via allow(id:)/deny(id:)/alwaysAllow(id:)/
    // alwaysAllowAcrossPanes(id:) advances the cursor to its successor
    // in that pre-removal visible queue (predecessor if it was last,
    // nil if it was the only one visible) -- so the banner keeps
    // stepping forward through the backlog instead of always snapping
    // back to the oldest. allowAllPending() clears the cursor outright
    // (nothing is left pending to point at). A stale id -- one that is
    // NOT the currently-displayed request, e.g. already resolved by some
    // other path -- must never move the cursor; and a brand-new arrival
    // submitted after a selection has been made must never move that
    // existing selection either.

    func test_selectNext_advancesCurrentAndPositionInfo() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        XCTAssertEqual(model.current?.id, first.id, "precondition: current starts at the oldest pending request")
        XCTAssertEqual(model.positionInfo?.index, 1, "positionInfo's index is 1-based")
        XCTAssertEqual(model.positionInfo?.count, 3, "positionInfo's count is the size of this window's visible queue")

        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "selectNext() must advance current to the next request in the visible queue")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 3)

        model.selectNext()
        XCTAssertEqual(model.current?.id, third.id, "a second selectNext() must advance current to the newest request")
        XCTAssertEqual(model.positionInfo?.index, 3)
        XCTAssertEqual(model.positionInfo?.count, 3)
    }

    func test_navigation_clampsAtQueueEnds() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        XCTAssertFalse(model.canSelectPrevious, "at the oldest (first) request, there is nothing before it to select")
        model.selectPrevious()
        XCTAssertEqual(model.current?.id, first.id, "selectPrevious() at the start of the queue must be a no-op")

        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: navigated to the newest request")
        XCTAssertFalse(model.canSelectNext, "at the newest (last) request, there is nothing after it to select")
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "selectNext() at the end of the queue must be a no-op")
    }

    func test_navigation_skipsForeignSurfaceRequests() {
        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        let t1 = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "t1", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let t2 = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "t2", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let t3 = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "t3", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(t1)
        store.submit(t2)
        store.submit(t3)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        XCTAssertEqual(model.positionInfo?.count, 2,
                       "positionInfo's count must reflect only requests this window owns, excluding the foreign-surface request")

        model.selectNext()
        XCTAssertEqual(model.current?.id, t3.id,
                       "selectNext() must skip over the foreign-surface request entirely and land on the next OWNED request")
    }

    func test_current_fallsBackToOldestVisible_whenSelectionResolvedExternally() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.current?.id, third.id, "precondition: navigated to the newest request")

        store.decide(id: third.id, .allowed)

        XCTAssertEqual(model.current?.id, first.id,
                       "once the selected request is resolved externally (bypassing the model), current must fall back to the oldest still-visible request")
        XCTAssertEqual(model.positionInfo?.index, 1)
        XCTAssertEqual(model.positionInfo?.count, 2)
    }

    func test_allow_onDisplayedRequest_advancesToSuccessor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: second.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.allow(id: second.id)

        XCTAssertEqual(model.current?.id, third.id,
                       "allow(id:) on the currently-displayed request must advance the cursor to its successor in the visible queue")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 2)

        let result = await waiter.value
        XCTAssertEqual(result, .allowed)
    }

    func test_deny_onLastDisplayedRequest_fallsBackToPredecessor() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.current?.id, third.id, "precondition: navigated to the last (newest) displayed request")

        model.deny(id: third.id)

        XCTAssertEqual(model.current?.id, second.id,
                       "deny(id:) on the last displayed request must fall back to its predecessor in the visible queue, since there is no successor")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 2)
    }

    /// Mirrors the pre-existing stale-id contract above (F5), but for the
    /// NEW cursor: once the SELECTED request has been resolved out from
    /// under the model by some other path, `current` has already fallen
    /// back to the oldest visible request -- a subsequent `allow(id:)`
    /// call using the (now stale) selected id must not move the cursor
    /// again, and must leave every still-pending request untouched.
    func test_allow_withStaleID_doesNotMoveCursor() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        // Some other path resolves the selected request while the model
        // still holds it as `selectedRequestID`.
        store.decide(id: second.id, .allowed)
        XCTAssertEqual(model.current?.id, first.id,
                       "precondition: current has already fallen back to the oldest visible request")

        model.allow(id: second.id)

        XCTAssertEqual(model.current?.id, first.id,
                       "a stale allow(id:) for a request that is no longer the displayed one must not move the cursor")
        XCTAssertEqual(store.pending.map(\.id), [first.id, third.id],
                       "the stale allow(id:) call must not touch any request that is still pending")
    }

    /// Same successor-advance contract as `allow(id:)`/`deny(id:)` above,
    /// exercised through the `.agentHook` branch of `alwaysAllow(id:)`
    /// instead. The two requests deliberately use DIFFERENT `toolName`s
    /// so the pane-scoped memory drain (see `alwaysAllow(id:)`'s own doc
    /// comment) takes only the clicked one, keeping this test isolated to
    /// the cursor-advance behavior rather than the drain's own matching
    /// rules (already covered elsewhere).
    func test_alwaysAllow_agentHook_onDisplayedRequest_advancesToSuccessor() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.navigationAlwaysAllowAgentHook"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let first = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Write", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)
        XCTAssertEqual(model.current?.id, first.id, "precondition: current defaults to the oldest (first) request")

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: first.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.alwaysAllow(id: first.id)

        XCTAssertEqual(store.pending.map(\.id), [second.id],
                       "precondition: the different-toolName request must be left pending by the pane-scoped drain")
        XCTAssertEqual(model.current?.id, second.id,
                       "alwaysAllow(id:) on the displayed request must advance the cursor to its successor, same as allow(id:)/deny(id:)")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed)
    }

    /// Bug reproducer: `advanceCursor(pastDisplayed:)` picks the
    /// immediate visible neighbor (index + 1, computed from the
    /// PRE-removal `visibleRequests`) as the new cursor before the drain
    /// actually runs -- but the `.agentHook` branch's pane-scoped drain
    /// (same surface + kind + toolName) can sweep that very neighbor away
    /// in the SAME call. Here, clicking Always-Allow on B (tool "bravo")
    /// drains both B and C (C shares B's toolName), so the neighbor
    /// `advanceCursor` picked (C) never survives. Once C is gone,
    /// `current`'s `selectedRequestID` lookup misses and falls all the
    /// way back to the OLDEST visible request (A) -- the banner snaps
    /// backward -- instead of stepping to the nearest FORWARD survivor,
    /// D, which is what the forward-triage contract actually promises.
    func test_alwaysAllow_agentHook_drainSweepsSuccessor_cursorLandsOnForwardSurvivor() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.drainSweepsSuccessor"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let a = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "alpha", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let b = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "bravo", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let c = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "bravo", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        let d = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "delta", createdAt: Date(timeIntervalSince1970: 1_700_000_300))
        store.submit(a)
        store.submit(b)
        store.submit(c)
        store.submit(d)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.selectNext()
        XCTAssertEqual(model.current?.id, b.id, "precondition: current is the displayed (2nd) request, B")

        let waiterB = Task { @MainActor in await store.awaitDecision(id: b.id, timeoutMs: 5_000) }
        let waiterC = Task { @MainActor in await store.awaitDecision(id: c.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: b.id)

        XCTAssertEqual(Set(store.pending.map(\.id)), Set([a.id, d.id]),
                       "precondition: the pane-scoped drain must decide both B and C (same surface+kind+tool " +
                       "'bravo'), leaving only A and D pending")

        XCTAssertEqual(model.current?.id, d.id,
                       "alwaysAllow(id:) must advance the cursor to the nearest FORWARD survivor (D) once its " +
                       "immediate successor (C) is itself swept up by the very same drain -- not fall back to " +
                       "the oldest visible request (A)")
        XCTAssertEqual(model.positionInfo?.index, 2, "D is now the 2nd (newest) of the 2 remaining visible requests")
        XCTAssertEqual(model.positionInfo?.count, 2)

        let resultB = await waiterB.value
        let resultC = await waiterC.value
        XCTAssertEqual(resultB, .allowed)
        XCTAssertEqual(resultC, .allowed)
    }

    /// Same underlying bug as the reproducer above, but here the
    /// drain sweeps the cursor's clicked request (C) AND its immediate
    /// successor (D) both, leaving NO forward survivor at all. The
    /// correct fallback in that case is the nearest BACKWARD survivor
    /// (B), not simply the oldest visible request (A) -- those two only
    /// coincide when the cursor itself was already at the oldest
    /// surviving position, which is NOT the case here. Distinct tool
    /// names (alpha/bravo/charlie/charlie) keep B out of the drain's own
    /// match (only same-toolName "charlie" requests, C and D, are
    /// swept), so B survives purely as the nearest predecessor, never as
    /// a side effect of the drain's own filtering. This is a second bug
    /// reproducer, not merely a pinning test: today's code also lands on
    /// A here (stale cursor -> oldest fallback), which is the wrong
    /// answer once a correct nearest-survivor fallback is implemented.
    func test_alwaysAllow_agentHook_drainSweepsAllForward_cursorFallsBackToNearestPredecessor() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.drainSweepsAllForward"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let a = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "alpha", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let b = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "bravo", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let c = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "charlie", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        let d = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "charlie", createdAt: Date(timeIntervalSince1970: 1_700_000_300))
        store.submit(a)
        store.submit(b)
        store.submit(c)
        store.submit(d)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.current?.id, c.id, "precondition: current is the displayed (3rd) request, C")

        let waiterC = Task { @MainActor in await store.awaitDecision(id: c.id, timeoutMs: 5_000) }
        let waiterD = Task { @MainActor in await store.awaitDecision(id: d.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: c.id)

        XCTAssertEqual(Set(store.pending.map(\.id)), Set([a.id, b.id]),
                       "precondition: the pane-scoped drain must decide both C and D (same surface+kind+tool " +
                       "'charlie'), leaving only A and B pending")

        XCTAssertEqual(model.current?.id, b.id,
                       "alwaysAllow(id:) must fall back to the nearest BACKWARD survivor (B) once BOTH the " +
                       "clicked request (C) and its immediate successor (D) are swept by the drain, leaving no " +
                       "forward survivor at all -- not fall back to the oldest visible request (A), which is " +
                       "not the correct predecessor")
        XCTAssertEqual(model.positionInfo?.index, 2, "B is now the 2nd (newest) of the 2 remaining visible requests")
        XCTAssertEqual(model.positionInfo?.count, 2)

        let resultC = await waiterC.value
        let resultD = await waiterD.value
        XCTAssertEqual(resultC, .allowed)
        XCTAssertEqual(resultD, .allowed)
    }

    func test_newArrival_neverMovesSelection() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the newest (second) request")

        let newer = makeRequest(targetSurfaceID: surfaceID, payload: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(newer)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival submitted with a NEWER createdAt (appended after the selection) must never move an existing selection")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 3)

        let older = makeRequest(targetSurfaceID: surfaceID, payload: "older", createdAt: Date(timeIntervalSince1970: 1_699_999_900))
        store.submit(older)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival submitted with an OLDER createdAt (inserted at the head of the queue) must also never move an existing selection")
        XCTAssertEqual(model.positionInfo?.index, 3)
        XCTAssertEqual(model.positionInfo?.count, 4)
    }

    func test_allowAllPending_clearsSelectionAndBanner() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the newest (second) request")

        let waiterFirst = Task { @MainActor in await store.awaitDecision(id: first.id, timeoutMs: 5_000) }
        let waiterSecond = Task { @MainActor in await store.awaitDecision(id: second.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.allowAllPending()

        XCTAssertNil(model.current, "allowAllPending() must clear the cursor along with every pending request, leaving the banner empty")
        XCTAssertNil(model.positionInfo, "positionInfo must be nil once nothing is left visible")

        let resultFirst = await waiterFirst.value
        let resultSecond = await waiterSecond.value
        XCTAssertEqual(resultFirst, .allowed)
        XCTAssertEqual(resultSecond, .allowed)
    }

    // MARK: - previewLine (Queue preview menu)
    //
    // ApprovalRequest.previewLine is "\(displayToolName): \(compactTarget)",
    // where compactTarget takes displayPayload through two steps: (1)
    // collapse every run of whitespace (including newlines and tabs) into
    // a single space, (2) trim leading/trailing whitespace. Its length is
    // deliberately not capped by a character count: the finished menu row
    // is bounded in points, and elided in its middle, by
    // ApprovalBannerView.fittedToMenuWidth(_:). An empty compactTarget
    // after steps (1)-(2) omits the trailing colon entirely, rendering
    // displayToolName alone. RAW, unescaped -- same caveat as
    // displayToolName/displayPayload themselves (ControlCharacterDisplay
    // escaping is the view layer's job, applied later, not here).

    func test_previewLine_agentHookBash_combinesDisplayToolNameAndCommand() throws {
        let request = try agentHookRequest(["command": "npm test"], toolName: "Bash")

        XCTAssertEqual(request.previewLine, "Claude Code · Bash: npm test",
                       "previewLine must combine displayToolName and the compacted target with a colon separator")
    }

    func test_previewLine_agentHookEdit_usesFilePathAsTarget() throws {
        let request = try agentHookRequest(["file_path": "/Users/dev/project/Sources/App.swift"], toolName: "Edit")

        XCTAssertEqual(request.previewLine, "Claude Code · Edit: /Users/dev/project/Sources/App.swift")
    }

    func test_previewLine_agentHookWrite_usesFilePathAsTarget() throws {
        let request = try agentHookRequest(["file_path": "/Users/dev/project/README.md"], toolName: "Write")

        XCTAssertEqual(request.previewLine, "Claude Code · Write: /Users/dev/project/README.md")
    }

    func test_previewLine_agentHookNotebookEdit_usesNotebookPathAsTarget() throws {
        let request = try agentHookRequest(["notebook_path": "/Users/dev/repo/notebook.ipynb"], toolName: "NotebookEdit")

        XCTAssertEqual(request.previewLine, "Claude Code · NotebookEdit: /Users/dev/repo/notebook.ipynb",
                       "NotebookEdit's target must come from tool_input.notebook_path, its own distinct key, never file_path")
    }

    func test_previewLine_agentHookWebFetch_usesUrlAsTarget() throws {
        let request = try agentHookRequest(["url": "https://example.com/docs"], toolName: "WebFetch")

        XCTAssertEqual(request.previewLine, "Claude Code · WebFetch: https://example.com/docs")
    }

    func test_previewLine_mcpToolSource_usesPayloadAsTarget() {
        let request = makeRequest(targetSurfaceID: nil, payload: "ls -la /tmp")

        XCTAssertEqual(request.previewLine, "pane_run: ls -la /tmp")
    }

    func test_previewLine_collapsesNewlinesAndTabsToSingleSpaces() {
        let request = makeRequest(targetSurfaceID: nil, payload: "line one\n\nline   two\t\tend")

        XCTAssertEqual(request.previewLine, "pane_run: line one line two end",
                       "every run of whitespace, including newlines and tabs, must collapse to exactly one space")
    }

    func test_previewLine_longTarget_notTruncatedByCharacterCount() {
        let target = String(repeating: "a", count: 400)
        let request = makeRequest(targetSurfaceID: nil, payload: target)

        XCTAssertEqual(request.previewLine, "pane_run: " + target,
                       "previewLine must leave its target's length alone: how long a menu row may be is bounded in points by ApprovalBannerView.fittedToMenuWidth(_:), not by a character count here")
    }

    func test_previewLine_longTarget_carriesNoEllipsis() {
        let target = String(repeating: "a", count: 400)
        let request = makeRequest(targetSurfaceID: nil, payload: target)

        XCTAssertFalse(request.previewLine.contains("…"),
                       "previewLine must not append an ellipsis of its own: the view elides the row's MIDDLE, and a trailing ellipsis here would be what survives that as the row's tail")
    }

    func test_previewLine_emptyTarget_omitsTrailingColon() {
        let request = makeRequest(targetSurfaceID: nil, payload: "   \n\t  ")

        XCTAssertEqual(request.previewLine, "pane_run",
                       "a payload that collapses to an empty compact target must render as displayToolName alone, with no trailing colon")
    }

    // MARK: - queueEntries (Queue preview menu)
    //
    // ApprovalBannerModel.queueEntries lists every request in
    // visibleRequests (same ownsSurface/isKeyWindow filter as current/
    // pendingCountForWindow), oldest-first, as a QueueEntry(id, 1-based
    // position, previewLine, isCurrent) -- the data the banner's queue
    // menu renders one row per pending request from.

    func test_queueEntries_oldestFirst_onebasedPositions_isCurrentOnlyOnCurrentPage() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        let entries = model.queueEntries

        XCTAssertEqual(entries.map(\.id), [first.id, second.id, third.id],
                       "queueEntries must list every visible request oldest-first, same order as visibleRequests")
        XCTAssertEqual(entries.map(\.position), [1, 2, 3], "position must be a 1-based index into that same order")
        XCTAssertEqual(entries.map(\.isCurrent), [false, true, false],
                       "isCurrent must be true only for the entry matching current's own id")
        XCTAssertEqual(entries.map(\.previewLine), ["pane_run: first", "pane_run: second", "pane_run: third"],
                       "each entry's previewLine must be its own request's previewLine")
    }

    func test_queueEntries_excludesRequestsOwnedByAnotherWindow() {
        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        let t1 = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "t1", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let t2 = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "t2", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let t3 = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "t3", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(t1)
        store.submit(t2)
        store.submit(t3)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        let entries = model.queueEntries

        XCTAssertEqual(entries.map(\.id), [t1.id, t3.id],
                       "queueEntries must exclude a request targeting a surface this window doesn't own, same visibility filter as visibleRequests")
        XCTAssertEqual(entries.map(\.position), [1, 2],
                       "position must renumber 1-based over only the visible subset, skipping the excluded foreign request")
    }

    func test_queueEntries_emptyWhenNoVisibleRequests() {
        let store = ApprovalInboxStore()
        let model = ApprovalBannerModel(store: store, ownsSurface: { _ in false }, isKeyWindow: { false })

        XCTAssertEqual(model.queueEntries, [], "queueEntries must be empty when visibleRequests is empty")
    }

    /// The selected request is resolved through the store directly, not
    /// through model.allow(id:)/deny(id:): those advance the cursor onto
    /// a surviving neighbor (see advanceCursor(pastDisplayed:excluding:)),
    /// which is the opposite of the stale cursor this pins -- one still
    /// pointing at a request that has left visibleRequests, with nothing
    /// having reassigned it.
    func test_queueEntries_withStaleCursor_marksOldestVisibleEntryCurrent() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.select(id: second.id)
        XCTAssertEqual(model.current?.id, second.id, "precondition: the cursor points at the middle request")

        store.decide(id: second.id, .allowed)

        let entries = model.queueEntries

        XCTAssertEqual(entries.map(\.id), [first.id, third.id],
                       "precondition: the selected request has left visibleRequests, leaving the cursor stale")
        XCTAssertEqual(entries.map(\.isCurrent), [true, false],
                       "a stale cursor must mark the OLDEST visible entry current, exactly where current itself falls back to -- never leave every entry unmarked")
        XCTAssertEqual(model.current?.id, first.id,
                       "queueEntries and current must resolve the same stale cursor to the same request")
    }

    // MARK: - select(id:) (Queue preview menu jump)
    //
    // select(id:) is the queue menu's row-click action: jump straight to a
    // chosen request instead of stepping one at a time via selectNext()/
    // selectPrevious(). Same visibleRequests-membership contract as those
    // two -- an id outside this window's own visible queue (never
    // submitted, already decided, or owned by another window) is a no-op.
    // Unlike those two, a select that actually moves the cursor posts
    // .calyxApprovalInboxChanged itself, since an NSMenuItem's action runs
    // outside the rendered view hierarchy (see select(id:)'s own doc
    // comment in ApprovalBannerModel.swift).

    func test_select_movesCurrentAndPositionInfoToTheChosenRequest() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        XCTAssertEqual(model.current?.id, first.id, "precondition: current starts at the oldest pending request")

        model.select(id: third.id)

        XCTAssertEqual(model.current?.id, third.id, "select(id:) must move current directly to the chosen request")
        XCTAssertEqual(model.positionInfo?.index, 3, "positionInfo must follow the newly selected request")
        XCTAssertEqual(model.positionInfo?.count, 3)
    }

    /// A wrong implementation that unconditionally assigns the cursor
    /// (skipping the visibleRequests membership check) would still make a
    /// bogus id LOOK like a no-op here, since `current`'s own fallback for
    /// an unresolvable selectedRequestID lands on the oldest visible
    /// request anyway -- so this starts from an explicit prior selection
    /// (second, not the oldest) to actually distinguish "stayed at second"
    /// from "silently fell back to first".
    func test_select_withIDNotInVisibleRequests_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.select(id: second.id)
        XCTAssertEqual(model.current?.id, second.id, "precondition: current follows an explicit select(id:) to the second request")

        model.select(id: UUID())

        XCTAssertEqual(model.current?.id, second.id,
                       "select(id:) with an id absent from visibleRequests must be a no-op, leaving the prior explicit selection at second untouched")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 2)
    }

    /// Same discriminating shape as the stale-id test above, but for an id
    /// that IS pending store-wide, just owned by a different window -- an
    /// implementation checking membership against store.pending instead of
    /// this window's own visibleRequests would wrongly accept it.
    func test_select_withForeignSurfaceID_isNoOp() {
        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        let owned1 = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "owned1", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let owned2 = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "owned2", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let foreign = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "foreign", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(owned1)
        store.submit(owned2)
        store.submit(foreign)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })
        model.select(id: owned2.id)
        XCTAssertEqual(model.current?.id, owned2.id, "precondition: current follows an explicit select(id:) to the second owned request")

        model.select(id: foreign.id)

        XCTAssertEqual(model.current?.id, owned2.id,
                       "select(id:) targeting a request pending store-wide but owned by ANOTHER window must be a no-op -- membership must be checked against this window's own visibleRequests, not store.pending")
    }

    func test_select_thenNewArrival_neverMovesSelection() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.select(id: second.id)
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the explicitly selected (second) request")

        let newer = makeRequest(targetSurfaceID: surfaceID, payload: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(newer)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival submitted with a NEWER createdAt after select(id:) must never move that existing selection")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 3)

        let older = makeRequest(targetSurfaceID: surfaceID, payload: "older", createdAt: Date(timeIntervalSince1970: 1_699_999_900))
        store.submit(older)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival with an OLDER createdAt, inserted at the head of the queue, must also never move the select(id:) selection")
        XCTAssertEqual(model.positionInfo?.index, 3)
        XCTAssertEqual(model.positionInfo?.count, 4)
    }

    // MARK: - AccessibilityID coverage for the new cross-actions menu (Stage E, spec-level only)
    //
    // SwiftUI Menu rendering itself is not unit-testable (no production
    // view code exercised here) -- this only pins that the new
    // identifiers exist, are distinct from each other and from the
    // pre-existing ApprovalBanner identifiers, and follow the same
    // "calyx.approvalBanner.*" prefix convention as
    // container/allowButton/denyButton/alwaysAllowButton/payload above.

    func test_accessibilityID_approvalBanner_crossActionsMenuIdentifiers_existAndAreDistinct() {
        let newIdentifiers = [
            AccessibilityID.ApprovalBanner.crossActionsMenu,
            AccessibilityID.ApprovalBanner.allowAllPendingItem,
            AccessibilityID.ApprovalBanner.alwaysAllowAllPanesItem,
            // Queue navigation (prev/next cursor): the banner's new
            // Previous/Next buttons and their "N / M" position label.
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
        ]

        for identifier in newIdentifiers {
            XCTAssertTrue(identifier.hasPrefix("calyx.approvalBanner."),
                         "\(identifier) must follow the existing calyx.approvalBanner.* naming convention")
        }

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.denyButton,
            AccessibilityID.ApprovalBanner.alwaysAllowButton,
            AccessibilityID.ApprovalBanner.payload,
        ]
        XCTAssertEqual(Set(newIdentifiers).intersection(preExistingIdentifiers), [],
                       "the 6 new identifiers must be distinct from every pre-existing ApprovalBanner identifier")
        XCTAssertEqual(Set(newIdentifiers).count, newIdentifiers.count,
                       "the 6 new identifiers must also be distinct from each other")
    }

    // MARK: - AccessibilityID coverage for the new queue preview menu (spec-level only, same shape as the cross-actions menu coverage above)

    func test_accessibilityID_approvalBanner_queueMenuIdentifier_existsAndIsDistinct() {
        let newIdentifier = AccessibilityID.ApprovalBanner.queueMenu

        XCTAssertTrue(newIdentifier.hasPrefix("calyx.approvalBanner."),
                     "\(newIdentifier) must follow the existing calyx.approvalBanner.* naming convention")

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.denyButton,
            AccessibilityID.ApprovalBanner.alwaysAllowButton,
            AccessibilityID.ApprovalBanner.payload,
            AccessibilityID.ApprovalBanner.crossActionsMenu,
            AccessibilityID.ApprovalBanner.allowAllPendingItem,
            AccessibilityID.ApprovalBanner.alwaysAllowAllPanesItem,
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
        ]
        XCTAssertFalse(preExistingIdentifiers.contains(newIdentifier),
                       "queueMenu must be distinct from every pre-existing ApprovalBanner identifier")
    }

    // MARK: - AccessibilityID coverage for the AskUserQuestion prompt UI (spec-level only, same shape as the other coverage above)

    func test_accessibilityID_approvalBanner_questionIdentifiers_existAndAreDistinct() {
        let newIdentifiers = [
            AccessibilityID.ApprovalBanner.questionText,
            AccessibilityID.ApprovalBanner.optionButton(0),
            AccessibilityID.ApprovalBanner.optionButton(1),
            AccessibilityID.ApprovalBanner.otherButton,
            AccessibilityID.ApprovalBanner.otherTextField,
            AccessibilityID.ApprovalBanner.answerButton,
            AccessibilityID.ApprovalBanner.answerInPaneButton,
            AccessibilityID.ApprovalBanner.questionPosition,
            AccessibilityID.ApprovalBanner.previewText,
            AccessibilityID.ApprovalBanner.amendButton,
            AccessibilityID.ApprovalBanner.amendTextField,
            AccessibilityID.ApprovalBanner.amendConfirmButton,
            AccessibilityID.ApprovalBanner.cancelButton,
            AccessibilityID.ApprovalBanner.chatButton,
            AccessibilityID.ApprovalBanner.backButton,
            AccessibilityID.ApprovalBanner.notesButton,
            AccessibilityID.ApprovalBanner.notesTextField,
        ]

        for identifier in newIdentifiers {
            XCTAssertTrue(identifier.hasPrefix("calyx.approvalBanner."),
                         "\(identifier) must follow the existing calyx.approvalBanner.* naming convention")
        }

        XCTAssertEqual(AccessibilityID.ApprovalBanner.optionButton(0), "calyx.approvalBanner.optionButton.0")
        XCTAssertEqual(AccessibilityID.ApprovalBanner.optionButton(1), "calyx.approvalBanner.optionButton.1")

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.denyButton,
            AccessibilityID.ApprovalBanner.alwaysAllowButton,
            AccessibilityID.ApprovalBanner.payload,
            AccessibilityID.ApprovalBanner.crossActionsMenu,
            AccessibilityID.ApprovalBanner.allowAllPendingItem,
            AccessibilityID.ApprovalBanner.alwaysAllowAllPanesItem,
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
            AccessibilityID.ApprovalBanner.queueMenu,
        ]
        XCTAssertEqual(Set(newIdentifiers).intersection(preExistingIdentifiers), [],
                       "the new question identifiers must be distinct from every pre-existing ApprovalBanner identifier")
        XCTAssertEqual(Set(newIdentifiers).count, newIdentifiers.count,
                       "the new question identifiers must also be distinct from each other")
    }

    // MARK: - answer(id:answers:) / skip(id:) / answerInPane(id:) (AskUserQuestion prompt)

    private func makeAnswers(for prompt: AgentQuestionPrompt) -> AgentQuestionAnswers {
        AgentQuestionAnswers(prompt: prompt, entries: prompt.questions.map { _ in .init(answer: .selectedOne("zsh"), notes: nil) })
    }

    func test_answer_resolvesAnswered_advancesCursor_invokesRestoreFocusOnce() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        guard case .agentQuestion(_, let prompt) = request.source else {
            XCTFail("precondition: request must be .agentQuestion")
            return
        }
        let answers = makeAnswers(for: prompt)

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.answer(id: request.id, answers: answers)

        XCTAssertTrue(store.pending.isEmpty, "answer(id:answers:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")
        XCTAssertEqual(spy.callCount, 1, "answer(id:answers:) must invoke restoreTerminalFocus exactly once")

        let result = await waiter.value
        XCTAssertEqual(result, .answered(answers), "answer(id:answers:) must resolve the awaiter with .answered(answers)")
    }

    func test_cancelQuestion_resolvesDeniedQuestionNotAnswered_advancesCursor_invokesRestoreFocusOnce() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.cancelQuestion(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "cancelQuestion(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")
        XCTAssertEqual(spy.callCount, 1, "cancelQuestion(id:) must invoke restoreTerminalFocus exactly once")

        let result = await waiter.value
        XCTAssertEqual(result, .denied(.questionNotAnswered), "cancelQuestion(id:) must resolve the awaiter with .denied(.questionNotAnswered)")
    }

    /// `cancelQuestion(id:)` is a no-op for a non-question id -- unlike
    /// `cancel(id:)`, which only ever makes sense for `.agentHook`.
    func test_cancelQuestion_onNonQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.cancelQuestion(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "cancelQuestion(id:) must never decide a non-.agentQuestion request")
    }

    // MARK: - chatAboutQuestion(id:)

    func test_chatAboutQuestion_resolvesInterruptedChatAboutQuestion_advancesCursor_invokesRestoreFocusOnce() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.chatAboutQuestion(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "chatAboutQuestion(id:) must decide that request, removing it from pending")
        XCTAssertEqual(spy.callCount, 1, "chatAboutQuestion(id:) must invoke restoreTerminalFocus exactly once")

        let result = await waiter.value
        XCTAssertEqual(result, .interrupted(.chatAboutQuestion))
    }

    /// Mirrors test_allow_onDisplayedRequest_advancesToSuccessor:
    /// chatAboutQuestion(id:) must advance the banner's cursor to the next
    /// queued request, not just clear the queue down to one element.
    func test_chatAboutQuestion_onDisplayedRequest_advancesToSuccessor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        let waiter = Task { @MainActor in await store.awaitDecision(id: second.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.chatAboutQuestion(id: second.id)

        XCTAssertEqual(model.current?.id, third.id,
                       "chatAboutQuestion(id:) on the currently-displayed request must advance the cursor to its successor in the visible queue")

        let result = await waiter.value
        XCTAssertEqual(result, .interrupted(.chatAboutQuestion))
    }

    func test_chatAboutQuestion_onNonQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.chatAboutQuestion(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "chatAboutQuestion(id:) must never decide a non-.agentQuestion request")
    }

    // MARK: - allowWithPermissions(id:offer:) / allowWithInput(id:toolInput:) / cancel(id:)

    private func makeOffer() -> AgentPermissionOffer {
        AgentPermissionOffer(
            label: "Yes, and always allow access to /tmp",
            entryJSON: try! JSONSerialization.data(withJSONObject: ["type": "addDirectories", "directories": ["/tmp"]])
        )
    }

    func test_allowWithPermissions_decidesAllowedWithPermissions_forAgentHookRequest() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        let offer = makeOffer()

        let waiter = Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.allowWithPermissions(id: request.id, offer: offer)

        XCTAssertTrue(store.pending.isEmpty)
        let result = await waiter.value
        XCTAssertEqual(result, .allowedWithPermissions(offer))
    }

    func test_allowWithPermissions_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.allowWithPermissions(id: request.id, offer: makeOffer())

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    func test_allowWithPermissions_onMcpToolID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.allowWithPermissions(id: request.id, offer: makeOffer())

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    func test_allowWithInput_decidesAllowedWithInput_forAgentHookRequest() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        let amendedInput = try! JSONSerialization.data(withJSONObject: ["command": "ls -la /amended"])

        let waiter = Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.allowWithInput(id: request.id, toolInput: amendedInput)

        XCTAssertTrue(store.pending.isEmpty)
        let result = await waiter.value
        XCTAssertEqual(result, .allowedWithInput(amendedInput))
    }

    func test_allowWithInput_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.allowWithInput(id: request.id, toolInput: Data("{}".utf8))

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    func test_cancel_decidesInterruptedCancelled_forAgentHookRequest() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiter = Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.cancel(id: request.id)

        XCTAssertTrue(store.pending.isEmpty)
        let result = await waiter.value
        XCTAssertEqual(result, .interrupted(.cancelled))
    }

    /// Mirrors test_allow_onDisplayedRequest_advancesToSuccessor: cancel(id:)
    /// must advance the banner's cursor to the next queued request, not just
    /// clear the queue down to one element.
    func test_cancel_onDisplayedRequest_advancesToSuccessor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        let waiter = Task { @MainActor in await store.awaitDecision(id: second.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.cancel(id: second.id)

        XCTAssertEqual(model.current?.id, third.id,
                       "cancel(id:) on the currently-displayed request must advance the cursor to its successor in the visible queue")

        let result = await waiter.value
        XCTAssertEqual(result, .interrupted(.cancelled))
    }

    func test_cancel_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.cancel(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    func test_cancel_onMcpToolID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.cancel(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    // MARK: - alwaysAllow/alwaysAllowAcrossPanes no-op when offers.cliOwnsPersistence

    func test_alwaysAllow_agentHookRequest_cliOwnsPersistence_isNoOp() {
        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(
            targetSurfaceID: surfaceID,
            offers: AgentHookOffers(
                permissionUpdates: [], amendableField: nil, originalToolInputJSON: nil,
                canStop: true, canAnswerInPane: true, cliOwnsPersistence: true
            )
        )
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.alwaysAllow(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "alwaysAllow(id:) must be a no-op when the CLI itself owns persistence of the permission decision")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "no pane memory may be recorded either")
    }

    func test_alwaysAllowAcrossPanes_agentHookRequest_cliOwnsPersistence_isNoOp() {
        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(
            targetSurfaceID: surfaceID,
            offers: AgentHookOffers(
                permissionUpdates: [], amendableField: nil, originalToolInputJSON: nil,
                canStop: true, canAnswerInPane: true, cliOwnsPersistence: true
            )
        )
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.alwaysAllowAcrossPanes(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    func test_answerInPane_resolvesExpired_advancesCursor_invokesRestoreFocusOnce() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.answerInPane(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "answerInPane(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")
        XCTAssertEqual(spy.callCount, 1, "answerInPane(id:) must invoke restoreTerminalFocus exactly once")

        let result = await waiter.value
        XCTAssertEqual(result, .expired, "answerInPane(id:) must resolve the awaiter with .expired")
    }

    func test_answerInPane_agentHookRequest_canAnswerInPane_resolvesExpired_invokesRestoreFocusOnce() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(
            targetSurfaceID: surfaceID,
            offers: AgentHookOffers(
                permissionUpdates: [], amendableField: nil, originalToolInputJSON: nil,
                canStop: true, canAnswerInPane: true, cliOwnsPersistence: true
            )
        )
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.answerInPane(id: request.id)

        XCTAssertTrue(store.pending.isEmpty,
                      "answerInPane(id:) must decide an .agentHook request whose offers.canAnswerInPane is true")
        XCTAssertEqual(spy.callCount, 1, "answerInPane(id:) must invoke restoreTerminalFocus exactly once")

        let result = await waiter.value
        XCTAssertEqual(result, .expired, "answerInPane(id:) must resolve the awaiter with .expired")
    }

    func test_answerInPane_agentHookRequest_cannotAnswerInPane_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID, offers: .none)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        model.answerInPane(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "answerInPane(id:) must be a no-op for an .agentHook request whose offers.canAnswerInPane " +
                       "is false: no body reaches the hook, so no CLI-side prompt is waiting to take over")
        XCTAssertEqual(spy.callCount, 0, "a no-op answerInPane(id:) must never invoke restoreTerminalFocus")
    }

    func test_answerInPane_onMcpToolID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        model.answerInPane(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "answerInPane(id:) must be a no-op for an .mcpTool-sourced request")
        XCTAssertEqual(spy.callCount, 0, "a no-op answerInPane(id:) must never invoke restoreTerminalFocus")
    }

    func test_answer_onDisplayedRequest_advancesToSuccessor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
        XCTAssertEqual(model.current?.id, first.id, "precondition: first is the oldest, currently-displayed request")

        guard case .agentQuestion(_, let prompt) = first.source else {
            XCTFail("precondition: request must be .agentQuestion")
            return
        }

        model.answer(id: first.id, answers: makeAnswers(for: prompt))

        XCTAssertEqual(model.current?.id, second.id,
                       "answer(id:answers:) on the currently-displayed request must advance the cursor to its successor")
    }

    func test_restoreTerminalFocusAfterInput_invokesClosureOnce() {
        let store = ApprovalInboxStore()
        let spy = RestoreFocusSpy()
        let model = ApprovalBannerModel(
            store: store, ownsSurface: { _ in false }, isKeyWindow: { true }, restoreTerminalFocus: { spy.call() }
        )

        model.restoreTerminalFocusAfterInput()

        XCTAssertEqual(spy.callCount, 1, "restoreTerminalFocusAfterInput() must invoke restoreTerminalFocus exactly once")
    }

    func test_restoreTerminalFocus_defaultsToNoOp_neverCrashesWhenOmitted() {
        let store = ApprovalInboxStore()
        // No restoreTerminalFocus argument at all -- every pre-existing
        // call site in this file constructs ApprovalBannerModel this way
        // and must remain unaffected by the new parameter.
        let model = ApprovalBannerModel(store: store, ownsSurface: { _ in false }, isKeyWindow: { true })

        model.restoreTerminalFocusAfterInput()
    }

    // MARK: - .agentQuestion requests are excluded from the allow-family actions

    func test_allowAllPending_leavesAgentQuestionRequestsPending() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.allowAllPendingExcludesQuestion"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let mcpRequest = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "mcp")
        let questionRequest = makeAgentQuestionRequest(targetSurfaceID: ownedSurfaceID)
        store.submit(mcpRequest)
        store.submit(questionRequest)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        model.allowAllPending()

        XCTAssertEqual(store.pending.map(\.id), [questionRequest.id],
                       "allowAllPending() must resolve every .mcpTool/.agentHook request but leave every " +
                       ".agentQuestion request pending")
    }

    func test_totalPendingCount_excludesAgentQuestionRequests() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        store.submit(makeRequest(targetSurfaceID: surfaceID, payload: "mcp"))
        store.submit(makeAgentQuestionRequest(targetSurfaceID: surfaceID))

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        XCTAssertEqual(model.totalPendingCount, 1,
                       "totalPendingCount must exclude .agentQuestion requests from the store-wide pending count")
    }

    func test_alwaysAllow_agentHook_neverDrainsAgentQuestionRequest_withSameKindAndToolName() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowNeverDrainsQuestion"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let clicked = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "AskUserQuestion")
        let questionRequest = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(clicked)
        store.submit(questionRequest)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.alwaysAllow(id: clicked.id)

        XCTAssertEqual(store.pending.map(\.id), [questionRequest.id],
                       "alwaysAllow(id:) must never sweep a queued .agentQuestion request into its drain, " +
                       "even sharing the exact same (surface, kind, toolName)")
    }

    func test_alwaysAllowAcrossPanes_neverDrainsAgentQuestionRequest_withSameKindAndToolName() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowAcrossPanesNeverDrainsQuestion"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let clicked = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "AskUserQuestion")
        let questionRequest = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(clicked)
        store.submit(questionRequest)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.alwaysAllowAcrossPanes(id: clicked.id)

        XCTAssertEqual(store.pending.map(\.id), [questionRequest.id],
                       "alwaysAllowAcrossPanes(id:) must never sweep a queued .agentQuestion request into " +
                       "its drain, even sharing the exact same (kind, toolName)")
    }

    // MARK: - allow(id:)/deny(id:)/alwaysAllow(id:)/alwaysAllowAcrossPanes(id:) on an .agentQuestion id are no-ops

    func test_allow_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.allow(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "allow(id:) must never decide an .agentQuestion request")
    }

    func test_deny_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        model.deny(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "deny(id:) must never decide an .agentQuestion request")
    }

    func test_alwaysAllow_onAgentQuestionID_isNoOp_recordsNoMemory() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let memory = AgentHookApprovalMemory()
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.alwaysAllow(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "alwaysAllow(id:) must never decide an .agentQuestion request")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "AskUserQuestion"),
                       "alwaysAllow(id:) on an .agentQuestion request must never record Always-Allow memory")
    }

    func test_alwaysAllowAcrossPanes_onAgentQuestionID_isNoOp_recordsNoMemory() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let memory = AgentHookApprovalMemory()
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

        model.alwaysAllowAcrossPanes(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "alwaysAllowAcrossPanes(id:) must never decide an .agentQuestion request")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "AskUserQuestion"),
                       "alwaysAllowAcrossPanes(id:) on an .agentQuestion request must never record Always-Allow memory")
    }
}
