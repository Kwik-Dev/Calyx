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
