//
//  CalyxMCPServerCommandEventTests.swift
//  CalyxTests
//
//  TDD Red Phase for CalyxMCPServer's new POST /command-event endpoint,
//  mirroring CalyxMCPServerAgentEventTests' structure for /agent-event.
//
//  Coverage:
//  - Wrong / missing bearer token -> 401
//  - Missing body / malformed JSON body -> 400
//  - Missing / empty X-Calyx-Surface-ID header -> 400 (malformed client)
//  - Body over 262_144 bytes -> 413
//  - Valid raw-UUID header -> 204, ingests a .running record
//  - A session-ID header registered in SessionSurfaceMap -> 204, ingests
//    against the resolved surfaceID
//  - An unresolvable (unregistered) session-ID header -> 204 drop, NOT
//    400 -- a detached persistent session keeps emitting after its pane
//    closes, which is normal steady-state, not a client error
//  - start then end through the endpoint -> a .finished record carrying
//    the script's exit code
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCommandEventTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "test-token-12345"

    /// Test-isolated `agent-endpoint.json` directory -- `tearDown`'s
    /// `server.stop()` still calls `AgentEndpointFile.remove(directory:)`,
    /// same rationale as `CalyxMCPServerAgentEventTests`.
    private var agentEndpointDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func b64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    /// `ts` (epoch milliseconds) is included only when non-nil, so every
    /// existing call site that doesn't pass it keeps decoding exactly as
    /// before (CommandEvent.decode falls back to CommandLogStore.now()).
    private func commandStartBody(cmdID: String, command: String = "ls -la", cwd: String = "/tmp", ts: Date? = nil) -> Data {
        let tsField = ts.map { ",\"ts\":\(Int($0.timeIntervalSince1970 * 1000))" } ?? ""
        return Data("""
        {"phase":"start","cmd_id":"\(cmdID)","command_b64":"\(b64(command))","cwd_b64":"\(b64(cwd))"\(tsField)}
        """.utf8)
    }

    /// `suspended` (a boolean flag distinct from exit_code -- see
    /// ShellIntegrationInstaller.fishIntegrationBody's own doc comment
    /// for why fish must report a suspend this way) is likewise included
    /// only when non-nil.
    private func commandEndBody(cmdID: String, exitCode: Int32?, ts: Date? = nil, suspended: Bool? = nil) -> Data {
        let exitCodeJSON = exitCode.map(String.init) ?? "null"
        let tsField = ts.map { ",\"ts\":\(Int($0.timeIntervalSince1970 * 1000))" } ?? ""
        let suspendedField = suspended.map { ",\"suspended\":\($0)" } ?? ""
        return Data("""
        {"phase":"end","cmd_id":"\(cmdID)","exit_code":\(exitCodeJSON)\(tsField)\(suspendedField)}
        """.utf8)
    }

    private func commandEventRequest(token: String?, surfaceIDHeader: String?, body: Data?) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        return HTTPRequest(method: "POST", path: "/command-event", headers: headers, body: body)
    }

    // MARK: - Authentication

    func test_routeCommandEvent_wrongToken_returns401() async {
        let request = commandEventRequest(
            token: "wrong-token", surfaceIDHeader: UUID().uuidString, body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 401)
    }

    func test_routeCommandEvent_missingToken_returns401() async {
        let request = commandEventRequest(
            token: nil, surfaceIDHeader: UUID().uuidString, body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 401)
    }

    // MARK: - Body validation

    func test_routeCommandEvent_missingBody_returns400() async {
        let request = commandEventRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: nil)

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_routeCommandEvent_malformedJSONBody_returns400() async {
        let request = commandEventRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: Data("not json {{{".utf8)
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_routeCommandEvent_oversizedBody_returns413() async {
        // One byte over the 262_144 cap; the token and surface header are
        // otherwise valid, so this isolates the size-cap behavior alone.
        let oversized = Data(repeating: 0x41, count: 262_145)
        let request = commandEventRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: oversized)

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 413)
    }

    // MARK: - Surface ID header validation

    func test_routeCommandEvent_missingSurfaceIDHeader_returns400() async {
        let request = commandEventRequest(
            token: testToken, surfaceIDHeader: nil, body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_routeCommandEvent_emptySurfaceIDHeader_returns400() async {
        let request = commandEventRequest(
            token: testToken, surfaceIDHeader: "", body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    // MARK: - Surface resolution + ingest

    func test_routeCommandEvent_validRawUUIDHeader_returns204AndIngestsRunningRecord() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let surfaceID = UUID()

        let response = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-1", command: "ls -la", cwd: "/tmp")
        ))

        XCTAssertEqual(response.statusCode, 204)
        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "A valid raw-UUID header must ingest exactly one record")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.cmdID, "cmd-1")
        XCTAssertEqual(record.command, "ls -la")
        XCTAssertEqual(record.cwd, "/tmp")
        XCTAssertEqual(record.state, .running)
    }

    func test_routeCommandEvent_sessionIDHeaderRegisteredInMap_returns204AndIngestsAtResolvedSurface() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let sessionMap = SessionSurfaceMap()
        server.sessionSurfaceMap = sessionMap
        let surfaceID = UUID()
        let sessionID = "session-\(UUID().uuidString)"
        sessionMap.register(sessionID: sessionID, surfaceID: surfaceID)

        let response = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: sessionID,
            body: commandStartBody(cmdID: "cmd-session", command: "npm test", cwd: "/Users/dev/repo")
        ))

        XCTAssertEqual(response.statusCode, 204)
        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1,
                       "A session-ID header registered in SessionSurfaceMap must ingest against the " +
                       "surfaceID it resolves to")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.cmdID, "cmd-session")
        XCTAssertEqual(record.command, "npm test")
        XCTAssertEqual(record.state, .running)
    }

    func test_routeCommandEvent_unresolvableSessionIDHeader_dropsSilently_returns204NoResidueOnceRegistered() async {
        let store = CommandLogStore()
        server.commandLogStore = store
        let sessionMap = SessionSurfaceMap()
        server.sessionSurfaceMap = sessionMap
        let unknownSessionID = "session-never-registered-\(UUID().uuidString)"

        let dropResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: unknownSessionID, body: commandStartBody(cmdID: "cmd-drop")
        ))

        XCTAssertEqual(dropResponse.statusCode, 204,
                       "An unresolvable X-Calyx-Surface-ID (a session ID with no SessionSurfaceMap entry) " +
                       "must be silently dropped -- 204, not an error -- since a detached persistent " +
                       "session can keep emitting after its pane closes")

        // Register that same session ID to a real surface and resend the
        // identical body: if the earlier (unresolvable) drop had left any
        // residue -- e.g. attributed to some wrong/default surfaceID this
        // registration happens to collide with -- this record's count
        // would be inflated above 1.
        let surfaceID = UUID()
        sessionMap.register(sessionID: unknownSessionID, surfaceID: surfaceID)

        let secondResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: unknownSessionID, body: commandStartBody(cmdID: "cmd-drop")
        ))
        XCTAssertEqual(secondResponse.statusCode, 204)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1,
                       "Exactly one record must exist once the session ID is registered and resent -- the " +
                       "earlier drop (while unregistered) must not have left any residue that inflates " +
                       "this count")
    }

    // MARK: - End-to-end lifecycle

    func test_routeCommandEvent_startThenEnd_producesFinishedRecordWithExitCode() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let surfaceID = UUID()

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-e2e", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-e2e", exitCode: 42)
        ))
        XCTAssertEqual(endResponse.statusCode, 204)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "start+end for the same cmd_id must merge into a single record")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.state, .finished)
        XCTAssertEqual(record.exitCode, 42)
    }

    // MARK: - AgentRegistry settle on phase: end (pane-level exit signal)

    // OpenCode and Hermes are the two kinds with no way to report their
    // own process exit: OpenCode's plugin event vocabulary has no
    // process-exit event, and Hermes has no hooks at all. phase: end --
    // the pane's foreground command finishing and the prompt returning --
    // is the signal that settles their row instead.

    func test_routeCommandEvent_phaseEnd_settlesAgentRegistryRowToDone() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-exit", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-exit", exitCode: 0)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "A phase: end command event is the pane's foreground command finishing -- it must " +
                       "settle the surface's Agents row for a CLI kind with no exit hook of its own")

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "The existing commandLogStore ingest behavior must be unchanged")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.state, .finished)
        XCTAssertEqual(record.exitCode, 0)
    }

    func test_routeCommandEvent_phaseStart_doesNotSettleAgentRegistryRow() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.openCodeKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        let response = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-start-only", command: "ls -la", cwd: "/tmp")
        ))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A phase: start command event is the pane's foreground command STARTING, not " +
                       "finishing, and must not settle the Agents row")
        XCTAssertEqual(registry.entries[surfaceID]?.source, .mcpConnection)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "The existing commandLogStore ingest behavior must be unchanged")
        XCTAssertEqual(records.first?.state, .running)
    }

    // MARK: - AgentRegistry settle also expires pending approvals (pane exit)

    // ApprovalRequest.targetSurfaceID scopes a pending Cockpit approval
    // to one surface; ApprovalInboxStore.expireForSurface(_:) is
    // otherwise wired only to SurfaceRegistry's own pane teardown. When
    // only the agent process dies and the pane itself stays open,
    // nothing expires a request still waiting on that dead agent's
    // behalf -- its banner, and its MCP caller's long-poll, would both
    // outlive the process that asked, for up to
    // approvalRequestTimeoutMs. A suspend must not expire anything: the
    // process that asked is still alive, about to resume.

    func test_routeCommandEvent_phaseEndSettlesRow_alsoExpiresPendingApprovalsForThatSurface() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let inbox = ApprovalInboxStore()
        server.approvalInbox = inbox
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID,
            payload: "ls", createdAt: Date()
        )
        inbox.submit(request)
        XCTAssertEqual(inbox.pending.map(\.id), [request.id], "Precondition")

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-approval-exit", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-approval-exit", exitCode: 0)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the pane signal settled the row")
        XCTAssertTrue(inbox.pending.isEmpty,
                      "A phase: end that settles the agent row must also expire that surface's pending approvals")
        let decision = await inbox.awaitDecision(id: request.id, timeoutMs: 250)
        XCTAssertEqual(decision, .expired,
                       "The MCP caller's own long-poll must resolve .expired rather than outlive the dead agent")
    }

    func test_routeCommandEvent_phaseEndSuspend_doesNotExpirePendingApprovals() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let inbox = ApprovalInboxStore()
        server.approvalInbox = inbox
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID,
            payload: "ls", createdAt: Date()
        )
        inbox.submit(request)

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-approval-suspend", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        // 146 = 128 + SIGTSTP: Ctrl-Z suspended the command, the process
        // is still alive.
        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-approval-suspend", exitCode: 146)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A suspend must not settle the row (see the handlePaneCommandFinished suspend-vs-exit tests)")
        XCTAssertEqual(inbox.pending.map(\.id), [request.id],
                       "A suspend must not expire pending approvals -- the agent that asked is still alive")
    }

    // MARK: - AgentRegistry settle: fish's suspend flag (separate from exit_code)

    // fish's own $status inside fish_postexec cannot itself distinguish a
    // Ctrl-Z suspend from the previous command's real exit code (see
    // ShellIntegrationInstaller.fishIntegrationBody's own doc comment),
    // so the shell integration reports a suspend through a separate
    // "suspended" flag instead of overloading exit_code. These tests
    // drive that flag over the wire, through CommandEvent's own
    // suspended property, into the settle decision -- a suspend test
    // should reach for that property rather than hand-parsing the body
    // or adding a second plumbing path. An ordinary exit code (0, 1)
    // alongside "suspended":true is the realistic case: while any job
    // stays stopped in the pane, EVERY later command's own end event
    // carries that same ordinary exit code plus the flag, and it must
    // be excluded from settling exactly like zsh's native stop-signal
    // exit code already is, with the real exit code still recorded in
    // the command log.

    func test_routeCommandEvent_phaseEndSuspendedTrue_ordinaryExitCode0_doesNotSettleOrExpireApprovals() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let inbox = ApprovalInboxStore()
        server.approvalInbox = inbox
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID,
            payload: "ls", createdAt: Date()
        )
        inbox.submit(request)

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-fish-suspend-0", command: "sleep 300", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-fish-suspend-0", exitCode: 0, suspended: true)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "suspended:true with an ordinary exit code must not settle the row -- the pane's " +
                       "foreground job is still alive, merely stopped")
        XCTAssertEqual(inbox.pending.map(\.id), [request.id],
                       "a suspend must not expire pending approvals -- the agent that asked is still alive")

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished)
        XCTAssertEqual(record.exitCode, 0,
                       "the command log must record the real exit code carried on the wire -- never a value " +
                       "derived from the suspended flag, which is the finding this test pins directly")
    }

    func test_routeCommandEvent_phaseEndSuspendedTrue_ordinaryExitCode1_doesNotSettleOrExpireApprovals() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let inbox = ApprovalInboxStore()
        server.approvalInbox = inbox
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID,
            payload: "ls", createdAt: Date()
        )
        inbox.submit(request)

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-fish-suspend-1", command: "npm test", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-fish-suspend-1", exitCode: 1, suspended: true)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "suspended:true must exclude the row from settling regardless of which ordinary exit " +
                       "code accompanies it")
        XCTAssertEqual(inbox.pending.map(\.id), [request.id],
                       "a suspend must not expire pending approvals -- the agent that asked is still alive")

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished)
        XCTAssertEqual(record.exitCode, 1, "the real exit code must be recorded, never a value derived from the flag")
    }

    func test_routeCommandEvent_phaseEndSuspendedFalseExplicit_ordinaryExitCode_settles() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-suspended-false", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-suspended-false", exitCode: 0, suspended: false)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "an explicit suspended:false must settle exactly like the key being absent -- the " +
                       "exclusion must key on the flag's value, not merely its presence in the payload")
    }

    // MARK: - AgentRegistry settle must not fire for an end CommandLogStore rejects

    // CommandLogStore.ingestEnd silently drops an end event that is not
    // a genuine match for the currently running record: one whose ts
    // predates it (a stale end from a previous, already-orphaned
    // instance of a recycled cmd_id), or a duplicate/late end for a
    // cmd_id that's already finalized. The agent-row settle must fire
    // only when the command log itself accepted the end event -- a
    // duplicate or late end the command log drops must not settle a
    // live row either, so a retried curl POST (or any other duplicate/
    // late end) can never kill a live agent row while the command log
    // correctly records nothing.

    func test_routeCommandEvent_endTsPredatesRunningRecord_rejectedByCommandLog_doesNotSettleRow() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.openCodeKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        let runningStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let staleEndTs = Date(timeIntervalSince1970: 1_699_999_000) // Before runningStartedAt.

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-stale-ts", command: "make build", cwd: "/tmp", ts: runningStartedAt)
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-stale-ts", exitCode: 0, ts: staleEndTs)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.state, .running,
                       "Precondition check: CommandLogStore must have actually rejected this end -- the record " +
                       "must still be running, with no exit code recorded")
        XCTAssertNil(records.first?.exitCode)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "An end event the command log itself rejected must not settle the agent row either")
    }

    func test_routeCommandEvent_duplicateEndForAlreadyFinalizedCmdID_rejectedByCommandLog_doesNotSettleRow() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()

        // No agent row exists yet -- this first start+end pair finalizes
        // the command log entirely independently of the agent registry.
        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-dup-end", command: "make build", cwd: "/tmp")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)
        let firstEndResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-dup-end", exitCode: 0)
        ))
        XCTAssertEqual(firstEndResponse.statusCode, 204)
        XCTAssertEqual(store.records(surfaceID: surfaceID, limit: nil, state: nil).first?.state, .finished,
                       "Precondition: the command log finalized this cmd_id")

        // The agent row registers only now, after the command log
        // already finalized cmd-dup-end -- so a settle below could only
        // come from this surface's NEXT end event, not from that first
        // one.
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.openCodeKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        // A retried/duplicate end for the same cmd_id, now already
        // finalized -- CommandLogStore.ingestEnd drops this silently
        // rather than re-finalizing or buffering it.
        let duplicateEndResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-dup-end", exitCode: 1)
        ))

        XCTAssertEqual(duplicateEndResponse.statusCode, 204)
        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1,
                       "Precondition check: the duplicate end must not have created or altered any record")
        XCTAssertEqual(records.first?.exitCode, 0, "The original exit code must be unchanged by the duplicate end")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A duplicate end for an already-finalized cmd_id must not settle the agent row")
    }

    // MARK: - phase: start alone must record Calyx's own shell integration

    // A phase: start event proves Calyx's shell integration is live in
    // this pane just as certainly as a phase: end does. Without
    // recording on .start too, ghostty's own OSC 133 D can arrive
    // first for the very same command -- see AgentRegistry
    // .calyxShellIntegrationReportedSurfaces's own doc comment for the
    // full race -- and settle the row itself before Calyx's own end
    // event ever reaches this endpoint.

    func test_routeCommandEvent_phaseStartAlone_recordsShellIntegration_defersGhosttySettle() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-start-alone", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertFalse(settled,
                       "a phase: start event alone must record that Calyx's own shell integration is live " +
                       "in this pane -- ghostty's fallback signal must defer once that memory exists, even " +
                       "though the start event itself never touches the Agents row")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "the row must stay untouched -- neither the start event nor the deferred ghostty " +
                       "signal may settle it")
    }

    // MARK: - The ghostty-vs-Calyx same-command race this fix exists for

    // Sequence: phase: start records the memory -> ghostty's own
    // pane-exit signal for the SAME command arrives first and must
    // defer -> Calyx's own phase: end then arrives and is the one
    // that settles the row and expires the pending approval. Without
    // the .start recording, ghostty would settle the row itself right
    // here, and the later Calyx end would return false against an
    // already-.done row (settlePaneCommandFinished's own
    // not-already-.done guard), so the approval expiry -- gated on
    // that same return value -- would be silently suppressed.

    func test_routeCommandEvent_phaseStartThenGhosttyRace_phaseEndSettlesRowAndExpiresApproval() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let inbox = ApprovalInboxStore()
        server.approvalInbox = inbox
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID,
            payload: "ls", createdAt: Date()
        )
        inbox.submit(request)
        XCTAssertEqual(inbox.pending.map(\.id), [request.id], "Precondition")

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-ghostty-race", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let ghosttySettled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)
        XCTAssertFalse(ghosttySettled,
                       "ghostty's own signal must defer once Calyx's shell integration has reported on " +
                       "this surface via the earlier start event")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "the deferred ghostty signal must not touch the row")

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-ghostty-race", exitCode: 0)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "Calyx's own phase: end must be the one that settles the row once ghostty's earlier " +
                       "signal deferred to it")
        XCTAssertTrue(inbox.pending.isEmpty,
                      "the settle from Calyx's own phase: end must still expire the surface's pending " +
                      "approval, even though ghostty's signal arrived first and deferred")
        let decision = await inbox.awaitDecision(id: request.id, timeoutMs: 250)
        XCTAssertEqual(decision, .expired,
                       "the MCP caller's own long-poll must resolve .expired rather than outlive the dead agent")
    }

    // MARK: - fish's first-command suspend window

    // Same race as above, but the pane's first command is merely
    // SUSPENDED (Ctrl-Z), not exited. Sequence: phase: start records
    // the memory -> ghostty's own pane-exit signal arrives first and
    // must defer, exactly as above -> fish's own phase: end then
    // arrives carrying suspended: true, which must not settle the row
    // or expire the pending approval. Without the .start recording,
    // ghostty would retire a merely-suspended agent's row right at the
    // deferred-signal step -- handleGhosttyCommandFinished has no
    // suspended parameter and no way to distinguish a stop from a real
    // exit on its own (see that method's own doc comment).

    func test_routeCommandEvent_phaseStartThenGhosttyRace_suspendedPhaseEndLeavesRowPending() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let inbox = ApprovalInboxStore()
        server.approvalInbox = inbox
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID,
            payload: "ls", createdAt: Date()
        )
        inbox.submit(request)

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-fish-first-suspend", command: "sleep 300", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let ghosttySettled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)
        XCTAssertFalse(ghosttySettled,
                       "ghostty's own signal must defer once Calyx's shell integration has reported on " +
                       "this surface via the earlier start event")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "the deferred ghostty signal must not touch the row")

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-fish-first-suspend", exitCode: 0, suspended: true)
        ))

        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "suspended: true must leave the row unsettled -- the pane's foreground job is still " +
                       "alive, merely stopped, even though ghostty's earlier signal already deferred to " +
                       "this same event")
        XCTAssertEqual(inbox.pending.map(\.id), [request.id],
                       "a suspend must not expire pending approvals -- the agent that asked is still alive")
    }
}
