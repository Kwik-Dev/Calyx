//
//  CalyxMCPServerSessionRoutingTests.swift
//  CalyxTests
//
//  Covers CalyxMCPServer's session -> surface resolution: a
//  persistent-session pane's calyx-agent-hook sends its stable
//  calyx-session ID (see AgentHookScriptSessionIDTests) in the same
//  X-Calyx-Surface-ID header a legacy pane sends its raw surface UUID
//  in. `route(request:)` must resolve a value that isn't a UUID via
//  the injected SessionSurfaceMap before giving up with 400.
//
//  Direct route(request:) style, matching CalyxMCPServerAgentEventTests
//  — no real NWConnection involved.
//
//  Coverage:
//  - A registered calyx-session ID in the header resolves to its
//    mapped surface UUID; the registry entry is keyed by that UUID
//  - An unresolvable (unregistered, non-UUID) value still 400s, same
//    as today's malformed-header behavior
//  - A plain surface UUID header keeps working unchanged (non-regression)
//  - /mcp must get the same session-ID
//    fallback /agent-event already has — today routeMCP intentionally
//    keeps using parseSurfaceID directly and does NOT fall back to
//    SessionSurfaceMap, so an MCP client running inside a
//    persistent-session pane (e.g. Claude Code's own MCP connection,
//    which reads the same CALYX_SESSION_ID/CALYX_SURFACE_ID
//    precedence) loses its surface binding across a reconnect even
//    though the /agent-event hook path already survives one
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerSessionRoutingTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "test-token-session-routing"
    private var agentEndpointDir: String!

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        // Isolated instance — never touch .shared, which other suites read.
        server.sessionSurfaceMap = SessionSurfaceMap()
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

    private func validAgentEventBody(sessionID: String = "claude-session-1", cwd: String = "/Users/dev/repo") -> Data {
        Data("""
        {"hook_event_name":"SessionStart","session_id":"\(sessionID)","cwd":"\(cwd)"}
        """.utf8)
    }

    private func sessionEndBody(sessionID: String) -> Data {
        Data("""
        {"hook_event_name":"SessionEnd","session_id":"\(sessionID)"}
        """.utf8)
    }

    private func agentEventRequest(token: String?, surfaceIDHeader: String?, body: Data?) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        return HTTPRequest(method: "POST", path: "/agent-event", headers: headers, body: body)
    }

    // MARK: - calyx-session ID resolution

    func test_agentEvent_headerCarriesRegisteredCalyxSessionID_resolvesToMappedSurface() async {
        let calyxSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        server.sessionSurfaceMap.register(sessionID: calyxSessionID, surfaceID: surfaceID)

        let request = agentEventRequest(token: testToken, surfaceIDHeader: calyxSessionID, body: validAgentEventBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 204,
                       "A calyx-session ID registered in SessionSurfaceMap must resolve and succeed, not 400")
        XCTAssertEqual(server.agentRegistry.entries.count, 1)
        XCTAssertNotNil(server.agentRegistry.entries[surfaceID],
                        "The registry entry must be keyed by the RESOLVED surface UUID, not the raw " +
                        "calyx-session ID string")
    }

    func test_agentEvent_unregisteredCalyxSessionID_returns400() async {
        let unregisteredSessionID = "01UNKNOWNZZZZZZZZZZZZZZZZZ"

        let request = agentEventRequest(token: testToken, surfaceIDHeader: unregisteredSessionID, body: validAgentEventBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400,
                       "A session ID SessionSurfaceMap cannot resolve must still 400, exactly like any " +
                       "other unresolvable X-Calyx-Surface-ID value")
    }

    // MARK: - Non-regression: plain surface UUID unaffected

    func test_agentEvent_plainSurfaceUUIDHeader_stillWorksUnchanged() async {
        let surfaceID = UUID()

        let request = agentEventRequest(token: testToken, surfaceIDHeader: surfaceID.uuidString, body: validAgentEventBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNotNil(server.agentRegistry.entries[surfaceID],
                        "An ordinary (non-persistent-session) pane's raw surface UUID must keep working " +
                        "exactly as before")
    }

    // MARK: - routeMCP session-ID fallback

    private func mcpRequest(
        token: String?,
        surfaceIDHeader: String?,
        sessionIDHeader: String? = nil,
        agentKind: String? = nil,
        body: Data
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        if let sessionIDHeader { headers["X-Calyx-Session-ID"] = sessionIDHeader }
        if let agentKind { headers["X-Calyx-Agent-Kind"] = agentKind }
        return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body)
    }

    private func initializeRequestBody(id: Int) -> Data {
        let dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    func test_routeMCP_headerCarriesRegisteredCalyxSessionID_resolvesToMappedSurfaceForPeerBinding() async throws {
        let calyxSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        server.sessionSurfaceMap.register(sessionID: calyxSessionID, surfaceID: surfaceID)

        let initResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: calyxSessionID, body: initializeRequestBody(id: 1)
        ))

        XCTAssertEqual(initResponse.statusCode, 200, "initialize must still succeed regardless of header resolution")
        let data = try XCTUnwrap(initResponse.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let instructions = try XCTUnwrap(result["instructions"] as? String)

        XCTAssertTrue(
            instructions.contains("Your peer_id is:"),
            "/mcp must resolve a calyx-session ID via SessionSurfaceMap the same way /agent-event does, " +
            "so initialize auto-registers and binds a peer for the resolved surface — today routeMCP only " +
            "calls parseSurfaceID directly, which fails on a non-UUID session ID, so no peer is registered at all"
        )
    }

    func test_routeMCP_separateSessionHeaderTakesPriorityAndRegistersAgentOnCurrentSurface() async {
        let calyxSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let staleSurfaceID = UUID()
        let currentSurfaceID = UUID()
        server.sessionSurfaceMap.register(sessionID: calyxSessionID, surfaceID: currentSurfaceID)

        let response = await server.route(request: mcpRequest(
            token: testToken,
            surfaceIDHeader: staleSurfaceID.uuidString,
            sessionIDHeader: calyxSessionID,
            agentKind: AgentEntry.hermesKind,
            body: initializeRequestBody(id: 2)
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(server.agentRegistry.entries[staleSurfaceID])
        XCTAssertEqual(server.agentRegistry.entries[currentSurfaceID]?.kind, AgentEntry.hermesKind)
    }

    func test_routeMCP_unresolvedSeparateSessionHeaderFallsBackToSurfaceHeader() async {
        let surfaceID = UUID()

        let response = await server.route(request: mcpRequest(
            token: testToken,
            surfaceIDHeader: surfaceID.uuidString,
            sessionIDHeader: "${CALYX_SESSION_ID}",
            agentKind: AgentEntry.hermesKind,
            body: initializeRequestBody(id: 3)
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(server.agentRegistry.entries[surfaceID]?.kind, AgentEntry.hermesKind)
    }

    // MARK: - Regression: one daemon-leaked stale surface header shared by multiple panes

    /// A persistent calyx-session daemon spawns every session shell as its
    /// own child process, so a CALYX_SURFACE_ID inherited from whichever
    /// pane first started the daemon leaks into every session it spawns
    /// afterward, across Calyx restarts, giving unrelated panes the
    /// daemon's own stale surface UUID. Reproduces that leak with two
    /// concurrent sessions: both initialize requests carry the identical
    /// stale surface header, but each pane's own distinct session header
    /// must still resolve to its own surface, keeping the two Agents rows
    /// separate rather than collapsing into one.
    func test_routeMCP_twoConcurrentSessionsSharingOneStaleSurfaceHeader_registryGetsTwoDistinctEntries() async {
        let staleSurfaceID = UUID()
        let sessionA = "01SESSION-A-CONCURRENT-CODEX-TEST"
        let sessionB = "01SESSION-B-CONCURRENT-CODEX-TEST"
        let surfaceA = UUID()
        let surfaceB = UUID()
        server.sessionSurfaceMap.register(sessionID: sessionA, surfaceID: surfaceA)
        server.sessionSurfaceMap.register(sessionID: sessionB, surfaceID: surfaceB)

        let responseA = await server.route(request: mcpRequest(
            token: testToken,
            surfaceIDHeader: staleSurfaceID.uuidString,
            sessionIDHeader: sessionA,
            agentKind: AgentEntry.codexKind,
            body: initializeRequestBody(id: 1)
        ))
        let responseB = await server.route(request: mcpRequest(
            token: testToken,
            surfaceIDHeader: staleSurfaceID.uuidString,
            sessionIDHeader: sessionB,
            agentKind: AgentEntry.codexKind,
            body: initializeRequestBody(id: 2)
        ))

        XCTAssertEqual(responseA.statusCode, 200)
        XCTAssertEqual(responseB.statusCode, 200)
        XCTAssertEqual(server.agentRegistry.entries.count, 2,
                       "Two distinct calyx-session IDs sharing one stale, daemon-leaked surface header " +
                       "must produce two distinct Agents rows, not collapse into one")
        XCTAssertEqual(server.agentRegistry.entries[surfaceA]?.kind, AgentEntry.codexKind)
        XCTAssertEqual(server.agentRegistry.entries[surfaceB]?.kind, AgentEntry.codexKind)
        XCTAssertNil(server.agentRegistry.entries[staleSurfaceID],
                     "The stale, daemon-leaked surface UUID must never itself get a registry entry")
    }

    /// A persistent-session pane's Claude Code process ends (SessionEnd)
    /// and Codex starts in the same tab afterward, so the resolved surface
    /// already holds a done Claude Code row when Codex's initialize
    /// request arrives, carrying an unrelated, daemon-leaked stale surface
    /// header. Pins that the occupying entry is replaced in place: kind,
    /// source, and state all change, and cwd carries over from the row it
    /// replaced rather than being reset, which is what shows a replace
    /// happened rather than a fresh insert. Does not pin anything
    /// `.done`-specific: `AgentRegistry.handleMCPConnection` replaces a
    /// different-kind `.hooks` entry regardless of its prior state, so a
    /// still-active row would be replaced identically.
    func test_routeMCP_codexInitializeReplacesDoneClaudeCodeEntryOnSameResolvedSurface() async {
        let calyxSessionID = "01SESSION-REPLACEMENT-CODEX-TEST"
        let surfaceA = UUID()
        let unrelatedStaleSurfaceID = UUID()
        server.sessionSurfaceMap.register(sessionID: calyxSessionID, surfaceID: surfaceA)

        // Seed a done Claude Code row on surfaceA through the registry's
        // own hook-event API (SessionStart then SessionEnd), the same path
        // a real Claude Code pane drives it through.
        let seedSessionID = "claude-session-being-replaced"
        let startResponse = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: validAgentEventBody(sessionID: seedSessionID)
        ))
        XCTAssertEqual(startResponse.statusCode, 204)
        let endResponse = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: sessionEndBody(sessionID: seedSessionID)
        ))
        XCTAssertEqual(endResponse.statusCode, 204)
        XCTAssertEqual(server.agentRegistry.entries[surfaceA]?.kind, AgentEntry.claudeCodeKind)
        XCTAssertEqual(server.agentRegistry.entries[surfaceA]?.state, .done)

        let response = await server.route(request: mcpRequest(
            token: testToken,
            surfaceIDHeader: unrelatedStaleSurfaceID.uuidString,
            sessionIDHeader: calyxSessionID,
            agentKind: AgentEntry.codexKind,
            body: initializeRequestBody(id: 1)
        ))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(server.agentRegistry.entries[surfaceA]?.kind, AgentEntry.codexKind,
                       "The surviving entry must be Codex's, not the old done Claude Code one")
        XCTAssertEqual(server.agentRegistry.entries[surfaceA]?.source, .mcpConnection,
                       "The surviving entry must no longer carry the seeded row's .hooks source")
        XCTAssertEqual(server.agentRegistry.entries[surfaceA]?.state, .idle,
                       "The replacement resets state; it is not gated on the seeded row having been .done")
        XCTAssertEqual(server.agentRegistry.entries[surfaceA]?.cwd, "/Users/dev/repo",
                       "The surviving entry must carry over the cwd of the row it replaced, proving a " +
                       "replace happened rather than a fresh insert")
        XCTAssertNil(server.agentRegistry.entries[unrelatedStaleSurfaceID],
                     "The unrelated stale surface header must never itself get a registry entry")
    }
}
