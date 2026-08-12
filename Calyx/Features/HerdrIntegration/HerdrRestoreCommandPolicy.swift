// HerdrRestoreCommandPolicy.swift
// Calyx
//
// Decides what command `AppDelegate.restoreTabSurfaces`' per-leaf branch
// (`createSurfaceWithPwd`) should use when a leaf's `HerdrPaneRef`
// survives a snapshot restore, extracted as an explicit, pure decision
// mirroring `HerdrChildExitedPolicy`/`HerdrHeuristicIngestionPolicy`'s
// own extraction shape: the caller resolves every raw domain lookup
// itself (herdr binary resolution, `HerdrSessionDiscovery
// .isAlive(socketPath:)`, and now the ref's own current `terminalID` --
// see this file's own "TERMINAL ID" section below) into already-computed
// values before calling in; this function does no I/O and touches no
// actor-isolated state.
//
// Mirrors the existing invalid-ULID `SessionRef` precedent in that same
// method (`AppDelegate.swift`, `restoreTabSurfaces`: "Reject any
// persisted SessionRef whose sessionID isn't shaped like a genuine
// ULID... The rejected leaf simply restores as an ordinary passthrough
// shell"): a herdr ref that can never be reattached must not silently
// keep trying on every future restore either -- `.plainShellAndPrune`
// tells the caller to drop the stale ref via `Tab.pruneHerdrPaneRefs(
// keeping:)` so it is not written back out by the next snapshot.
//
// `.bridgeCommand`'s payload is EXACTLY `HerdrAttachBridgeCommand
// .build(...)`'s own output -- this type synthesizes no command of its
// own, it only decides WHICH path applies.
//
// TERMINAL ID: `HerdrAttachBridgeCommand
// .build` now takes a herdr TERMINAL id, not a pane id (that file's own
// header) -- `herdr agent attach <paneID>` fails outright for any pane
// with no agent running; `herdr terminal attach <terminalID>` is the
// measured, working replacement. A persisted `HerdrPaneRef` carries only
// (socketPath, paneID) -- its own STABLE identity, unaffected by this
// change (see that type's own header) -- never a terminal id, so `decide`
// now takes one as a separate, caller-resolved `terminalID: String?`
// parameter: `nil` (unresolvable) reaches the SAME `.plainShellAndPrune`
// outcome as every other "cannot reattach" gate below.
//
// RESOLVED FRESH, NEVER PERSISTED -- the deliberate choice between this
// file's own two options: terminal ids
// are NOT stable across a herdr server restart, so persisting one
// alongside `HerdrPaneRef` would let a STALE value silently build a
// `.bridgeCommand` that reattaches to the wrong terminal (or one that no
// longer exists) after a restart -- `HerdrPaneRef`'s own identity
// (socketPath, paneID) would then no longer honestly describe what the
// ref actually reattaches to. Resolving fresh via a live
// `session.snapshot` (`HerdrRestoreTerminalIDResolver.resolve(refs:)`,
// called once by `AppDelegate.restoreTabSurfaces` before this file's own
// per-leaf loop, NEVER by this file itself -- see this type's own header
// above, "this function does no I/O") means a pane that no longer exists
// on a restarted server simply has no map entry, `terminalID` decides
// `nil`, and this file's own EXISTING `.plainShellAndPrune` discipline
// self-heals the stale ref (pruned, never retried) instead of silently
// reattaching to the wrong thing.
//
// `isValidPaneID` is RETAINED as an explicit gate below even though
// `HerdrAttachBridgeCommand.build` itself no longer takes (or validates)
// a paneID at all -- defense in depth: `herdrPaneRef.paneID` is still
// this leaf's own persisted identity, and a corrupted/malicious value
// there must still never be treated as a legitimate, reattachable ref,
// regardless of what else about it might resolve. See
// `HerdrPaneRef.isValidPaneID`'s own header for the full rationale.

import Foundation

enum HerdrRestoreCommandOutcome: Equatable {
    /// Reattach via herdr: `HerdrAttachBridgeCommand.build(...)`'s own
    /// output, verbatim.
    case bridgeCommand(String)
    /// Restore as an ordinary passthrough shell AND drop the leaf's
    /// stale `HerdrPaneRef` (`Tab.pruneHerdrPaneRefs(keeping:)`) -- it
    /// can never be reattached (herdr unavailable, its socket dead, or
    /// the ref itself is invalid), so it must not linger to be written
    /// back out by the next snapshot.
    case plainShellAndPrune
    /// Restore as an ordinary passthrough shell, untouched.
    /// No `HerdrPaneRef` exists for this leaf at all,
    /// so there is nothing to prune either.
    case plainShell
}

enum HerdrRestoreCommandPolicy {

    /// `herdrPaneRef` nil -> `.plainShell` (no ref, nothing to decide).
    /// Otherwise: `herdrPaneRef.paneID` invalid (see this file's own
    /// header, "isValidPaneID is RETAINED"), `herdrBinPath` unresolvable,
    /// the socket dead, `terminalID` unresolved (`nil` -- see this
    /// file's own header, "TERMINAL ID"), or `HerdrAttachBridgeCommand
    /// .build` itself returning `nil` (its own `isValidTerminalID` gate)
    /// -> `.plainShellAndPrune`. Else `.bridgeCommand` with `build`'s own
    /// output.
    static func decide(
        herdrPaneRef: HerdrPaneRef?, herdrBinPath: String?, isSocketAlive: Bool, terminalID: String?
    ) -> HerdrRestoreCommandOutcome {
        guard let herdrPaneRef else { return .plainShell }
        guard HerdrPaneRef.isValidPaneID(herdrPaneRef.paneID),
              let herdrBinPath, isSocketAlive, let terminalID,
              let command = HerdrAttachBridgeCommand.build(
                  herdrBin: herdrBinPath, socketPath: herdrPaneRef.socketPath, terminalID: terminalID
              )
        else {
            return .plainShellAndPrune
        }
        return .bridgeCommand(command)
    }
}
