// AgentEvent.swift
// Calyx
//
// Data model for AI agent lifecycle state (AgentEntry) and the decoded form
// of a Claude Code hook's stdin JSON payload (AgentEvent).

import Foundation

// MARK: - AgentState

enum AgentState: Sendable, Equatable {
    case blocked, working, done, idle
}

// MARK: - AgentSource

enum AgentSource: Sendable, Equatable {
    case hooks, mcpConnection, titleHeuristic
    /// A row sourced from an external agent runtime (herdr) rather than
    /// Calyx's own hooks/title-heuristic pipeline. Stored in
    /// `AgentRegistry.externalEntries`, a separate store from `entries`
    /// -- see that property's doc comment.
    case external
}

// MARK: - AgentEntry

struct AgentEntry: Identifiable, Sendable, Equatable {
    var id: UUID { surfaceID }
    let surfaceID: UUID
    var sessionID: String?
    var source: AgentSource
    var state: AgentState
    var cwd: String?
    /// Identifies which agent CLI this entry belongs to. Always
    /// `"claude-code"` in v1 (the only integration `AgentRegistry` wires
    /// up); Phase 2 adds `"codex"` / `"opencode"` alongside their own
    /// hook/plugin sources.
    var kind: String
    var lastEventAt: Date
    /// Count of unread IPC messages waiting for the peer bound to this
    /// surface, kept in sync by `AgentRegistry.updateInbox` /
    /// `syncInboxCounts` from `IPCStore`'s current inbox count.
    var unreadCount: Int = 0
    /// The Calyx surface (if any) an `.external` entry's row should
    /// focus when clicked -- an external entry's own `surfaceID` is not
    /// necessarily a Calyx `SurfaceRegistry` UUID, so this is a
    /// separate, optional pointer to a Calyx-hosted surface that
    /// represents the same agent (if one exists). `nil` for every
    /// Native (`.hooks`/`.mcpConnection`/`.titleHeuristic`) entries, whose
    /// own `surfaceID` already IS the surface to focus. Defaulted so every
    /// existing call site
    /// is unaffected.
    var focusSurfaceID: UUID? = nil
}

extension AgentEntry {
    /// Human-readable label for `kind`, shown as the row's secondary
    /// line in `AgentStatusView`.
    static func displayName(forKind kind: String) -> String {
        switch kind {
        case Self.claudeCodeKind: return "Claude Code"
        case Self.codexKind: return "Codex"
        case Self.openCodeKind: return "OpenCode"
        case Self.hermesKind: return "Hermes Agent"
        case Self.grokKind: return "Grok"
        default: return kind
        }
    }
}

extension AgentEntry {
    /// `kind` constants for the three agent CLIs `AgentRegistry` produces
    /// entries for: `AgentHookScript`'s `$1` argv default for Claude Code,
    /// `CodexHooksConfigManager`'s installed `command` argument for Codex,
    /// and `OpenCodePluginManager`'s `X-Calyx-Agent-Kind` header for
    /// OpenCode all resolve to one of these three.
    static let claudeCodeKind = "claude-code"
    static let codexKind = "codex"
    /// Keep in sync with the `"opencode"` literal in
    /// `OpenCodePluginManager.scriptBody`'s `X-Calyx-Agent-Kind` header —
    /// that value lives in a JS string embedded in a Swift string constant,
    /// so it can't reference this constant directly.
    static let openCodeKind = "opencode"
    static let hermesKind = "hermes"
    /// Grok's `kind`: `GrokHooksConfigManager`'s installed `command`
    /// argument and `GrokConfigManager`'s `X-Calyx-Agent-Kind` header
    /// both resolve to this.
    static let grokKind = "grok"
}

// MARK: - AgentEvent

/// Decoded form of a Claude Code hook's stdin JSON payload
/// (`hook_event_name` / `session_id` / `cwd` / `message`, snake_case), or
/// of Grok's camelCase equivalent normalized onto the same field and
/// event-name vocabulary -- see `decode(from:)`.
struct AgentEvent: Sendable, Equatable {
    let hookEventName: String
    let sessionID: String?
    let cwd: String?
    let message: String?
    /// For a `PreToolUse` event whose `tool_name` is one of Calyx's own
    /// `mcp__calyx-ipc__*` tools, this surface's own peer ID (extracted
    /// from `tool_input.from` for `send_message`/`broadcast`, or
    /// `tool_input.peer_id` for `receive_messages`) — or,
    /// for a `PostToolUse` event whose `tool_name` is
    /// `mcp__calyx-ipc__register_peer`, the peer ID the server just
    /// generated for this surface (`tool_response.peerId`) — used by
    /// `AgentRegistry` to learn the surface-to-peer binding that drives
    /// unread-message badges. Registering the binding right at
    /// `register_peer` itself (rather than waiting for this surface's
    /// first `send_message`/`receive_messages`/etc. call) means an
    /// unread message sent to it immediately after registration still
    /// lights up the badge. `nil` for every other event / tool
    /// (including `list_peers`, which carries no self-identifying peer
    /// ID field).
    ///
    /// `var`, not `let`: a stored property needs `var` for Swift to
    /// include it as an overridable (rather than permanently
    /// default-only) parameter in the synthesized memberwise
    /// initializer — see SE-0242. Every mutation in practice still goes
    /// through `decode(from:)`'s single construction site.
    var ipcSelfPeerID: String? = nil

    /// Decodes a hook's stdin JSON payload. `hook_event_name` is mandatory;
    /// all other fields are optional. Unknown fields are tolerated.
    ///
    /// A payload that names no `hook_event_name` at all but does name
    /// `hookEventName` is Grok's envelope and goes through
    /// `decodeGrokShaped` instead: Grok spells every key in camelCase and
    /// every event value in snake_case, and a `/bin/sh` hook script cannot
    /// rewrite JSON, so the normalization happens here. A payload carrying
    /// both keys is a Claude Code / Codex payload and stays on the
    /// snake_case path, which reads no camelCase alias of any field.
    static func decode(from data: Data) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["hook_event_name"] == nil, object["hookEventName"] != nil {
            return decodeGrokShaped(object: object)
        }
        guard let hookEventName = object["hook_event_name"] as? String else {
            return nil
        }
        return AgentEvent(
            hookEventName: hookEventName,
            sessionID: object["session_id"] as? String,
            cwd: object["cwd"] as? String,
            message: object["message"] as? String,
            ipcSelfPeerID: extractIPCSelfPeerID(hookEventName: hookEventName, object: object)
        )
    }

    /// Grok's `stop` `reason` for a genuine turn end. Grok fires an extra
    /// observe-only `stop` at session teardown with `channel_closed` or
    /// `shutdown`; treating those as turn ends would roll a
    /// `SessionEnd`-settled `.done` row back to `.idle`.
    private static let grokTurnEndReason = "end_turn"

    /// The one `notificationType` that fires while a permission UI is
    /// actually waiting. The accompanying `message` is display text that
    /// changes between releases, so the type is what gets matched.
    private static let grokPermissionNotificationType = "permission_prompt"

    /// Decodes Grok's camelCase envelope. `hookEventName` is the only
    /// field Grok guarantees; everything else is optional.
    ///
    /// An event carrying a non-empty `subagentType` happened inside a
    /// child agent, so its name is left as the unmapped raw value (which
    /// `AgentRegistry.resultingState` ignores) and its `sessionId` / `cwd`
    /// are dropped: recording a child's session ID into the pane's resume
    /// meta would make a later reattach offer `grok --resume <child>`.
    ///
    /// No `ipcSelfPeerID` is extracted here: Grok binds its peer through
    /// the MCP `initialize` surface header rather than through tool
    /// arguments.
    private static func decodeGrokShaped(object: [String: Any]) -> AgentEvent? {
        guard let rawEventName = object["hookEventName"] as? String else { return nil }

        let subagentType = object["subagentType"] as? String
        let isSubagentEvent = !(subagentType ?? "").isEmpty

        return AgentEvent(
            hookEventName: isSubagentEvent ? rawEventName : grokEventName(rawEventName, object: object),
            sessionID: isSubagentEvent ? nil : object["sessionId"] as? String,
            cwd: isSubagentEvent ? nil : object["cwd"] as? String,
            message: object["message"] as? String,
            ipcSelfPeerID: nil
        )
    }

    /// Maps a Grok event value onto the event vocabulary
    /// `AgentRegistry.resultingState` reads. An unmapped name is passed
    /// through verbatim so the registry ignores it rather than the
    /// decoder inventing a state change.
    private static func grokEventName(_ rawEventName: String, object: [String: Any]) -> String {
        switch rawEventName {
        case "session_start":
            return "SessionStart"
        case "user_prompt_submit":
            return "UserPromptSubmit"
        case "pre_tool_use":
            return "PreToolUse"
        case "post_tool_use", "post_tool_use_failure":
            // A failed tool call still means the turn is running.
            return "PostToolUse"
        case "stop":
            guard let reason = object["reason"] as? String else { return "Stop" }
            return reason == grokTurnEndReason ? "Stop" : rawEventName
        case "stop_failure", "stop_cancelled":
            // Either runs instead of `stop` when a turn ends on an API
            // error or without completing: the turn is over either way.
            return "Stop"
        case "session_end":
            return "SessionEnd"
        case "notification":
            return (object["notificationType"] as? String) == grokPermissionNotificationType
                ? "PermissionRequest" : "Notification"
        default:
            return rawEventName
        }
    }

    /// `tool_name`s whose self peer ID is carried in `tool_input.from`
    /// (the sender identifies itself when originating a message).
    private static let fromKeyToolNames: Set<String> = [
        "mcp__calyx-ipc__send_message", "mcp__calyx-ipc__broadcast",
    ]

    /// `tool_name`s whose self peer ID is carried in `tool_input.peer_id`
    /// (the caller identifies itself when reading its own inbox).
    private static let peerIDKeyToolNames: Set<String> = [
        "mcp__calyx-ipc__receive_messages",
    ]

    /// The one `tool_name` whose self peer ID is learned from its
    /// `PostToolUse` response (`tool_response.peerId`) rather than from
    /// `PreToolUse`'s `tool_input` — `register_peer` is the only
    /// `calyx-ipc` tool call that doesn't already know its own peer ID
    /// going in; the server generates it, so it's only available once
    /// the call has returned.
    private static let registerPeerToolName = "mcp__calyx-ipc__register_peer"

    private static func extractIPCSelfPeerID(hookEventName: String, object: [String: Any]) -> String? {
        guard let toolName = object["tool_name"] as? String else { return nil }

        if hookEventName == "PreToolUse", let toolInput = object["tool_input"] as? [String: Any] {
            if fromKeyToolNames.contains(toolName) {
                return toolInput["from"] as? String
            }
            if peerIDKeyToolNames.contains(toolName) {
                return toolInput["peer_id"] as? String
            }
        }

        if hookEventName == "PostToolUse", toolName == registerPeerToolName,
           let toolResponse = object["tool_response"] as? [String: Any] {
            return toolResponse["peerId"] as? String
        }

        return nil
    }
}
