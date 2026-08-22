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
// Row-state decisions stay in AgentStateResolver, and so does a child's
// LIFETIME: this type never inspects a non-subagent event's name.
// AgentStateResolver.resolveHook decides whether a parent-scoped event
// retires every child of the surface (AgentResolution.retiresChildren),
// and AgentRegistry.apply carries that decision out by calling
// handleSurfaceDestroyed below -- the same call site an actual row
// removal or .done settle already uses. This type reuses
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

    /// Returns the children of `parentSurfaceID`, sorted by `agentID` so
    /// repeated calls (with no mutation between them) return the exact
    /// same order -- `AgentSidebarRows.build` renders this list directly
    /// and must not have rows reorder themselves on every redraw.
    func children(of parentSurfaceID: UUID) -> [SubagentEntry] {
        (entries[parentSurfaceID] ?? [:]).values.sorted { $0.agentID < $1.agentID }
    }

    /// Applies one hook event already routed to `parentSurfaceID`. Only
    /// a subagent event (`event.agentID` present) is ever handled here.
    /// A non-subagent event -- including a parent-scoped `Stop`/
    /// `SessionEnd`/`SessionStart` that retires every child of the
    /// surface -- never reaches this type at all: `AgentRegistry
    /// .handleHookEvent` only forwards a subagent event, and a parent
    /// row's own children-retiring effect is carried out by `AgentRegistry
    /// .apply` calling `handleSurfaceDestroyed` below, driven entirely by
    /// `AgentStateResolver.resolveHook`'s `AgentResolution
    /// .retiresChildren`. This type has no vocabulary of parent event
    /// names of its own -- see this file's own header comment.
    ///
    /// A subagent event either removes the one child it names --
    /// `SubagentStop`, or a `SessionEnd` fired inside that child's own
    /// session (a Grok subagent has its own session, so its teardown
    /// arrives this way rather than as `SubagentStop`; both names report
    /// the same fact, that this child is over) -- or creates/updates
    /// that child. `SubagentStart` maps to no `AgentState` in
    /// `AgentStateResolver.resultingState(for:)`, so a newly created
    /// child starts at `.working` -- the CLI just reported it started.
    /// An event naming an `agentID` this registry has never seen before
    /// also creates a child: the CLI reported that child exists, which
    /// is a reported fact, not an invention. A subagent-scoped
    /// `SessionStart` is deliberately excluded from the removal branch
    /// below: a child's own start is not a report that the child ended,
    /// so it never removes one.
    ///
    /// A CLI that omits `agent_id` on its own `SubagentStop` still
    /// degrades rather than leaking permanently: an ACCEPTED parent
    /// `Stop`/`SessionEnd`/`SessionStart` -- resolved through the same
    /// path as every other parent-scoped event above -- still retires
    /// the lingering child once the parent's own turn or session ends.
    func handleHookEvent(_ event: AgentEvent, parentSurfaceID: UUID, now: Date = Date()) {
        guard let agentID = event.agentID else { return }

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

    /// Removes every child of `parentSurfaceID`. Called when the pane
    /// itself is destroyed (`AgentRegistry.handleSurfaceDestroyed`), and
    /// by `AgentRegistry.apply(_:surfaceID:)` on any of three
    /// resolutions: the parent's row is removed, the parent's row
    /// settles to `.done`, or the resolver accepted a parent-scoped
    /// turn/session-boundary event for the parent row
    /// (`AgentResolution.retiresChildren`) -- in every case, no child of
    /// that surface can still be running.
    func handleSurfaceDestroyed(parentSurfaceID: UUID) {
        entries.removeValue(forKey: parentSurfaceID)
    }

    /// Removes every child of every parent. Called by
    /// `AgentRegistry.reset()` -- the server stopped.
    func reset() {
        entries.removeAll()
    }
}
