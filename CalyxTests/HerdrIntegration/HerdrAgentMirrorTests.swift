//
//  HerdrAgentMirrorTests.swift
//  CalyxTests
//
//  Tests (herdr ): HerdrAgentMirror translating herdr
//  session state into AgentRegistry's external-entry store. See
//  HerdrAgentMirror.swift's own header for the frozen mapping rules,
//  which the implementation below follows.
//
//  Every test constructs a FRESH `AgentRegistry()` (never `.shared`) and
//  a `HerdrAgentMirror(registry:)` wired to it directly -- no fakes/
//  mocks needed anywhere in this file: `HerdrSessionSnapshot` /
//  `HerdrAgentRecord` / `HerdrEvent` / `HerdrPaneAgentStatusChangedEvent`
//  are all plain, directly-constructible Swift value types (see
//  HerdrEvent.swift / HerdrSocketSession.swift's own memberwise
//  initializers), so this file drives HerdrAgentMirror's real public API
//  with real argument values end to end, the same "direct-call, no
//  process boundary to mock" style AgentRegistryExternalEntriesTests
//  already uses for AgentRegistry itself.
//
//  Coverage:
//  - applySnapshot creates a row with correct kind/state/cwd/source, and
//    focusSurfaceID nil
//  - a second applySnapshot missing a previously-present agent removes
//    that row
//  - apply(event: .paneAgentStatusChanged) updates an existing row's state
//  - apply(event: .paneAgentStatusChanged) CREATES a row when none existed
//    yet (the "shell pane launches Claude" scenario -- see
//    HerdrAgentMirror.swift's header)
//  - C3 fix: a nil cwd/agent on an UPDATE (applySnapshot or
//    paneAgentStatusChanged) preserves the row's previous cwd/kind
//    rather than blanking/relabelling it; paneAgentStatusChanged's
//    update branch never touches cwd at all
//  - unknown/unrecognized status in a snapshot: never creates a row for a
//    new pane; leaves an EXISTING row's state untouched (does not
//    downgrade) across a working -> unknown transition
//  - connectionLost clears every external row but leaves a native row
//    (registered directly via AgentRegistry.handleHookEvent) untouched
//  - kind mapping: herdr "claude" -> AgentEntry.claudeCodeKind; an
//    unrecognized kind string passes through unchanged
//  - stable ids: the same pane across two separate snapshots keeps the
//    same AgentEntry.id
//  - paneCreated alone never creates a row
//  - an unknown(eventType:) event is fully ignored
//  - apply(event: .paneClosed)/.paneExited removes that pane's external
//    row immediately (A6); a harmless no-op when no row ever existed for
//    that pane id
//

import XCTest
@testable import Calyx

@MainActor
final class HerdrAgentMirrorTests: XCTestCase {

    private let socketPath = "/tmp/herdr-agent-mirror-test/herdr.sock"

    // MARK: - Fixture builders

    private func agentRecord(
        paneID: String,
        agent: String? = "claude",
        status: HerdrAgentStatus = .working,
        workspaceID: String = "w1",
        cwd: String? = "/Users/dev/project"
    ) -> HerdrAgentRecord {
        HerdrAgentRecord(
            terminalID: "term_\(paneID)", agentStatus: status, workspaceID: workspaceID,
            tabID: "\(workspaceID):t1", paneID: paneID, focused: false, revision: 0,
            agent: agent, agentSession: nil, cwd: cwd, displayAgent: nil, foregroundCwd: cwd,
            name: nil, terminalTitle: nil, terminalTitleStripped: nil, title: nil,
            interactiveReady: nil, launchPending: nil, screenDetectionSkipped: nil,
            stateChangeSeq: nil, stateLabels: nil, tokens: nil
        )
    }

    private func snapshot(agents: [HerdrAgentRecord]) -> HerdrSessionSnapshot {
        HerdrSessionSnapshot(
            version: "0.8.0", protocolVersion: 19, workspaces: [], tabs: [], panes: [], layouts: [],
            agents: agents, focusedWorkspaceID: nil, focusedTabID: nil, focusedPaneID: nil
        )
    }

    private func statusChangedEvent(
        paneID: String,
        status: HerdrAgentStatus,
        agent: String? = "claude",
        workspaceID: String = "w1"
    ) -> HerdrEvent {
        .paneAgentStatusChanged(
            HerdrPaneAgentStatusChangedEvent(
                paneID: paneID, workspaceID: workspaceID, agentStatus: status, agent: agent,
                displayAgent: nil, title: nil, stateLabels: nil
            )
        )
    }

    private func paneRecord(paneID: String, workspaceID: String = "w1") -> HerdrPaneRecord {
        HerdrPaneRecord(
            terminalID: "term_\(paneID)", agentStatus: .unknown, workspaceID: workspaceID,
            tabID: "\(workspaceID):t1", paneID: paneID, focused: false, revision: 0,
            agent: nil, agentSession: nil, cwd: nil, displayAgent: nil, foregroundCwd: nil,
            label: nil, scroll: nil, terminalTitle: nil, terminalTitleStripped: nil, title: nil,
            stateLabels: nil, tokens: nil
        )
    }

    // MARK: - applySnapshot: creates a row with correct fields

    func test_applySnapshot_createsExternalRow_withCorrectKindStateCwdAndSource() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude", status: .working, cwd: "/Users/dev/alpha")]),
            socketPath: socketPath
        )

        let entry = registry.externalEntries[id]
        XCTAssertNotNil(entry, "applySnapshot must create an external row keyed by HerdrStableID.make(...)")
        XCTAssertEqual(entry?.source, .external)
        XCTAssertEqual(entry?.state, .working)
        XCTAssertEqual(entry?.cwd, "/Users/dev/alpha")
        XCTAssertEqual(entry?.kind, AgentEntry.claudeCodeKind)
        XCTAssertNil(entry?.focusSurfaceID, "focusSurfaceID must stay nil in this stage")
    }

    // MARK: - applySnapshot: removes a row missing from a later snapshot

    func test_applySnapshot_secondSnapshotMissingAnAgent_removesThatRow() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let keepID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        let dropID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p2")

        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1"), agentRecord(paneID: "w1:p2")]),
            socketPath: socketPath
        )
        XCTAssertEqual(registry.externalEntries.count, 2, "Precondition: both rows must exist after the first snapshot")

        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1")]), socketPath: socketPath)

        XCTAssertNotNil(registry.externalEntries[keepID], "a pane still present in the new snapshot must survive")
        XCTAssertNil(registry.externalEntries[dropID], "a pane no longer present in the new snapshot must be removed")
    }

    // MARK: - apply(event:): paneAgentStatusChanged updates an existing row

    func test_apply_paneAgentStatusChanged_updatesExistingRowState() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .idle)]), socketPath: socketPath)
        XCTAssertEqual(registry.externalEntries[id]?.state, .idle, "Precondition")

        mirror.apply(event: statusChangedEvent(paneID: "w1:p1", status: .blocked), socketPath: socketPath)

        XCTAssertEqual(registry.externalEntries[id]?.state, .blocked)
    }

    // MARK: - apply(event:): paneAgentStatusChanged creates a row when none existed

    func test_apply_paneAgentStatusChanged_createsRow_whenNoRowExistedYet() {
        // The "shell pane launches Claude" scenario -- see
        // HerdrAgentMirror.swift's header: the pane's per-pane
        // agentStatusChanged subscription already exists from the
        // moment it was first known (a plain shell pane, status
        // "unknown" -- no row), so its FIRST sign of running an agent
        // is this event, with no prior snapshot row to "update".
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p9")
        XCTAssertNil(registry.externalEntries[id], "Precondition: no row exists yet for this pane")

        mirror.apply(event: statusChangedEvent(paneID: "w1:p9", status: .working, agent: "claude"), socketPath: socketPath)

        let entry = registry.externalEntries[id]
        XCTAssertEqual(entry?.state, .working, "a paneAgentStatusChanged event must create a row when none existed")
        XCTAssertEqual(entry?.kind, AgentEntry.claudeCodeKind)
        XCTAssertEqual(entry?.source, .external)
        XCTAssertNil(entry?.cwd, "an event-created row has no cwd -- the event payload carries no cwd field")
    }

    // MARK: - C3 fix: nil cwd/agent on an update preserves the previous value

    func test_applySnapshot_secondSnapshotNilCwd_preservesPreviousCwd() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working, cwd: "/Users/dev/alpha")]),
            socketPath: socketPath
        )
        XCTAssertEqual(registry.externalEntries[id]?.cwd, "/Users/dev/alpha", "Precondition")

        // A later snapshot with a nil cwd for the SAME pane must not
        // blank out the previously-known cwd.
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", status: .blocked, cwd: nil)]),
            socketPath: socketPath
        )

        XCTAssertEqual(registry.externalEntries[id]?.cwd, "/Users/dev/alpha",
                       "A nil cwd on an update must preserve the row's previous cwd, not blank it out")
        XCTAssertEqual(registry.externalEntries[id]?.state, .blocked, "state must still update normally")
    }

    func test_applySnapshot_secondSnapshotNilAgent_preservesPreviousKindNotClaudeCodeDefault() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "codex", status: .working)]),
            socketPath: socketPath
        )
        XCTAssertEqual(registry.externalEntries[id]?.kind, "codex", "Precondition")

        // A later snapshot with a nil agent for the SAME pane must not
        // silently relabel a codex row as Claude Code -- mapKind(nil)'s
        // own default is only correct for a brand-new row.
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: nil, status: .blocked)]),
            socketPath: socketPath
        )

        XCTAssertEqual(
            registry.externalEntries[id]?.kind, "codex",
            "A nil agent on an update must preserve the row's previous kind, not relabel it as Claude Code"
        )
    }

    func test_apply_paneAgentStatusChanged_nilAgentOnUpdate_preservesPreviousKind() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "codex", status: .working)]),
            socketPath: socketPath
        )
        XCTAssertEqual(registry.externalEntries[id]?.kind, "codex", "Precondition")

        mirror.apply(event: statusChangedEvent(paneID: "w1:p1", status: .blocked, agent: nil), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries[id]?.kind, "codex",
            "A paneAgentStatusChanged event with a nil agent must not relabel an already-known row"
        )
    }

    func test_apply_paneAgentStatusChanged_idleWithNoAgent_marksExistingRowDone() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude", status: .idle)]),
            socketPath: socketPath
        )

        mirror.apply(
            event: statusChangedEvent(paneID: "w1:p1", status: .idle, agent: nil),
            socketPath: socketPath
        )

        XCTAssertEqual(
            registry.externalEntries[id]?.state, .done,
            "herdr reports agent=nil when the CLI exits but the shell pane remains; that transition must be blue/done"
        )
        XCTAssertEqual(registry.externalEntries[id]?.kind, AgentEntry.claudeCodeKind)
    }

    func test_apply_paneAgentStatusChanged_updateBranch_neverTouchesCwd() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", status: .idle, cwd: "/Users/dev/alpha")]),
            socketPath: socketPath
        )

        mirror.apply(event: statusChangedEvent(paneID: "w1:p1", status: .blocked), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries[id]?.cwd, "/Users/dev/alpha",
            "paneAgentStatusChanged carries no cwd field at all; updating a row must never touch cwd"
        )
    }

    // MARK: - Unknown/unrecognized status handling (documented rule)

    func test_applySnapshot_unknownStatus_neverCreatesARowForANewPane() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:shell")

        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:shell", agent: nil, status: .unknown)]),
            socketPath: socketPath
        )

        XCTAssertNil(
            registry.externalEntries[id],
            "a plain shell pane (status \"unknown\", no agent) must never get an Agents-sidebar row"
        )
    }

    func test_applySnapshot_unknownStatusWithNoAgent_forAlreadyKnownPane_marksItDone() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        XCTAssertEqual(registry.externalEntries[id]?.state, .working, "Precondition")

        // The shell pane remains, but herdr no longer detects an agent.
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: nil, status: .unknown)]),
            socketPath: socketPath
        )

        XCTAssertEqual(
            registry.externalEntries[id]?.state, .done,
            "an already-known agent becoming agent=nil must be shown as completed, not left green or working"
        )
    }

    // MARK: - connectionLost

    func test_connectionLost_clearsExternalRows_leavesNativeRowPresent() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1")]), socketPath: socketPath)
        let nativeSurfaceID = UUID()
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SessionStart", sessionID: "s1", cwd: "/Users/dev/native", message: nil),
            surfaceID: nativeSurfaceID
        )
        XCTAssertFalse(registry.externalEntries.isEmpty, "Precondition: an external row must exist")
        XCTAssertNotNil(registry.entries[nativeSurfaceID], "Precondition: a native row must exist")

        mirror.connectionLost()

        XCTAssertTrue(registry.externalEntries.isEmpty, "connectionLost must clear every external row")
        XCTAssertNotNil(registry.entries[nativeSurfaceID], "connectionLost must never touch native rows")
    }

    // MARK: - Kind mapping

    func test_applySnapshot_mapsHerdrClaudeKind_toClaudeCodeKindConstant() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude")]), socketPath: socketPath)

        XCTAssertEqual(registry.externalEntries[id]?.kind, AgentEntry.claudeCodeKind)
    }

    func test_applySnapshot_passesThroughUnrecognizedKind_unchanged() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "some-future-cli")]),
            socketPath: socketPath
        )

        XCTAssertEqual(
            registry.externalEntries[id]?.kind, "some-future-cli",
            "an unrecognized herdr agent kind must pass through unchanged -- AgentEntry.displayName(forKind:) " +
            "already falls through to the raw string"
        )
    }

    // MARK: - Stable ids across snapshots

    func test_applySnapshot_stableIDs_sameRowKeepsSameIDAcrossTwoSnapshots() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)

        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .idle)]), socketPath: socketPath)
        let idsAfterFirst = Set(registry.externalEntries.keys)
        XCTAssertEqual(idsAfterFirst.count, 1, "Precondition")

        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        let idsAfterSecond = Set(registry.externalEntries.keys)

        XCTAssertEqual(
            idsAfterFirst, idsAfterSecond,
            "the same herdr pane observed across two snapshots must keep the identical AgentEntry.id"
        )
    }

    // MARK: - paneCreated is a pure no-op

    func test_apply_paneCreated_neverCreatesARow() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        mirror.apply(event: .paneCreated(paneRecord(paneID: "w1:p1")), socketPath: socketPath)

        XCTAssertNil(registry.externalEntries[id], "paneCreated alone must never create an agent row")
    }

    // MARK: - unknown(eventType:) is ignored

    func test_apply_unknownEvent_isIgnored() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        let before = registry.externalEntries
        XCTAssertFalse(before.isEmpty, "Precondition")

        mirror.apply(event: .unknown(eventType: "layout_updated"), socketPath: socketPath)

        XCTAssertEqual(registry.externalEntries, before, "an unknown(eventType:) event must never change any row")
    }

    // MARK: - paneClosed / paneExited remove the row immediately (A6)

    func test_apply_paneClosed_removesExistingRow_immediately() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        XCTAssertNotNil(registry.externalEntries[id], "Precondition: the snapshot must have created a row")

        mirror.apply(event: .paneClosed(paneID: "w1:p1"), socketPath: socketPath)

        XCTAssertNil(
            registry.externalEntries[id],
            "a paneClosed event must remove that pane's row immediately, not wait for the next snapshot"
        )
    }

    func test_apply_paneExited_removesExistingRow_immediately() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        XCTAssertNotNil(registry.externalEntries[id], "Precondition: the snapshot must have created a row")

        mirror.apply(event: .paneExited(paneID: "w1:p1"), socketPath: socketPath)

        XCTAssertNil(
            registry.externalEntries[id],
            "a paneExited event must remove that pane's row immediately, not wait for the next snapshot"
        )
    }

    func test_apply_paneClosed_forPaneWithNoExistingRow_isHarmlessNoOp() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        let before = registry.externalEntries
        XCTAssertFalse(before.isEmpty, "Precondition")

        // "w1:neverExisted" never had a row (e.g. a plain shell pane that
        // closed without ever reporting a known agent status) -- removing
        // it must not touch any other row, or throw/crash.
        mirror.apply(event: .paneClosed(paneID: "w1:neverExisted"), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries, before,
            "a paneClosed event for a pane id with no existing row must be a harmless no-op"
        )
    }

    func test_apply_paneExited_forPaneWithNoExistingRow_isHarmlessNoOp() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry)
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        let before = registry.externalEntries
        XCTAssertFalse(before.isEmpty, "Precondition")

        mirror.apply(event: .paneExited(paneID: "w1:neverExisted"), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries, before,
            "a paneExited event for a pane id with no existing row must be a harmless no-op"
        )
    }
}
