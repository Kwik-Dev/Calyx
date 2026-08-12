// HerdrAttachOrCreateFlow.swift
// Calyx
//
// SessionBrowserWindowController's own flow for a herdr server row's
// "New" button: sends workspace.create, then opens the workspace that
// creates. Always creates, unconditionally -- there is no decision to
// make here (a workspace row's own "Attach" button opens an already-known
// workspace id directly through HerdrTabCoordinator
// .openWorkspace(workspaceID:socketPath:), never through this file; see
// SessionBrowserWindowController.attachHerdrWorkspace(_:)).
//
// openWorkspace is injected as that SAME HerdrTabCoordinator
// .openWorkspace(workspaceID:socketPath:) entry point: there is exactly
// one place that opens a workspace as a native Calyx tab, and this file
// never reimplements it. Injected (rather than taking a
// HerdrTabCoordinator directly) so this flow is testable with a plain spy
// closure, without constructing a full coordinator -- see
// HerdrAttachOrCreateFlowTests.swift.
//
// @MainActor: openWorkspace's production closure captures a @MainActor
// HerdrTabCoordinator; running this flow off the main actor would force
// that capture across an isolation boundary.
//
// logger is the caller's own Logger value (Logger is a struct) passed
// in, not a second instance declared here, so every failure this file
// logs goes through the exact same logger SessionBrowserWindowController
// already uses for "Failed to open herdr workspace ...". workspace.create
// failing, and the newly created workspace failing to open, both log.
//

import Foundation
import os

@MainActor
enum HerdrAttachOrCreateFlow {
    /// Creates a new herdr workspace on `socketPath` and opens it through
    /// `openWorkspace` -- the server row's own "New" button always
    /// performs exactly this, regardless of how many workspaces already
    /// exist on that socket. `workspace.create`'s params carry exactly
    /// one key, `focus` -- WorkspaceCreateParams' own schema shape
    /// (`herdr api schema --json`): `cwd`/`env`/`focus`/`label` all
    /// optional. No cwd is sent, so herdr chooses (it uses the focused
    /// workspace's directory, falling back to the home directory when no
    /// workspace exists). `env`/`label` are never sent.
    static func createAndOpen(
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
