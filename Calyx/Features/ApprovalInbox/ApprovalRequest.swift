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
        /// A `PreToolUse` call intercepted from a non-MCP CLI agent hook
        /// (Claude Code / Codex) rather than Calyx's own MCP server --
        /// `kind` identifies the owning CLI (`AgentEntry.claudeCodeKind`
        /// / `AgentEntry.codexKind`); `toolName` and `summary` come from
        /// the decoded `AgentHookToolCall`.
        case agentHook(toolName: String, kind: String, summary: String)
    }

    let id: UUID
    let source: Source
    let targetSurfaceID: UUID?
    let payload: String
    let createdAt: Date
}

enum ApprovalDecision: Sendable, Equatable {
    case allowed
    case denied
    case expired
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
        case .agentHook(let toolName, let kind, _):
            return "\(AgentEntry.displayName(forKind: kind)) · \(toolName)"
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
        case .agentHook(_, _, let summary):
            return summary
        }
    }

    /// One-line summary for the queue preview menu
    /// (`ApprovalBannerModel.queueEntries`, rendered by
    /// `ApprovalBannerView`'s queue navigator Menu):
    /// `"\(displayToolName): \(compactTarget)"`, omitting the trailing
    /// colon entirely once `compactTarget` is empty. BOTH halves are
    /// bounded here. `compactTarget` collapses every run of whitespace
    /// (including newlines/tabs) in `displayPayload` into a single
    /// space, trims the result, then truncates it to a trailing single
    /// U+2026 ellipsis once it exceeds either of two caps: 80
    /// `Character`s (plain ASCII of exactly 80 is left intact; 81
    /// becomes its first 79 plus the ellipsis) or 240 unicode scalars
    /// (see `maxTargetCharacters`/`maxTargetScalars` for why both caps
    /// are needed). `displayToolName` goes through the same two-cap
    /// truncation at `maxToolNameCharacters`/`maxToolNameScalars`,
    /// applied here rather than inside `displayToolName` itself, which
    /// the banner header renders in full. RAW, unescaped -- same caveat
    /// as `displayToolName`/`displayPayload` above
    /// (`ControlCharacterDisplay` escaping is the view layer's job,
    /// applied later, not here).
    var previewLine: String {
        let toolName = Self.truncated(displayToolName, maxCharacters: Self.maxToolNameCharacters, maxScalars: Self.maxToolNameScalars)
        let target = Self.compactTarget(from: displayPayload)
        guard !target.isEmpty else { return toolName }
        return "\(toolName): \(target)"
    }

    /// The two caps `previewLine` truncates `displayToolName` at, the
    /// same `Character`-plus-scalar pairing (and the same reasoning) as
    /// `maxTargetCharacters`/`maxTargetScalars` below. Nothing upstream
    /// bounds that string: `AgentHookToolCall.decode` caps a hook call's
    /// `summary` at `maxSummaryLength` `Character`s and its `payload` at
    /// `maxPayloadBytes` UTF-8 bytes, but takes `tool_name` from the
    /// hook JSON at whatever length it arrives, and `AgentEntry.
    /// displayName(forKind:)` passes an unrecognized `kind` through raw,
    /// so both halves of an `.agentHook` `displayToolName` come from an
    /// external process unmeasured. Uncapped, the tool name alone could
    /// stretch a menu row out to `ControlCharacterDisplay.render`'s own
    /// 2000-scalar bound. The values sit far above the longest realistic
    /// name (a composed `mcp__server__tool`, or "Claude Code ·
    /// NotebookEdit"), so a real one is never truncated.
    private static let maxToolNameCharacters = 120
    private static let maxToolNameScalars = 360

    /// The two independent caps `compactTarget(from:)` truncates at.
    /// A `Character` (extended grapheme cluster) can legally carry an
    /// unbounded number of combining-mark scalars, so a single "Zalgo"
    /// cluster counts as just 1 against a `Character`-only cap while
    /// dragging thousands of scalars into the menu row: counting scalars
    /// too is what actually bounds the string, exactly the reasoning
    /// behind `ControlCharacterDisplay.render`'s own scalar-counted
    /// `cap` (see its doc comment). The scalar cap sits well above the
    /// `Character` cap so ordinary text that spends several scalars per
    /// `Character` (accented Latin, Hangul, emoji) is still bounded by
    /// the `Character` cap alone, leaving the scalar cap to bite only on
    /// pathological input.
    private static let maxTargetCharacters = 80
    private static let maxTargetScalars = 240

    /// Collapses every whitespace run to a single space and trims the
    /// result in one step (`split(whereSeparator:)`'s default
    /// `omittingEmptySubsequences: true` drops the empty leading/
    /// trailing components a leading/trailing whitespace run would
    /// otherwise produce), then applies the target caps.
    private static func compactTarget(from payload: String) -> String {
        let collapsed = payload.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return truncated(collapsed, maxCharacters: maxTargetCharacters, maxScalars: maxTargetScalars)
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
