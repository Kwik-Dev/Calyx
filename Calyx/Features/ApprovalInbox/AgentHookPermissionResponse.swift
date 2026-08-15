// AgentHookPermissionResponse.swift
// Calyx
//
// The PermissionRequest hook stdout body Calyx writes back to a CLI
// agent to carry a human's approval decision into that CLI's own
// synchronous permission gate -- shape and field names follow the
// PermissionRequest hook-response contract both Claude Code and Codex
// document (`hookSpecificOutput.decision.behavior`), replacing the
// older PreToolUse-era `hookSpecificOutput.permissionDecision` /
// `permissionDecisionReason` shape entirely -- neither CLI recognizes
// those two field names under PermissionRequest.
//
// This body only ever emits `behavior` and, for a deny, `message`: a
// deliberate intersection of both CLIs' contracts, not every field
// either one individually allows. `updatedInput`, `updatedPermissions`,
// and `interrupt` are all Codex fail-closed under PermissionRequest --
// Codex rejects the whole response if any of them is present -- so none
// of them may ever appear in a body this type could send to Codex.
// Claude Code is less restrictive (its own reference documents
// `updatedPermissions` as a valid field for `"allow"`, and `message` /
// `interrupt` as valid for `"deny"` only), but this type does not use
// that extra room: emitting only the shared subset keeps one code path
// safe for both CLIs, without a per-kind branch for fields that would
// make Codex reject the response. Neither CLI has an "ask" analog under
// PermissionRequest -- an expired decision produces no body at all for
// either kind, so the CLI's own confirmation prompt takes over.
//
// FAIL-SAFE CONTRACT: `body(kind:decision:)` returns `nil` for any
// `kind` other than `AgentEntry.claudeCodeKind` / `AgentEntry.codexKind`.
// Calyx must never inject a permission decision into a CLI hook
// protocol it doesn't recognize -- guessing at an unknown CLI's own
// stdout shape risks either silently authorizing a dangerous action or
// corrupting that CLI's own parsing of its hook's output.

import Foundation

enum AgentHookPermissionResponse {

    /// Builds the JSON body for a CLI agent's PermissionRequest hook
    /// stdout, encoding `decision` in the shared `hookSpecificOutput
    /// .decision.behavior` shape both Claude Code and Codex document.
    /// `nil` for any `kind` other than `claude-code`/`codex` (see this
    /// file's header), and also for `.expired` on either kind (no
    /// fallback body under PermissionRequest -- absent output lets that
    /// CLI's own confirmation prompt take over).
    static func body(kind: String, decision: ApprovalDecision) -> Data? {
        switch kind {
        case AgentEntry.claudeCodeKind, AgentEntry.codexKind:
            guard let behavior = behavior(for: decision) else { return nil }
            return encode(behavior: behavior)
        default:
            return nil
        }
    }

    /// `nil` for `.expired`: PermissionRequest has no "ask" analog, so an
    /// expired decision produces no body at all rather than a fabricated
    /// one.
    private static func behavior(for decision: ApprovalDecision) -> String? {
        switch decision {
        case .allowed: return "allow"
        case .denied: return "deny"
        case .expired: return nil
        }
    }

    /// A denied decision additionally carries a non-empty, human-readable
    /// `message`; an allowed decision carries only `behavior` -- neither
    /// PermissionRequest CLI contract defines a message field for allow.
    private static func encode(behavior: String) -> Data? {
        var decision: [String: Any] = ["behavior": behavior]
        if behavior == "deny" {
            decision["message"] = "Denied from the Calyx approval inbox."
        }
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": ApprovalHookEvent.name,
                "decision": decision,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
