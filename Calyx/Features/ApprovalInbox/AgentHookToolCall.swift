// AgentHookToolCall.swift
// Calyx
//
// Decoded form of a CLI agent's synchronous approval-gate hook stdin
// JSON payload (`tool_name` / `tool_input`, snake_case for Claude Code
// and Codex -- the same shape the older PreToolUse hook carried; the
// camelCase `toolName` / `toolInput` for Grok) into the toolName/payload/
// summary/hookEventName/permissionMode set the approval inbox needs to
// render a banner for a non-MCP agent hook call, and the route needs to
// decide whether that banner is Calyx's to raise. Mirrors
// AgentEvent.decode's JSONSerialization-based style -- see AgentEvent.swift.

import Foundation

struct AgentHookToolCall: Sendable {
    let toolName: String
    let payload: String
    let summary: String

    /// The payload's top-level hook event name, decoded verbatim from
    /// whichever envelope the payload uses. `nil` when the key is absent,
    /// an explicit JSON `null`, or a non-string value --
    /// `routeApprovalRequest` only advances a payload into the approval
    /// flow when this names the event that CLI's synchronous gate fires
    /// under (`ApprovalHookEvent.isApprovalGate(_:kind:)`), so a stale
    /// pre-migration hook's own `"PreToolUse"` POST (or any payload
    /// missing the key entirely) must decode to something that guard can
    /// compare against, never a fabricated default.
    let hookEventName: String?

    /// The permission mode the session raising this call is running in,
    /// decoded verbatim. `nil` when the key is absent, an explicit JSON
    /// `null`, or a non-string value.
    ///
    /// Read from the top level rather than through `Envelope`: Grok
    /// documents exactly one spelling for it, it never reaches a banner
    /// (so the "name one call, describe another" hazard the envelope
    /// exists for does not apply to it), and its only reader is the grok
    /// branch of `routeApprovalRequest`, whose kind comes from the
    /// request header rather than from the payload. Claude Code's and
    /// Codex's own spelling of the same idea is deliberately NOT aliased
    /// here: nothing reads it for those kinds, and inventing a key name
    /// they may not use would pin a contract this code has not verified.
    let permissionMode: String?

    /// `payload`'s cap, in UTF-8 bytes -- see `decode(from:)` for the
    /// character-boundary truncation contract.
    static let maxPayloadBytes = 16_384

    /// `summary`'s cap, in `Character`s.
    static let maxSummaryLength = 500

    /// `tool_name`s whose `summary` is the string at `tool_input.file_path`.
    /// `NotebookEdit` is deliberately NOT in this set -- Claude Code's
    /// actual PreToolUse schema for it is `tool_input.notebook_path`, a
    /// distinct key of its own (see `derivedSummary`'s own `NotebookEdit`
    /// case).
    private static let filePathToolNames: Set<String> = ["Write", "Edit", "Read"]

    /// Tool names whose `summary` is the string at `tool_input.command`:
    /// Claude Code's and Codex's `Bash`, and Grok's own shell tool
    /// `run_terminal_command`.
    private static let commandToolNames: Set<String> = ["Bash", "run_terminal_command"]

    /// Grok's top-level permission-mode key, the one spelling its hook
    /// payloads use for it. Not part of `Envelope` -- see
    /// `permissionMode`'s own doc comment.
    private static let permissionModeKey = "permissionMode"

    /// One CLI's spelling of the three keys this payload is read from.
    /// Which spelling a payload uses is decided once, from its tool-name
    /// key alone, so a banner can never name one call and describe
    /// another.
    private struct Envelope {
        let toolNameKey: String
        let toolInputKey: String
        let hookEventNameKey: String

        static let snakeCase = Envelope(
            toolNameKey: "tool_name", toolInputKey: "tool_input", hookEventNameKey: "hook_event_name"
        )
        /// Grok's envelope. The camelCase keys are a fallback, never an
        /// override: a payload naming `tool_name` is a Claude Code /
        /// Codex payload even when it also carries camelCase keys.
        static let camelCase = Envelope(
            toolNameKey: "toolName", toolInputKey: "toolInput", hookEventNameKey: "hookEventName"
        )
    }

    /// Decodes a CLI agent's approval-gate hook stdin JSON. The tool name
    /// is mandatory (a non-empty string) -- a missing/empty/non-string
    /// value rejects the whole payload. The tool input is optional; its
    /// absence yields an empty `payload`/`summary`. The hook event name
    /// and the permission mode are optional; see their own doc comments
    /// for the absent/null/non-string decode contract they share.
    /// Unknown top-level fields are tolerated.
    ///
    /// `payload` is the compact JSON of `tool_input`, truncated to at
    /// most `maxPayloadBytes` UTF-8 bytes without ever splitting a
    /// `Character` (backs off to the last whole character that still
    /// fits, rather than cutting mid-character). `summary` is a
    /// tool-specific human-readable string (the command for `Bash` and
    /// Grok's `run_terminal_command`, the file path for
    /// `Write`/`Edit`/`Read`, the notebook path for `NotebookEdit` -- its
    /// own distinct `tool_input.notebook_path` key, never `file_path` --
    /// the URL for `WebFetch`) capped at `maxSummaryLength` characters --
    /// any other tool name, or a recognized one missing its expected key,
    /// falls back to the same compact JSON of `tool_input` used for
    /// `payload`.
    ///
    /// Grok spells the same three top-level keys `toolName` / `toolInput`
    /// / `hookEventName`. All three are read from one envelope, chosen by
    /// which tool-name key the payload carries -- see `Envelope`.
    static func decode(from data: Data) -> AgentHookToolCall? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let envelope = object[Envelope.snakeCase.toolNameKey] is String
            ? Envelope.snakeCase : Envelope.camelCase
        guard let toolName = object[envelope.toolNameKey] as? String, !toolName.isEmpty else {
            return nil
        }
        let hookEventName = object[envelope.hookEventNameKey] as? String
        let permissionMode = object[permissionModeKey] as? String

        guard let toolInput = object[envelope.toolInputKey] as? [String: Any] else {
            return AgentHookToolCall(
                toolName: toolName, payload: "", summary: "",
                hookEventName: hookEventName, permissionMode: permissionMode
            )
        }

        let compactJSON = (try? JSONSerialization.data(withJSONObject: toolInput))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        let payload = truncatedToByteCap(compactJSON, cap: maxPayloadBytes)
        let derivedSummary = derivedSummary(toolName: toolName, toolInput: toolInput, compactJSON: compactJSON)

        return AgentHookToolCall(
            toolName: toolName, payload: payload, summary: String(derivedSummary.prefix(maxSummaryLength)),
            hookEventName: hookEventName, permissionMode: permissionMode
        )
    }

    /// `summary`'s tool-specific well-known key per tool_name, falling
    /// back to `compactJSON` when `toolName` isn't one of these, or the
    /// expected key is absent/not a string.
    private static func derivedSummary(toolName: String, toolInput: [String: Any], compactJSON: String) -> String {
        switch toolName {
        case _ where commandToolNames.contains(toolName):
            return (toolInput["command"] as? String) ?? compactJSON
        case _ where filePathToolNames.contains(toolName):
            return (toolInput["file_path"] as? String) ?? compactJSON
        case "NotebookEdit":
            return (toolInput["notebook_path"] as? String) ?? compactJSON
        case "WebFetch":
            return (toolInput["url"] as? String) ?? compactJSON
        default:
            return compactJSON
        }
    }

    /// Truncates `text` to at most `cap` UTF-8 bytes without ever
    /// splitting a `Character` in half -- backs off to the last whole
    /// character that still fits under `cap`.
    private static func truncatedToByteCap(_ text: String, cap: Int) -> String {
        guard text.utf8.count > cap else { return text }
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
}
