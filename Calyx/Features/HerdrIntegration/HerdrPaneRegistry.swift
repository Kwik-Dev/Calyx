// HerdrPaneRegistry.swift
// Calyx
//
// The paneID-to-surfaceID side table, keyed both ways:
//   surfaceID -> HerdrPaneRef (which herdr pane a given ghostty surface
//   bridges)
//   (socketPath, paneID) -> surfaceID (which surface, if any, currently
//   bridges a given herdr pane)
// Subsumes HerdrHostedSurfaces's role: isBridgeSurface(_:)
// replaces HerdrHostedSurfaces.contains(_:) for every purpose that
// file's own header describes, letting the title-heuristic
// ingestion skip a pane whose "real" state already arrives over herdr's
// own event stream.
//
// SINGLE-CONTROLLER INVARIANT (1 pane, 1 controller): registering a NEW
// surfaceID for a (socketPath, paneID) pair some OTHER surfaceID
// already claims evicts that other surfaceID from the registry entirely
// -- two surfaces must never simultaneously claim to bridge the same
// herdr pane.
//
// Pruned via .calyxSurfaceDestroyed (AgentRegistry.swift's notification,
// posted by SurfaceRegistry.destroySurface with userInfo["surfaceID"])
// -- mirrors HerdrHostedSurfaces's identical prune-on-teardown shape
// exactly (same notification, same NSObject/@objc-selector wiring), so
// this class fits the codebase's one established idiom for that
// notification instead of inventing a second one.
//
// HerdrPaneRef is Equatable but deliberately NOT Hashable (see that
// file's own header) and this file must not modify HerdrPaneRef.swift,
// so the reverse (socketPath, paneID) -> surfaceID map is keyed by a
// composite string rather than the ref itself -- a NUL byte joiner
// (socket paths and pane ids are both plain text that cannot contain
// one) rather than a plain colon, since paneID already contains one
// ("wB:p1").
//
// "shared singleton + injectable": .shared is the real, process-wide
// instance every production call site uses, but init() is not private,
// so a test can construct its own throwaway instance instead of
// fighting cross-test pollution on .shared -- identical to
// HerdrHostedSurfaces's own init() shape.

import Foundation

@MainActor
final class HerdrPaneRegistry: NSObject {

    static let shared = HerdrPaneRegistry()

    private var refsBySurfaceID: [UUID: HerdrPaneRef] = [:]
    private var surfaceIDByPaneKey: [String: UUID] = [:]
    private var isObserving = false

    override init() {
        super.init()
    }

    /// Idempotent: a second call is a no-op, mirroring
    /// HerdrHostedSurfaces.startObserving()'s own precedent.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSurfaceDestroyed(_:)), name: .calyxSurfaceDestroyed, object: nil
        )
    }

    /// Records that `surfaceID` bridges the herdr pane `ref` describes.
    /// Re-registering the same `surfaceID` replaces its ref and clears
    /// the old (socketPath, paneID) reverse mapping. If some OTHER
    /// surfaceID already claims `ref`'s (socketPath, paneID) pair, that
    /// surfaceID is evicted entirely first (single-controller invariant:
    /// see this file's header).
    func register(surfaceID: UUID, ref: HerdrPaneRef) {
        if let previousRef = refsBySurfaceID[surfaceID] {
            surfaceIDByPaneKey.removeValue(forKey: Self.paneKey(previousRef))
        }
        let key = Self.paneKey(ref)
        if let priorSurfaceID = surfaceIDByPaneKey[key], priorSurfaceID != surfaceID {
            refsBySurfaceID.removeValue(forKey: priorSurfaceID)
        }
        refsBySurfaceID[surfaceID] = ref
        surfaceIDByPaneKey[key] = surfaceID
    }

    /// Removes `surfaceID` from both the forward and reverse mapping.
    /// A `surfaceID` never registered is a no-op.
    func unregister(surfaceID: UUID) {
        guard let ref = refsBySurfaceID.removeValue(forKey: surfaceID) else { return }
        surfaceIDByPaneKey.removeValue(forKey: Self.paneKey(ref))
    }

    /// Whether `surfaceID` currently bridges a herdr pane.
    func isBridgeSurface(_ surfaceID: UUID) -> Bool {
        refsBySurfaceID[surfaceID] != nil
    }

    /// The herdr pane `surfaceID` bridges, if any.
    func paneRef(forSurfaceID surfaceID: UUID) -> HerdrPaneRef? {
        refsBySurfaceID[surfaceID]
    }

    /// The surfaceID currently bridging `(socketPath, paneID)`, if any.
    /// socketPath is part of the pane's identity: the same paneID text
    /// under a different socket never resolves (HerdrPaneRef.swift's
    /// own header on why two independent herdr sockets can reuse pane
    /// numbering).
    func surfaceID(forPaneID paneID: String, socketPath: String) -> UUID? {
        surfaceIDByPaneKey[Self.paneKey(socketPath: socketPath, paneID: paneID)]
    }

    /// Prunes the destroyed surface's entry, mirroring
    /// HerdrHostedSurfaces.handleSurfaceDestroyed(_:)'s identical
    /// userInfo["surfaceID"] extraction (SurfaceRegistry
    /// .destroySurface's own post shape). A `surfaceID` this instance
    /// never registered is a no-op.
    @objc private func handleSurfaceDestroyed(_ notification: Notification) {
        guard let id = notification.userInfo?["surfaceID"] as? UUID else { return }
        unregister(surfaceID: id)
    }

    private static func paneKey(_ ref: HerdrPaneRef) -> String {
        paneKey(socketPath: ref.socketPath, paneID: ref.paneID)
    }

    private static func paneKey(socketPath: String, paneID: String) -> String {
        "\(socketPath)\u{0}\(paneID)"
    }

    #if DEBUG
    /// Test-only: undoes startObserving(), mirroring
    /// HerdrHostedSurfaces._stopObserving()'s own precedent exactly.
    /// Safe to call even if startObserving() was never called. DO NOT
    /// use from production code.
    func _stopObserving() {
        guard isObserving else { return }
        NotificationCenter.default.removeObserver(self)
        isObserving = false
    }
    #endif
}
