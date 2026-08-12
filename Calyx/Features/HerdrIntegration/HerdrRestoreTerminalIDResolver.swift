// HerdrRestoreTerminalIDResolver.swift
// Calyx
//
// Resolves a (socketPath, paneID) -> terminalID map for
// AppDelegate.restoreTabSurfaces' herdr-bridge-leaf branch
// (createSurfaceWithPwd) -- a persisted HerdrPaneRef carries only
// (socketPath, paneID) (its own stable identity; see HerdrPaneRef.swift's
// own header), never a terminal id, and HerdrAttachBridgeCommand.build
// now needs one (see that file's own header, and
// HerdrRestoreCommandPolicy.swift's own header for why this is resolved
// FRESH here rather than persisted).
//
// This gate mirrors createSurfaceWithPwd's own existing per-leaf gate
// (AppDelegate.swift): `resolve(refs:)` does ZERO herdr I/O when `refs`
// is empty -- most
// restored tabs carry no HerdrPaneRef at all, so a launch with zero
// herdr refs anywhere must still touch no herdr socket at all, exactly
// like the per-leaf herdrBinPath/isSocketAlive gate already guarantees
// for the OTHER two herdr-availability checks.
//
// ONE session.snapshot PER DISTINCT socketPath among `refs` (typically
// exactly one -- a single herdr server -- but HerdrPaneRef.swift's own
// header notes two independent sockets can legitimately reuse the same
// pane numbering, so this groups by socketPath rather than assuming a
// single socket), via HerdrSyncSnapshotFetch.fetch(socketPath:) (a
// bounded, SYNCHRONOUS call -- see that file's own header for why this
// whole call graph stays synchronous). A socket whose fetch fails (dead
// socket, timeout, malformed response, ...) simply contributes no
// entries to the returned map -- every ref on that socket then resolves
// to a `nil` terminalID lookup, which HerdrRestoreCommandPolicy.decide
// already treats as `.plainShellAndPrune`, the same outcome an
// unresolvable ref already reaches via its OTHER gates (herdrBinPath
// nil, isSocketAlive false); this is not a new failure mode, just this
// one's own route to the existing one.
//
// KEYED BY A COMPOSITE STRING, NOT HerdrPaneRef ITSELF: HerdrPaneRef is
// Equatable but deliberately NOT Hashable (HerdrPaneRegistry.swift's own
// header) -- `key(socketPath:paneID:)` mirrors
// HerdrPaneRegistry.paneKey(socketPath:paneID:)'s own NUL-byte-joined
// idiom exactly (a plain colon would collide with a pane id that already
// contains one, e.g. "wB:p1"), duplicated here rather than shared since
// that method is `private` to HerdrPaneRegistry.

import Foundation

enum HerdrRestoreTerminalIDResolver {

    /// See this file's header "KEYED BY A COMPOSITE STRING".
    static func key(socketPath: String, paneID: String) -> String {
        "\(socketPath)\u{0}\(paneID)"
    }

    /// See this file's header. `refs` need not be deduplicated by the
    /// caller -- grouping by socketPath below absorbs any repeats.
    static func resolve(refs: [HerdrPaneRef]) -> [String: String] {
        guard !refs.isEmpty else { return [:] }

        let socketPaths = Set(refs.map(\.socketPath))
        var result: [String: String] = [:]
        for socketPath in socketPaths {
            guard let snapshot = HerdrSyncSnapshotFetch.fetch(socketPath: socketPath) else { continue }
            // `uniquingKeysWith:` (never `uniqueKeysWithValues:`): unlike
            // this file's OWN freshly-generated keys elsewhere in this
            // codebase (e.g. HerdrTabCoordinator's leaf UUIDs), pane_id
            // here is SERVER-SUPPLIED wire data -- a malformed/duplicated
            // snapshot must not crash this process by trapping on a
            // duplicate key.
            let terminalIDByPaneID = Dictionary(
                snapshot.panes.map { ($0.paneID, $0.terminalID) }, uniquingKeysWith: { _, latest in latest }
            )
            for (paneID, terminalID) in terminalIDByPaneID {
                result[key(socketPath: socketPath, paneID: paneID)] = terminalID
            }
        }
        return result
    }
}
