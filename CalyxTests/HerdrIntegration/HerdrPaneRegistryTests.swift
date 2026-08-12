//
//  HerdrPaneRegistryTests.swift
//  CalyxTests
//
//  TDD Red Phase for HerdrPaneRegistry: paneID-to-surfaceID
//  side table, keyed both ways --
//    surfaceID -> HerdrPaneRef (which herdr pane a given ghostty surface
//    bridges)
//    (socketPath, paneID) -> surfaceID (which surface, if any, currently
//    bridges a given herdr pane)
//  -- and the type that subsumes HerdrHostedSurfaces role:
//  isBridgeSurface(_:) replaces HerdrHostedSurfaces.contains(_:) for
//  every purpose HerdrHostedSurfaces.swift's own header describes --
//  letting title-heuristic ingestion skip a pane whose "real"
//  state already arrives over herdr's own event stream.
//
//  DI/lifecycle shape mirrors HerdrHostedSurfaces.swift exactly: a
//  non-private init() so each test constructs its own throwaway
//  instance (no cross-test pollution on a shared singleton),
//  startObserving() idempotently subscribes to .calyxSurfaceDestroyed
//  (AgentRegistry.swift's notification, posted by
//  SurfaceRegistry.destroySurface with userInfo["surfaceID"]), and a
//  DEBUG-only _stopObserving() test teardown hook (SurfacePropertyStore
//  /HerdrHostedSurfaces's own established precedent).
//
//  SINGLE-CONTROLLER INVARIANT (1 pane, 1 controller): registering a
//  NEW surfaceID for a (socketPath, paneID) pair some OTHER surfaceID
//  already claims evicts that other surfaceID from the registry
//  entirely -- two surfaces must never simultaneously claim to bridge
//  the same herdr pane.
//
//  HerdrPaneRef is Equatable but deliberately NOT Hashable (see that
//  file's own header), and this file must not touch HerdrPaneRef.swift,
//  so none of these tests build a Set<HerdrPaneRef> or use HerdrPaneRef
//  as a Dictionary key -- the registry's own reverse-lookup storage is
//  an implementation detail these tests never assume a shape for.
//
//  Coverage:
//  - register(surfaceID:ref:) then isBridgeSurface(_:) true; an unknown
//    surfaceID reads false
//  - surfaceID(forPaneID:socketPath:) returns the registered surface;
//    the same paneID under a DIFFERENT socketPath returns nil (socket
//    path is part of the pane's identity -- mirrors HerdrPaneRef.swift's
//    own header on why two independent herdr sockets can reuse the same
//    pane numbering)
//  - paneRef(forSurfaceID:) returns the registered ref
//  - unregister(surfaceID:) removes both the forward and reverse
//    mapping
//  - a .calyxSurfaceDestroyed notification for a registered surface
//    prunes only that surface, leaving an unrelated registered surface
//    untouched
//  - re-registering the SAME surfaceID with a DIFFERENT ref replaces it
//    (no duplicate reverse-mapping entries: the OLD (socketPath,
//    paneID) pair no longer resolves to this surface)
//  - registering a DIFFERENT surfaceID for a (socketPath, paneID) pair
//    an existing surfaceID already claims evicts the existing surfaceID
//

import XCTest
@testable import Calyx

@MainActor
final class HerdrPaneRegistryTests: XCTestCase {

    private var registry: HerdrPaneRegistry!

    override func setUp() {
        super.setUp()
        registry = HerdrPaneRegistry()
    }

    override func tearDown() {
        registry._stopObserving()
        registry = nil
        super.tearDown()
    }

    // MARK: - register / isBridgeSurface

    func test_register_thenIsBridgeSurface_true() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")

        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertTrue(registry.isBridgeSurface(surfaceID))
    }

    func test_isBridgeSurface_unknownSurface_false() {
        XCTAssertFalse(registry.isBridgeSurface(UUID()))
    }

    // MARK: - surfaceID(forPaneID:socketPath:)

    func test_surfaceIDForPaneID_returnsRegisteredSurface() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertEqual(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            surfaceID
        )
    }

    func test_surfaceIDForPaneID_sameIDDifferentSocketPath_returnsNil() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertNil(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/tmp/a-different-herdr.sock"),
            "socketPath is part of a pane's identity -- the same paneID text under a different socket must not resolve"
        )
    }

    // MARK: - paneRef(forSurfaceID:)

    func test_paneRefForSurfaceID_returnsRegisteredRef() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        XCTAssertEqual(registry.paneRef(forSurfaceID: surfaceID), ref)
    }

    func test_paneRefForSurfaceID_unknownSurface_returnsNil() {
        XCTAssertNil(registry.paneRef(forSurfaceID: UUID()))
    }

    // MARK: - unregister

    func test_unregister_removesBothDirections() {
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        registry.register(surfaceID: surfaceID, ref: ref)

        registry.unregister(surfaceID: surfaceID)

        XCTAssertFalse(registry.isBridgeSurface(surfaceID))
        XCTAssertNil(registry.paneRef(forSurfaceID: surfaceID))
        XCTAssertNil(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            "unregister must also clear the reverse (socketPath, paneID) -> surfaceID mapping"
        )
    }

    // MARK: - .calyxSurfaceDestroyed pruning

    func test_surfaceDestroyedNotification_prunesOnlyThatSurface_leavesUnrelatedSurfaceIntact() {
        let destroyedSurface = UUID()
        let destroyedRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        let survivingSurface = UUID()
        let survivingRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wC:p1")

        registry.register(surfaceID: destroyedSurface, ref: destroyedRef)
        registry.register(surfaceID: survivingSurface, ref: survivingRef)
        registry.startObserving()

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": destroyedSurface])

        XCTAssertFalse(registry.isBridgeSurface(destroyedSurface), "a destroyed surface must be pruned")
        XCTAssertNil(registry.paneRef(forSurfaceID: destroyedSurface))
        XCTAssertNil(registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"))

        XCTAssertTrue(
            registry.isBridgeSurface(survivingSurface),
            "an unrelated, still-live surface must survive another surface's destroy notification -- an " +
            "implementation that clears the whole registry on any destroy would wrongly pass a single-surface " +
            "version of this test"
        )
        XCTAssertEqual(registry.paneRef(forSurfaceID: survivingSurface), survivingRef)
    }

    // MARK: - Replace (same surfaceID, different ref)

    func test_register_sameSurfaceIDTwiceWithDifferentRef_replacesWithoutStaleReverseMapping() {
        let surfaceID = UUID()
        let firstRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        let secondRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wC:p1")

        registry.register(surfaceID: surfaceID, ref: firstRef)
        registry.register(surfaceID: surfaceID, ref: secondRef)

        XCTAssertEqual(
            registry.paneRef(forSurfaceID: surfaceID), secondRef,
            "a second registration for the same surfaceID must replace the ref, not add a duplicate"
        )
        XCTAssertNil(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            "the OLD (socketPath, paneID) reverse mapping must not linger once the surface has moved on"
        )
        XCTAssertEqual(
            registry.surfaceID(forPaneID: "wC:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            surfaceID
        )
    }

    // MARK: - Single-controller invariant (eviction)

    func test_register_secondSurfaceClaimingSamePane_evictsFirstSurface() {
        let firstSurface = UUID()
        let secondSurface = UUID()
        let sharedRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")

        registry.register(surfaceID: firstSurface, ref: sharedRef)
        registry.register(surfaceID: secondSurface, ref: sharedRef)

        XCTAssertFalse(
            registry.isBridgeSurface(firstSurface),
            "1 pane, 1 controller: a second surface claiming the same (socketPath, paneID) must evict the " +
            "first, never let two surfaces bridge the same herdr pane simultaneously"
        )
        XCTAssertNil(registry.paneRef(forSurfaceID: firstSurface))

        XCTAssertTrue(registry.isBridgeSurface(secondSurface))
        XCTAssertEqual(registry.paneRef(forSurfaceID: secondSurface), sharedRef)
        XCTAssertEqual(
            registry.surfaceID(forPaneID: "wB:p1", socketPath: "/Users/dev/.config/herdr/herdr.sock"),
            secondSurface
        )
    }
}
