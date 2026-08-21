// SubagentRegistry.swift
// Calyx
//
// Storage for the child rows a CLI's subagent hook events report,
// separate from AgentRegistry.entries -- a child never becomes a row of
// its own (AgentEntry.id == surfaceID is the "one pane, one row"
// foundation; see .claude/architecture.md section 5). Children live only
// as long as the CLI reports them: no timer, no retention count, no
// eviction policy.
//
// Row-state decisions stay in AgentStateResolver. This type reuses
// AgentStateResolver.resultingState(for:) for a child's own state so no
// child-specific vocabulary is ever duplicated -- the same table decides
// what a hook event means for a parent row and for a child row.

import Foundation

/// One child row: a subagent a CLI currently reports running under a
/// parent pane. `id` combines `parentSurfaceID` and `agentID` because a
/// child's identity only exists relative to the parent that reported it
/// -- two different parents could in principle report the same raw
/// `agentID` string.
struct SubagentEntry: Identifiable, Sendable, Equatable {
    let parentSurfaceID: UUID
    let agentID: String
    var agentType: String?
    var state: AgentState
    var lastToolName: String?
    var lastEventAt: Date
    var id: String { "\(parentSurfaceID.uuidString)/\(agentID)" }
}

@MainActor
@Observable
final class SubagentRegistry {

    /// Child rows keyed by parent surface, then by the child's own
    /// `agentID`. `AgentEntry.id == surfaceID` is the "one pane, one
    /// row" foundation elsewhere in `AgentMonitor` -- this store never
    /// feeds `AgentRegistry.entries` / `externalEntries`, so a child can
    /// never collide with or replace a pane's own row.
    private(set) var entries: [UUID: [String: SubagentEntry]] = [:]

    /// Hook event names that, on the PARENT's own event (never a
    /// subagent event), remove every child of that parent -- the turn
    /// ended, the session ended, or a new session started, so no child
    /// of the OLD session/turn can still be running. This is also what
    /// makes a CLI that omits `agent_id` on its own `SubagentStop`
    /// degrade (children linger until the parent's turn ends) rather
    /// than leak permanently.
    private static let parentSweepEventNames: Set<String> = [
        "Stop", "SessionEnd", "SessionStart",
    ]

    /// Returns the children of `parentSurfaceID`, sorted by `agentID` so
    /// repeated calls (with no mutation between them) return the exact
    /// same order -- `AgentSidebarRows.build` renders this list directly
    /// and must not have rows reorder themselves on every redraw.
    func children(of parentSurfaceID: UUID) -> [SubagentEntry] {
        (entries[parentSurfaceID] ?? [:]).values.sorted { $0.agentID < $1.agentID }
    }

    /// Applies one hook event already routed to `parentSurfaceID`.
    ///
    /// A non-subagent event (`event.isSubagentEvent == false`) only ever
    /// sweeps: if its name is `parentSweepEventNames`, every child of
    /// `parentSurfaceID` is removed. Every other non-subagent event is a
    /// no-op here -- `AgentStateResolver` already handles what it means
    /// for the parent's own row.
    ///
    /// A subagent event (`agentID` present) either removes the one child
    /// it names -- `SubagentStop`, or a `SessionEnd` fired inside that
    /// child's own session (a Grok subagent has its own session, so its
    /// teardown arrives this way rather than as `SubagentStop`; both
    /// names report the same fact, that this child is over) -- or
    /// creates/updates that child. `SubagentStart` maps to no
    /// `AgentState` in `AgentStateResolver.resultingState(for:)`, so a
    /// newly created child starts at `.working` -- the CLI just reported
    /// it started. An event naming an `agentID` this registry has never
    /// seen before also creates a child: the CLI reported that child
    /// exists, which is a reported fact, not an invention. A
    /// subagent-scoped `SessionStart` is deliberately excluded from this
    /// removal rule: a child's own start is not a report that the child
    /// ended, so it never removes one.
    func handleHookEvent(_ event: AgentEvent, parentSurfaceID: UUID, now: Date = Date()) {
        guard let agentID = event.agentID else {
            if Self.parentSweepEventNames.contains(event.hookEventName) {
                entries.removeValue(forKey: parentSurfaceID)
            }
            return
        }

        if event.hookEventName == "SubagentStop" || event.hookEventName == "SessionEnd" {
            entries[parentSurfaceID]?.removeValue(forKey: agentID)
            if entries[parentSurfaceID]?.isEmpty == true {
                entries.removeValue(forKey: parentSurfaceID)
            }
            return
        }

        var byAgent = entries[parentSurfaceID] ?? [:]
        var child = byAgent[agentID] ?? SubagentEntry(
            parentSurfaceID: parentSurfaceID, agentID: agentID, agentType: nil,
            state: .working, lastToolName: nil, lastEventAt: now
        )

        if let newState = AgentStateResolver.resultingState(for: event) {
            child.state = newState
        }
        if event.hookEventName == "PreToolUse" || event.hookEventName == "PostToolUse",
           let toolName = event.toolName {
            child.lastToolName = toolName
        }
        if let agentType = event.agentType {
            child.agentType = agentType
        }
        child.lastEventAt = now

        byAgent[agentID] = child
        entries[parentSurfaceID] = byAgent
    }

    /// Removes every child of `parentSurfaceID`. Called both when the
    /// pane itself is destroyed (`AgentRegistry.handleSurfaceDestroyed`)
    /// and whenever `AgentRegistry.apply(_:surfaceID:)` sees a resolution
    /// remove the parent's row or settle it to `.done` -- either way, no
    /// child of that surface can still be running.
    func handleSurfaceDestroyed(parentSurfaceID: UUID) {
        entries.removeValue(forKey: parentSurfaceID)
    }

    /// Removes every child of every parent. Called by
    /// `AgentRegistry.reset()` -- the server stopped.
    func reset() {
        entries.removeAll()
    }
}
