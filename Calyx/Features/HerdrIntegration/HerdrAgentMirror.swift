// HerdrAgentMirror.swift
// Calyx
//
// Translates herdr's own session state (a `HerdrSessionSnapshot`, or a
// pushed `HerdrEvent`) into `AgentRegistry` EXTERNAL entries -- the
// separate `externalEntries` store `AgentRegistry.swift` documents as
// "rows describing agents Calyx learned about from an external source
// (herdr's own event stream)". This type owns ONLY that store: it never
// reads or writes `AgentRegistry.entries` (the native hooks/
// titleHeuristic rows), matching `AgentRegistry.upsertExternalEntry` /
// `.removeExternalEntry`'s own "never touches entries" contract.
//
// `HerdrIntegrationCoordinator` (the herdr integration's lifecycle owner,
// HerdrIntegrationCoordinator.swift) is this type's only intended
// caller: it forwards every `session.snapshot()` result to
// `applySnapshot(_:socketPath:)`, every pushed `HerdrEvent` to
// `apply(event:socketPath:)`, and calls `connectionLost()` when its
// subscribed connection ends. This type itself never touches a
// transport/session/socket -- it is a pure state translator, which is
// exactly why it is injected into the coordinator as a concrete
// instance rather than needing its own transport-avoidance seam.
//
// MAPPING RULES (frozen by this file's test suite):
//
//   - herdr `HerdrAgentStatus` -> Calyx `AgentState`: idle -> .idle,
//     working -> .working, blocked -> .blocked, done -> .done.
//     A record/event whose status is unknown/unrecognized never CREATES
//     a row. For an existing row, `agent == nil` paired with `.idle` or
//     `.unknown` means herdr no longer detects that CLI while the shell
//     pane remains, so the row becomes `.done`. An unknown status that
//     still carries an agent identity remains non-actionable and leaves
//     the row untouched.
//
//   - herdr `agent` kind string -> Calyx `AgentEntry.kind`: "claude" ->
//     `AgentEntry.claudeCodeKind` ("claude-code") -- the one measured
//     correspondence (herdr and Calyx name the same CLI differently).
//     Every other kind string passes through UNCHANGED:
//     `AgentEntry.displayName(forKind:)` already falls through to the
//     raw string for anything it doesn't recognize, so an unmapped kind
//     still renders sensibly rather than needing a decode error.
//
//   - Both `cwd` (on `HerdrAgentRecord`) and `agent` (on both
//     `HerdrAgentRecord` and `HerdrPaneAgentStatusChangedEvent`) are
//     OPTIONAL on the wire, and can legitimately go missing on a record/
//     event for a pane this file already has a row for (a snapshot's
//     `cwd` momentarily unavailable, or `mapKind(nil)`'s own claude-code
//     default -- see that function's doc comment). When UPDATING an
//     existing row, `applySnapshot` and `applyStatusChanged` therefore
//     fall back to the row's OWN previous `cwd`/`kind` rather than the
//     incoming (possibly nil/defaulted) value -- a nil `cwd` must never
//     blank out an already-known working directory, and a nil `agent`
//     must never silently relabel an already-known codex/opencode row as
//     Claude Code. It may still mark that preserved-kind row `.done` per
//     the absent-agent rule above. This only applies to updates: a brand-new row (no
//     previous value to fall back to) still gets `cwd: nil` / the
//     `mapKind(nil)` default exactly as documented above and below.
//
//   - `paneCreated` is a pure no-op for this file: a plain shell pane
//     has no agent (status "unknown"), so a bare "a pane now exists"
//     structural event carries no information this file acts on --
//     `HerdrIntegrationCoordinator` is what reacts to it (a pane-set
//     change that may require rebuilding the subscribed connection);
//     the authoritative status this file DOES act on always arrives
//     either via a full `session.snapshot()` (`applySnapshot`) or a
//     dedicated `paneAgentStatusChanged` event.
//
//   - `paneAgentStatusChanged` MAY create a new row (not just update an
//     existing one) when no row exists yet for that pane AND the event
//     carries a known (non-unknown) status: herdr's per-pane
//     `pane.agent_status_changed` subscription exists for every known
//     pane from the moment it is first subscribed (see
//     HerdrIntegrationCoordinator.swift), independent of whether that
//     pane had a detected agent YET -- the common case this covers is a
//     plain shell pane (no row, status "unknown" at snapshot time) that
//     later launches Claude Code: the very first sign of that is a
//     `paneAgentStatusChanged` event with no pre-existing row to
//     "update". A row created this way has `cwd: nil` (the event
//     carries no cwd field at all) -- a degraded-but-valid row, mirrors
//     this codebase's established "a degraded row beats no row"
//     precedent (e.g. `HerdrSessionInfo`'s own doc comment).
//
//   - `paneClosed(paneID:)`/`paneExited(paneID:)` each remove that
//     pane's external row IMMEDIATELY, rather than waiting for the next
//     `applySnapshot`'s own removal pass to notice its absence --
//     `HerdrIntegrationCoordinator` already rebuilds its connection on
//     either event, but the rebuilt connection's own fresh snapshot only
//     arrives once that new handshake completes, and the sidebar row
//     should disappear the moment herdr says the pane is gone, not after
//     that round trip. A harmless no-op when this instance never owned a
//     row for that pane id (e.g. a plain shell pane that closed without
//     ever reporting a known agent status) -- `AgentRegistry
//     .removeExternalEntry` on a missing id is itself already a no-op.
//
//   - `workspaceClosed(workspaceID:)` is a pure no-op here: this file
//     only ever removes a row by PANE id (`paneClosed`/`paneExited`
//     above), and herdr does NOT push `pane.closed` for a closed
//     workspace's own panes (the measured wire fact `workspaceClosed`
//     itself exists for) -- so any external row this file owns for that
//     workspace's panes is left in place until the next `applySnapshot`
//     naturally prunes it (this file's header, the paragraph on
//     `applySnapshot`'s own removal pass, below). `HerdrIntegrationCoordinator`
//     forwards this event to `HerdrTabCoordinator` only (its own
//     `HerdrStructureEventObserver.herdrWorkspaceClosed`), never to this
//     file.
//
//   - `unknown(eventType:)` (every herdr event type this codebase
//     doesn't decode strongly, PLUS any genuinely unrecognized type --
//     see HerdrEvent.swift's own header) is a pure no-op here.
//
//   - `focusSurfaceID` stays `nil` on every entry this file produces --
//     this type never resolves a herdr pane to a Calyx-hosted surface.
//
//   - `applySnapshot(_:socketPath:)` also REMOVES any external entry
//     this instance previously created for `socketPath` that is no
//     longer present in the new snapshot's `agents[]` (by pane id, ANY
//     status -- an unknown-status record for an already-known pane
//     still counts as "present", so its row is updated or preserved by
//     the rules above rather than being pruned as "gone"). Ownership
//     is tracked PER socketPath so two independently-managed
//     connections (a future multi-session possibility) never prune each
//     other's rows.
//
// import order matches this codebase's other HerdrIntegration files
// (Foundation only -- no CryptoKit/Darwin needed here).

import Foundation

@MainActor
final class HerdrAgentMirror {

    private let registry: AgentRegistry

    /// External-entry ids this instance itself created/updated, keyed
    /// by the owning socketPath -- see this file's header for why
    /// per-socketPath (not a single flat set) and why an unknown-status
    /// pane id is still included.
    private var ownedIDsBySocketPath: [String: Set<UUID>] = [:]

    init(registry: AgentRegistry = .shared) {
        self.registry = registry
    }

    /// Applies a full `session.snapshot()` result: upserts a row for
    /// every agent record with a known (non-unknown/unrecognized)
    /// status, and removes any previously-owned row for `socketPath`
    /// no longer present in `snapshot.agents` -- see this file's header
    /// for the exact rules.
    func applySnapshot(_ snapshot: HerdrSessionSnapshot, socketPath: String) {
        var owned = ownedIDsBySocketPath[socketPath] ?? []
        var presentIDs: Set<UUID> = []

        for record in snapshot.agents {
            let id = HerdrStableID.make(socketPath: socketPath, paneID: record.paneID)
            // A record for an already-known pane counts as "present"
            // for the removal pass below EVEN with an unknown/
            // unrecognized status -- it is updated or preserved by the
            // rules above rather than pruned as gone.
            presentIDs.insert(id)

            let existing = registry.externalEntries[id]
            if record.agent == nil,
               let existing,
               Self.isAbsentAgentTerminalStatus(record.agentStatus) {
                var updated = existing
                updated.state = .done
                updated.cwd = record.cwd ?? existing.cwd
                updated.lastEventAt = Date()
                registry.upsertExternalEntry(updated)
                owned.insert(id)
                continue
            }

            guard let state = Self.mapState(record.agentStatus) else {
                // Unknown/unrecognized status with no terminal transition:
                // never create a row and leave an existing row untouched.
                continue
            }

            // A nil `cwd`/`agent` on this record must not blank
            // out or relabel an already-known row -- fall back to its
            // previous value rather than the degraded creation-time
            // default. See this file's header.
            let cwd = record.cwd ?? existing?.cwd
            let kind: String
            if let agent = record.agent {
                kind = Self.mapKind(agent)
            } else {
                kind = existing?.kind ?? Self.mapKind(nil)
            }

            registry.upsertExternalEntry(AgentEntry(
                surfaceID: id,
                sessionID: nil,
                source: .external,
                state: state,
                cwd: cwd,
                kind: kind,
                lastEventAt: Date()
            ))
            owned.insert(id)
        }

        for staleID in owned.subtracting(presentIDs) {
            registry.removeExternalEntry(id: staleID)
        }
        owned.formIntersection(presentIDs)
        ownedIDsBySocketPath[socketPath] = owned
    }

    /// Applies one pushed `HerdrEvent`: `paneAgentStatusChanged` updates
    /// (or creates) that pane's row; `paneClosed`/`paneExited` remove
    /// that pane's row immediately; `paneCreated`, `workspaceClosed`, and
    /// `unknown` are no-ops -- see this file's header for the exact
    /// rules.
    func apply(event: HerdrEvent, socketPath: String) {
        switch event {
        case .paneCreated:
            // Pure no-op for this file -- see this file's header.
            break
        case .paneAgentStatusChanged(let changed):
            applyStatusChanged(changed, socketPath: socketPath)
        case .paneClosed(let paneID), .paneExited(let paneID):
            removeRow(paneID: paneID, socketPath: socketPath)
        case .workspaceClosed:
            // Pure no-op for this file -- see this file's header.
            break
        case .unknown:
            break
        }
    }

    /// Removes every external entry this instance owns (across every
    /// socketPath it has ever applied a snapshot/event for), leaving
    /// `registry.entries` (native rows) completely untouched -- this
    /// instance never had access to that store in the first place.
    func connectionLost() {
        for (_, ids) in ownedIDsBySocketPath {
            for id in ids {
                registry.removeExternalEntry(id: id)
            }
        }
        ownedIDsBySocketPath.removeAll()
    }

    // MARK: - paneClosed / paneExited

    /// `apply(event:socketPath:)`'s real work for `.paneClosed`/
    /// `.paneExited` -- see this file's header. Removes the row for
    /// `paneID` (owned by `socketPath`) from the registry immediately,
    /// and drops it from `ownedIDsBySocketPath` too, so a later
    /// `connectionLost()`/`applySnapshot(_:socketPath:)` never redundantly
    /// tries to remove it again. A harmless no-op when no row was ever
    /// created for this `(socketPath, paneID)` pair -- both the registry
    /// removal and the set removal below are no-ops for an id that was
    /// never present.
    private func removeRow(paneID: String, socketPath: String) {
        let id = HerdrStableID.make(socketPath: socketPath, paneID: paneID)
        registry.removeExternalEntry(id: id)
        ownedIDsBySocketPath[socketPath]?.remove(id)
    }

    // MARK: - paneAgentStatusChanged

    /// `apply(event:socketPath:)`'s real work for `.paneAgentStatusChanged`
    /// -- see this file's header ("MAY create a new row... when no row
    /// exists yet for that pane"). Updating an EXISTING row only touches
    /// `state`/`lastEventAt`, and `kind` when `changed.agent` is non-nil
    /// (a nil `agent` must not relabel an already-known row --
    /// see this file's header). `cwd` is never touched on update, full
    /// stop -- this event carries no cwd field at all, and a status
    /// change must never wipe out a cwd a prior snapshot already
    /// established, mirroring `AgentRegistry.handleHookEvent`'s own "cwd
    /// is not re-derived here" precedent. Creating a new row leaves `cwd`
    /// nil and applies `mapKind`'s own nil-agent default, per this file's
    /// header.
    private func applyStatusChanged(_ changed: HerdrPaneAgentStatusChangedEvent, socketPath: String) {
        let id = HerdrStableID.make(socketPath: socketPath, paneID: changed.paneID)

        if changed.agent == nil,
           let existing = registry.externalEntries[id],
           Self.isAbsentAgentTerminalStatus(changed.agentStatus) {
            var updated = existing
            updated.state = .done
            updated.lastEventAt = Date()
            registry.upsertExternalEntry(updated)
            var owned = ownedIDsBySocketPath[socketPath] ?? []
            owned.insert(id)
            ownedIDsBySocketPath[socketPath] = owned
            return
        }

        guard let state = Self.mapState(changed.agentStatus) else {
            // Unknown/unrecognized status with no terminal transition:
            // never creates a row and leaves an existing row untouched.
            return
        }

        if let existing = registry.externalEntries[id] {
            var updated = existing
            updated.state = state
            if let agent = changed.agent {
                updated.kind = Self.mapKind(agent)
            }
            updated.lastEventAt = Date()
            registry.upsertExternalEntry(updated)
        } else {
            registry.upsertExternalEntry(AgentEntry(
                surfaceID: id,
                sessionID: nil,
                source: .external,
                state: state,
                cwd: nil,
                kind: Self.mapKind(changed.agent),
                lastEventAt: Date()
            ))
        }

        var owned = ownedIDsBySocketPath[socketPath] ?? []
        owned.insert(id)
        ownedIDsBySocketPath[socketPath] = owned
    }

    // MARK: - Mapping helpers

    /// herdr `HerdrAgentStatus` -> Calyx `AgentState`, per this file's
    /// header. `nil` for `.unknown`/`.unrecognized` -- the caller's own
    /// absent-agent terminal handling before falling back to no-op.
    private static func mapState(_ status: HerdrAgentStatus) -> AgentState? {
        switch status {
        case .idle: return .idle
        case .working: return .working
        case .blocked: return .blocked
        case .done: return .done
        case .unknown, .unrecognized: return nil
        }
    }

    /// herdr keeps the shell pane after an agent CLI exits and reports the
    /// transition as `agent: nil` with an idle/unknown status. That is a
    /// completed agent run, not an idle live agent.
    private static func isAbsentAgentTerminalStatus(_ status: HerdrAgentStatus) -> Bool {
        switch status {
        case .idle, .unknown:
            return true
        case .working, .blocked, .done, .unrecognized:
            return false
        }
    }

    /// herdr `agent` kind string -> Calyx `AgentEntry.kind`, per this
    /// file's header: "claude" maps to `AgentEntry.claudeCodeKind`,
    /// every other string passes through unchanged. A `nil` agent falls
    /// back to `AgentEntry.claudeCodeKind`, matching the same default
    /// `AgentRegistry.handleTitleChange`/`.handleScreenClassification`
    /// already use whenever no other kind information is available --
    /// this is only the right default for a brand-new row. `agent` CAN
    /// be nil alongside a KNOWN (non-"unknown") status too, not only
    /// herdr's documented "unknown"-status default (see this file's
    /// header), so `applySnapshot` / `applyStatusChanged` never
    /// call this with `nil` when UPDATING an already-known row -- they
    /// preserve that row's previous `kind` instead.
    private static func mapKind(_ agent: String?) -> String {
        guard let agent else { return AgentEntry.claudeCodeKind }
        return agent == "claude" ? AgentEntry.claudeCodeKind : agent
    }
}
