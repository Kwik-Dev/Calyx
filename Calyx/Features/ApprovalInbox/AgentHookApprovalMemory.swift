// AgentHookApprovalMemory.swift
// Calyx
//
// Session-scoped "Always Allow" memory for agent-hook approval requests
// (see ApprovalRequest.Source.agentHook). Lets a human's Always-Allow
// click on the approval banner skip the inbox entirely on a later
// matching request, without touching the blanket
// CockpitSettings.autoApproveEnabled toggle -- that setting stays a
// separate, coarser escape hatch.
//
// Trust model, stated plainly: surfaceID and kind here are whatever the
// client-supplied request headers say, with no independent verification
// of either -- this server's loopback bind plus its bearer token are the
// WHOLE authorization boundary, so any process holding that token can
// claim any surfaceID/kind and therefore any Always-Allow scope this
// memory grants.
//
// One scope: PANE (rememberPane) -- auto-allows only the exact
// (surfaceID, kind, toolName) tuple that was recorded, i.e. "always allow
// THIS tool in THIS pane".
//
// Session-scoped only: cleared entirely when the MCP server stops
// (CalyxMCPServer.stop() calls clearAll(), mirroring its own
// approvalInbox.expireAll()), and pane entries for a specific surface are
// cleared when that surface is torn down (SurfaceRegistry.
// destroySurface(_:) calls clearPaneEntries(surfaceID:), mirroring its
// own approvalInboxStore.expireForSurface(_:) call) -- never persisted to
// disk.
//
// Per-tool granularity is deliberately coarse: remembering "Bash" allows
// ALL future shell commands from that pane for the rest of the session,
// not just the one command that was actually shown in the banner. This
// mirrors CockpitSettings.autoApproveEnabled's own all-or-nothing shape,
// just narrowed to a (surfaceID, kind, toolName) tuple instead of
// everything.
//
// init() must never construct another singleton in a stored property --
// same hard rule as ApprovalInboxStore's own header comment (a prior
// circular-init crash makes this a hard rule for this codebase).

import Foundation

@MainActor
final class AgentHookApprovalMemory {

    static let shared = AgentHookApprovalMemory()

    private struct PaneKey: Hashable {
        let surfaceID: UUID
        let kind: String
        let toolName: String
    }

    private var paneEntries: Set<PaneKey> = []

    init() {}

    // MARK: - remember

    /// "Always allow THIS tool in THIS pane": scopes the memory to the
    /// exact (surfaceID, kind, toolName) tuple.
    func rememberPane(surfaceID: UUID, kind: String, toolName: String) {
        paneEntries.insert(PaneKey(surfaceID: surfaceID, kind: kind, toolName: toolName))
    }

    // MARK: - query

    func isAutoAllowed(surfaceID: UUID, kind: String, toolName: String) -> Bool {
        paneEntries.contains(PaneKey(surfaceID: surfaceID, kind: kind, toolName: toolName))
    }

    // MARK: - clear

    /// Removes only `surfaceID`'s own pane entries, leaving every other
    /// surface's pane entries untouched. Called from
    /// SurfaceRegistry.destroySurface(_:), mirroring that method's own
    /// approvalInboxStore.expireForSurface(_:) cleanup.
    func clearPaneEntries(surfaceID: UUID) {
        paneEntries = paneEntries.filter { $0.surfaceID != surfaceID }
    }

    /// Clears all pane memory. Called from CalyxMCPServer.stop(),
    /// mirroring that method's own approvalInbox.expireAll() cleanup.
    func clearAll() {
        paneEntries.removeAll()
    }
}
