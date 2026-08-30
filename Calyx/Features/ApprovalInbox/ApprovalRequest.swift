// ApprovalRequest.swift
// Calyx
//
// Cockpit approval-core data model: a pending gated action (e.g. an MCP
// tool call) waiting on a human decision from the approval inbox. See
// ApprovalInboxStore for the queueing/decision lifecycle and
// ApprovalPolicy for whether a given action requires approval at all.

import Foundation

struct ApprovalRequest: Identifiable, Sendable {
    enum Source: Sendable, Equatable {
        case mcpTool(name: String)
        /// A tool call intercepted from a non-MCP CLI agent's own
        /// approval-gate hook (Claude Code / Codex / Grok), or from pi's
        /// extension gate, rather than Calyx's own MCP server -- `kind`
        /// identifies the owning CLI (`AgentEntry.claudeCodeKind` /
        /// `AgentEntry.codexKind` / `AgentEntry.grokKind` /
        /// `AgentEntry.piKind`); `toolName` and `summary` come from the
        /// decoded `AgentHookToolCall`.
        case agentHook(toolName: String, kind: String, summary: String, offers: AgentHookOffers)
        /// Claude Code's `AskUserQuestion` tool call, decoded into an
        /// `AgentQuestionPrompt` rather than the generic `.agentHook`
        /// summary -- the approval banner renders this as option buttons
        /// instead of a Deny/Always Allow/Allow row. `kind` is always
        /// `AgentEntry.claudeCodeKind` (see `AgentHookToolCall.question`'s
        /// own doc comment for why no other kind ever produces one), kept
        /// here rather than hardcoded so `displayToolName` stays a plain
        /// switch over `Source` with no special-cased kind literal. No
        /// separate `toolName`: it is always "AskUserQuestion" (the gate
        /// that produces a `.agentQuestion` at all), so there is nothing
        /// for a second field to carry that `displayToolName`'s own
        /// "Question" literal doesn't already say.
        case agentQuestion(kind: String, prompt: AgentQuestionPrompt)
    }

    let id: UUID
    let source: Source
    let targetSurfaceID: UUID?
    let payload: String
    let createdAt: Date
}

/// What an `.agentHook`-sourced request may offer beyond the plain
/// "Yes"/"No" -- everything `AgentToolApprovalView` reads to decide which
/// rows/buttons to render, all derived once at decode time
/// (`AgentHookToolCall`) so the view never branches on `kind` itself.
struct AgentHookOffers: Sendable, Equatable {
    /// One choice row per element -- see `AgentPermissionOffer`.
    let permissionUpdates: [AgentPermissionOffer]
    /// The `tool_input` field name `AgentToolApprovalView`'s "Amend…" flow
    /// may rewrite -- see `AgentHookToolCall.amendableField`.
    let amendableField: String?
    /// The whole original `tool_input`, re-serialized -- `amendableField`'s
    /// current value is read from this, and `.allowedWithInput(_:)`
    /// replaces that one field on a copy of this whole object. A non-nil
    /// `amendableField` always implies a non-nil `originalToolInputJSON`
    /// (it can only be derived from a decoded `tool_input`); the converse
    /// does not hold, since `tool_input` decodes into this field for
    /// every kind, not only one whose `amendableField` is non-nil.
    let originalToolInputJSON: Data?
    /// Whether this kind's hook accepts `interrupt: true` -- gates the
    /// [Cancel] button (`.interrupted(.cancelled)`).
    let canStop: Bool
    /// Whether [Answer in Pane] renders at all -- `capabilities.
    /// promptsWhenUndecided`. Resolving `.expired` sends that kind no
    /// body at all, and only a kind that then shows its own prompt has
    /// anything in the pane to answer; for grok/pi the same `.expired`
    /// encodes as an explicit deny (`AgentHookPermissionResponse.
    /// flatBody`), so a button promising a pane prompt would in fact
    /// refuse the call.
    let canAnswerInPane: Bool
    /// Per request, not per kind: true iff `permissionUpdates` is
    /// non-empty on a kind whose hook accepts `updatedPermissions` --
    /// i.e. this request actually carries at least one CLI always-allow
    /// row. When true, the CLI itself persists the human's always-allow
    /// choice through one of those rows, so `ApprovalBannerModel.
    /// alwaysAllow(id:)`/`alwaysAllowAcrossPanes(id:)` (Calyx's OWN
    /// pane/cross-pane memory) are no-ops for this request: recording a
    /// second, Calyx-side memory alongside the CLI's own would be
    /// redundant and could silently diverge from it. When the CLI's own
    /// kind accepts `updatedPermissions` but this particular request
    /// offered no usable suggestion, `cliOwnsPersistence` is still
    /// false: Calyx's own memory is the only persistence available, and
    /// the pane-scoped row renders again.
    let cliOwnsPersistence: Bool

    /// The all-capabilities-off constant: no permission updates, no amend,
    /// no cancel, no answer-in-pane, and Calyx's own pane/cross-pane
    /// Always-Allow memory is the only persistence available. Used as a
    /// default where no offers apply -- test fixtures and any caller with
    /// no decoded call at hand -- not something `routeApprovalRequest`
    /// itself produces. A claude-code request whose payload offered no
    /// usable `permission_suggestions` carries `cliOwnsPersistence: false`
    /// but is NOT this constant: it still keeps `canStop`/`canAnswerInPane`/
    /// `amendableField` per claude-code's own capabilities.
    static let none = AgentHookOffers(
        permissionUpdates: [], amendableField: nil, originalToolInputJSON: nil,
        canStop: false, canAnswerInPane: false, cliOwnsPersistence: false
    )
}

/// Why a `.denied` decision was made -- the model/view pick a reason,
/// never a wire string; `AgentHookPermissionResponse` alone maps a reason
/// to the message/reason text a given `kind`'s hook actually reads.
enum DenyReason: Sendable, Equatable {
    /// The human clicked "No" on an ordinary tool-call banner.
    case userRejected
    /// The human dismissed an `.agentQuestion` prompt (Cancel) without
    /// answering it.
    case questionNotAnswered
}

/// Why an `.interrupted` decision was made.
enum InterruptReason: Sendable, Equatable {
    /// The banner's own [Cancel] action on an `.agentHook`-sourced
    /// request whose `offers.canStop` is true.
    case cancelled
    /// The question banner's [Chat about this] action -- the human wants
    /// to reply free-form in the pane instead of answering the structured
    /// prompt.
    case chatAboutQuestion
}

enum ApprovalDecision: Sendable, Equatable {
    case allowed
    /// Accepting one of `AgentHookOffers.permissionUpdates` -- the CLI's
    /// own "always allow" choice, echoed back verbatim.
    case allowedWithPermissions(AgentPermissionOffer)
    /// Accepting an "Amend…" edit -- the whole original `tool_input` with
    /// `AgentHookOffers.amendableField` replaced.
    case allowedWithInput(Data)
    case denied(DenyReason)
    /// The banner's own [Cancel]/[Chat about this] action -- distinct
    /// from `.denied`: the CLI is told to STOP and wait for the human,
    /// not that the call was refused.
    case interrupted(InterruptReason)
    case expired
    /// A human's answer to an `.agentQuestion`-sourced request's
    /// `AskUserQuestion` prompt -- see `AgentQuestionAnswers`.
    case answered(AgentQuestionAnswers)
}

extension ApprovalRequest {
    /// The tool-name label `ApprovalBannerView` renders in its header.
    /// RAW, unescaped -- escaping untrusted text for display is
    /// `ControlCharacterDisplay`'s job, applied later in the view layer,
    /// not here. `.mcpTool` is just the tool's own name (today's
    /// semantics, unchanged); `.agentHook` combines the owning CLI's
    /// display label (`AgentEntry.displayName(forKind:)`) with the tool
    /// name, since an agent-hook call has no MCP tool name of its own.
    var displayToolName: String {
        switch source {
        case .mcpTool(let name):
            return name
        case .agentHook(let toolName, let kind, _, _):
            return "\(AgentEntry.displayName(forKind: kind)) · \(toolName)"
        case .agentQuestion(let kind, _):
            return "\(AgentEntry.displayName(forKind: kind)) · Question"
        }
    }

    /// The payload text `ApprovalBannerView` renders in its body. RAW,
    /// unescaped, same caveat as `displayToolName` above. `.mcpTool`
    /// reuses `payload` unchanged (today's semantics); `.agentHook` uses
    /// the hook call's own `summary` instead -- `payload` there is the
    /// full (and possibly large) `tool_input` JSON, not what's meant for
    /// display.
    var displayPayload: String {
        switch source {
        case .mcpTool:
            return payload
        case .agentHook(_, _, let summary, _):
            return summary
        case .agentQuestion(_, let prompt):
            return prompt.questions.map(\.text).joined(separator: "\n")
        }
    }

    /// One-line summary for the queue preview menu
    /// (`ApprovalBannerModel.queueEntries`, rendered by
    /// `ApprovalBannerView`'s queue navigator Menu):
    /// `"\(displayToolName): \(compactTarget)"`, omitting the trailing
    /// colon entirely once `compactTarget` is empty. `compactTarget`
    /// collapses every run of whitespace (including newlines/tabs) in
    /// `displayPayload` into a single space and trims the result,
    /// leaving its length alone: how long a menu row may be is a
    /// question about how wide it DRAWS, which only the view can answer
    /// (`ApprovalBannerView.fittedToMenuWidth(_:)` bounds the finished
    /// row in points and elides its middle). `displayToolName` still
    /// goes through a two-cap truncation at `maxToolNameCharacters`/
    /// `maxToolNameScalars`, applied here rather than inside
    /// `displayToolName` itself, which the banner header renders in
    /// full. RAW, unescaped -- same caveat as `displayToolName`/
    /// `displayPayload` above (`ControlCharacterDisplay` escaping is the
    /// view layer's job, applied later, not here).
    var previewLine: String {
        let toolName = Self.truncated(displayToolName, maxCharacters: Self.maxToolNameCharacters, maxScalars: Self.maxToolNameScalars)
        let target = Self.compactTarget(from: displayPayload)
        guard !target.isEmpty else { return toolName }
        return "\(toolName): \(target)"
    }

    /// The two caps `previewLine` truncates `displayToolName` at. A
    /// `Character` (extended grapheme cluster) can legally carry an
    /// unbounded number of combining-mark scalars, so a single "Zalgo"
    /// cluster counts as just 1 against a `Character`-only cap while
    /// dragging thousands of scalars into the row: counting scalars too
    /// is what actually bounds the string, exactly the reasoning behind
    /// `ControlCharacterDisplay.render`'s own scalar-counted `cap` (see
    /// its doc comment). Nothing upstream bounds that string:
    /// `AgentHookToolCall.decode` caps a hook call's `summary` at
    /// `maxSummaryLength` `Character`s and its `payload` at
    /// `maxPayloadBytes` UTF-8 bytes, but takes `tool_name` from the
    /// hook JSON at whatever length it arrives, and `AgentEntry.
    /// displayName(forKind:)` passes an unrecognized `kind` through raw,
    /// so both halves of an `.agentHook` `displayToolName` come from an
    /// external process unmeasured. The values sit far above the longest
    /// realistic name (a composed `mcp__server__tool`, or "Claude Code ·
    /// NotebookEdit"), so a real one is never truncated.
    private static let maxToolNameCharacters = 120
    private static let maxToolNameScalars = 360

    /// Collapses every whitespace run to a single space and trims the
    /// result in one step (`split(whereSeparator:)`'s default
    /// `omittingEmptySubsequences: true` drops the empty leading/
    /// trailing components a leading/trailing whitespace run would
    /// otherwise produce).
    private static func compactTarget(from payload: String) -> String {
        payload.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Truncates to a trailing single U+2026 ellipsis as soon as EITHER
    /// cap is exceeded, returning `text` untouched while both hold. The
    /// truncated form appends whole `Character`s only (never splitting a
    /// grapheme cluster) and reserves one `Character` and one scalar of
    /// each budget for that ellipsis, so the returned string itself
    /// satisfies both caps. A leading cluster already wider than the
    /// scalar budget therefore leaves nothing but that ellipsis.
    private static func truncated(_ text: String, maxCharacters: Int, maxScalars: Int) -> String {
        guard text.count > maxCharacters || text.unicodeScalars.count > maxScalars else {
            return text
        }

        var truncated = ""
        var characterCount = 0
        var scalarCount = 0
        for character in text {
            let characterScalars = character.unicodeScalars.count
            guard characterCount < maxCharacters - 1,
                  scalarCount + characterScalars <= maxScalars - 1 else { break }
            truncated.append(character)
            characterCount += 1
            scalarCount += characterScalars
        }
        return truncated + "…"
    }
}
