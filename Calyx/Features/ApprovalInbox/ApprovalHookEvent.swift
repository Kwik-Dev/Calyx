// ApprovalHookEvent.swift
// Calyx
//
// Single source of truth for the hook event Calyx's synchronous approval
// entry fires under: ClaudeHooksConfigManager and CodexHooksConfigManager
// both install their approval command entry keyed to this event name,
// GrokHooksConfigManager keys Grok's entry to that CLI's own blocking
// event instead, CalyxMCPServer.routeApprovalRequest gates the approval
// endpoint on an incoming request naming the event its kind's gate fires
// under, and AgentHookPermissionResponse echoes the PermissionRequest
// name back in its own response body's hookSpecificOutput.hookEventName.
// All of them must agree, or a future rename that updates the installers
// without updating the gate (or vice versa) leaves every new install's
// approval banner silently inert -- see CalyxMCPServer.routeApprovalRequest's
// own doc comment for exactly that failure mode during the PreToolUse ->
// PermissionRequest migration this type was introduced for. Mirrors
// ApprovalHookTiming's own "one file, one cross-layer contract fact"
// precedent.
//
// It also owns the one permission-mode fact the approval route branches
// on: which mode leaves Calyx's gate as the only approval mechanism
// behind a call (gateIsSoleAuthority), since for Grok that is what
// decides whether a banner belongs to Calyx or to Grok's own pane.

import Foundation

enum ApprovalHookEvent {
    /// The hook event Claude Code / Codex fire once they've already
    /// decided a tool call needs a confirmation prompt, unlike
    /// PreToolUse, which fires for every tool call regardless of
    /// whether it needs approval.
    static let name = "PermissionRequest"

    /// The event key GrokHooksConfigManager registers the approval gate
    /// under. Grok has no PermissionRequest event at all: PreToolUse is
    /// its only blocking one, so that is where the gate has to live, and
    /// it fires for every tool call rather than only the ones Grok would
    /// have prompted for itself.
    static let grokRegistrationName = "PreToolUse"

    /// What that same event is called in the stdin payload Grok hands the
    /// gate. Grok's hook file keys are PascalCase while its event values
    /// are snake_case, so the two spellings above and below are the same
    /// event named twice, and `isApprovalGate(_:kind:)` is what keeps the
    /// registration and the gate from drifting apart.
    static let grokPayloadName = "pre_tool_use"

    /// Whether `hookEventName` names the event `kind`'s synchronous
    /// approval gate fires under. The kind allowlist and the payload
    /// shape are independent axes, so grok accepts either spelling: a
    /// forwarded PreToolUse payload names `pre_tool_use`, while a
    /// PermissionRequest-shaped payload is still a request for a
    /// decision Calyx has a response contract for.
    static func isApprovalGate(_ hookEventName: String?, kind: String) -> Bool {
        if hookEventName == name { return true }
        return kind == AgentEntry.grokKind && hookEventName == grokPayloadName
    }

    /// Grok's always-approve permission mode, in the spelling its hook
    /// payloads carry. Every Grok hook payload names the mode its
    /// session runs in; the others its hook documentation lists are
    /// `default`, `auto` and `plan`.
    static let grokBypassPermissionsMode = "bypassPermissions"

    /// Whether Calyx's gate is the only approval mechanism standing
    /// between the call this payload describes and its execution, and so
    /// whether Calyx should raise a banner for it at all.
    ///
    /// Always true for claude-code and codex: their PermissionRequest
    /// event fires only for calls those CLIs have already decided to
    /// prompt about, and the hook's answer IS that prompt's answer.
    ///
    /// Always true for pi too, by the opposite route: pi ships no
    /// permission prompt at all, so its extension gate fires for every
    /// tool call and nothing behind that gate would ever ask anyone.
    ///
    /// Grok is mode-dependent. Its gate is PreToolUse, which runs before
    /// the permission system rather than in place of it: a hook deny
    /// stops the call, while a hook allow, or no decision at all, falls
    /// through to Grok's own deny/ask rules, remembered grants and
    /// in-pane prompt. So under `default`, `auto` and `plan` a Calyx
    /// banner would ask a question Grok is about to ask again in its own
    /// pane, and Calyx's allow could not grant anything anyway. Only
    /// under `bypassPermissions` does that pipeline run the call without
    /// asking anyone, which is what makes Calyx's gate the sole
    /// mechanism there.
    ///
    /// An absent or unrecognized mode is not `bypassPermissions`, so the
    /// gate stays out of the way: silence leaves Grok deciding exactly as
    /// it would if Calyx were not installed, which is the same property
    /// claude-code's and codex's silence relies on.
    static func gateIsSoleAuthority(kind: String, permissionMode: String?) -> Bool {
        guard kind == AgentEntry.grokKind else { return true }
        return permissionMode == grokBypassPermissionsMode
    }
}
