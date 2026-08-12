// SessionBrowserWindowController.swift
// Calyx
//
// Independent window (same shape as `SettingsWindowController`) that
// shows the session browser — every calyx-session the daemon knows
// about, across all Calyx windows and launches, not just this
// process's currently-live panes. No dedicated test file: the logic
// worth testing lives in `SessionBrowserModel`, not this AppKit shell.

import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SessionBrowserWindowController")

@MainActor
final class SessionBrowserWindowController: NSWindowController {

    static let shared = SessionBrowserWindowController()

    let model = SessionBrowserModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = NSHostingView(rootView: SessionBrowserView(model: model))

        // "Attach" on a row already visible somewhere in this process
        // (`isAttachedHere`) reveals that pane via the same
        // `.calyxFocusSurface` notification every window controller
        // already observes (`AgentStatusView`'s identical pattern) — a
        // second attach connection to an already-live session makes no
        // sense. Otherwise (an orphaned, running session with no local
        // surface) opens a brand-new window that reattaches to it.
        model.onAttachRequested = { [weak self] row in
            self?.attach(row)
        }

        // Remote sessions: mirrors the onAttachRequested wiring
        // immediately above -- reaches a window controller the same
        // way attach(_:) does (via AppDelegate), for a chosen remote
        // host's SessionSpawnContext instead of an existing session
        // row.
        model.onRemoteSessionRequested = { [weak self] context in
            self?.attachRemote(context)
        }

        // Herdr attach: mirrors onAttachRequested's wiring
        // immediately above, for a herdr row instead of a calyx-session
        // one.
        model.onHerdrAttachRequested = { [weak self] row in
            self?.attachHerdr(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func attach(_ row: SessionBrowserRow) {
        if row.isAttachedHere, let surfaceID = SessionSurfaceMap.shared.surfaceID(for: row.id) {
            NotificationCenter.default.post(
                name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": surfaceID]
            )
            return
        }
        (NSApp.delegate as? AppDelegate)?.attachSessionAsTab(sessionID: row.id, cwd: row.info.cwd)
    }

    private func attachRemote(_ context: SessionSpawnContext) {
        (NSApp.delegate as? AppDelegate)?.spawnRemoteSessionTab(host: context.host)
    }

    /// A herdr row click now opens that session NATIVELY --
    /// one Calyx tab per live workspace on `row`'s own socket, iTerm2
    /// tmux -CC semantics -- instead of the old single TUI-attach tab
    /// (that old behavior moved to the Command Palette's
    /// `herdr.attachTUI` action, `CalyxWindowController.setupCommandRegistry()`,
    /// which still calls `AppDelegate.openHerdrAttachTab(command:title:)`
    /// directly, unchanged).
    ///
    /// Takes a one-shot `session.snapshot` on its OWN fresh transport
    /// (mirrors `HerdrIntegrationCoordinator.attemptConnect`'s identical
    /// one-shot snapshot step) to learn `row`'s CURRENT live workspaces,
    /// then `openWorkspace`s each via `AppDelegate.herdrTabCoordinator`.
    /// Workspace ids are derived from `snapshot.panes[].workspaceID` --
    /// the strongly-typed, schema-required field -- NOT from
    /// `snapshot.workspaces`, which decodes as `[AnyCodable]` with its
    /// element shape deliberately out of scope (`HerdrSessionSnapshot`'s
    /// own doc comment, `HerdrEvent.swift`), so it carries no
    /// schema-derived id to read.
    ///
    /// Re-opens the FOCUS workspace last so it ends focused rather than
    /// whichever opened most recently -- `openWorkspace`'s own FIRST
    /// check, `focusExistingTab`, short-circuits that re-open into a
    /// pure focus with no wire round trip (`HerdrTabCoordinator.swift`'s
    /// own header, "OPEN SEQUENCE"). The FOCUS workspace
    /// is `snapshot.focusedWorkspaceID` (herdr's own notion of which
    /// workspace was actually focused/in-use) when present AND actually
    /// named in `workspaceIDs`, falling back to the sorted-first id
    /// otherwise (absent snapshot field, or a workspace id it names that
    /// this row's own pane list doesn't contain).
    ///
    /// A failed snapshot (herdr since died, or `AppDelegate.herdrTabCoordinator`
    /// is `nil` because herdr itself was never resolvable) silently does
    /// nothing -- matches this integration's broader no-dialog philosophy for
    /// herdr absence/death (`AppDelegate.openHerdrAttachTab`'s own doc
    /// comment): a herdr that dies mid-session simply drops its section
    /// on the Session Browser's next poll, no error UI. A per-workspace
    /// `openWorkspace` failure is logged (this file's own
    /// `logger`, mirroring `AppDelegate.openHerdrAttachTab`'s own
    /// `logger.error` on its analogous failure) rather than silently
    /// dropped.
    private func attachHerdr(_ row: HerdrSessionRow) {
        guard let coordinator = (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator else { return }
        let socketPath = row.info.id

        Task {
            let transport = await LiveHerdrTransportFactory().makeTransport()
            let request = HerdrOneShotRequest(transport: transport)
            let snapshotResult: HerdrSnapshotRPCResult
            do {
                snapshotResult = try await request.send(method: "session.snapshot", socketPath: socketPath)
            } catch {
                return
            }
            let snapshot = snapshotResult.snapshot

            let workspaceIDs = Set(snapshot.panes.map(\.workspaceID)).sorted()
            guard let firstWorkspaceID = workspaceIDs.first else { return }
            let focusWorkspaceID: String
            if let focusedWorkspaceID = snapshot.focusedWorkspaceID, workspaceIDs.contains(focusedWorkspaceID) {
                focusWorkspaceID = focusedWorkspaceID
            } else {
                focusWorkspaceID = firstWorkspaceID
            }

            for workspaceID in workspaceIDs {
                let opened = await coordinator.openWorkspace(workspaceID: workspaceID, socketPath: socketPath)
                if !opened {
                    logger.error(
                        "Failed to open herdr workspace \(workspaceID, privacy: .public) on socket \(socketPath, privacy: .public)"
                    )
                }
            }
            if workspaceIDs.count > 1 {
                let refocused = await coordinator.openWorkspace(workspaceID: focusWorkspaceID, socketPath: socketPath)
                if !refocused {
                    logger.error(
                        "Failed to focus herdr workspace \(focusWorkspaceID, privacy: .public) on socket \(socketPath, privacy: .public)"
                    )
                }
            }
        }
    }

    func showBrowser() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refreshRemoteHostCandidates()
        Task { await model.refresh() }
    }
}
