//
//  AgentHookPermissionResponseTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentHookPermissionResponse.body(kind:decision:):
//  the PermissionRequest hook stdout body Calyx writes back to a CLI
//  agent to carry a human's approval decision into that CLI's own
//  synchronous permission gate -- shape and field names follow the
//  PermissionRequest hook-response contract both Claude Code and Codex
//  document (hookSpecificOutput.decision.behavior), replacing the older
//  PreToolUse-era hookSpecificOutput.permissionDecision shape entirely.
//  permissionDecision, permissionDecisionReason, updatedInput,
//  updatedPermissions, and interrupt are all reserved or invalid under
//  PermissionRequest, so none of them may ever appear in this body.
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

    // MARK: - unrecognized kind

    func test_body_unknownKind_isNilForAllDecisions() {
        let unknownKind = "some-unrecognized-cli"

        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .allowed))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .denied))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .expired))
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
