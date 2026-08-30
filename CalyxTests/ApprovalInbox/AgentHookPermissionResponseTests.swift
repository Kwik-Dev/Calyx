//
//  AgentHookPermissionResponseTests.swift
//  CalyxTests
//
//  Covers AgentHookPermissionResponse.body(kind:decision:):
//  the PermissionRequest hook stdout body Calyx writes back to a CLI
//  agent to carry a human's approval decision into that CLI's own
//  synchronous permission gate -- shape and field names follow the
//  PermissionRequest hook-response contract both Claude Code and Codex
//  document (hookSpecificOutput.decision.behavior), replacing the older
//  PreToolUse-era hookSpecificOutput.permissionDecision shape entirely.
//  permissionDecision, permissionDecisionReason, updatedPermissions, and
//  interrupt are all reserved or invalid under PermissionRequest, so none
//  of them may ever appear in this body. updatedInput is the one
//  documented exception: it appears only in claude-code's .answered
//  (AskUserQuestion) body, never in an allow/deny/expired body.
//
//  Coverage:
//  - claude-code / codex: allowed produces decision.behavior "allow";
//    denied produces decision.behavior "deny" with a non-empty message;
//    both share hookEventName "PermissionRequest"
//  - claude-code / codex: expired produces nil for both kinds -- neither
//    CLI has a fallback body under PermissionRequest, so no output lets
//    that CLI's own confirmation prompt take over
//  - any kind other than claude-code/codex produces nil for every
//    decision -- Calyx must never inject a decision into a CLI it
//    doesn't recognize
//  - the body never carries any of PermissionRequest's reserved/invalid
//    fields, pinned via an exact key-set assertion rather than substring
//    checks, so a stray extra field is caught too
//  - claude-code's .answered body: behavior "allow" plus updatedInput
//    (the original tool_input object plus an answers map), the one
//    documented exception to the reserved-field rule above
//
//  Bodies are re-parsed with JSONSerialization and asserted field by
//  field -- never by string equality, since key order in the serialized
//  JSON is unspecified.
//

import XCTest
@testable import Calyx

final class AgentHookPermissionResponseTests: XCTestCase {

    // MARK: - Helpers

    private func hookSpecificOutput(_ data: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
    }

    /// Asserts `body(kind:decision:)`'s decoded shape: `hookEventName`
    /// is always `PermissionRequest`, `decision.behavior` matches
    /// `expectedBehavior`, and -- only for a denied decision, whose
    /// contract additionally carries a human-readable reason --
    /// `decision.message` is present and non-empty.
    private func assertPermissionDecision(
        kind: String,
        decision: ApprovalDecision,
        expectedBehavior: String,
        expectsMessage: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: kind, decision: decision),
            file: file, line: line
        )
        let output = try hookSpecificOutput(data)
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest", file: file, line: line)

        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(decisionObject["behavior"] as? String, expectedBehavior, file: file, line: line)

        if expectsMessage {
            let message = try XCTUnwrap(decisionObject["message"] as? String, file: file, line: line)
            XCTAssertFalse(message.isEmpty, "a denied decision's message must be non-empty", file: file, line: line)
        }
    }

    // MARK: - claude-code

    func test_body_claude_allowed_isAllowBehavior() throws {
        try assertPermissionDecision(
            kind: AgentEntry.claudeCodeKind, decision: .allowed, expectedBehavior: "allow", expectsMessage: false
        )
    }

    func test_body_claude_denied_isDenyBehaviorWithNonEmptyMessage() throws {
        try assertPermissionDecision(
            kind: AgentEntry.claudeCodeKind, decision: .denied, expectedBehavior: "deny", expectsMessage: true
        )
    }

    func test_body_claude_expired_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .expired),
                    "PermissionRequest has no fallback body for an expired decision -- no output lets " +
                    "Claude Code's own confirmation prompt take over, the same fail-safe principle " +
                    "ApprovalHookScript's stdout silence upholds")
    }

    // MARK: - codex

    func test_body_codex_allowed_isAllowBehavior() throws {
        try assertPermissionDecision(
            kind: AgentEntry.codexKind, decision: .allowed, expectedBehavior: "allow", expectsMessage: false
        )
    }

    func test_body_codex_denied_isDenyBehaviorWithNonEmptyMessage() throws {
        try assertPermissionDecision(
            kind: AgentEntry.codexKind, decision: .denied, expectedBehavior: "deny", expectsMessage: true
        )
    }

    func test_body_codex_expired_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.codexKind, decision: .expired),
                    "Codex has no fallback body for an expired decision either -- no output lets Codex's " +
                    "own confirmation prompt take over")
    }

    // MARK: - grok
    //
    // Grok's PreToolUse decision vocabulary is a flat, top-level
    // `{"decision":"allow"}` / `{"decision":"deny","reason":"..."}`,
    // not Claude Code's and Codex's nested
    // `hookSpecificOutput.decision.behavior`.
    //
    // Grok has no "ask" analog, and an expired decision maps to deny.
    // Silence at Grok's gate hands the call back to Grok's own
    // permission pipeline rather than to a guaranteed prompt, and the
    // route only ever holds a grok request under `bypassPermissions`
    // (`ApprovalHookEvent.gateIsSoleAuthority`), the mode in which that
    // pipeline runs the call without asking anyone. A banner nobody
    // answered within the hold window is not an approval.

    /// Parses Grok's flat decision body.
    private func grokDecision(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_body_grok_allowed_isFlatAllowDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: .allowed)
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "allow")
        XCTAssertEqual(Set(object.keys), ["decision"],
                       "An allow carries the decision alone. Grok reads hookSpecificOutput only for " +
                       "updatedInput, and an updatedInput that fails the tool's schema BLOCKS the call, " +
                       "so nothing extra may ride along here")
    }

    func test_body_grok_denied_isFlatDenyDecisionWithReason() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: .denied)
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        XCTAssertEqual(Set(object.keys), ["decision", "reason"],
                       "A deny carries exactly decision and reason: Grok names the field reason, not " +
                       "Claude Code's and Codex's message")
        let reason = try XCTUnwrap(object["reason"] as? String)
        XCTAssertFalse(reason.isEmpty,
                       "The reason is shown to the model as the deny explanation, so it must not be empty")
    }

    func test_body_grok_expired_isADenyDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: .expired),
            "A grok request is only held for a decision under bypassPermissions, where silence lets " +
            "Grok run the call without asking anyone. An unanswered banner must therefore produce an " +
            "explicit deny, not no body"
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        let reason = try XCTUnwrap(object["reason"] as? String)
        XCTAssertFalse(reason.isEmpty,
                       "The model is told why the call was refused, so an expiry states its own reason")
    }

    func test_body_grok_expired_differsFromTheOtherKinds() {
        for kind in [AgentEntry.claudeCodeKind, AgentEntry.codexKind] {
            XCTAssertNil(AgentHookPermissionResponse.body(kind: kind, decision: .expired),
                         "[\(kind)] answers an expiry with silence so its own confirmation prompt takes " +
                         "over. Grok cannot: the only mode its requests are held in is bypassPermissions, " +
                         "where no prompt waits behind the gate, so the two contracts must stay distinct")
        }
    }

    func test_body_grok_neverUsesTheClaudeCodeEnvelope() throws {
        for decision in [ApprovalDecision.allowed, .denied, .expired] {
            let data = try XCTUnwrap(
                AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: decision)
            )
            let object = try grokDecision(data)
            XCTAssertNil(object["hookSpecificOutput"],
                         "Grok parses a top-level decision. Nesting it the Claude Code way would make " +
                         "the hook look like it returned no decision at all, handing the call back to " +
                         "Grok's own pipeline: under bypassPermissions, the mode these bodies are " +
                         "written in, that runs a call a human may have just denied")
        }
    }

    func test_body_claudeCodeAndCodex_keepTheirNestedEnvelope() throws {
        for kind in [AgentEntry.claudeCodeKind, AgentEntry.codexKind] {
            let data = try XCTUnwrap(AgentHookPermissionResponse.body(kind: kind, decision: .allowed))
            let object = try grokDecision(data)
            XCTAssertNotNil(object["hookSpecificOutput"],
                            "[\(kind)] adding grok must not flatten the existing kinds' envelope")
            XCTAssertNil(object["decision"],
                         "[\(kind)] must not gain a top-level decision key")
        }
    }

    // MARK: - pi
    //
    // pi's gate is a `tool_call` extension handler that reads this body
    // itself and returns `{ block: true, reason }` on a deny, so it uses
    // the same flat, top-level decision vocabulary Grok does rather than
    // Claude Code's and Codex's nested hookSpecificOutput envelope.
    //
    // An expired decision denies. pi ships no permission prompt of its
    // own (`docs/usage.md`: it intentionally does not include permission
    // popups), so there is nothing behind Calyx's gate to defer to: a
    // silent answer would let an unreviewed call run, and a banner nobody
    // answered within the hold window is not an approval.

    func test_body_pi_allowed_isFlatAllowDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.piKind, decision: .allowed),
            "pi must not fall into the fail-safe default branch: an unrecognized kind answers with no " +
            "body at all, which the extension reads as no opinion, and the call runs unreviewed"
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "allow")
        XCTAssertEqual(Set(object.keys), ["decision"],
                       "An allow carries the decision alone. The extension reads a top-level decision " +
                       "field and nothing else")
    }

    func test_body_pi_denied_isFlatDenyDecisionWithReason() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.piKind, decision: .denied)
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        XCTAssertEqual(Set(object.keys), ["decision", "reason"],
                       "A deny carries exactly decision and reason")
        let reason = try XCTUnwrap(object["reason"] as? String)
        XCTAssertFalse(reason.isEmpty,
                       "pi hands the block reason to the model as the tool result content, so an empty " +
                       "reason would tell the model nothing about why the call failed")
    }

    func test_body_pi_expired_isADenyDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.piKind, decision: .expired),
            "pi has no confirmation prompt of its own to fall back on, so silence here would run the " +
            "call unreviewed. An expiry must deny explicitly"
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        XCTAssertEqual(Set(object.keys), ["decision", "reason"])
        let reason = try XCTUnwrap(object["reason"] as? String)
        XCTAssertFalse(reason.isEmpty,
                       "The model is told why the call was refused, so an expiry states its own reason")
    }

    // MARK: - unrecognized kind

    func test_body_unknownKind_isNilForAllDecisions() {
        let unknownKind = "some-unrecognized-cli"

        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .allowed))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .denied))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .expired))
    }

    // MARK: - claude-code: .answered (AskUserQuestion)
    //
    // `.answered` carries the original `questions` array back verbatim
    // (re-parsed as an identical JSON value, not necessarily identical
    // bytes -- key order in JSONSerialization output is unspecified) plus
    // an `answers` object mapping each question's own text to its chosen
    // value: a single label, multi-select labels joined with ", ", or the
    // typed text for a free-text "Other" choice.

    private func toolInputValue(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func makeAnswers() -> AgentQuestionAnswers {
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which shell?", "options": [["label": "zsh"], ["label": "bash"]]],
                ["question": "Which editors?", "multiSelect": true,
                 "options": [["label": "vim"], ["label": "emacs"], ["label": "nano"]]],
                ["question": "Anything else?", "options": [["label": "Other"]]],
            ],
        ]
        let originalToolInputJSON = try! JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [
                AgentQuestionPrompt.Question(
                    text: "Which shell?", header: nil,
                    options: [
                        AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "bash", description: nil, preview: nil),
                    ],
                    multiSelect: false
                ),
                AgentQuestionPrompt.Question(
                    text: "Which editors?", header: nil,
                    options: [
                        AgentQuestionPrompt.Option(label: "vim", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "emacs", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "nano", description: nil, preview: nil),
                    ],
                    multiSelect: true
                ),
                AgentQuestionPrompt.Question(
                    text: "Anything else?", header: nil,
                    options: [AgentQuestionPrompt.Option(label: "Other", description: nil, preview: nil)],
                    multiSelect: false
                ),
            ],
            originalToolInputJSON: originalToolInputJSON
        )
        return AgentQuestionAnswers(
            prompt: prompt,
            answers: [.selectedOne("zsh"), .selectedMany(["vim", "emacs"]), .freeText("Please also install ripgrep")]
        )
    }

    func test_body_claude_answered_isAllowBehaviorWithUpdatedInput() throws {
        let answers = makeAnswers()
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")

        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(Set(decisionObject.keys), ["behavior", "updatedInput"],
                       "an answered decision's decision object must contain exactly behavior and updatedInput")
        XCTAssertEqual(decisionObject["behavior"] as? String, "allow")

        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        XCTAssertEqual(Set(updatedInput.keys), ["questions", "answers"],
                       "updatedInput must contain exactly the original tool_input keys (questions) plus answers")

        let questionsValue = try XCTUnwrap(updatedInput["questions"])
        let questionsData = try JSONSerialization.data(withJSONObject: ["questions": questionsValue])
        let originalToolInput = try toolInputValue(answers.prompt.originalToolInputJSON)
        XCTAssertEqual(try toolInputValue(questionsData)["questions"] as? NSArray, originalToolInput["questions"] as? NSArray,
                       "updatedInput.questions must equal originalToolInputJSON's own questions re-parsed as an identical JSON value")

        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        XCTAssertEqual(answersObject, [
            "Which shell?": "zsh",
            "Which editors?": "vim, emacs",
            "Anything else?": "Please also install ripgrep",
        ])
    }

    /// `updatedInput`'s key set is the original `tool_input` keys plus
    /// `answers` -- a `tool_input` carrying an unknown top-level key
    /// (e.g. `metadata`) must round-trip that key through unchanged.
    func test_body_claude_answered_updatedInputKeys_areOriginalToolInputKeysPlusAnswers() throws {
        let toolInput: [String: Any] = [
            "questions": [["question": "Which shell?", "options": [["label": "zsh"]]]],
            "metadata": ["source": "cli"],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil)],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, answers: [.selectedOne("zsh")])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])

        XCTAssertEqual(Set(updatedInput.keys), ["questions", "metadata", "answers"],
                       "updatedInput must carry every original tool_input key (including an unknown one like " +
                       "metadata) plus answers -- Claude Code's own contract replaces the whole input object")
    }

    /// A `tool_input` that already carries a stale `answers` key (e.g. a
    /// prior round's own leftover) must be OVERWRITTEN by the freshly
    /// built object, never merged with it -- the stale key must be gone
    /// and the fresh question-text key must be present, with the key set
    /// staying exactly `questions` + `answers`.
    func test_body_claude_answered_staleAnswersKeyInToolInput_isOverwrittenNotMerged() throws {
        let toolInput: [String: Any] = [
            "questions": [["question": "Which shell?", "options": [["label": "zsh"]]]],
            "answers": ["stale": "value"],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil)],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, answers: [.selectedOne("zsh")])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])

        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        XCTAssertEqual(answersObject, ["Which shell?": "zsh"],
                       "updatedInput.answers must be exactly the freshly built object -- the stale key must " +
                       "be gone and the question-text key must be present")
        XCTAssertEqual(Set(updatedInput.keys), ["questions", "answers"],
                       "the key set must stay exactly questions + answers, not grow from a merge")
    }

    func test_body_nonClaudeCodeKinds_answered_isNil() {
        let answers = makeAnswers()
        for kind in [AgentEntry.codexKind, AgentEntry.grokKind, AgentEntry.piKind, "some-unrecognized-cli"] {
            XCTAssertNil(AgentHookPermissionResponse.body(kind: kind, decision: .answered(answers)),
                        "[\(kind)] .answered must produce no body -- only claude-code recognizes AskUserQuestion")
        }
    }

    // MARK: - selectedLabelsAnswerValue (claude-code's multi-select answer encoding)
    //
    // Claude Code's own encoding (2.1.251, verbatim from the binary):
    // labels.map(t => t.includes(", ") || t.includes('"') ? JSON.stringify(t) : t).join(", ").
    // A label containing ", " or a double quote must be JSON-string-quoted
    // or Claude Code's own round-trip check silently fails to recognize
    // the answer; every other label rides through bare.

    func test_selectedLabelsAnswerValue_plainLabels_joinsWithCommaSpace() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue(["zsh", "bash"]), "zsh, bash")
    }

    func test_selectedLabelsAnswerValue_singlePlainLabel_returnsItself() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue(["zsh"]), "zsh")
    }

    func test_selectedLabelsAnswerValue_labelContainingCommaSpace_isJSONQuoted() {
        XCTAssertEqual(
            AgentHookPermissionResponse.selectedLabelsAnswerValue(["Swift, Rust", "Go"]),
            "\"Swift, Rust\", Go"
        )
    }

    func test_selectedLabelsAnswerValue_labelContainingDoubleQuote_isJSONQuoted() {
        XCTAssertEqual(
            AgentHookPermissionResponse.selectedLabelsAnswerValue(["Say \"hi\""]),
            "\"Say \\\"hi\\\"\""
        )
    }

    /// Pins a one-element multi-select answer: even with nothing to join,
    /// a lone label still goes through the quoted round-trip check when
    /// it contains ", " or a double quote.
    func test_selectedLabelsAnswerValue_oneElementMultiSelectAnswer_labelContainingCommaSpace_isQuotedAlone() {
        XCTAssertEqual(
            AgentHookPermissionResponse.selectedLabelsAnswerValue(["Swift, Rust"]),
            "\"Swift, Rust\""
        )
    }

    func test_selectedLabelsAnswerValue_labelContainingSlash_isNotEscaped() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue(["a/b"]), "a/b")
    }

    func test_selectedLabelsAnswerValue_emptyArray_returnsEmptyString() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue([]), "")
    }

    /// `.selectedOne` with a label containing ", " is emitted raw --
    /// never run through `selectedLabelsAnswerValue` -- a single-select
    /// answer is matched against the listed label set verbatim.
    func test_body_claude_answered_selectedOne_labelContainingCommaSpace_isEmittedRaw() throws {
        let toolInput: [String: Any] = [
            "questions": [["question": "Which pair?", "options": [["label": "Swift, Rust"], ["label": "Go"]]]],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which pair?", header: nil,
                options: [
                    AgentQuestionPrompt.Option(label: "Swift, Rust", description: nil, preview: nil),
                    AgentQuestionPrompt.Option(label: "Go", description: nil, preview: nil),
                ],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, answers: [.selectedOne("Swift, Rust")])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(answersObject["Which pair?"], "Swift, Rust",
                       "a .selectedOne label must be emitted raw, never JSON-quoted -- that round-trip check " +
                       "only ever runs for a multi-select answer")
    }

    /// `.selectedMany` is emitted through `selectedLabelsAnswerValue`
    /// -- the multi-select answer for a label containing ", " must be
    /// JSON-quoted, matching Claude Code's own round-trip check.
    func test_body_claude_answered_selectedMany_isEmittedThroughSelectedLabelsAnswerValue() throws {
        let precomputed = AgentHookPermissionResponse.selectedLabelsAnswerValue(["Swift, Rust", "Go"])
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which languages?", "multiSelect": true,
                 "options": [["label": "Swift, Rust"], ["label": "Go"]]],
            ],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [
                AgentQuestionPrompt.Question(
                    text: "Which languages?", header: nil,
                    options: [
                        AgentQuestionPrompt.Option(label: "Swift, Rust", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "Go", description: nil, preview: nil),
                    ],
                    multiSelect: true
                ),
            ],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, answers: [.selectedMany(["Swift, Rust", "Go"])])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(answersObject["Which languages?"], precomputed,
                       "a .selectedMany answer must be run through selectedLabelsAnswerValue, quoting the " +
                       "label that contains \", \"")
    }

    /// `.freeText` is emitted raw, including text that itself contains
    /// ", " -- free text is meant to reach the CLI unencoded, never
    /// matched against the listed label set at all.
    func test_body_claude_answered_freeText_isEmittedRaw_evenContainingCommaSpace() throws {
        let toolInput: [String: Any] = ["questions": [["question": "Anything else?", "options": [["label": "Other"]]]]]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Anything else?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "Other", description: nil, preview: nil)],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let freeText = "Install ripgrep, then fd"
        let answers = AgentQuestionAnswers(prompt: prompt, answers: [.freeText(freeText)])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(answersObject["Anything else?"], freeText,
                       "a .freeText answer must be emitted raw, unencoded, even though it contains \", \"")
    }

    // MARK: - denyMessage: dismissedQuestionMessage vs the default

    /// A skipped question denies with `dismissedQuestionMessage`, passed
    /// explicitly by the caller; a plain agent-hook deny with no
    /// `denyMessage` argument keeps the default `deniedMessage`.
    func test_body_claude_denied_dismissedQuestionMessage_vs_defaultDeniedMessage() throws {
        let questionDenyData = try XCTUnwrap(
            AgentHookPermissionResponse.body(
                kind: AgentEntry.claudeCodeKind, decision: .denied,
                denyMessage: AgentHookPermissionResponse.dismissedQuestionMessage
            )
        )
        let questionOutput = try hookSpecificOutput(questionDenyData)
        let questionDecision = try XCTUnwrap(questionOutput["decision"] as? [String: Any])
        XCTAssertEqual(questionDecision["message"] as? String, AgentHookPermissionResponse.dismissedQuestionMessage,
                       "a skipped question's deny body must carry dismissedQuestionMessage")

        let plainDenyData = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .denied)
        )
        let plainOutput = try hookSpecificOutput(plainDenyData)
        let plainDecision = try XCTUnwrap(plainOutput["decision"] as? [String: Any])
        XCTAssertEqual(plainDecision["message"] as? String, AgentHookPermissionResponse.deniedMessage,
                       "a plain agent-hook deny with no explicit denyMessage must keep the default deniedMessage")
    }

    // MARK: - forbidden fields (PermissionRequest reserved/invalid keys)

    /// PermissionRequest's own contract reserves or rejects
    /// permissionDecision, permissionDecisionReason, updatedInput,
    /// updatedPermissions, and interrupt (all valid on the older
    /// PreToolUse hook, none valid here) -- pinned via an EXACT key-set
    /// assertion on both hookSpecificOutput and decision, rather than
    /// separate substring checks per forbidden name, so any stray extra
    /// field (not just these five) is caught too.
    func test_body_neverContainsForbiddenPermissionRequestFields() throws {
        let allowData = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .allowed)
        )
        let allowOutput = try hookSpecificOutput(allowData)
        XCTAssertEqual(Set(allowOutput.keys), ["hookEventName", "decision"],
                       "an allowed decision's hookSpecificOutput must contain exactly hookEventName and decision")
        let allowDecision = try XCTUnwrap(allowOutput["decision"] as? [String: Any])
        XCTAssertEqual(Set(allowDecision.keys), ["behavior"],
                       "an allowed decision's decision object must contain exactly behavior")

        let denyData = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .denied)
        )
        let denyOutput = try hookSpecificOutput(denyData)
        XCTAssertEqual(Set(denyOutput.keys), ["hookEventName", "decision"],
                       "a denied decision's hookSpecificOutput must contain exactly hookEventName and decision")
        let denyDecision = try XCTUnwrap(denyOutput["decision"] as? [String: Any])
        XCTAssertEqual(Set(denyDecision.keys), ["behavior", "message"],
                       "a denied decision's decision object must contain exactly behavior and message")
    }
}
