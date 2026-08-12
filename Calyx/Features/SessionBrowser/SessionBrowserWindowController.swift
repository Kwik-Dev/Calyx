// SessionBrowserWindowController.swift
// Calyx
//
// Independent window (same shape as `SettingsWindowController`) that
// shows the session browser — every calyx-session the daemon knows
// about, across all Calyx windows and launches, not just this
// process's currently-live panes. No dedicated test file: the logic
// worth testing lives in `SessionBrowserModel` or, for the herdr-attach
// wire flow, `HerdrAttachOrCreateFlow` (HerdrAttachOrCreateFlow.swift),
// not this AppKit shell.

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
    /// tmux -CC semantics, or, when the socket currently has none,
    /// creates one and opens it -- instead of the old single TUI-attach
    /// tab (that old behavior moved to the Command Palette's
    /// `herdr.attachTUI` action, `CalyxWindowController.setupCommandRegistry()`,
    /// which still calls `AppDelegate.openHerdrAttachTab(command:title:)`
    /// directly, unchanged).
    ///
    /// Delegates the wire sequence and the create-versus-attach decision
    /// to `HerdrAttachOrCreateFlow.run` (HerdrAttachOrCreateFlow.swift),
    /// from a FRESH `session.snapshot` fetched at click time -- never
    /// `row`'s own cached counts, which only drive the Attach/New button
    /// title (`HerdrAttachGate.decide`, SessionBrowserModel.swift), so a
    /// stale row can never send the wrong request. `openWorkspace` wraps
    /// `AppDelegate.herdrTabCoordinator`'s own entry point; this file's
    /// `logger` is passed straight through, so every failure path (a
    /// per-workspace open, a `workspace.create`, or opening the
    /// workspace it created) still logs exactly as it always has. A
    /// `herdrTabCoordinator` that is `nil` (herdr itself was never
    /// resolvable) does nothing, same as today.
    private func attachHerdr(_ row: HerdrSessionRow) {
        guard let coordinator = (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator else { return }
        let socketPath = row.info.id

        Task {
            await HerdrAttachOrCreateFlow.run(
                socketPath: socketPath,
                transportFactory: LiveHerdrTransportFactory(),
                logger: logger,
                openWorkspace: { workspaceID, socketPath in
                    await coordinator.openWorkspace(workspaceID: workspaceID, socketPath: socketPath)
                }
            )
        }
    }

    func showBrowser() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refreshRemoteHostCandidates()
        Task { await model.refresh() }
    }
}
