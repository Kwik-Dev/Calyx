//
//  CalyxMCPServerGrokRoutingTests.swift
//  CalyxTests
//
//  End-to-end coverage for Grok's two server routes, driven through
//  `server.route(request:)` with real Grok-shaped payloads rather than
//  through the decoder alone: `POST /agent-event` (row state) and
//  `POST /approval-request` (the kind allowlist).
//
//  These pin the seams the decoder tests cannot reach on their own:
//  that a Grok payload survives the whole route (an event the decoder
//  rejects becomes a 400 and no row at all), that the approval endpoint
//  recognizes `grok` as a kind it has a response contract for, and that
//  it holds a Grok tool call for a human only in the permission mode
//  where nothing else would ask one.
//
//  Harness idioms follow CalyxMCPServerAgentEventTests and
//  CalyxMCPServerApprovalRequestTests: HTTPRequest construction with a
//  direct `route(...)` drive, no sockets, an isolated
//  `agent-endpoint.json` directory, and injected registry / inbox /
//  memory instances.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerGrokRoutingTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "grok-routing-test-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerGrokRoutingTests"
    private var agentEndpointDir: String!
    private var registry: AgentRegistry!
    private var approvalInbox: ApprovalInboxStore!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        CockpitSettings._testUseSuite(named: settingsSuiteName)
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        registry = AgentRegistry()
        server.agentRegistry = registry
        approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
        registry = nil
        approvalInbox = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        CockpitSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Bounded scheduler drain, the same idiom the other approval-route
    /// suites use to let a held route reach its long-poll before the
    /// test inspects the inbox.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    private func agentEventRequest(surfaceID: UUID, body: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: "/agent-event",
            headers: [
                "Authorization": "Bearer \(testToken)",
                "X-Calyx-Surface-ID": surfaceID.uuidString,
                "X-Calyx-Agent-Kind": AgentEntry.grokKind,
            ],
            body: Data(body.utf8)
        )
    }

    @discardableResult
    private func postAgentEvent(
        surfaceID: UUID, body: String, file: StaticString = #filePath, line: UInt = #line
    ) async -> Int {
        let response = await server.route(request: agentEventRequest(surfaceID: surfaceID, body: body))
        XCTAssertEqual(response.statusCode, 204,
                       "a Grok hook payload must be accepted, not rejected as undecodable",
                       file: file, line: line)
        return response.statusCode
    }

    // MARK: - POST /agent-event

    func test_grokSessionStart_createsIdleRowWithGrokKind() async {
        let surfaceID = UUID()

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"session_start","sessionId":"grok-session-1","cwd":"/Users/dev/repo"}
        """)

        XCTAssertEqual(registry.entries[surfaceID]?.kind, AgentEntry.grokKind)
        XCTAssertEqual(registry.entries[surfaceID]?.sessionID, "grok-session-1")
        XCTAssertEqual(registry.entries[surfaceID]?.cwd, "/Users/dev/repo")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)
    }

    func test_grokUserPromptSubmitThenStop_movesRowWorkingThenIdle() async {
        let surfaceID = UUID()
        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"session_start","sessionId":"grok-session-1","cwd":"/repo"}
        """)

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"user_prompt_submit","sessionId":"grok-session-1","cwd":"/repo"}
        """)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"stop","sessionId":"grok-session-1","cwd":"/repo","reason":"end_turn"}
        """)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A genuine turn end settles the row")
    }

    func test_grokPermissionPromptNotification_blocksRow() async {
        let surfaceID = UUID()
        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"session_start","sessionId":"grok-session-1","cwd":"/repo"}
        """)

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"notification","sessionId":"grok-session-1","cwd":"/repo",
         "notificationType":"permission_prompt","message":"Grok wants to run a command"}
        """)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A waiting permission prompt Calyx did not raise itself (Grok asking directly, " +
                       "or an approval hook that failed open) must still show the pane as blocked")
    }

    func test_grokSessionEndThenTeardownStop_rowStaysDone() async {
        let surfaceID = UUID()
        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"session_start","sessionId":"grok-session-1","cwd":"/repo"}
        """)
        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"session_end","sessionId":"grok-session-1","cwd":"/repo","reason":"shutdown"}
        """)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the session ended")

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"stop","sessionId":"grok-session-1","cwd":"/repo","reason":"channel_closed"}
        """)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "Grok fires an extra observe-only stop during teardown, after SessionEnd. Without " +
                       "the reason filter the finished row would flip back to idle and the pane would " +
                       "look like it still had a live agent in it")
    }

    func test_grokSubagentEvent_isAccepted_andLeavesTheHostRowAlone() async {
        let surfaceID = UUID()
        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"session_start","sessionId":"grok-session-1","cwd":"/repo"}
        """)

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hookEventName":"pre_tool_use","sessionId":"child-session-9","cwd":"/elsewhere",
         "subagentType":"explore","toolName":"read_file"}
        """)

        XCTAssertEqual(registry.entries.count, 1, "A subagent must never mint a row of its own")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A child agent's tool call is not the host session's state")
        XCTAssertEqual(registry.entries[surfaceID]?.sessionID, "grok-session-1",
                       "The host row must keep its own session ID; adopting the child's would make a " +
                       "later reattach offer to resume the subagent instead of the conversation")
        XCTAssertEqual(registry.entries[surfaceID]?.cwd, "/repo")
    }

    // MARK: - POST /approval-request kind allowlist

    private func approvalRequest(kind: String, body: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: "/approval-request",
            headers: [
                "Authorization": "Bearer \(testToken)",
                "X-Calyx-Surface-ID": UUID().uuidString,
                "X-Calyx-Agent-Kind": kind,
            ],
            body: Data(body.utf8)
        )
    }

    /// The Claude Code / Codex envelope, so a failure here isolates the
    /// kind allowlist from the payload shape. Carries the always-approve
    /// mode because a grok request is only held for a decision there.
    private let claudeShapedApprovalBody = """
    {"tool_name":"Bash","tool_input":{"command":"ls -la"},"hook_event_name":"PermissionRequest",
     "permissionMode":"bypassPermissions"}
    """

    /// What `calyx-approval-hook` actually forwards from a Grok
    /// PreToolUse gate: camelCase keys, a snake_case event value, and
    /// Grok's own shell tool name.
    private let grokShapedApprovalBody = """
    {"hookEventName":"pre_tool_use","sessionId":"grok-session-1","cwd":"/repo",
     "permissionMode":"bypassPermissions",
     "toolName":"run_terminal_command","toolInput":{"command":"rm -rf build"}}
    """

    /// The same real payload in the mode a Grok session runs in by
    /// default, where Grok's own permission pipeline still stands behind
    /// the gate.
    private let grokShapedApprovalBodyInDefaultMode = """
    {"hookEventName":"pre_tool_use","sessionId":"grok-session-1","cwd":"/repo",
     "permissionMode":"default",
     "toolName":"run_terminal_command","toolInput":{"command":"rm -rf build"}}
    """

    func test_approvalRequest_grokKind_isRecognized_andAnswersInGroksVocabulary() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true

        let response = await server.route(
            request: approvalRequest(kind: AgentEntry.grokKind, body: claudeShapedApprovalBody)
        )

        XCTAssertEqual(response.statusCode, 200)
        let data = try XCTUnwrap(response.body,
                                 "grok must not fall into the unrecognized-kind branch, whose answer is " +
                                 "an empty body")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["decision"] as? String, "allow",
                       "Grok reads a flat top-level decision, not Claude Code's nested envelope")
    }

    /// The payload the approval gate really receives has to reach a
    /// decision. Grok's PreToolUse envelope names neither `tool_name`
    /// nor `hook_event_name`, so a route that only recognizes the Claude
    /// Code spelling answers with an empty body and the gate is inert:
    /// in an always-approve session, the one this payload comes from,
    /// that means every tool call runs unreviewed with nothing on screen
    /// to reveal it.
    func test_approvalRequest_grokShapedPayload_reachesADecision() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true

        let response = await server.route(
            request: approvalRequest(kind: AgentEntry.grokKind, body: grokShapedApprovalBody)
        )

        XCTAssertEqual(response.statusCode, 200)
        let data = try XCTUnwrap(response.body,
                                 "A real Grok PreToolUse payload must not short-circuit to the inert " +
                                 "empty-body branch")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["decision"] as? String, "allow")
    }

    // MARK: - POST /approval-request permission-mode gate
    //
    // Grok's gate is PreToolUse, which runs before its permission system
    // rather than in place of it: a hook deny stops a call, while a hook
    // allow only declines to deny and falls through to Grok's own
    // deny/ask rules and in-pane prompt. So a banner is Calyx's to raise
    // only under `bypassPermissions`, where that pipeline runs the call
    // without asking anyone. In every other mode Calyx answers with no
    // decision at all, leaving Grok to decide exactly as it would if
    // Calyx were not installed: raising a banner there would ask the same
    // human twice and, unanswered, would turn "ask in the pane" into
    // "refuse".

    func test_approvalRequest_grokDefaultMode_staysSilentAndQueuesNothing() async {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = false
        server.approvalSurfaceExists = { _ in true }

        let response = await server.route(
            request: approvalRequest(kind: AgentEntry.grokKind, body: grokShapedApprovalBodyInDefaultMode)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body,
                     "Grok's own prompt still stands behind the gate in default mode, and a Calyx allow " +
                     "could not answer it: the only non-duplicating answer is no decision at all")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "No banner may be raised for a call Grok is about to ask about itself: an " +
                      "unanswered one would expire into a deny, refusing what the human was never asked")
    }

    func test_approvalRequest_grokMissingPermissionMode_staysSilent() async {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = false
        server.approvalSurfaceExists = { _ in true }

        let bodyWithoutMode = """
        {"hookEventName":"pre_tool_use","sessionId":"grok-session-1","cwd":"/repo",
         "toolName":"run_terminal_command","toolInput":{"command":"rm -rf build"}}
        """

        let response = await server.route(
            request: approvalRequest(kind: AgentEntry.grokKind, body: bodyWithoutMode)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body,
                     "An absent mode is not bypassPermissions. Assuming it were would gate calls Grok " +
                     "prompts for itself, and deny the ones nobody answered in time")
        XCTAssertTrue(approvalInbox.pending.isEmpty)
    }

    func test_approvalRequest_grokBypassPermissions_isHeldForAHumanDecision() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = false
        server.approvalSurfaceExists = { _ in true }

        let task = Task { @MainActor in
            await self.server.route(
                request: self.approvalRequest(kind: AgentEntry.grokKind, body: self.grokShapedApprovalBody)
            )
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "Always-approve is the one mode with no prompt behind the gate, so this is where " +
                       "Calyx's banner is the only thing that can review the call")
        guard let requestID = approvalInbox.pending.first?.id else {
            // Drain the held route so this test doesn't leak a suspended Task.
            task.cancel()
            _ = await task.value
            return
        }
        approvalInbox.decide(id: requestID, .denied)

        let response = await task.value
        let data = try XCTUnwrap(response.body, "A decided grok request answers in Grok's own vocabulary")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["decision"] as? String, "deny")
    }

    /// The mode gate is grok-scoped: Claude Code's PermissionRequest
    /// fires only for calls it has already decided to prompt about, and
    /// the hook's answer IS that prompt's answer, whatever mode the
    /// session runs in.
    func test_approvalRequest_claudeCodeInDefaultMode_stillReachesADecision() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true

        let body = """
        {"tool_name":"Bash","tool_input":{"command":"ls -la"},"hook_event_name":"PermissionRequest",
         "permissionMode":"default"}
        """

        let response = await server.route(
            request: approvalRequest(kind: AgentEntry.claudeCodeKind, body: body)
        )

        XCTAssertEqual(response.statusCode, 200)
        let data = try XCTUnwrap(response.body,
                                 "Grok's mode rule must not leak into the kinds whose gate fires only " +
                                 "for calls they would prompt for")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
    }

    func test_approvalRequest_stillRejectsAKindWithNoResponseContract() async {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true

        let response = await server.route(
            request: approvalRequest(kind: AgentEntry.hermesKind, body: claudeShapedApprovalBody)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body,
                     "Admitting grok must not open the allowlist generally: guessing at an unknown CLI's " +
                     "hook stdout shape risks silently authorizing a dangerous call")
    }
}
