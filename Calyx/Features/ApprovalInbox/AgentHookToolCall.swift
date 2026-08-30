// AgentHookToolCall.swift
// Calyx
//
// Decoded form of a CLI agent's synchronous approval-gate hook stdin
// JSON payload (`tool_name` / `tool_input`, snake_case for Claude Code
// and Codex -- the same shape the older PreToolUse hook carried; the
// camelCase `toolName` / `toolInput` for Grok) into the toolName/payload/
// summary/hookEventName/permissionMode/question set the approval inbox
// needs to render a banner for a non-MCP agent hook call, and the route
// needs to decide whether that banner is Calyx's to raise. Mirrors
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

    /// Populated only for a claude-code `AskUserQuestion` call whose
    /// `tool_input.questions` decodes at least one usable `Question` --
    /// see `decodeQuestions(from:)` for the lenient, drop-the-bad-element
    /// decode contract. `nil` for every other kind or tool name, or when
    /// `tool_input.questions` decodes zero usable questions, in which
    /// case `toolName`/`payload`/`summary` still decode exactly as they
    /// would for any other tool call -- and `routeApprovalRequest` still
    /// raises a (generic `.agentHook`) banner for it, never auto-allowed
    /// (see `isQuestionTool`).
    let question: AgentQuestionPrompt?

    /// True iff this call is claude-code's own `AskUserQuestion` tool --
    /// `kind == AgentEntry.claudeCodeKind && toolName == "AskUserQuestion"`
    /// -- regardless of whether `tool_input.questions` actually decoded
    /// into `question`. Every AskUserQuestion call must reach a human: an
    /// AskUserQuestion call whose `questions` failed to decode still
    /// falls back to the generic `.agentHook` banner (`question == nil`)
    /// rather than a question banner, but it must never be silently
    /// auto-allowed either -- `CalyxMCPServer.routeApprovalRequest` gates
    /// its auto-approve/Always-Allow short-circuits on THIS field, not on
    /// `question != nil`, so a decode failure can never turn into a
    /// silent allow.
    let isQuestionTool: Bool

    /// `payload`'s cap, in UTF-8 bytes -- see `decode(from:)` for the
    /// character-boundary truncation contract.
    static let maxPayloadBytes = 16_384

    /// `summary`'s cap, in `Character`s.
    static let maxSummaryLength = AgentToolSummary.maxSummaryLength

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
    /// `payload`. The derivation itself lives in
    /// `AgentToolSummary.derive(toolName:toolInput:fallback:)`, shared
    /// with the Agents sidebar's own subagent tool line.
    ///
    /// Grok spells the same three top-level keys `toolName` / `toolInput`
    /// / `hookEventName`. All three are read from one envelope, chosen by
    /// which tool-name key the payload carries -- see `Envelope`.
    ///
    /// `isQuestionTool` is the wire-boundary check for claude-code's
    /// `AskUserQuestion` tool (`kind == AgentEntry.claudeCodeKind &&
    /// toolName == "AskUserQuestion"`) -- see its own doc comment. `question`
    /// is populated only when `isQuestionTool` is true AND `tool_input.
    /// questions` decodes at least one usable question per
    /// `decodeQuestions(from:)`'s own lenient contract; every other case
    /// leaves it `nil` while every other field keeps decoding exactly as
    /// it does for any other tool call.
    static func decode(from data: Data, kind: String) -> AgentHookToolCall? {
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
        let isQuestionTool = kind == AgentEntry.claudeCodeKind && toolName == "AskUserQuestion"

        guard let toolInput = object[envelope.toolInputKey] as? [String: Any] else {
            return AgentHookToolCall(
                toolName: toolName, payload: "", summary: "",
                hookEventName: hookEventName, permissionMode: permissionMode, question: nil,
                isQuestionTool: isQuestionTool
            )
        }

        let compactJSON = AgentToolSummary.compactJSON(toolInput)

        let payload = AgentToolSummary.truncatedToByteCap(compactJSON, cap: maxPayloadBytes)
        let derivedSummary = AgentToolSummary.derive(
            toolName: toolName, toolInput: toolInput, fallback: compactJSON
        )

        let question = isQuestionTool ? decodeQuestions(from: toolInput) : nil

        return AgentHookToolCall(
            toolName: toolName, payload: payload, summary: String(derivedSummary.prefix(maxSummaryLength)),
            hookEventName: hookEventName, permissionMode: permissionMode, question: question,
            isQuestionTool: isQuestionTool
        )
    }

    /// Reads `value` as a strict JSON boolean, `nil` for anything else --
    /// in particular a JSON number. `JSONSerialization` bridges both a
    /// JSON `true`/`false` and a JSON number to `NSNumber`, so a plain
    /// `as? Bool` cast also accepts `1`/`0`; `CFGetTypeID` distinguishes
    /// the two by comparing against `CFBooleanGetTypeID()`, since only an
    /// actual JSON boolean bridges to the `CFBoolean` singleton type.
    private static func strictJSONBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// Decodes `tool_input.questions` into an `AgentQuestionPrompt`,
    /// leniently: every AskUserQuestion call must be answerable in Calyx,
    /// so a malformed ELEMENT is dropped rather than rejecting the whole
    /// prompt (the old, stricter contract) -- only a `nil` `question` (no
    /// element survived at all) falls back to the generic `.agentHook`
    /// banner, which cannot be auto-allowed either (see `isQuestionTool`).
    ///
    /// `toolInput` must carry a `questions` array; `nil` otherwise. Each
    /// element that is an object with a non-empty `question` (`String`)
    /// becomes a `Question`; every other element (not an object, or
    /// missing/empty `question`) is dropped. `nil` overall iff zero
    /// elements survive. Within a surviving element, `options`: each
    /// element that is an object with a `label` (`String`) becomes an
    /// `Option`; every other element is dropped; a missing or non-array
    /// `options` yields an empty options list (an empty-options question
    /// still renders -- see `ApprovalBannerView`'s own free-text-only
    /// layout for it). `header`/`multiSelect`/an option's `description`/
    /// `preview` are optional: absent, an explicit JSON `null`, or (for
    /// `multiSelect`) a non-boolean value -- including a JSON number like
    /// `1`, which `strictJSONBool` rejects rather than accepting as
    /// `true` -- all decode the same way: `nil` for the `String?` fields,
    /// `false` for `multiSelect`.
    ///
    /// `originalToolInputJSON` is the WHOLE `toolInput` object (not just
    /// `questions`) re-serialized verbatim -- see `AgentQuestionPrompt`'s
    /// own doc comment for why.
    private static func decodeQuestions(from toolInput: [String: Any]) -> AgentQuestionPrompt? {
        guard let questionsArray = toolInput["questions"] as? [Any] else {
            return nil
        }

        var questions: [AgentQuestionPrompt.Question] = []
        for questionValue in questionsArray {
            guard let questionObject = questionValue as? [String: Any],
                  let text = questionObject["question"] as? String, !text.isEmpty else { continue }

            var options: [AgentQuestionPrompt.Option] = []
            if let optionsArray = questionObject["options"] as? [Any] {
                for optionValue in optionsArray {
                    guard let optionObject = optionValue as? [String: Any],
                          let label = optionObject["label"] as? String else { continue }
                    options.append(AgentQuestionPrompt.Option(
                        label: label,
                        description: optionObject["description"] as? String,
                        preview: optionObject["preview"] as? String
                    ))
                }
            }

            questions.append(AgentQuestionPrompt.Question(
                text: text, header: questionObject["header"] as? String,
                options: options, multiSelect: strictJSONBool(questionObject["multiSelect"]) ?? false
            ))
        }

        guard !questions.isEmpty,
              let originalToolInputJSON = try? JSONSerialization.data(withJSONObject: toolInput) else {
            return nil
        }
        return AgentQuestionPrompt(questions: questions, originalToolInputJSON: originalToolInputJSON)
    }
}
