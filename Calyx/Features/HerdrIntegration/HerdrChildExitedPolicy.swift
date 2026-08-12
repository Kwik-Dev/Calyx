// HerdrChildExitedPolicy.swift
// Calyx
//
// Decides whether a `GHOSTTY_ACTION_SHOW_CHILD_EXITED` event for a
// surface should auto-close the pane, extracted as an explicit, pure
// decision mirroring `SessionCloseKillPolicy`'s own extraction shape:
// the caller resolves any raw domain lookup itself (here,
// `HerdrHostedSurfaces.shared.contains(surfaceID)` and
// `HerdrPaneRegistry.shared.isBridgeSurface(surfaceID)`) into
// already-computed `Bool` discriminators before calling in, rather than
// this function reaching into either registry directly -- the same
// style `killSessionIfPersistent` already uses when it resolves
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
// Extension: a bridged herdr pane (`HerdrPaneRegistry`, a native-tab
// pane bridge running `herdr terminal attach <terminalID>` as the
// surface's child) reaches the identical dead end once its child exits:
// also never in `SessionSurfaceMap`, so the same reconnect no-op
// applies, and the attach client's own exit is not itself a herdr-side
// `pane.closed` event (`HerdrTabCoordinator.handlePaneClosed`), so
// nothing arrives from that side either, regardless of why the child
// exited (a `herdr server stop` kills every attach process at once; a
// crash or dropped connection kills one). `isBridgeSurface` is
// REQUIRED, with no default, mirroring
// `HerdrHeuristicIngestionPolicy.shouldIngest`'s own identical
// extension: a defaulted parameter would let a call site compile
// unchanged without ever consulting `HerdrPaneRegistry`, silently
// keeping the old (wrong) behavior by omission.
//
enum HerdrChildExitedPolicy {

    /// `true` (herdr-hosted OR herdr-bridged): auto-close the pane --
    /// nothing else will ever close it (see this file's header).
    /// `false`: leave the pane alone / defer to the existing
    /// session-reconnect child-exited handling.
    static func shouldAutoClose(isHerdrHosted: Bool, isBridgeSurface: Bool) -> Bool {
        isHerdrHosted || isBridgeSurface
    }
}
