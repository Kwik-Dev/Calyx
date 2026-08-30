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
// This body only ever emits `behavior` and, for a deny, `message` -- with
// exactly one documented exception: `.answered` (claude-code only, see
// below) additionally emits `updatedInput`. Otherwise it is a deliberate
// intersection of both CLIs' contracts, not every field either one
// individually allows. `updatedInput`, `updatedPermissions`,
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
// Grok and pi are the exception to every sentence above: neither reads
// the nested envelope, and both answer in a flat, top-level
// `{"decision":"allow"}` / `{"decision":"deny","reason":"..."}`
// vocabulary. Grok's gate is PreToolUse (it has no PermissionRequest
// event at all); pi's is a `tool_call` extension handler that reads this
// body itself and returns `{ block: true, reason }` on a deny. The allow
// body carries the decision alone -- Grok reads `hookSpecificOutput`
// only for `updatedInput`, and an `updatedInput` that fails the tool's
// schema BLOCKS the call, so nothing extra may ride along.
//
// Neither has an "ask" analog, and for both an expired decision maps to
// an explicit deny -- a banner nobody answered within the hold window is
// not an approval -- but the two get there for different reasons.
//
// Silence at Grok's gate hands the call back to Grok's own permission
// pipeline rather than to a guaranteed prompt: a hook deny stops a call,
// while a hook allow only declines to deny and falls through to that
// pipeline. Under `bypassPermissions` the pipeline runs the call without
// asking anyone, so a banner nobody answered would silently permit
// exactly what Calyx was asked to gate -- hence the expiry deny. That
// mode is also the only one a grok request is ever held for:
// `CalyxMCPServer.routeApprovalRequest` answers every other mode with no
// body at all (`ApprovalHookEvent.gateIsSoleAuthority`), so Grok's own
// prompt keeps deciding there, the same way claude-code's and codex's
// do.
//
// pi has no such pipeline in any mode: it ships no permission prompt at
// all (`docs/usage.md`: it intentionally does not include permission
// popups), so Calyx's gate is the only approval mechanism a pi tool call
// ever passes through, and an expiry has nothing to defer to. Silence
// would run the call unreviewed.
//
// `.answered` is claude-code's own AskUserQuestion decision (see
// `ApprovalDecision.answered(_:)`): `behavior: "allow"` plus
// `updatedInput`, which is the ENTIRE original `tool_input` echoed back
// verbatim (`AgentQuestionPrompt.originalToolInputJSON`, re-parsed as a
// JSON object) plus an `answers` key mapping each question's own text to
// its chosen value -- Claude Code's own hook contract documents
// `updatedInput` as replacing the whole input object, so every unchanged
// field (e.g. `questions` itself, or an unknown key such as `metadata`)
// must round-trip through here too, not just `questions`. `nil` for
// every other kind -- codex fails closed on any `updatedInput` at all
// (see above), and grok/pi have no question tool reaching their gate.
//
// FAIL-SAFE CONTRACT: `body(kind:decision:)` returns `nil` for any
// `kind` other than `AgentEntry.claudeCodeKind` / `AgentEntry.codexKind`
// / `AgentEntry.grokKind` / `AgentEntry.piKind`. Calyx must never inject
// a permission decision into a CLI hook protocol it doesn't recognize --
// guessing at an unknown CLI's own stdout shape risks either silently
// authorizing a dangerous action or corrupting that CLI's own parsing of
// its hook's output.

import Foundation

enum AgentHookPermissionResponse {

    /// The deny message every plain decline uses by default -- overridden
    /// by `denyMessage` for a skipped `AskUserQuestion` prompt (see
    /// `dismissedQuestionMessage`).
    static let deniedMessage = "Denied from the Calyx approval inbox."

    /// The message a skipped `AskUserQuestion` prompt denies with --
    /// distinct from `deniedMessage` because the human dismissed a
    /// QUESTION rather than declining a tool call outright. Passed as
    /// `denyMessage` by `CalyxMCPServer.routeApprovalRequest` when the
    /// resolved request was `.agentQuestion`-sourced.
    static let dismissedQuestionMessage = "The user dismissed this question in the Calyx approval inbox without answering."

    /// Claude Code's own multi-select answer encoding (2.1.251, verbatim
    /// from the binary): `labels.map(t => t.includes(", ") || t.includes('"')
    /// ? JSON.stringify(t) : t).join(", ")`. On receipt Claude Code parses
    /// the string back apart (a quoted token via `JSON.parse`, a bare token
    /// by splitting on `", "`) and only recognizes the result as a listed
    /// selection if re-encoding those parsed tokens reproduces the string
    /// exactly and every token names a listed option -- so a label that
    /// itself contains `", "` or `"` MUST be JSON-string-quoted here, or
    /// Claude Code's own round-trip check silently fails to recognize the
    /// answer. This round-trip check runs ONLY for a multi-select answer
    /// (the binary's own recognition logic: `W.has(B)` -- is the raw
    /// string a member of the listed label set -- checked FIRST, and only
    /// falls through to the quoted round-trip when the question is
    /// multi-select): a single-select answer is matched against its
    /// listed labels verbatim, so this function must never be applied to
    /// one -- `encodedValue(for:)` is the only caller, and only for
    /// `.selectedMany`. Kept internal (not `private`), not because
    /// production code outside this encoder may call it -- it may not --
    /// but so a test can exercise the encoding rule directly, independent
    /// of `encodeAnswered`'s own JSON envelope. A one-element multi-select
    /// answer still goes through this function, matching Claude Code's
    /// own dialog.
    static func selectedLabelsAnswerValue(_ labels: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return labels.map { label in
            guard label.contains(", ") || label.contains("\"") else { return label }
            let quoted = try? encoder.encode(label)
            guard let quoted, let json = String(data: quoted, encoding: .utf8) else { return label }
            return json
        }.joined(separator: ", ")
    }

    /// Builds the JSON body for a CLI agent's approval-gate hook stdout,
    /// encoding `decision` in the shared `hookSpecificOutput
    /// .decision.behavior` shape both Claude Code and Codex document, or
    /// in the flat top-level `decision` shape Grok and pi read. `nil` for
    /// any `kind` other than `claude-code`/`codex`/`grok`/`pi` (see this
    /// file's header), and also for `.expired` on claude-code/codex (no
    /// fallback body under PermissionRequest -- absent output lets that
    /// CLI's own confirmation prompt take over; a grok request is only
    /// ever held for a decision under `bypassPermissions`, where nothing
    /// behind the gate would ask anyone, and pi has no prompt of its own
    /// in any mode, so both of those expiries deny instead). `.answered`
    /// is claude-code only -- `nil` for every other kind (see this file's
    /// own header comment). `denyMessage` is the `message`/`reason` a
    /// `.denied` decision carries; callers pass `dismissedQuestionMessage`
    /// for a skipped question, `deniedMessage` (the default) otherwise.
    static func body(kind: String, decision: ApprovalDecision, denyMessage: String = deniedMessage) -> Data? {
        if case .answered(let answers) = decision {
            return kind == AgentEntry.claudeCodeKind ? encodeAnswered(answers) : nil
        }
        switch kind {
        case AgentEntry.claudeCodeKind, AgentEntry.codexKind:
            guard let behavior = behavior(for: decision) else { return nil }
            return encode(behavior: behavior, denyMessage: denyMessage)
        case AgentEntry.grokKind, AgentEntry.piKind:
            return encodeFlatDecision(decision, denyMessage: denyMessage)
        default:
            return nil
        }
    }

    /// `nil` for `.expired`: PermissionRequest has no "ask" analog, so an
    /// expired decision produces no body at all rather than a fabricated
    /// one. `.answered` never reaches here -- `body(kind:decision:
    /// denyMessage:)`'s own early return handles it before this is called.
    private static func behavior(for decision: ApprovalDecision) -> String? {
        switch decision {
        case .allowed: return "allow"
        case .denied: return "deny"
        case .expired: return nil
        case .answered: return nil // unreachable, see this method's own doc comment
        }
    }

    /// Wraps `decision` in the `hookSpecificOutput{hookEventName,
    /// decision}` envelope both Claude Code and Codex document -- the one
    /// shape `encode(behavior:denyMessage:)` and `encodeAnswered(_:)` both
    /// produce.
    private static func envelope(decision: [String: Any]) -> Data? {
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": ApprovalHookEvent.name,
                "decision": decision,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// A denied decision additionally carries a non-empty, human-readable
    /// `message`; an allowed decision carries only `behavior` -- neither
    /// PermissionRequest CLI contract defines a message field for allow.
    private static func encode(behavior: String, denyMessage: String) -> Data? {
        var decision: [String: Any] = ["behavior": behavior]
        if behavior == "deny" {
            decision["message"] = denyMessage
        }
        return envelope(decision: decision)
    }

    /// claude-code's `.answered` body: `behavior: "allow"` plus
    /// `updatedInput` -- the original `tool_input` object (`answers.prompt.
    /// originalToolInputJSON`, re-parsed) with `"answers"` set on it, so
    /// the key set is the original keys plus `answers` (for a plain
    /// payload, exactly `questions` + `answers`) -- see this file's own
    /// header comment for why the whole object round-trips, not just
    /// `questions`. `encodedValue(for:)` is the ONE place that turns an
    /// `AgentQuestionAnswer` (free of wire encoding, see that type's own
    /// doc comment) into the string Claude Code's own hook reads.
    private static func encodeAnswered(_ answers: AgentQuestionAnswers) -> Data? {
        guard var updatedInput = try? JSONSerialization.jsonObject(with: answers.prompt.originalToolInputJSON) as? [String: Any] else {
            return nil
        }
        var answersObject: [String: String] = [:]
        for (question, answer) in zip(answers.prompt.questions, answers.answers) {
            answersObject[question.text] = encodedValue(for: answer)
        }
        updatedInput["answers"] = answersObject
        let decision: [String: Any] = [
            "behavior": "allow",
            "updatedInput": updatedInput,
        ]
        return envelope(decision: decision)
    }

    /// The wire string for one question's answer -- the sole place this
    /// type maps `AgentQuestionAnswer` to what Claude Code's own
    /// AskUserQuestion recognition logic expects (2.1.251 binary):
    /// `.selectedOne` sends the label RAW, since a single-select answer is
    /// matched against `W` (the listed label set) verbatim; `.selectedMany`
    /// runs the labels through `selectedLabelsAnswerValue` (the quoted
    /// round-trip, which that recognition logic only falls through to for
    /// a multi-select question); `.freeText` sends the typed text RAW --
    /// free text is meant to reach the CLI unencoded, never matched
    /// against `W` at all.
    private static func encodedValue(for answer: AgentQuestionAnswer) -> String {
        switch answer {
        case .selectedOne(let label): return label
        case .selectedMany(let labels): return selectedLabelsAnswerValue(labels)
        case .freeText(let text): return text
        }
    }

    /// Grok's and pi's flat body: `decision` alone for an allow,
    /// `decision` plus a non-empty `reason` (their spelling of the field
    /// Claude Code and Codex call `message`) for a deny. The reason is
    /// what the model is shown as the refusal explanation -- pi hands it
    /// straight to the model as the blocked call's tool result content --
    /// so an expiry states its own rather than reusing the human-denial
    /// wording. `denyMessage` mirrors `encode(behavior:denyMessage:)`'s
    /// own parameter for symmetry, though neither grok nor pi reaches
    /// this with a question to dismiss today (a question is claude-code
    /// only). `.answered` never reaches here -- `body(kind:decision:
    /// denyMessage:)`'s own early return handles it before this is called.
    private static func encodeFlatDecision(_ decision: ApprovalDecision, denyMessage: String) -> Data? {
        let object: [String: Any]
        switch decision {
        case .allowed:
            object = ["decision": "allow"]
        case .denied:
            object = ["decision": "deny", "reason": denyMessage]
        case .expired:
            object = [
                "decision": "deny",
                "reason": "No approval was given in the Calyx approval inbox before the request expired.",
            ]
        case .answered:
            return nil // unreachable, see this method's own doc comment
        }
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
