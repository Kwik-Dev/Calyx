// HerdrHostedSurfaces.swift
// Calyx
//
// Records which ghostty surface IDs are hosting a herdr attach/TUI
// process (`AppDelegate.openHerdrAttachTab`) or a herdr pane bridge
// (`HerdrPaneRegistry`) -- so downstream consumers can skip them. The
// title-heuristic/screen-poll agent ingestion must not cast a
// duplicate `.titleHeuristic` Agents-sidebar row for a pane whose "real"
// state already arrives over herdr's own event stream.
//
// Pruned via `.calyxSurfaceDestroyed` (`AgentRegistry.swift`'s
// notification, posted by `SurfaceRegistry.destroySurface`) -- mirrors
// `SurfacePropertyStore`'s identical prune-on-teardown shape exactly
// (same notification, same NSObject/@objc-selector wiring), so this
// class fits the codebase's one established idiom for that notification
// instead of inventing a second one.
//
// "shared singleton + injectable": `.shared` is the real, process-wide
// instance every production call site uses, but `init()` is not
// private, so a test can construct its own throwaway instance instead
// of fighting cross-test pollution on `.shared` -- identical to
// `SurfacePropertyStore`'s own `init()` shape.

import Foundation

@MainActor
final class HerdrHostedSurfaces: NSObject {

    static let shared = HerdrHostedSurfaces()

    private var surfaceIDs: Set<UUID> = []
    private var isObserving = false

    override init() {
        super.init()
    }

    /// Idempotent: a second call is a no-op, mirroring
    /// `SurfacePropertyStore.startObserving()`'s own precedent.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSurfaceDestroyed(_:)), name: .calyxSurfaceDestroyed, object: nil
        )
    }

    /// Records `surfaceID` as herdr-hosted (an attach/TUI
    /// surface `AppDelegate.openHerdrAttachTab` just created, or
    /// a pane bridge). Idempotent -- a `Set` insert of an
    /// already-present ID is a no-op.
    func register(_ surfaceID: UUID) {
        surfaceIDs.insert(surfaceID)
    }

    /// Whether `surfaceID` is currently recorded as herdr-hosted.
    func contains(_ surfaceID: UUID) -> Bool {
        surfaceIDs.contains(surfaceID)
    }

    /// Prunes the destroyed surface's ID, mirroring
    /// `SurfacePropertyStore.handleSurfaceDestroyed(_:)`'s identical
    /// `userInfo["surfaceID"]` extraction (`SurfaceRegistry
    /// .destroySurface`'s own post shape). A `surfaceID` this instance
    /// never registered (e.g. an ordinary, non-herdr surface's teardown)
    /// is a no-op `Set.remove`.
    @objc private func handleSurfaceDestroyed(_ notification: Notification) {
        guard let id = notification.userInfo?["surfaceID"] as? UUID else { return }
        surfaceIDs.remove(id)
    }

    #if DEBUG
    /// Test-only: clears whatever `register(_:)` has recorded so
    /// `.shared` never leaks state across tests. DO NOT use from
    /// production code.
    func _testReset() {
        surfaceIDs.removeAll()
    }

    /// Test-only: undoes `startObserving()`, mirroring
    /// `SurfacePropertyStore._stopObserving()`'s own precedent exactly.
    /// DO NOT use from production code.
    func _stopObserving() {
        guard isObserving else { return }
        NotificationCenter.default.removeObserver(self)
        isObserving = false
    }
    #endif
}
