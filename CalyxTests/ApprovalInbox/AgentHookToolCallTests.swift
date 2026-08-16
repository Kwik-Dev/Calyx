//
//  AgentHookToolCallTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentHookToolCall.decode(from:): parses a CLI
//  agent's PreToolUse hook stdin JSON (tool_name / tool_input) into the
//  toolName/payload/summary trio the approval inbox needs to render a
//  banner for a non-MCP agent hook call -- mirrors AgentEvent.decode's
//  JSONSerialization-based style (see AgentEventTests.swift).
//
//  Coverage:
//  - Bash/Write/Edit/Read/WebFetch each derive `summary` from their own
//    well-known tool_input key; NotebookEdit derives it from its own
//    distinct `notebook_path` key (NOT `file_path` -- see
//    test_decode_notebookEditTool_summaryIsNotebookPath)
//  - an unrecognized tool_name, or a recognized one missing its expected
//    key, falls back to the compact JSON of tool_input
//  - tool_name is mandatory; empty/non-string/missing values reject the
//    payload
//  - tool_input is optional; its absence yields an empty payload/summary
//  - payload is capped at maxPayloadBytes UTF-8 bytes, truncated on a
//    character boundary; summary is capped at maxSummaryLength characters
//  - unknown extra top-level fields are tolerated
//  - malformed JSON is rejected
//  - hookEventName decodes the top-level hook_event_name key: absent,
//    explicit null, and a non-string value all decode to nil; a string
//    value decodes to that exact string
//

import XCTest
@testable import Calyx

final class AgentHookToolCallTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func compactJSON(_ object: [String: Any]) throws -> String {
        try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    /// Truncates `text` to at most `cap` UTF-8 bytes without ever
    /// splitting a `Character` -- the same "character boundary" contract
    /// AgentHookToolCall.payload is specced to uphold, computed here
    /// independently of the decoder under test.
    private func truncatedToByteCap(_ text: String, cap: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in text {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= cap else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }

    // MARK: - summary derivation per tool_name

    func test_decode_bashTool_summaryIsCommandString() throws {
        let data = json(["tool_name": "Bash", "tool_input": ["command": "ls -la /tmp"]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertEqual(call.summary, "ls -la /tmp")
    }

    func test_decode_writeTool_summaryIsFilePath() throws {
        for toolName in ["Write", "Edit", "Read"] {
            let data = json(["tool_name": toolName, "tool_input": ["file_path": "/Users/dev/repo/file.swift"]])

            let call = try XCTUnwrap(AgentHookToolCall.decode(from: data), "tool_name=\(toolName)")

            XCTAssertEqual(call.toolName, toolName, "tool_name=\(toolName)")
            XCTAssertEqual(call.summary, "/Users/dev/repo/file.swift", "tool_name=\(toolName)")
        }
    }

    /// R1 fix-pin: Claude Code's actual PreToolUse `tool_input` schema for
    /// `NotebookEdit` is `notebook_path` (+ `new_source`), NOT `file_path`
    /// -- unlike Write/Edit/Read above, so it must derive its summary
    /// from its own distinct well-known key rather than sharing
    /// Write/Edit/Read's `file_path`.
    func test_decode_notebookEditTool_summaryIsNotebookPath() throws {
        let data = json([
            "tool_name": "NotebookEdit",
            "tool_input": ["notebook_path": "/Users/dev/repo/notebook.ipynb", "new_source": "print(1)"],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.toolName, "NotebookEdit")
        XCTAssertEqual(call.summary, "/Users/dev/repo/notebook.ipynb",
                       "NotebookEdit's summary must come from tool_input.notebook_path, never file_path")
    }

    /// A stray/incorrect `file_path` alongside the real `notebook_path`
    /// must never be preferred -- `notebook_path` alone is NotebookEdit's
    /// well-known key.
    func test_decode_notebookEditTool_strayFilePath_stillUsesNotebookPath() throws {
        let data = json([
            "tool_name": "NotebookEdit",
            "tool_input": ["file_path": "/wrong/path.py", "notebook_path": "/Users/dev/repo/notebook.ipynb"],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary, "/Users/dev/repo/notebook.ipynb",
                       "a stray tool_input.file_path must never be preferred over the real notebook_path")
    }

    func test_decode_webFetchTool_summaryIsURL() throws {
        let data = json(["tool_name": "WebFetch", "tool_input": ["url": "https://example.com/docs"]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary, "https://example.com/docs")
    }

    // MARK: - fallback to compact JSON of tool_input

    func test_decode_unknownTool_summaryIsCompactJSONOfToolInput() throws {
        let toolInput: [String: Any] = ["foo": "bar"]
        let data = json(["tool_name": "SomeFutureUnknownTool", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        let expected = try compactJSON(toolInput)
        XCTAssertEqual(call.summary, expected)
        XCTAssertFalse(call.summary.contains("\n"), "summary must be compact JSON, never pretty-printed")
        XCTAssertEqual(call.payload, expected, "payload is also the compact JSON of tool_input")
    }

    func test_decode_bashMissingCommandKey_fallsBackToCompactJSON() throws {
        let toolInput: [String: Any] = ["foo": "bar"]
        let data = json(["tool_name": "Bash", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        let expected = try compactJSON(toolInput)
        XCTAssertEqual(call.summary, expected,
                       "Bash without a tool_input.command key must fall back to compact JSON, same as an unknown tool")
    }

    // MARK: - tool_name rejection

    func test_decode_missingToolName_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData), "Precondition: a well-formed payload must decode")

        let data = json(["tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: data), "tool_name is mandatory")
    }

    func test_decode_emptyOrNonStringToolName_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData), "Precondition: a well-formed payload must decode")

        let emptyData = json(["tool_name": "", "tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: emptyData), "an empty tool_name must be rejected")

        let numericData = json(["tool_name": 42, "tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: numericData), "a non-string tool_name must be rejected")
    }

    // MARK: - tool_input absence

    func test_decode_missingToolInput_payloadEmpty_summaryEmpty() throws {
        let data = json(["tool_name": "Bash"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.payload, "", "tool_input absent must yield an empty payload")
        XCTAssertEqual(call.summary, "", "tool_input absent must yield an empty summary")
    }

    // MARK: - capping

    func test_decode_payloadOverCap_truncatedAtCharacterBoundary() throws {
        // "あ" is 3 UTF-8 bytes; {"data":"<N x あ>"} makes the raw
        // byte-16384 cut point land mid-character, since 16384 minus the
        // 9-byte `{"data":"` prefix (16375) is not a multiple of 3 --
        // proving the cap backs off to a whole character instead of
        // splitting one.
        let repeatCount = 6_000
        let bigValue = String(repeating: "あ", count: repeatCount)
        let toolInput: [String: Any] = ["data": bigValue]
        let data = json(["tool_name": "SomeFutureUnknownTool", "tool_input": toolInput])

        let fullJSON = try compactJSON(toolInput)
        XCTAssertGreaterThan(fullJSON.utf8.count, AgentHookToolCall.maxPayloadBytes,
                            "Precondition: the fixture must actually exceed maxPayloadBytes")

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertLessThanOrEqual(call.payload.utf8.count, AgentHookToolCall.maxPayloadBytes,
                                "payload must never exceed maxPayloadBytes")

        let expected = truncatedToByteCap(fullJSON, cap: AgentHookToolCall.maxPayloadBytes)
        XCTAssertEqual(call.payload, expected,
                       "payload must be the full compact JSON truncated to the byte cap on a character boundary")
    }

    func test_decode_summaryOverCap_truncatedTo500Chars() throws {
        let longCommand = String(repeating: "a", count: AgentHookToolCall.maxSummaryLength + 100)
        let data = json(["tool_name": "Bash", "tool_input": ["command": longCommand]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary.count, AgentHookToolCall.maxSummaryLength)
        XCTAssertEqual(call.summary, String(longCommand.prefix(AgentHookToolCall.maxSummaryLength)))
    }

    // MARK: - tolerance / malformed input

    func test_decode_toleratesUnknownFields() throws {
        let data = json([
            "tool_name": "Bash",
            "tool_input": ["command": "pwd"],
            "hook_event_name": "PreToolUse",
            "an_unknown_future_field": ["nested": [1, 2, 3]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertEqual(call.summary, "pwd")
    }

    func test_decode_malformedJSON_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData), "Precondition: a well-formed payload must decode")

        let data = Data("this is not { json".utf8)
        XCTAssertNil(AgentHookToolCall.decode(from: data))
    }

    // MARK: - hookEventName decoding

    /// `routeApprovalRequest` only advances a payload into the approval
    /// flow when `hookEventName == "PermissionRequest"` -- a minimal
    /// payload with no top-level `hook_event_name` key at all (the
    /// mandatory-fields-only shape) must decode to `nil`, never a
    /// fabricated default.
    func test_decode_hookEventNameAbsent_minimalPayload_isNil() throws {
        let data = json(["tool_name": "Bash"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertNil(call.hookEventName, "hookEventName must be nil when hook_event_name is absent from the payload")
    }

    func test_decode_hookEventNamePresent_isDecodedVerbatim() throws {
        let data = json(["tool_name": "Bash", "hook_event_name": "PermissionRequest"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.hookEventName, "PermissionRequest")
    }

    /// An explicit JSON `null` must decode the same as an absent key --
    /// hookEventName is optional, so a nullable field must decode from
    /// both shapes identically, never crash or coerce to an empty string.
    func test_decode_hookEventNameExplicitNull_isNil() throws {
        let data = json(["tool_name": "Bash", "hook_event_name": NSNull()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertNil(call.hookEventName, "an explicit JSON null for hook_event_name must decode the same as an absent key")
    }

    func test_decode_hookEventNameNonStringValue_isNil() throws {
        let data = json(["tool_name": "Bash", "hook_event_name": 42])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertNil(call.hookEventName, "a non-string hook_event_name value must decode to nil, not crash or coerce")
    }

    // MARK: - permissionMode decoding
    //
    // Grok names the session's permission mode on every hook payload, and
    // `routeApprovalRequest` holds a grok tool call for a human only when
    // that mode is `bypassPermissions` -- the one mode where Grok's own
    // permission pipeline would otherwise run the call without asking
    // anyone. A fabricated default here would either gate calls Grok is
    // about to prompt for itself, or drop the gate where nothing else
    // asks.

    func test_decode_permissionModePresent_isDecodedVerbatim() throws {
        let data = json(["toolName": "run_terminal_command", "permissionMode": "bypassPermissions"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.permissionMode, "bypassPermissions")
    }

    func test_decode_permissionModeAbsent_isNil() throws {
        let data = json(["toolName": "run_terminal_command"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertNil(call.permissionMode,
                     "An absent permissionMode must decode to nil, never to a fabricated default")
    }

    func test_decode_permissionModeExplicitNull_isNil() throws {
        let data = json(["toolName": "run_terminal_command", "permissionMode": NSNull()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertNil(call.permissionMode,
                     "an explicit JSON null for permissionMode must decode the same as an absent key")
    }

    func test_decode_permissionModeNonStringValue_isNil() throws {
        let data = json(["toolName": "run_terminal_command", "permissionMode": 42])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertNil(call.permissionMode, "a non-string permissionMode value must decode to nil, not coerce")
    }

    /// The tool-input-less early return builds the struct on its own, so
    /// it has to carry the mode too: a payload with no `toolInput` at all
    /// must not lose the field the gate branches on.
    func test_decode_permissionModeSurvivesAMissingToolInput() throws {
        let data = json(["toolName": "run_terminal_command", "permissionMode": "bypassPermissions"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.payload, "", "Precondition: this payload carries no tool input")
        XCTAssertEqual(call.permissionMode, "bypassPermissions")
    }

    // MARK: - Grok's camelCase envelope
    //
    // Grok spells the same two fields toolName / toolInput, and names its
    // shell tool run_terminal_command rather than Bash. Without the
    // aliases the whole payload is rejected on the mandatory-tool_name
    // guard, so a Grok banner would carry no tool name at all.

    func test_decode_camelCaseToolNameAndToolInput_areAccepted() throws {
        let toolInput: [String: Any] = ["command": "npm test"]
        let data = json(["toolName": "run_terminal_command", "toolInput": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data),
                                 "Grok's camelCase envelope must decode, not be rejected as nameless")

        XCTAssertEqual(call.toolName, "run_terminal_command")
        XCTAssertEqual(call.payload, try compactJSON(toolInput))
    }

    func test_decode_runTerminalCommand_summaryIsTheCommand() throws {
        let toolInput: [String: Any] = ["command": "rm -rf build"]
        let data = json(["toolName": "run_terminal_command", "toolInput": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary, "rm -rf build",
                       "run_terminal_command is Grok's Bash: the banner must show the command a human " +
                       "is being asked about, not the raw JSON wrapping it")
    }

    func test_decode_runTerminalCommand_missingCommandKey_fallsBackToCompactJSON() throws {
        let toolInput: [String: Any] = ["cwd": "/repo"]
        let data = json(["toolName": "run_terminal_command", "toolInput": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary, try compactJSON(toolInput),
                       "A recognized tool missing its expected key falls back to the compact JSON, the " +
                       "same rule Bash already follows")
    }

    func test_decode_unrecognizedGrokTool_summaryIsCompactJSON() throws {
        let toolInput: [String: Any] = ["query": "hooks"]
        let data = json(["toolName": "web_search", "toolInput": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary, try compactJSON(toolInput))
    }

    func test_decode_snakeCaseKeysWinOverCamelCaseAliases() throws {
        let snakeInput: [String: Any] = ["command": "ls"]
        let camelInput: [String: Any] = ["command": "rm -rf /"]
        let data = json([
            "tool_name": "Bash", "tool_input": snakeInput,
            "toolName": "run_terminal_command", "toolInput": camelInput,
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.toolName, "Bash",
                       "The camelCase keys are a fallback, never an override: a payload carrying both " +
                       "is a Claude Code / Codex payload")
        XCTAssertEqual(call.summary, "ls",
                       "tool_input must be read from the same envelope tool_name came from, or the " +
                       "banner would name one call and describe another")
    }

    func test_decode_camelCaseToolNameEmpty_rejectsPayload() {
        XCTAssertNil(AgentHookToolCall.decode(from: json(["toolName": ""])),
                     "The alias inherits the non-empty requirement: an empty name is no name")
    }
}
