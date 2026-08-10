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

        // P5 (remote sessions): mirrors the onAttachRequested wiring
        // immediately above -- reaches a window controller the same
        // way attach(_:) does (via AppDelegate), for a chosen remote
        // host's SessionSpawnContext instead of an existing session
        // row.
        model.onRemoteSessionRequested = { [weak self] context in
            self?.attachRemote(context)
        }

        // Stage 1 herdr attach: mirrors onAttachRequested's wiring
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

    /// Synthesizes `row`'s attach command (`/usr/bin/env
    /// HERDR_SOCKET_PATH=<socketPath> <herdrBin>`, token-escaped by
    /// `HerdrAttachCommandSynthesizer`) and opens it as a new tab via
    /// `AppDelegate.openHerdrAttachTab(command:title:)`. Passes
    /// `row.info.id` -- the socket path that was actually probed alive
    /// for this row -- as `socketPath`, pinning the exact socket the
    /// user clicked rather than a name herdr would have to re-resolve;
    /// `row.info.name` is used only for the tab title. Re-resolves the
    /// herdr binary here rather than caching one from whatever produced
    /// `row` (`HerdrSessionInfo` carries no binary path of its own --
    /// only session identity), silently doing nothing if it's since
    /// gone missing (e.g. uninstalled between the last Session Browser
    /// poll and this click): matches Stage 1's broader no-dialog
    /// philosophy for herdr absence -- a herdr that dies mid-session
    /// simply drops its section on the next poll, no error UI.
    private func attachHerdr(_ row: HerdrSessionRow) {
        guard let herdrBin = HerdrBinaryResolver().resolve() else { return }
        let command = HerdrAttachCommandSynthesizer.attachCommand(herdrBin: herdrBin, socketPath: row.info.id)
        let title = row.info.name.map { "herdr: \($0)" } ?? "herdr"
        (NSApp.delegate as? AppDelegate)?.openHerdrAttachTab(command: command, title: title)
    }

    func showBrowser() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refreshRemoteHostCandidates()
        Task { await model.refresh() }
    }
}
