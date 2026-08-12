//
//  AgentRowDisplayTests.swift
//  CalyxTests
//
//  Tests (herdr TRACK B): AgentRowDisplay.primaryLabel,
//  extracted from AgentStatusView's AgentRowView.displayName so it's
//  directly testable. Pins a deliberate behavior change: an empty-cwd
//  row's primary label must fall back to AgentEntry.displayName(forKind:)
//  instead of the hardcoded "Claude Code" string, which previously
//  mislabelled an empty-cwd codex/opencode row as "Claude Code".
//
//  Coverage:
//  - Non-empty cwd: basename wins regardless of kind (unaffected by
//    this change)
//  - Empty/nil cwd + claude-code kind: falls back to "Claude Code" (the
//    common case, unaffected by this change -- displayName(forKind:)
//    happens to already resolve to the same string)
//  - Empty/nil cwd + codex/opencode kind: falls back to the CORRECT
//    per-kind label instead of the hardcoded "Claude Code" -- the
//    actual regression this change fixes.
//

import XCTest
@testable import Calyx

@MainActor
final class AgentRowDisplayTests: XCTestCase {

    // MARK: - Non-empty cwd

    func test_primaryLabel_nonEmptyCwd_returnsBasenameRegardlessOfKind() {
        XCTAssertEqual(
            AgentRowDisplay.primaryLabel(cwd: "/Users/dev/repo-a", kind: AgentEntry.codexKind),
            "repo-a"
        )
    }

    // MARK: - Empty/nil cwd, claude-code kind (unaffected baseline)

    func test_primaryLabel_emptyCwd_claudeCodeKind_fallsBackToClaudeCode() {
        XCTAssertEqual(
            AgentRowDisplay.primaryLabel(cwd: "", kind: AgentEntry.claudeCodeKind),
            "Claude Code"
        )
    }

    func test_primaryLabel_nilCwd_claudeCodeKind_fallsBackToClaudeCode() {
        XCTAssertEqual(
            AgentRowDisplay.primaryLabel(cwd: nil, kind: AgentEntry.claudeCodeKind),
            "Claude Code"
        )
    }

    // MARK: - Empty/nil cwd, non-claude-code kind (the fix)

    func test_primaryLabel_emptyCwd_codexKind_fallsBackToDisplayNameNotHardcodedClaudeCode() {
        // Regression: before this change, ANY empty-cwd row (regardless
        // of kind) was mislabelled "Claude Code" -- including a codex
        // row that has not yet reported a cwd. This is a deliberate
        // behavior change, not a coincidental side effect; see this
        // file's header.
        XCTAssertEqual(
            AgentRowDisplay.primaryLabel(cwd: "", kind: AgentEntry.codexKind),
            "Codex",
            "An empty-cwd codex row must be labelled \"Codex\", not the hardcoded \"Claude Code\""
        )
    }

    func test_primaryLabel_nilCwd_openCodeKind_fallsBackToDisplayNameNotHardcodedClaudeCode() {
        XCTAssertEqual(
            AgentRowDisplay.primaryLabel(cwd: nil, kind: AgentEntry.openCodeKind),
            "OpenCode",
            "A nil-cwd opencode row must be labelled \"OpenCode\", not the hardcoded \"Claude Code\""
        )
    }
}
