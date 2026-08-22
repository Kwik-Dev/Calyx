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
// LIFETIME: this type never inspects a non-subagent event's name and
// never compares sessionIDs itself. AgentStateResolver.resolveHook
// decides whether a parent-scoped SessionEnd/SessionStart, or a row
// replacement where a different session takes the row over, retires
// every child of the surface (AgentResolution.retiresChildren) -- a
// same-session parent Stop no longer does, since a CLI can and does keep
// a subagent running past its parent's own turn ending -- and
// AgentRegistry.apply carries that decision out by
// calling handleSurfaceDestroyed below -- the same call site an actual
// row removal or .done settle already uses. This type reuses
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
    /// When Calyx first observed the CLI reporting this child: stamped
    /// from `handleHookEvent`'s own `now` at creation, once, and never
    /// restamped by any later event for this child, unlike
    /// `state`/`lastToolName`/`agentType`. The CLI supplies no start
    /// timestamp of its own in any subagent event, and the event that
    /// creates the child is not necessarily `SubagentStart` -- see
    /// `handleHookEvent`'s own doc comment -- so this is an approximation
    /// of the child's start, Calyx's own receipt time of whichever event
    /// first named its `agentID`, not a timestamp the CLI reported. The
    /// sidebar renders how long the child has been running from this,
    /// not a Calyx-side timer.
    let startedAt: Date
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
    /// A non-subagent event -- including a parent-scoped `SessionEnd`/
    /// `SessionStart`, or a row replacement where a different session
    /// takes the row over, either of which retires every child of the
    /// surface -- never reaches this type at all: `AgentRegistry
    /// .handleHookEvent` only forwards a subagent event, and a parent
    /// row's own children-retiring effect is carried out by
    /// `AgentRegistry.apply` calling `handleSurfaceDestroyed` below,
    /// driven entirely by `AgentStateResolver.resolveHook`'s
    /// `AgentResolution.retiresChildren`. This type has no vocabulary of
    /// parent event names, or of sessionIDs, of its own -- see this
    /// file's own header comment. A parent's own, same-session `Stop` is
    /// not among the retiring names either, so it never reaches this
    /// type in any capacity: a child can and does keep running past its
    /// parent's own turn ending. A `Stop` that instead lands via a
    /// session-mismatch replacement does retire, since it is a different
    /// session taking the row over that matters, not the event's name.
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
    /// `SessionEnd`/`SessionStart`, or a session-mismatch row
    /// replacement -- resolved through the same path as every other
    /// parent-scoped event above -- still retires the lingering child
    /// once the parent's own session ends, restarts, or changes hands to
    /// a different session. That window is now longer than a single
    /// turn, since the parent's own, same-session `Stop` no longer
    /// retires it, but the trade is still the right one: deleting a
    /// child the CLI still reports running is the worse violation.
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
            state: .working, lastToolName: nil, startedAt: now
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

        byAgent[agentID] = child
        entries[parentSurfaceID] = byAgent
    }

    /// Removes every child of `parentSurfaceID`. Called when the pane
    /// itself is destroyed (`AgentRegistry.handleSurfaceDestroyed`), and
    /// by `AgentRegistry.apply(_:surfaceID:)` on any of three
    /// resolutions: the parent's row is removed, the parent's row
    /// settles to `.done`, or the resolver accepted a resolution for the
    /// parent row that must retire its children
    /// (`AgentResolution.retiresChildren` -- a parent-scoped
    /// session-boundary event, `SessionEnd`/`SessionStart`, or a row
    /// replacement where a different session took the surface over) --
    /// in every case, no child of that surface can still be running. An accepted,
    /// same-session parent `Stop` is not among these: it settles the
    /// parent row same as before without reaching this method at all.
    func handleSurfaceDestroyed(parentSurfaceID: UUID) {
        entries.removeValue(forKey: parentSurfaceID)
    }

    /// Removes every child of every parent. Called by
    /// `AgentRegistry.reset()` -- the server stopped.
    func reset() {
        entries.removeAll()
    }
}
