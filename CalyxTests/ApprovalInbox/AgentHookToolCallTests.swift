//
//  AgentHookToolCallTests.swift
//  CalyxTests
//
//  Covers AgentHookToolCall.decode(from:): parses a CLI
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

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertEqual(call.summary, "ls -la /tmp")
    }

    func test_decode_writeTool_summaryIsFilePath() throws {
        for toolName in ["Write", "Edit", "Read"] {
            let data = json(["tool_name": toolName, "tool_input": ["file_path": "/Users/dev/repo/file.swift"]])

            let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind), "tool_name=\(toolName)")

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

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

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

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.summary, "/Users/dev/repo/notebook.ipynb",
                       "a stray tool_input.file_path must never be preferred over the real notebook_path")
    }

    func test_decode_webFetchTool_summaryIsURL() throws {
        let data = json(["tool_name": "WebFetch", "tool_input": ["url": "https://example.com/docs"]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.summary, "https://example.com/docs")
    }

    // MARK: - fallback to compact JSON of tool_input

    func test_decode_unknownTool_summaryIsCompactJSONOfToolInput() throws {
        let toolInput: [String: Any] = ["foo": "bar"]
        let data = json(["tool_name": "SomeFutureUnknownTool", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        let expected = try compactJSON(toolInput)
        XCTAssertEqual(call.summary, expected)
        XCTAssertFalse(call.summary.contains("\n"), "summary must be compact JSON, never pretty-printed")
        XCTAssertEqual(call.payload, expected, "payload is also the compact JSON of tool_input")
    }

    func test_decode_bashMissingCommandKey_fallsBackToCompactJSON() throws {
        let toolInput: [String: Any] = ["foo": "bar"]
        let data = json(["tool_name": "Bash", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        let expected = try compactJSON(toolInput)
        XCTAssertEqual(call.summary, expected,
                       "Bash without a tool_input.command key must fall back to compact JSON, same as an unknown tool")
    }

    // MARK: - tool_name rejection

    func test_decode_missingToolName_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData, kind: AgentEntry.claudeCodeKind), "Precondition: a well-formed payload must decode")

        let data = json(["tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind), "tool_name is mandatory")
    }

    func test_decode_emptyOrNonStringToolName_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData, kind: AgentEntry.claudeCodeKind), "Precondition: a well-formed payload must decode")

        let emptyData = json(["tool_name": "", "tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: emptyData, kind: AgentEntry.claudeCodeKind), "an empty tool_name must be rejected")

        let numericData = json(["tool_name": 42, "tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: numericData, kind: AgentEntry.claudeCodeKind), "a non-string tool_name must be rejected")
    }

    // MARK: - tool_input absence

    func test_decode_missingToolInput_payloadEmpty_summaryEmpty() throws {
        let data = json(["tool_name": "Bash"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

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

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertLessThanOrEqual(call.payload.utf8.count, AgentHookToolCall.maxPayloadBytes,
                                "payload must never exceed maxPayloadBytes")

        let expected = truncatedToByteCap(fullJSON, cap: AgentHookToolCall.maxPayloadBytes)
        XCTAssertEqual(call.payload, expected,
                       "payload must be the full compact JSON truncated to the byte cap on a character boundary")
    }

    func test_decode_summaryOverCap_truncatedTo500Chars() throws {
        let longCommand = String(repeating: "a", count: AgentHookToolCall.maxSummaryLength + 100)
        let data = json(["tool_name": "Bash", "tool_input": ["command": longCommand]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

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

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertEqual(call.summary, "pwd")
    }

    func test_decode_malformedJSON_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData, kind: AgentEntry.claudeCodeKind), "Precondition: a well-formed payload must decode")

        let data = Data("this is not { json".utf8)
        XCTAssertNil(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))
    }

    // MARK: - hookEventName decoding

    /// `routeApprovalRequest` only advances a payload into the approval
    /// flow when `hookEventName == "PermissionRequest"` -- a minimal
    /// payload with no top-level `hook_event_name` key at all (the
    /// mandatory-fields-only shape) must decode to `nil`, never a
    /// fabricated default.
    func test_decode_hookEventNameAbsent_minimalPayload_isNil() throws {
        let data = json(["tool_name": "Bash"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.hookEventName, "hookEventName must be nil when hook_event_name is absent from the payload")
    }

    func test_decode_hookEventNamePresent_isDecodedVerbatim() throws {
        let data = json(["tool_name": "Bash", "hook_event_name": "PermissionRequest"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.hookEventName, "PermissionRequest")
    }

    /// An explicit JSON `null` must decode the same as an absent key --
    /// hookEventName is optional, so a nullable field must decode from
    /// both shapes identically, never crash or coerce to an empty string.
    func test_decode_hookEventNameExplicitNull_isNil() throws {
        let data = json(["tool_name": "Bash", "hook_event_name": NSNull()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.hookEventName, "an explicit JSON null for hook_event_name must decode the same as an absent key")
    }

    func test_decode_hookEventNameNonStringValue_isNil() throws {
        let data = json(["tool_name": "Bash", "hook_event_name": 42])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

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

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertEqual(call.permissionMode, "bypassPermissions")
    }

    func test_decode_permissionModeAbsent_isNil() throws {
        let data = json(["toolName": "run_terminal_command"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertNil(call.permissionMode,
                     "An absent permissionMode must decode to nil, never to a fabricated default")
    }

    func test_decode_permissionModeExplicitNull_isNil() throws {
        let data = json(["toolName": "run_terminal_command", "permissionMode": NSNull()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertNil(call.permissionMode,
                     "an explicit JSON null for permissionMode must decode the same as an absent key")
    }

    func test_decode_permissionModeNonStringValue_isNil() throws {
        let data = json(["toolName": "run_terminal_command", "permissionMode": 42])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertNil(call.permissionMode, "a non-string permissionMode value must decode to nil, not coerce")
    }

    /// The tool-input-less early return builds the struct on its own, so
    /// it has to carry the mode too: a payload with no `toolInput` at all
    /// must not lose the field the gate branches on.
    func test_decode_permissionModeSurvivesAMissingToolInput() throws {
        let data = json(["toolName": "run_terminal_command", "permissionMode": "bypassPermissions"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

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

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind),
                                 "Grok's camelCase envelope must decode, not be rejected as nameless")

        XCTAssertEqual(call.toolName, "run_terminal_command")
        XCTAssertEqual(call.payload, try compactJSON(toolInput))
    }

    func test_decode_runTerminalCommand_summaryIsTheCommand() throws {
        let toolInput: [String: Any] = ["command": "rm -rf build"]
        let data = json(["toolName": "run_terminal_command", "toolInput": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertEqual(call.summary, "rm -rf build",
                       "run_terminal_command is Grok's Bash: the banner must show the command a human " +
                       "is being asked about, not the raw JSON wrapping it")
    }

    func test_decode_runTerminalCommand_missingCommandKey_fallsBackToCompactJSON() throws {
        let toolInput: [String: Any] = ["cwd": "/repo"]
        let data = json(["toolName": "run_terminal_command", "toolInput": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertEqual(call.summary, try compactJSON(toolInput),
                       "A recognized tool missing its expected key falls back to the compact JSON, the " +
                       "same rule Bash already follows")
    }

    func test_decode_unrecognizedGrokTool_summaryIsCompactJSON() throws {
        let toolInput: [String: Any] = ["query": "hooks"]
        let data = json(["toolName": "web_search", "toolInput": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertEqual(call.summary, try compactJSON(toolInput))
    }

    func test_decode_snakeCaseKeysWinOverCamelCaseAliases() throws {
        let snakeInput: [String: Any] = ["command": "ls"]
        let camelInput: [String: Any] = ["command": "rm -rf /"]
        let data = json([
            "tool_name": "Bash", "tool_input": snakeInput,
            "toolName": "run_terminal_command", "toolInput": camelInput,
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.grokKind))

        XCTAssertEqual(call.toolName, "Bash",
                       "The camelCase keys are a fallback, never an override: a payload carrying both " +
                       "is a Claude Code / Codex payload")
        XCTAssertEqual(call.summary, "ls",
                       "tool_input must be read from the same envelope tool_name came from, or the " +
                       "banner would name one call and describe another")
    }

    func test_decode_camelCaseToolNameEmpty_rejectsPayload() {
        XCTAssertNil(AgentHookToolCall.decode(from: json(["toolName": ""]), kind: AgentEntry.grokKind),
                     "The alias inherits the non-empty requirement: an empty name is no name")
    }

    // MARK: - question (AskUserQuestion) decoding
    //
    // `question` is populated only for a claude-code AskUserQuestion call
    // whose tool_input.questions is an array. Decoding is lenient at the
    // element level: an element that is an object with a non-empty
    // `question` string becomes a Question; any other element (not an
    // object, or missing/empty `question`) is dropped. Within a
    // surviving element, `options`: each element that is an object with
    // a `label` string becomes an Option; every other element is
    // dropped; a missing or non-array `options` yields an empty list. A
    // question with zero options still survives (free-text-only).
    // `question` is nil overall only when zero elements survive at all,
    // or when `tool_input.questions` itself is missing/non-array. Every
    // other case leaves toolName/payload/summary decoding exactly as
    // they would for any other tool call.

    private func askUserQuestionData(toolName: String = "AskUserQuestion", questions: [[String: Any]]) -> Data {
        json(["tool_name": toolName, "tool_input": ["questions": questions]])
    }

    private func minimalQuestion(_ text: String = "Which shell?", labels: [String] = ["zsh", "bash"]) -> [String: Any] {
        ["question": text, "options": labels.map { ["label": $0] }]
    }

    func test_decode_askUserQuestion_claudeCode_populatesQuestion() throws {
        let data = askUserQuestionData(questions: [
            ["question": "Which shell?", "header": "Shell", "multiSelect": false,
             "options": [
                ["label": "zsh", "description": "Default on macOS"],
                ["label": "bash", "description": "Portable"],
             ]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        let prompt = try XCTUnwrap(call.question)
        XCTAssertEqual(prompt.questions.count, 1)
        let first = prompt.questions[0]
        XCTAssertEqual(first.text, "Which shell?")
        XCTAssertEqual(first.header, "Shell")
        XCTAssertEqual(first.multiSelect, false)
        XCTAssertEqual(first.options, [
            AgentQuestionPrompt.Option(label: "zsh", description: "Default on macOS", preview: nil),
            AgentQuestionPrompt.Option(label: "bash", description: "Portable", preview: nil),
        ])
    }

    func test_decode_askUserQuestion_nonClaudeCodeKind_questionIsNil() throws {
        let data = askUserQuestionData(questions: [minimalQuestion()])

        for kind in [AgentEntry.codexKind, AgentEntry.grokKind, AgentEntry.piKind] {
            let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: kind), "kind=\(kind)")
            XCTAssertNil(call.question, "question must be populated only for claude-code, got kind=\(kind)")
        }
    }

    func test_decode_askUserQuestion_wrongToolName_questionIsNil() throws {
        let data = json(["tool_name": "Bash", "tool_input": ["questions": [minimalQuestion()]]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question, "question must be populated only for tool_name == AskUserQuestion")
    }

    func test_decode_askUserQuestion_emptyQuestionsArray_isNil() throws {
        let data = askUserQuestionData(questions: [])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question, "an empty questions array must never populate question")
    }

    func test_decode_askUserQuestion_missingQuestionsKey_isNil() throws {
        let data = json(["tool_name": "AskUserQuestion", "tool_input": ["foo": "bar"]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question)
    }

    /// Lenient element-level decode: an option missing its mandatory
    /// `label` is dropped, but the question itself still survives (the
    /// whole prompt is not rejected for one malformed option).
    func test_decode_askUserQuestion_optionMissingLabel_optionDroppedQuestionSurvives() throws {
        let data = askUserQuestionData(questions: [
            ["question": "Which shell?", "options": [["description": "no label here"], ["label": "bash"]]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        let prompt = try XCTUnwrap(call.question, "the question must survive even though one option was malformed")
        XCTAssertEqual(prompt.questions.count, 1)
        XCTAssertEqual(prompt.questions[0].options, [AgentQuestionPrompt.Option(label: "bash", description: nil, preview: nil)],
                       "the malformed option (missing label) must be dropped; the valid sibling must survive")
    }

    /// Element-level decode applies to `options` too: a non-object
    /// element (a number) is dropped alone, never rejecting the whole
    /// `options` array or the question it belongs to.
    func test_decode_askUserQuestion_optionsArrayContainsNonObjectNumber_dropsOnlyThatElement() throws {
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which shell?", "options": [["label": "zsh"], ["label": "bash"], 42]],
            ],
        ]
        let data = json(["tool_name": "AskUserQuestion", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))
        let prompt = try XCTUnwrap(call.question)

        XCTAssertEqual(prompt.questions.count, 1)
        XCTAssertEqual(prompt.questions[0].options.map(\.label), ["zsh", "bash"],
                       "a non-object options element (42) must be dropped alone, leaving both labelled options")
    }

    /// Same element-level tolerance for a string and an explicit JSON
    /// null mixed into `options`.
    func test_decode_askUserQuestion_optionsArrayContainsStringAndNull_dropsOnlyThoseElements() throws {
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which shell?", "options": [["label": "zsh"], "junk", NSNull()]],
            ],
        ]
        let data = json(["tool_name": "AskUserQuestion", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))
        let prompt = try XCTUnwrap(call.question)

        XCTAssertEqual(prompt.questions.count, 1)
        XCTAssertEqual(prompt.questions[0].options.map(\.label), ["zsh"],
                       "a string element and an explicit null must both be dropped alone, leaving the one labelled option")
    }

    /// A question with a genuinely empty `options` array still survives
    /// as a free-text-only question -- lenient decoding accepts zero
    /// options rather than rejecting the whole prompt.
    func test_decode_askUserQuestion_emptyOptionsArray_questionSurvivesWithEmptyOptions() throws {
        let data = askUserQuestionData(questions: [
            ["question": "Which shell?", "options": []],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        let prompt = try XCTUnwrap(call.question, "a question with no options at all must still survive as free-text-only")
        XCTAssertEqual(prompt.questions.count, 1)
        XCTAssertEqual(prompt.questions[0].options, [])
    }

    func test_decode_askUserQuestion_questionMissingQuestionKey_isNil() throws {
        let data = askUserQuestionData(questions: [
            ["options": [["label": "zsh"]]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question)
    }

    // MARK: - question: header/multiSelect/description absent / present / explicit null

    func test_decode_askUserQuestion_headerAbsent_isNil() throws {
        let data = askUserQuestionData(questions: [minimalQuestion()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question?.questions.first?.header)
    }

    func test_decode_askUserQuestion_headerExplicitNull_isNil() throws {
        var question = minimalQuestion()
        question["header"] = NSNull()
        let data = askUserQuestionData(questions: [question])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question?.questions.first?.header,
                     "an explicit JSON null for header must decode the same as an absent key")
    }

    func test_decode_askUserQuestion_headerPresent_isDecodedVerbatim() throws {
        var question = minimalQuestion()
        question["header"] = "Shell"
        let data = askUserQuestionData(questions: [question])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.question?.questions.first?.header, "Shell")
    }

    func test_decode_askUserQuestion_multiSelectAbsent_defaultsFalse() throws {
        let data = askUserQuestionData(questions: [minimalQuestion()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.question?.questions.first?.multiSelect, false)
    }

    func test_decode_askUserQuestion_multiSelectExplicitNull_defaultsFalse() throws {
        var question = minimalQuestion()
        question["multiSelect"] = NSNull()
        let data = askUserQuestionData(questions: [question])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.question?.questions.first?.multiSelect, false,
                       "an explicit JSON null for multiSelect must decode the same as an absent key")
    }

    func test_decode_askUserQuestion_multiSelectTrue_isDecodedVerbatim() throws {
        var question = minimalQuestion()
        question["multiSelect"] = true
        let data = askUserQuestionData(questions: [question])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.question?.questions.first?.multiSelect, true)
    }

    func test_decode_askUserQuestion_optionDescriptionAbsent_isNil() throws {
        let data = askUserQuestionData(questions: [minimalQuestion()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question?.questions.first?.options.first?.description)
    }

    func test_decode_askUserQuestion_optionDescriptionExplicitNull_isNil() throws {
        let data = askUserQuestionData(questions: [
            ["question": "Which shell?", "options": [["label": "zsh", "description": NSNull()]]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question?.questions.first?.options.first?.description,
                     "an explicit JSON null for an option's description must decode the same as an absent key")
    }

    func test_decode_askUserQuestion_optionDescriptionPresent_isDecodedVerbatim() throws {
        let data = askUserQuestionData(questions: [
            ["question": "Which shell?", "options": [["label": "zsh", "description": "Default on macOS"]]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.question?.questions.first?.options.first?.description, "Default on macOS")
    }

    // MARK: - originalToolInputJSON

    /// `originalToolInputJSON` is the WHOLE `tool_input` object, not just
    /// `questions` -- a top-level key the decoder never reads (e.g.
    /// `metadata`) must round-trip verbatim alongside every decoded field.
    func test_decode_askUserQuestion_originalToolInputJSON_roundTripsUnknownFields() throws {
        let questions: [[String: Any]] = [
            ["question": "Which shell?",
             "options": [
                ["label": "zsh", "preview": "the current default"],
                ["label": "bash"],
             ]],
        ]
        let toolInput: [String: Any] = ["questions": questions, "metadata": ["source": "cli"]]
        let data = json(["tool_name": "AskUserQuestion", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))
        let prompt = try XCTUnwrap(call.question)

        let decodedOriginal = try XCTUnwrap(JSONSerialization.jsonObject(with: prompt.originalToolInputJSON) as? NSDictionary)
        XCTAssertEqual(decodedOriginal, toolInput as NSDictionary,
                       "originalToolInputJSON must round-trip the WHOLE tool_input object verbatim, including " +
                       "keys outside the decode contract (e.g. a top-level metadata object)")
    }

    /// `originalToolInputJSON` must survive whole even when `payload`
    /// (the compact JSON of the WHOLE `tool_input`, also truncated) hits
    /// the 16 KB cap -- the two are built from the same underlying data
    /// but have independent size contracts.
    func test_decode_askUserQuestion_originalToolInputJSON_survivesPayloadTruncation() throws {
        let bigDescription = String(repeating: "a", count: 20_000)
        let questions: [[String: Any]] = [
            ["question": "Which shell?", "options": [["label": "zsh", "description": bigDescription]]],
        ]
        let toolInput: [String: Any] = ["questions": questions]
        let data = json(["tool_name": "AskUserQuestion", "tool_input": toolInput])

        let toolInputJSON = try compactJSON(toolInput)
        XCTAssertGreaterThan(toolInputJSON.utf8.count, AgentHookToolCall.maxPayloadBytes,
                            "Precondition: the fixture's tool_input must actually exceed maxPayloadBytes")

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertLessThanOrEqual(call.payload.utf8.count, AgentHookToolCall.maxPayloadBytes,
                                "payload must still be truncated to the byte cap")

        let prompt = try XCTUnwrap(call.question)
        let decodedOriginal = try XCTUnwrap(JSONSerialization.jsonObject(with: prompt.originalToolInputJSON) as? NSDictionary)
        XCTAssertEqual(decodedOriginal, toolInput as NSDictionary,
                       "originalToolInputJSON must survive the 16 KB payload truncation whole, undamaged " +
                       "by the cap that truncates payload")
    }

    // MARK: - AskUserQuestion: realistic multi-field fixture

    /// A schema-shaped fixture Claude Code could really send: two
    /// questions, a header, 2 options each carrying a description, one
    /// question multiSelect, one option carrying a preview, and a
    /// top-level tool_input key (metadata) the decoder does not read.
    /// Exercises every decoded field at once, plus originalToolInputJSON
    /// round-tripping the unknown top-level key and the preview field.
    func test_decode_askUserQuestion_realisticFixture_decodesEveryField() throws {
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which shell?", "header": "Shell", "multiSelect": false,
                 "options": [
                    ["label": "zsh", "description": "Default on macOS", "preview": "the current default"],
                    ["label": "bash", "description": "Portable"],
                 ]],
                ["question": "Which editors?", "header": "Editors", "multiSelect": true,
                 "options": [
                    ["label": "vim", "description": "Modal"],
                    ["label": "emacs", "description": "Extensible"],
                 ]],
            ],
            "metadata": ["source": "cli", "version": 2],
        ]
        let data = json(["tool_name": "AskUserQuestion", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))
        XCTAssertTrue(call.isQuestionTool)
        let prompt = try XCTUnwrap(call.question)
        XCTAssertEqual(prompt.questions.count, 2)

        let shellQuestion = prompt.questions[0]
        XCTAssertEqual(shellQuestion.text, "Which shell?")
        XCTAssertEqual(shellQuestion.header, "Shell")
        XCTAssertEqual(shellQuestion.multiSelect, false)
        XCTAssertEqual(shellQuestion.options, [
            AgentQuestionPrompt.Option(label: "zsh", description: "Default on macOS", preview: "the current default"),
            AgentQuestionPrompt.Option(label: "bash", description: "Portable", preview: nil),
        ])

        let editorsQuestion = prompt.questions[1]
        XCTAssertEqual(editorsQuestion.text, "Which editors?")
        XCTAssertEqual(editorsQuestion.header, "Editors")
        XCTAssertEqual(editorsQuestion.multiSelect, true)
        XCTAssertEqual(editorsQuestion.options, [
            AgentQuestionPrompt.Option(label: "vim", description: "Modal", preview: nil),
            AgentQuestionPrompt.Option(label: "emacs", description: "Extensible", preview: nil),
        ])

        let decodedOriginal = try XCTUnwrap(JSONSerialization.jsonObject(with: prompt.originalToolInputJSON) as? NSDictionary)
        XCTAssertEqual(decodedOriginal, toolInput as NSDictionary,
                       "originalToolInputJSON must round-trip metadata and every option's preview verbatim")
    }

    // MARK: - AskUserQuestion: preview absent / explicit null / present

    func test_decode_askUserQuestion_optionPreviewAbsent_isNil() throws {
        let data = askUserQuestionData(questions: [minimalQuestion()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question?.questions.first?.options.first?.preview)
    }

    func test_decode_askUserQuestion_optionPreviewExplicitNull_isNil() throws {
        let data = askUserQuestionData(questions: [
            ["question": "Which shell?", "options": [["label": "zsh", "preview": NSNull()]]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question?.questions.first?.options.first?.preview,
                     "an explicit JSON null for an option's preview must decode the same as an absent key")
    }

    func test_decode_askUserQuestion_optionPreviewPresent_isDecodedVerbatim() throws {
        let data = askUserQuestionData(questions: [
            ["question": "Which shell?", "options": [["label": "zsh", "preview": "the current default"]]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.question?.questions.first?.options.first?.preview, "the current default")
    }

    // MARK: - AskUserQuestion: multiSelect: 1 (JSON number, not boolean)

    func test_decode_askUserQuestion_multiSelectJSONNumberOne_decodesFalse() throws {
        var question = minimalQuestion()
        question["multiSelect"] = 1
        let data = askUserQuestionData(questions: [question])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertEqual(call.question?.questions.first?.multiSelect, false,
                       "a JSON number (1) must decode the same as absent/null -- strictJSONBool rejects " +
                       "anything other than an actual JSON boolean")
    }

    // MARK: - AskUserQuestion: one invalid question dropped, sibling survives

    func test_decode_askUserQuestion_oneQuestionMissingText_droppedSiblingSurvives() throws {
        let data = askUserQuestionData(questions: [
            ["options": [["label": "zsh"]]],
            minimalQuestion("Which editor?", labels: ["vim", "emacs"]),
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))
        let prompt = try XCTUnwrap(call.question)

        XCTAssertEqual(prompt.questions.count, 1, "the question missing its text must be dropped")
        XCTAssertEqual(prompt.questions.first?.text, "Which editor?", "the valid sibling must survive")
    }

    /// Element-level decode applies to `questions` itself: a non-object
    /// element (a string, a number) is dropped alone, never rejecting
    /// the whole `questions` array or the valid element beside it.
    func test_decode_askUserQuestion_questionsArrayContainsNonObjectElements_dropsOnlyThoseElements() throws {
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which shell?", "options": [["label": "zsh"]]],
                "junk",
                7,
            ],
        ]
        let data = json(["tool_name": "AskUserQuestion", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertTrue(call.isQuestionTool)
        let prompt = try XCTUnwrap(call.question)
        XCTAssertEqual(prompt.questions.count, 1,
                       "the non-object elements (a string and a number) must each be dropped alone")
        XCTAssertEqual(prompt.questions.first?.text, "Which shell?")
    }

    // MARK: - AskUserQuestion: every question invalid -> question nil, isQuestionTool still true

    func test_decode_askUserQuestion_everyQuestionInvalid_questionNil_isQuestionToolTrue() throws {
        let data = askUserQuestionData(questions: [
            ["options": [["label": "zsh"]]],
            ["header": "no question key at all"],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertNil(call.question, "zero surviving questions must leave question nil")
        XCTAssertTrue(call.isQuestionTool, "isQuestionTool must stay true regardless of decode success, " +
                      "so the route never auto-allows a decode failure")
    }

    // MARK: - isQuestionTool: false for a non-claude-code kind and a non-AskUserQuestion tool

    func test_isQuestionTool_false_forCodexKind() throws {
        let data = askUserQuestionData(questions: [minimalQuestion()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.codexKind))

        XCTAssertFalse(call.isQuestionTool, "isQuestionTool must be false for any kind other than claude-code")
    }

    func test_isQuestionTool_false_forClaudeCodeBashCall() throws {
        let data = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        XCTAssertFalse(call.isQuestionTool, "isQuestionTool must be false for a claude-code call that isn't AskUserQuestion")
    }

    // MARK: - unicode round-tripping

    func test_decode_askUserQuestion_unicodeLabelsAndQuestionText_roundTrip() throws {
        let data = askUserQuestionData(questions: [
            ["question": "どのシェル？ 🐚", "options": [["label": "zsh 日本語"], ["label": "bash Ünïcödé"]]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))
        let prompt = try XCTUnwrap(call.question)

        XCTAssertEqual(prompt.questions.first?.text, "どのシェル？ 🐚")
        XCTAssertEqual(prompt.questions.first?.options.map(\.label), ["zsh 日本語", "bash Ünïcödé"])
    }

    // MARK: - minimal fixture still decodes

    func test_decode_askUserQuestion_minimalFixture_decodes() throws {
        let data = askUserQuestionData(questions: [minimalQuestion()])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data, kind: AgentEntry.claudeCodeKind))

        let prompt = try XCTUnwrap(call.question)
        XCTAssertEqual(prompt.questions.count, 1)
        XCTAssertEqual(prompt.questions.first?.options.map(\.label), ["zsh", "bash"])
    }
}
