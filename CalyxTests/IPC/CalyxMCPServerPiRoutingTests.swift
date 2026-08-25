//
//  CalyxMCPServerPiRoutingTests.swift
//  CalyxTests
//
//  Coverage for pi's two server routes, driven through
//  `server.route(request:)` with the payloads
//  `PiExtensionManager.scriptBody` actually sends: `POST /agent-event`
//  (row state) and `POST /approval-request` (the kind allowlist).
//
//  pi's extension posts the canonical snake_case envelope Claude Code's
//  hooks already use, so these tests are what prove the claim the design
//  rests on: pi needs no decoder change at all, and the only new server
//  behavior is admitting `pi` to the approval endpoint's kind allowlist.
//
//  The `X-Calyx-Agent-Kind` header carries the literal string the
//  TypeScript sends, never `AgentEntry.piKind`, so these tests exercise
//  the real wire value; the assertions then compare the stored kind
//  against `AgentEntry.piKind`, which is what ties the Swift constant to
//  the TypeScript literal.
//
//  Harness idioms follow CalyxMCPServerGrokRoutingTests: HTTPRequest
//  construction with a direct `route(...)` drive, no sockets, an isolated
//  `agent-endpoint.json` directory, and injected registry / inbox /
//  memory instances.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerPiRoutingTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "pi-routing-test-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerPiRoutingTests"
    private var agentEndpointDir: String!
    private var registry: AgentRegistry!

    /// The literal `X-Calyx-Agent-Kind` value pi's extension sends.
    private let piKindHeaderValue = "pi"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        CockpitSettings._testUseSuite(named: settingsSuiteName)
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        registry = AgentRegistry()
        server.agentRegistry = registry
        server.approvalInbox = ApprovalInboxStore()
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
        registry = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        CockpitSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func agentEventRequest(surfaceID: UUID, body: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: "/agent-event",
            headers: [
                "Authorization": "Bearer \(testToken)",
                "X-Calyx-Surface-ID": surfaceID.uuidString,
                "X-Calyx-Agent-Kind": piKindHeaderValue,
            ],
            body: Data(body.utf8)
        )
    }

    private func postAgentEvent(
        surfaceID: UUID, body: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let response = await server.route(request: agentEventRequest(surfaceID: surfaceID, body: body))
        XCTAssertEqual(response.statusCode, 204,
                       "pi's extension posts the canonical snake_case envelope, which the server must " +
                       "accept without a decoder change",
                       file: file, line: line)
    }

    // MARK: - POST /agent-event

    func test_piSessionStart_createsIdleRowAttributedToPi() async {
        let surfaceID = UUID()

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hook_event_name":"SessionStart","session_id":"01a009d4-e212-7236-ba5f-7b75daf7e70a","cwd":"/Users/dev/repo"}
        """)

        XCTAssertEqual(registry.entries[surfaceID]?.kind, AgentEntry.piKind,
                       "The row must be attributed to pi. AgentEntry.piKind is the Swift end of the same " +
                       "wire contract the extension's header literal is the other end of")
        XCTAssertEqual(registry.entries[surfaceID]?.sessionID, "01a009d4-e212-7236-ba5f-7b75daf7e70a",
                       "The session id pi's extension reads from sessionManager.getSessionId() must land " +
                       "on the row, so a later reattach can offer to resume this conversation")
        XCTAssertEqual(registry.entries[surfaceID]?.cwd, "/Users/dev/repo")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)
    }

    func test_piPromptThenToolThenStop_movesRowWorkingThenIdle() async {
        let surfaceID = UUID()
        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hook_event_name":"SessionStart","session_id":"pi-session-1","cwd":"/repo"}
        """)

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hook_event_name":"UserPromptSubmit","session_id":"pi-session-1","cwd":"/repo"}
        """)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "before_agent_start maps to UserPromptSubmit, which starts the turn")

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hook_event_name":"PostToolUse","session_id":"pi-session-1","cwd":"/repo"}
        """)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "tool_execution_end maps to PostToolUse: a finished tool call means the turn is " +
                       "still running")

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hook_event_name":"Stop","session_id":"pi-session-1","cwd":"/repo"}
        """)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "agent_end maps to Stop, which settles the row")
        XCTAssertEqual(registry.entries[surfaceID]?.kind, AgentEntry.piKind)
    }

    func test_piSessionShutdown_settlesRowDone() async {
        let surfaceID = UUID()
        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hook_event_name":"SessionStart","session_id":"pi-session-1","cwd":"/repo"}
        """)

        await postAgentEvent(surfaceID: surfaceID, body: """
        {"hook_event_name":"SessionEnd","session_id":"pi-session-1","cwd":"/repo"}
        """)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "session_shutdown maps to SessionEnd: the pi process is gone and the row must " +
                       "stop claiming a live agent")
        XCTAssertEqual(registry.entries[surfaceID]?.kind, AgentEntry.piKind)
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

    /// What pi's `tool_call` handler posts: the canonical
    /// PermissionRequest envelope, so the request passes
    /// `ApprovalHookEvent.isApprovalGate` with no server-side change.
    private let piApprovalBody = """
    {"hook_event_name":"PermissionRequest","session_id":"pi-session-1","cwd":"/repo",
     "tool_name":"bash","tool_input":{"command":"rm -rf build"}}
    """

    func test_approvalRequest_piKind_isRecognized_andStillRejectsAKindWithNoContract() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true

        let response = await server.route(
            request: approvalRequest(kind: piKindHeaderValue, body: piApprovalBody)
        )

        XCTAssertEqual(response.statusCode, 200)
        let data = try XCTUnwrap(response.body,
                                 "pi must not fall into the unrecognized-kind branch, whose answer is an " +
                                 "empty body. pi ships no permission prompt of its own, so an inert gate " +
                                 "means every pi tool call runs unreviewed with nothing on screen to " +
                                 "reveal it")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["decision"] as? String, "allow",
                       "pi's extension reads a flat top-level decision, not Claude Code's nested envelope")

        let unknown = await server.route(
            request: approvalRequest(kind: AgentEntry.hermesKind, body: piApprovalBody)
        )
        XCTAssertEqual(unknown.statusCode, 200)
        XCTAssertNil(unknown.body,
                     "Admitting pi must not open the allowlist generally: guessing at an unknown CLI's " +
                     "own gate contract risks silently authorizing a dangerous call")
    }
}
