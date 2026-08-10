// HerdrChildExitedPolicy.swift
// Calyx
//
// Decides whether a `GHOSTTY_ACTION_SHOW_CHILD_EXITED` event for a
// surface should auto-close the pane, extracted as an explicit, pure
// decision mirroring `SessionCloseKillPolicy`'s own extraction shape:
// the caller resolves any raw domain lookup itself (here,
// `HerdrHostedSurfaces.shared.contains(surfaceID)`) into an
// already-computed `Bool` discriminator before calling in, rather than
// this function reaching into `HerdrHostedSurfaces` directly -- the
// same style `killSessionIfPersistent` already uses when it resolves
// `SessionSurfaceMap.shared.sessionID(for:) != nil` itself and passes
// the Bool into `SessionCloseKillPolicy.shouldKill`.
//
// Background: herdr attach tabs (`AppDelegate.openHerdrAttachTab`) run
// the herdr client as the surface's child process with wait-after-
// command forced on, so ghostty leaves its own "process exited" banner
// up instead of closing the surface itself. The surface is also
// deliberately never registered in `SessionSurfaceMap` (herdr session
// identity must never enter it -- see `HerdrHostedSurfaces.swift`'s
// header), so `SessionReconnectCoordinator.childExited`'s own
// `surfaceMap.sessionID(for:) != nil` gate provably no-ops for it --
// there is no competing close/reconnect path that will ever close this
// pane on its own. This policy is what tells `CalyxWindowController
// .processChildExited` to close it directly instead.
//
enum HerdrChildExitedPolicy {

    /// `true` (herdr-hosted): auto-close the pane -- nothing else will
    /// ever close it (see this file's header). `false`: leave the pane
    /// alone / defer to the existing session-reconnect child-exited
    /// handling.
    static func shouldAutoClose(isHerdrHosted: Bool) -> Bool {
        isHerdrHosted
    }
}
