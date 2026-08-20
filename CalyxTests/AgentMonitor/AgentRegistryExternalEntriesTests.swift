//
//  AgentRegistryExternalEntriesTests.swift
//  CalyxTests
//
//  Tests (herdr TRACK B): AgentRegistry's external
//  (herdr) entry store -- a SEPARATE dictionary from `entries`, so
//  herdr rows survive AgentRegistry.reset() and never interact with the
//  native hooks/titleHeuristic arbitration in handleHookEvent /
//  handleTitleChange / handleScreenClassification.
//
//  Coverage:
//  - AgentEntry.focusSurfaceID: defaults to nil, round-trips explicitly
//  - upsertExternalEntry / removeExternalEntry / hasExternalEntries:
//    basic CRUD on the external store, isolated from `entries`
//  - reset() clears `entries` but preserves `externalEntries` -- already
//    true by construction given the separate-store design (reset()
//    never references externalEntries at all); pinned anyway as a
//    permanent regression guard, since this is the exact property the
//    separate-store design exists to guarantee
//  - handleHookEvent / handleTitleChange / handleScreenClassification
//    never mutate an existing external entry, even under a same-UUID
//    collision with a native surface -- also already true by
//    construction today (none of the three consult externalEntries at
//    all); pinned so a future change to any of them can't accidentally
//    start doing so
//  - sortedEntries merges both stores through the EXISTING blocked >
//    working > idle > done, then cwd-basename ordering, so an external
//    row appears in it alongside native entries
//
//  Tests marked "already true by construction" above are documented
//  per-test below; they are legitimate regression pins (they WOULD fail
//  if a future change wired reset()/the hook handlers to touch
//  externalEntries), not vacuous assertions -- they simply don't
//  require new production logic to pass today, unlike the
//  sortedEntries merge test.
//

import XCTest
@testable import Calyx

@MainActor
final class AgentRegistryExternalEntriesTests: XCTestCase {

    // MARK: - Helpers

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        _ name: String,
        sessionID: String? = "session-1",
        cwd: String? = "/Users/dev/project"
    ) -> AgentEvent {
        AgentEvent(hookEventName: name, sessionID: sessionID, cwd: cwd, message: nil)
    }

    private func externalEntry(
        id: UUID,
        cwd: String,
        state: AgentState = .working,
        kind: String = AgentEntry.claudeCodeKind
    ) -> AgentEntry {
        AgentEntry(
            surfaceID: id, sessionID: nil, source: .external, state: state,
            cwd: cwd, kind: kind, lastEventAt: fixedDate
        )
    }

    // MARK: - AgentEntry.focusSurfaceID

    func test_agentEntry_focusSurfaceID_defaultsToNilWhenOmitted() {
        let entry = AgentEntry(
            surfaceID: UUID(), sessionID: nil, source: .hooks, state: .idle,
            cwd: nil, kind: AgentEntry.claudeCodeKind, lastEventAt: fixedDate
        )

        XCTAssertNil(entry.focusSurfaceID,
                     "focusSurfaceID must default to nil so existing call sites are unaffected")
    }

    func test_agentEntry_focusSurfaceID_explicitValueRoundTrips() {
        let focusID = UUID()
        let entry = AgentEntry(
            surfaceID: UUID(), sessionID: nil, source: .external, state: .working,
            cwd: nil, kind: AgentEntry.claudeCodeKind, lastEventAt: fixedDate,
            unreadCount: 0, focusSurfaceID: focusID
        )

        XCTAssertEqual(entry.focusSurfaceID, focusID)
    }

    // MARK: - upsertExternalEntry / removeExternalEntry

    func test_upsertExternalEntry_addsToExternalStore_leavesNativeEntriesEmpty() {
        let registry = AgentRegistry()
        let id = UUID()
        let entry = externalEntry(id: id, cwd: "/x/alpha")

        registry.upsertExternalEntry(entry)

        XCTAssertEqual(registry.externalEntries[id], entry)
        XCTAssertTrue(registry.entries.isEmpty,
                      "An external upsert must never populate the native entries store")
    }

    func test_upsertExternalEntry_sameIDTwice_replacesRatherThanDuplicates() {
        let registry = AgentRegistry()
        let id = UUID()
        registry.upsertExternalEntry(externalEntry(id: id, cwd: "/x/alpha", state: .working))

        registry.upsertExternalEntry(externalEntry(id: id, cwd: "/x/alpha", state: .blocked))

        XCTAssertEqual(registry.externalEntries.count, 1)
        XCTAssertEqual(registry.externalEntries[id]?.state, .blocked)
    }

    func test_removeExternalEntry_removesOnlyTheGivenID() {
        let registry = AgentRegistry()
        let keepID = UUID()
        let dropID = UUID()
        registry.upsertExternalEntry(externalEntry(id: keepID, cwd: "/x/alpha"))
        registry.upsertExternalEntry(externalEntry(id: dropID, cwd: "/x/bravo"))

        registry.removeExternalEntry(id: dropID)

        XCTAssertNotNil(registry.externalEntries[keepID])
        XCTAssertNil(registry.externalEntries[dropID])
    }

    func test_removeExternalEntry_unknownID_isNoOp() {
        let registry = AgentRegistry()
        let id = UUID()
        registry.upsertExternalEntry(externalEntry(id: id, cwd: "/x/alpha"))

        registry.removeExternalEntry(id: UUID())

        XCTAssertNotNil(registry.externalEntries[id], "Removing an unknown id must not touch other entries")
    }

    func test_hasExternalEntries_reflectsExternalStoreEmptiness() {
        let registry = AgentRegistry()
        XCTAssertFalse(registry.hasExternalEntries, "A fresh registry has no external entries")

        let id = UUID()
        registry.upsertExternalEntry(externalEntry(id: id, cwd: "/x/alpha"))
        XCTAssertTrue(registry.hasExternalEntries)

        registry.removeExternalEntry(id: id)
        XCTAssertFalse(registry.hasExternalEntries)
    }

    // MARK: - reset() preserves externalEntries

    func test_reset_clearsNativeEntries_preservesExternalEntries() {
        // Already true by construction (see this file's header):
        // externalEntries is a fully separate store reset() has never
        // touched. Pinned anyway as a permanent regression guard -- the
        // exact property the separate-store design exists to guarantee.
        let registry = AgentRegistry()
        let externalID = UUID()
        let seeded = externalEntry(id: externalID, cwd: "/x/alpha", state: .blocked)
        registry.upsertExternalEntry(seeded)
        registry.handleHookEvent(event("SessionStart"), surfaceID: UUID())
        XCTAssertEqual(registry.entries.count, 1, "Precondition: a native entry must exist")

        registry.reset()

        XCTAssertTrue(registry.entries.isEmpty, "reset() must still clear every native entry")
        XCTAssertEqual(registry.externalEntries[externalID], seeded,
                       "reset() must preserve external entries untouched")
    }

    // MARK: - Native ingestion never mutates an external entry

    func test_handleHookEvent_neverMutatesExternalEntry_evenOnSurfaceIDCollision() {
        // Already true by construction (see this file's header):
        // handleHookEvent only ever reads/writes `entries`, never
        // `externalEntries`. Pinned so a future change to
        // handleHookEvent can't accidentally start doing so -- per the
        // separate-store rationale (mixing the two stores would require
        // auditing every source-arbitration site in this method).
        let registry = AgentRegistry()
        let collidingID = UUID()
        let seeded = externalEntry(id: collidingID, cwd: "/x/alpha", state: .blocked)
        registry.upsertExternalEntry(seeded)

        registry.handleHookEvent(event("SessionStart"), surfaceID: collidingID)

        XCTAssertEqual(registry.externalEntries[collidingID], seeded,
                       "handleHookEvent must never mutate an external entry")
        XCTAssertEqual(registry.entries[collidingID]?.source, .hooks,
                       "Precondition: handleHookEvent must still register its own native entry " +
                       "for the same surfaceID, proving the two stores are genuinely independent, " +
                       "not that handleHookEvent silently no-op'd")
    }

    func test_handleTitleChange_neverMutatesExternalEntry_evenOnSurfaceIDCollision() {
        let registry = AgentRegistry()
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
        let collidingID = UUID()
        let seeded = externalEntry(id: collidingID, cwd: "/x/alpha", state: .blocked)
        registry.upsertExternalEntry(seeded)

        registry.handleTitleChange(surfaceID: collidingID, title: "✳ Compacting conversation")

        XCTAssertEqual(registry.externalEntries[collidingID], seeded,
                       "handleTitleChange must never mutate an external entry")
        XCTAssertEqual(registry.entries[collidingID]?.source, .titleHeuristic,
                       "Precondition: handleTitleChange must still register its own native entry")
        registry.reset()
    }

    func test_handleScreenClassification_neverMutatesExternalEntry_evenOnSurfaceIDCollision() {
        let registry = AgentRegistry()
        let collidingID = UUID()
        let seeded = externalEntry(id: collidingID, cwd: "/x/alpha", state: .blocked)
        registry.upsertExternalEntry(seeded)

        registry.handleScreenClassification(surfaceID: collidingID, state: .working)

        XCTAssertEqual(registry.externalEntries[collidingID], seeded,
                       "handleScreenClassification must never mutate an external entry")
        XCTAssertEqual(registry.entries[collidingID]?.source, .titleHeuristic,
                       "Precondition: handleScreenClassification must still register its own " +
                       "native entry")
    }

    // MARK: - sortedEntries merges both stores

    func test_sortedEntries_mergesBothStoresThroughExistingPriorityAndBasenameOrdering() {
        let registry = AgentRegistry()

        let externalBlocked = UUID()
        registry.upsertExternalEntry(externalEntry(id: externalBlocked, cwd: "/x/zeta", state: .blocked))

        let nativeWorkingAlpha = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "s-alpha", cwd: "/x/alpha"), surfaceID: nativeWorkingAlpha
        )
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "s-alpha"), surfaceID: nativeWorkingAlpha)

        let nativeWorkingBravo = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "s-bravo", cwd: "/x/bravo"), surfaceID: nativeWorkingBravo
        )
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "s-bravo"), surfaceID: nativeWorkingBravo)

        let externalWorkingCharlie = UUID()
        registry.upsertExternalEntry(externalEntry(id: externalWorkingCharlie, cwd: "/x/charlie", state: .working))

        let nativeIdle = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "s-idle", cwd: "/x/delta"), surfaceID: nativeIdle)

        let externalDone = UUID()
        registry.upsertExternalEntry(externalEntry(id: externalDone, cwd: "/x/echo", state: .done))

        let sorted = registry.sortedEntries

        XCTAssertEqual(sorted.map(\.id), [
            externalBlocked,
            nativeWorkingAlpha, nativeWorkingBravo, externalWorkingCharlie,
            nativeIdle,
            externalDone,
        ], "sortedEntries must merge both stores: priority first (an external .blocked row sorts " +
           "above every .working row, native or external, despite its basename \"zeta\" sorting " +
           "last alphabetically), then cwd basename within the same priority tier interleaved " +
           "across stores (alpha, bravo, charlie), then idle, then done")
    }
}
