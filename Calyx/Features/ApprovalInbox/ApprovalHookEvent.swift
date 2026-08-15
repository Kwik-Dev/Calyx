// ApprovalHookEvent.swift
// Calyx
//
// Single source of truth for the hook event Calyx's synchronous approval
// entry fires under: ClaudeHooksConfigManager and CodexHooksConfigManager
// both install their approval command entry keyed to this event name,
// CalyxMCPServer.routeApprovalRequest gates the approval endpoint on an
// incoming request naming exactly this event, and AgentHookPermissionResponse
// echoes it back in its own response body's hookSpecificOutput.hookEventName.
// All four must agree, or a future rename that updates the installers
// without updating the gate (or vice versa) leaves every new install's
// approval banner silently inert -- see CalyxMCPServer.routeApprovalRequest's
// own doc comment for exactly that failure mode during the PreToolUse ->
// PermissionRequest migration this type was introduced for. Mirrors
// ApprovalHookTiming's own "one file, one cross-layer contract fact"
// precedent.

import Foundation

enum ApprovalHookEvent {
    /// The hook event Claude Code / Codex fire once they've already
    /// decided a tool call needs a confirmation prompt, unlike
    /// PreToolUse, which fires for every tool call regardless of
    /// whether it needs approval.
    static let name = "PermissionRequest"
}
