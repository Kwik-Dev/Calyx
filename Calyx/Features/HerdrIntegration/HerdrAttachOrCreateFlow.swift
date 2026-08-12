// HerdrAttachOrCreateFlow.swift
// Calyx
//
// SessionBrowserWindowController.attachHerdr(_:)'s own flow: fetch a
// LIVE session.snapshot on socketPath, then either open every workspace
// it names (today's existing-workspace attach, unchanged) or, when it
// names zero, send workspace.create and open the one workspace that
// creates. Decides from this fresh snapshot only, never from a herdr
// row's own cached counts -- those drive just the Attach/New button
// title (HerdrAttachGate.decide, SessionBrowserModel.swift) -- so a
// stale row can never send the wrong request.
//
// openWorkspace is injected as the SAME HerdrTabCoordinator
// .openWorkspace(workspaceID:socketPath:) entry point every
// existing-workspace attach already calls: there is exactly one place
// that opens a workspace as a native Calyx tab, and this file never
// reimplements it. Injected (rather than taking a HerdrTabCoordinator
// directly) so this flow is testable with a plain spy closure, without
// constructing a full coordinator -- see HerdrAttachOrCreateFlowTests.swift.
//
// @MainActor: openWorkspace's production closure captures a @MainActor
// HerdrTabCoordinator; running this flow off the main actor would force
// that capture across an isolation boundary.
//
// logger is the caller's own Logger value (Logger is a struct) passed
// in, not a second instance declared here, so every failure this file
// logs goes through the exact same logger SessionBrowserWindowController
// already uses for "Failed to open herdr workspace ...". The initial
// session.snapshot failing (herdr died, or was never reachable) stays
// silent, unchanged from today -- this integration's existing no-dialog
// contract for herdr absence/death. workspace.create failing, and the
// newly created workspace failing to open, are both NEW failure paths
// and both log.
//

import Foundation
import os

@MainActor
enum HerdrAttachOrCreateFlow {
    static func run(
        socketPath: String,
        transportFactory: any HerdrTransportFactory,
        logger: Logger,
        openWorkspace: (String, String) async -> Bool
    ) async {
        let snapshot: HerdrSessionSnapshot
        do {
            let transport = await transportFactory.makeTransport()
            let request = HerdrOneShotRequest(transport: transport)
            let result: HerdrSnapshotRPCResult = try await request.send(method: "session.snapshot", socketPath: socketPath)
            snapshot = result.snapshot
        } catch {
            return
        }

        // Workspace ids come from panes[].workspaceID -- schema-required,
        // strongly typed -- never from snapshot.workspaces, which decodes
        // as [AnyCodable] (HerdrSessionSnapshot's own doc comment).
        let workspaceIDs = Set(snapshot.panes.map(\.workspaceID)).sorted()

        guard let firstWorkspaceID = workspaceIDs.first else {
            await createAndOpen(socketPath: socketPath, transportFactory: transportFactory, logger: logger, openWorkspace: openWorkspace)
            return
        }

        // The FOCUS workspace re-opens LAST so it ends focused rather
        // than whichever opened most recently -- openWorkspace's own
        // FIRST check, focusExistingTab, short-circuits that re-open
        // into a pure focus with no wire round trip. snapshot
        // .focusedWorkspaceID wins when present AND actually named in
        // workspaceIDs; the sorted-first id otherwise.
        let focusWorkspaceID: String
        if let focusedWorkspaceID = snapshot.focusedWorkspaceID, workspaceIDs.contains(focusedWorkspaceID) {
            focusWorkspaceID = focusedWorkspaceID
        } else {
            focusWorkspaceID = firstWorkspaceID
        }

        for workspaceID in workspaceIDs {
            let opened = await openWorkspace(workspaceID, socketPath)
            if !opened {
                logger.error(
                    "Failed to open herdr workspace \(workspaceID, privacy: .public) on socket \(socketPath, privacy: .public)"
                )
            }
        }
        if workspaceIDs.count > 1 {
            let refocused = await openWorkspace(focusWorkspaceID, socketPath)
            if !refocused {
                logger.error(
                    "Failed to focus herdr workspace \(focusWorkspaceID, privacy: .public) on socket \(socketPath, privacy: .public)"
                )
            }
        }
    }

    /// The snapshot named zero workspaces: create one, then open it
    /// through the same `openWorkspace` every existing workspace uses.
    /// `workspace.create`'s params are exactly `{"focus":true}` --
    /// WorkspaceCreateParams' own schema shape (`herdr api schema
    /// --json`): `cwd`/`env`/`focus`/`label` all optional. The user
    /// chose herdr's own default working directory over sending `cwd`,
    /// and no label is invented.
    private static func createAndOpen(
        socketPath: String,
        transportFactory: any HerdrTransportFactory,
        logger: Logger,
        openWorkspace: (String, String) async -> Bool
    ) async {
        let workspaceID: String
        do {
            let transport = await transportFactory.makeTransport()
            let request = HerdrOneShotRequest(transport: transport)
            let result: HerdrWorkspaceCreateRPCResult = try await request.send(
                method: "workspace.create", params: HerdrWorkspaceCreateParams(), socketPath: socketPath
            )
            workspaceID = result.workspace.workspaceID
        } catch {
            logger.error("Failed to create herdr workspace on socket \(socketPath, privacy: .public)")
            return
        }

        let opened = await openWorkspace(workspaceID, socketPath)
        if !opened {
            logger.error(
                "Failed to open newly created herdr workspace \(workspaceID, privacy: .public) on socket \(socketPath, privacy: .public)"
            )
        }
    }
}

// MARK: - Wire params/result (file-private -- HerdrConnection.swift stays method-agnostic)

/// `workspace.create`'s own request `params` -- WorkspaceCreateParams'
/// schema shape (`herdr api schema --json`): `cwd`/`env`/`focus`/`label`
/// all optional. This file only ever sends `focus`, so encoding this
/// type produces exactly `{"focus":true}` on the wire, nothing else.
private struct HerdrWorkspaceCreateParams: Encodable {
    let focus = true
}

/// `workspace.create`'s own RPC result wrapper --
/// {"type":"workspace_created","workspace":{...},"tab":{...},
/// "root_pane":{...}}, all four required. Only `workspace.workspace_id`
/// is read here (the new workspace's id, passed to `openWorkspace`);
/// `tab`/`root_pane` are schema-required on the response but never
/// decoded, per this project's "define the minimal Decodable you need"
/// rule.
private struct HerdrWorkspaceCreateRPCResult: Sendable, Decodable {
    let workspace: HerdrCreatedWorkspaceInfo
}

private struct HerdrCreatedWorkspaceInfo: Sendable, Decodable {
    let workspaceID: String

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}
