//
//  AgentEventGrokDecodeTests.swift
//  CalyxTests
//
//  Coverage for AgentEvent.decode(from:)'s Grok payload shape. Grok's
//  hook stdin envelope disagrees with Claude Code's on both axes at
//  once: the keys are camelCase (`hookEventName`, `sessionId`) and the
//  event VALUES are snake_case (`pre_tool_use`, not `PreToolUse`). A
//  `/bin/sh` hook script cannot rewrite JSON, so the normalization
//  happens here, at the decoder.
//
//  Contract, from ~/.grok/docs/user-guide/10-hooks.md:
//  - The Grok branch is entered only when `hook_event_name` is absent
//    AND `hookEventName` is present. A payload carrying both stays on
//    the Claude Code / Codex path untouched.
//  - Only `hookEventName` is required. Every other field is optional,
//    so the minimal payload `{"hookEventName":"pre_tool_use"}` must
//    decode.
//  - `stop` fires an extra observe-only time at session teardown with
//    `reason` `channel_closed` or `shutdown`; only `end_turn` (or an
//    absent reason) is a genuine turn end. The teardown fires must not
//    resolve to `Stop`, or a `SessionEnd`-driven `.done` row would roll
//    back to `.idle`.
//  - `notification` carries `notificationType`; `permission_prompt` is
//    the only type that fires while a permission UI is actually
//    waiting. Its `message` is display text that changes between
//    releases, so the type is what gets matched, never the message.
//  - Events that can fire inside a subagent carry `subagentType`. Those
//    must not touch the host pane's row at all: the event name is left
//    as the unmapped raw value (so `resultingState` ignores it) and
//    `sessionID` / `cwd` are stripped, because a recorded child session
//    ID would make a later reattach offer `grok --resume <child>`.
//  - The Grok branch never extracts `ipcSelfPeerID`: Grok's peer binding
//    is established through the MCP `initialize` surface header instead.
//

import XCTest
@testable import Calyx

final class AgentEventGrokDecodeTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// Decodes `payload` and asserts only the resulting `hookEventName`,
    /// the single fact the event-name mapping table is about.
    private func assertMapping(
        _ payload: String,
        to expected: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json(payload)), message, file: file, line: line)
        XCTAssertEqual(event.hookEventName, expected, message, file: file, line: line)
    }

    // MARK: - Minimal payload (schema-required fields only)

    func test_decode_grokMinimalPayload_carriesOnlyHookEventName() throws {
        let event = try XCTUnwrap(
            AgentEvent.decode(from: json(#"{"hookEventName":"pre_tool_use"}"#)),
            "hookEventName is the only field Grok's envelope guarantees, so a payload carrying " +
            "nothing else must still decode"
        )

        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.cwd)
        XCTAssertNil(event.message)
        XCTAssertNil(event.ipcSelfPeerID)
    }

    func test_decode_neitherHookEventNameKey_returnsNil() throws {
        // Precondition: the camelCase key alone must decode, so the nil
        // below is caused by both keys being absent and not by the Grok
        // branch simply never being reachable.
        XCTAssertNotNil(AgentEvent.decode(from: json(#"{"hookEventName":"session_start"}"#)),
                        "Precondition: a camelCase-only payload must decode")

        XCTAssertNil(AgentEvent.decode(from: json(#"{"sessionId":"abc-123","cwd":"/repo"}"#)),
                     "A payload naming neither hook_event_name nor hookEventName is not a hook event")
    }

    // MARK: - Field aliasing

    func test_decode_grokPreToolUse_documentedPayload_populatesAliasedFields() throws {
        // The literal PreToolUse example from
        // ~/.grok/docs/user-guide/10-hooks.md's "Input" section.
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {
            "hookEventName": "pre_tool_use",
            "sessionId": "abc-123",
            "cwd": "/Users/you/project",
            "workspaceRoot": "/Users/you/project",
            "permissionMode": "default",
            "toolName": "run_terminal_command",
            "toolInput": { "command": "npm test" },
            "timestamp": "2026-04-14T12:00:00Z"
        }
        """)))

        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertEqual(event.sessionID, "abc-123",
                       "Grok spells the session identifier sessionId, not session_id")
        XCTAssertEqual(event.cwd, "/Users/you/project")
    }

    // MARK: - Event name mapping

    func test_decode_grokSessionStart_mapsToSessionStart() throws {
        try assertMapping(#"{"hookEventName":"session_start","sessionId":"s1","source":"startup"}"#,
                          to: "SessionStart", "session_start maps to SessionStart")
    }

    func test_decode_grokUserPromptSubmit_mapsToUserPromptSubmit() throws {
        try assertMapping(#"{"hookEventName":"user_prompt_submit","sessionId":"s1","promptId":"p1"}"#,
                          to: "UserPromptSubmit", "user_prompt_submit maps to UserPromptSubmit")
    }

    func test_decode_grokPostToolUse_mapsToPostToolUse() throws {
        try assertMapping(#"{"hookEventName":"post_tool_use","sessionId":"s1","toolName":"read_file"}"#,
                          to: "PostToolUse", "post_tool_use maps to PostToolUse")
    }

    func test_decode_grokPostToolUseFailure_mapsToPostToolUse() throws {
        try assertMapping(#"{"hookEventName":"post_tool_use_failure","sessionId":"s1","toolName":"read_file"}"#,
                          to: "PostToolUse",
                          "A failed tool call still means the turn is running, so post_tool_use_failure " +
                          "settles the row the same way post_tool_use does")
    }

    func test_decode_grokSessionEnd_mapsToSessionEnd() throws {
        try assertMapping(#"{"hookEventName":"session_end","sessionId":"s1","reason":"shutdown"}"#,
                          to: "SessionEnd", "session_end maps to SessionEnd")
    }

    func test_decode_grokStopFailure_mapsToStop() throws {
        try assertMapping(#"{"hookEventName":"stop_failure","sessionId":"s1","error":"rate_limit"}"#,
                          to: "Stop",
                          "stop_failure runs instead of stop when a turn ends on an API error: the turn " +
                          "is over, so the row settles to idle")
    }

    func test_decode_grokStopCancelled_mapsToStop() throws {
        try assertMapping("""
        {"hookEventName":"stop_cancelled","sessionId":"s1","reason":"permission_rejected","cancelledBy":"user"}
        """,
                          to: "Stop",
                          "stop_cancelled runs instead of stop when a turn is interrupted or its " +
                          "permission prompt is declined, and must release a blocked row back to idle")
    }

    func test_decode_grokUnknownEventName_passesRawValueThrough() throws {
        try assertMapping(#"{"hookEventName":"pre_compact","sessionId":"s1"}"#,
                          to: "pre_compact",
                          "An event Calyx does not map is passed through verbatim, so resultingState " +
                          "ignores it rather than the decoder inventing a state change")
    }

    // MARK: - stop: the reason field decides

    func test_decode_grokStop_endTurn_mapsToStop() throws {
        try assertMapping(#"{"hookEventName":"stop","sessionId":"s1","reason":"end_turn","stopHookActive":false}"#,
                          to: "Stop", "reason end_turn is a genuine turn end")
    }

    func test_decode_grokStop_reasonAbsent_mapsToStop() throws {
        try assertMapping(#"{"hookEventName":"stop","sessionId":"s1","stopHookActive":false}"#,
                          to: "Stop",
                          "reason is optional; its absence must not be read as a teardown fire")
    }

    func test_decode_grokStop_channelClosed_staysUnmapped() throws {
        try assertMapping(#"{"hookEventName":"stop","sessionId":"s1","reason":"channel_closed"}"#,
                          to: "stop",
                          "Grok fires an extra observe-only stop at session teardown; mapping it to Stop " +
                          "would roll a SessionEnd-settled done row back to idle")
    }

    func test_decode_grokStop_shutdown_staysUnmapped() throws {
        try assertMapping(#"{"hookEventName":"stop","sessionId":"s1","reason":"shutdown"}"#,
                          to: "stop",
                          "shutdown is the second session-teardown stop reason and is excluded for the " +
                          "same reason as channel_closed")
    }

    // MARK: - notification: the type decides, never the message

    func test_decode_grokNotification_permissionPrompt_mapsToPermissionRequest() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {
            "hookEventName": "notification",
            "sessionId": "s1",
            "notificationType": "permission_prompt",
            "message": "Grok wants to run a command"
        }
        """)))

        XCTAssertEqual(event.hookEventName, "PermissionRequest",
                       "permission_prompt is the one notification type that fires while a permission UI " +
                       "is actually waiting, and PermissionRequest is the event AgentRegistry resolves " +
                       "to blocked unconditionally, without consulting the release-unstable message text")
    }

    func test_decode_grokNotification_idlePrompt_mapsToNotificationCarryingItsMessage() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {
            "hookEventName": "notification",
            "sessionId": "s1",
            "notificationType": "idle_prompt",
            "message": "Grok has been idle for a minute"
        }
        """)))

        XCTAssertEqual(event.hookEventName, "Notification",
                       "Any notification type other than permission_prompt stays a plain Notification")
        XCTAssertEqual(event.message, "Grok has been idle for a minute",
                       "The message rides along so AgentRegistry's own substring backstop can run")
    }

    func test_decode_grokNotification_missingType_mapsToNotification() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {"hookEventName":"notification","sessionId":"s1","message":"something happened"}
        """)))

        XCTAssertEqual(event.hookEventName, "Notification",
                       "An absent notificationType is not permission_prompt, so it must not be promoted " +
                       "to PermissionRequest")
    }

    // MARK: - subagentType stripping

    func test_decode_grokSubagentPreToolUse_keepsRawNameAndStripsSessionAndCwd() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {
            "hookEventName": "pre_tool_use",
            "sessionId": "child-session-9",
            "cwd": "/Users/dev/repo",
            "subagentType": "explore",
            "toolName": "read_file"
        }
        """)))

        XCTAssertEqual(event.hookEventName, "pre_tool_use",
                       "A subagent's event must keep its unmapped raw name so resultingState ignores it: " +
                       "a child agent's tool call is not the host pane's state")
        XCTAssertNil(event.sessionID,
                     "The child session ID must be stripped, or routeAgentEvent records it into the " +
                     "pane's resume meta and a later reattach offers grok --resume <child>")
        XCTAssertNil(event.cwd, "The child's cwd must be stripped for the same reason")
    }

    func test_decode_grokSubagentStop_endTurn_stillKeepsRawName() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {"hookEventName":"stop","sessionId":"child-1","cwd":"/repo","reason":"end_turn","subagentType":"explore"}
        """)))

        XCTAssertEqual(event.hookEventName, "stop",
                       "subagentType outranks the reason filter: a child's genuine turn end is still not " +
                       "the session's")
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.cwd)
    }

    func test_decode_grokEmptySubagentType_isNotTreatedAsASubagent() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {"hookEventName":"user_prompt_submit","sessionId":"main-1","cwd":"/repo","subagentType":""}
        """)))

        XCTAssertEqual(event.hookEventName, "UserPromptSubmit",
                       "An empty subagentType names no subagent, so the main session's event must still " +
                       "map and keep its identity")
        XCTAssertEqual(event.sessionID, "main-1")
        XCTAssertEqual(event.cwd, "/repo")
    }

    // MARK: - No peer-ID extraction on the Grok branch

    func test_decode_grokPreToolUse_calyxIPCTool_leavesIpcSelfPeerIDNil() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {
            "hookEventName": "pre_tool_use",
            "sessionId": "s1",
            "toolName": "mcp__calyx-ipc__send_message",
            "toolInput": {
                "from": "77777777-7777-7777-7777-777777777777",
                "to": "88888888-8888-8888-8888-888888888888",
                "content": "hi"
            }
        }
        """)))

        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertNil(event.ipcSelfPeerID,
                     "Grok binds its peer through the MCP initialize surface header, so the Grok branch " +
                     "must not also mine tool arguments for a self peer ID")
    }

    // MARK: - Claude Code / Codex regression

    func test_decode_bothKeysPresent_snakeCasePathWins() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {
            "hook_event_name": "PreToolUse",
            "hookEventName": "stop",
            "session_id": "snake-session",
            "sessionId": "camel-session",
            "cwd": "/repo",
            "reason": "channel_closed"
        }
        """)))

        XCTAssertEqual(event.hookEventName, "PreToolUse",
                       "hook_event_name being present keeps the payload on the Claude Code / Codex path; " +
                       "the Grok branch is reachable only when that key is absent")
        XCTAssertEqual(event.sessionID, "snake-session",
                       "The snake_case path must keep reading session_id")
    }

    func test_decode_snakeCasePayload_doesNotAdoptCamelCaseAliases() throws {
        let event = try XCTUnwrap(AgentEvent.decode(from: json("""
        {"hook_event_name":"SessionStart","sessionId":"camel-only","cwd":"/repo"}
        """)))

        XCTAssertEqual(event.hookEventName, "SessionStart")
        XCTAssertNil(event.sessionID,
                     "Adding the Grok branch must not make the Claude Code path start accepting " +
                     "camelCase aliases: session_id is the only key that path reads")
    }
}
