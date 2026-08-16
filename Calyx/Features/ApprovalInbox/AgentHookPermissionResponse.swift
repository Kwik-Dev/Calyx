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
// Grok is the exception to every sentence above: its gate is PreToolUse
// (it has no PermissionRequest event at all) and its decision vocabulary
// is a flat, top-level `{"decision":"allow"}` /
// `{"decision":"deny","reason":"..."}`. Its allow body carries the
// decision alone -- Grok reads `hookSpecificOutput` only for
// `updatedInput`, and an `updatedInput` that fails the tool's schema
// BLOCKS the call, so nothing extra may ride along. Grok also has no
// "ask" analog, and silence at its gate hands the call back to Grok's
// own permission pipeline rather than to a guaranteed prompt: a hook
// deny stops a call, while a hook allow only declines to deny and falls
// through to that pipeline. Under `bypassPermissions` the pipeline runs
// the call without asking anyone, so a banner nobody answered would
// silently permit exactly what Calyx was asked to gate -- hence the
// expiry deny. That mode is also the only one a grok request is ever
// held for: `CalyxMCPServer.routeApprovalRequest` answers every other
// mode with no body at all
// (`ApprovalHookEvent.gateIsSoleAuthority`), so Grok's own prompt
// keeps deciding there, the same way claude-code's and codex's do.
//
// FAIL-SAFE CONTRACT: `body(kind:decision:)` returns `nil` for any
// `kind` other than `AgentEntry.claudeCodeKind` / `AgentEntry.codexKind`
// / `AgentEntry.grokKind`. Calyx must never inject a permission decision
// into a CLI hook protocol it doesn't recognize -- guessing at an
// unknown CLI's own stdout shape risks either silently authorizing a
// dangerous action or corrupting that CLI's own parsing of its hook's
// output.

import Foundation

enum AgentHookPermissionResponse {

    /// Builds the JSON body for a CLI agent's approval-gate hook stdout,
    /// encoding `decision` in the shared `hookSpecificOutput
    /// .decision.behavior` shape both Claude Code and Codex document, or
    /// in Grok's flat top-level `decision` shape. `nil` for any `kind`
    /// other than `claude-code`/`codex`/`grok` (see this file's header),
    /// and also for `.expired` on claude-code/codex (no fallback body
    /// under PermissionRequest -- absent output lets that CLI's own
    /// confirmation prompt take over; a grok request is only ever held
    /// for a decision under `bypassPermissions`, where nothing behind
    /// the gate would ask anyone, so its expiry denies instead).
    static func body(kind: String, decision: ApprovalDecision) -> Data? {
        switch kind {
        case AgentEntry.claudeCodeKind, AgentEntry.codexKind:
            guard let behavior = behavior(for: decision) else { return nil }
            return encode(behavior: behavior)
        case AgentEntry.grokKind:
            return encodeGrok(decision: decision)
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

    /// Grok's flat body: `decision` alone for an allow, `decision` plus a
    /// non-empty `reason` (Grok's spelling of the field Claude Code and
    /// Codex call `message`) for a deny. The reason is what the model is
    /// shown as the refusal explanation, so an expiry states its own
    /// rather than reusing the human-denial wording.
    private static func encodeGrok(decision: ApprovalDecision) -> Data? {
        let object: [String: Any]
        switch decision {
        case .allowed:
            object = ["decision": "allow"]
        case .denied:
            object = ["decision": "deny", "reason": "Denied from the Calyx approval inbox."]
        case .expired:
            object = [
                "decision": "deny",
                "reason": "No approval was given in the Calyx approval inbox before the request expired.",
            ]
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
