//
//  HerdrAgentMirrorTests.swift
//  CalyxTests
//
//  Tests: HerdrAgentMirror translating herdr session state into
//  AgentRegistry's external-entry store. See HerdrAgentMirror.swift's
//  own header for the frozen mapping rules, which the implementation
//  below follows.
//
//  Every test constructs a FRESH `AgentRegistry()` and a FRESH, throwaway
//  `HerdrPaneRegistry()` (never `.shared` for either) and wires them
//  together via `HerdrAgentMirror(registry:paneRegistry:)` -- no fakes/
//  mocks needed anywhere in this file: `HerdrSessionSnapshot` /
//  `HerdrAgentRecord` / `HerdrEvent` / `HerdrPaneAgentStatusChangedEvent`
//  are all plain, directly-constructible Swift value types (see
//  HerdrEvent.swift / HerdrSocketSession.swift's own memberwise
//  initializers), so this file drives HerdrAgentMirror's real public API
//  with real argument values end to end, the same "direct-call, no
//  process boundary to mock" style AgentRegistryExternalEntriesTests
//  already uses for AgentRegistry itself. Only the focusSurfaceID-
//  resolution and bridge-observer tests below actually exercise their
//  own `HerdrPaneRegistry()` (registering/unregistering bridges against
//  it); every other test's own throwaway pane registry stays inert,
//  since this file's socketPath/pane ids are never registered against
//  it -- constructed only so the test carries no dependency on
//  `HerdrPaneRegistry.shared`, a process-wide singleton with no reset
//  seam between tests.
//
//  Coverage:
//  - applySnapshot creates a row with correct kind/state/cwd/source
//  - a second applySnapshot missing a previously-present agent removes
//    that row
//  - apply(event: .paneAgentStatusChanged) updates an existing row's state
//  - apply(event: .paneAgentStatusChanged) CREATES a row when none existed
//    yet (the "shell pane launches Claude" scenario -- see
//    HerdrAgentMirror.swift's header)
//  - a nil cwd/agent on an UPDATE (applySnapshot or paneAgentStatusChanged)
//    preserves the row's previous cwd/kind rather than blanking/
//    relabelling it; paneAgentStatusChanged's update branch never
//    touches cwd at all
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
//    row immediately; a harmless no-op when no row ever existed for that
//    pane id
//
//  FOCUS SURFACE RESOLUTION (HerdrPaneRegistry.surfaceID(forPaneID:
//  socketPath:)): every one of this file's five row-write sites
//  (applySnapshot's absent-agent-terminal path and its main upsert;
//  applyStatusChanged's absent-agent-terminal path, its update branch,
//  and its create path) resolves `focusSurfaceID` fresh from the
//  injected pane registry rather than defaulting it or carrying an
//  existing row's previous value forward unexamined:
//  - a pane the pane registry has no bridge entry for produces a row
//    with a nil focusSurfaceID -- true of every row this file creates
//    for an unbridged pane, not merely a transient default
//  - a pane the pane registry already bridges produces a row whose
//    focusSurfaceID equals the registered surfaceID, via either
//    creation path (applySnapshot's main upsert, and
//    paneAgentStatusChanged's create path)
//  - a row created while its pane was unbridged self-heals to a non-nil
//    focusSurfaceID the next time applySnapshot runs after the pane
//    becomes bridged
//  - each of the remaining three write sites (both absent-agent-terminal
//    paths, and paneAgentStatusChanged's plain update branch) also
//    resolves focusSurfaceID fresh rather than merely carrying the
//    row's previous value forward
//
//  BRIDGE OBSERVER CONFORMANCE (HerdrPaneBridgeObserver): once a mirror
//  is registered as a HerdrPaneRegistry's bridge observer
//  (`paneRegistry.setBridgeObserver(mirror)`), the registry's own
//  register(surfaceID:ref:)/unregister(surfaceID:) calls push a
//  focusSurfaceID refresh directly into any row this instance already
//  owns for that pane, with no intervening applySnapshot/apply(event:)
//  call needed:
//  - register(surfaceID:ref:) for a pane with an existing row sets that
//    row's focusSurfaceID to the newly bridged surfaceID, without
//    touching lastEventAt or a second, unrelated row
//  - a later unregister(surfaceID:) for the same pane returns that row's
//    focusSurfaceID to nil, again without touching lastEventAt or a
//    second, unrelated row
//  - register(surfaceID:ref:) for a pane with no existing row is a
//    no-op: it never creates one, and never touches a different pane's
//    existing row either -- proven alongside a register call for a
//    pane that DOES have a row, so the no-op is distinguishable from
//    the callback never firing at all
//
//  END-TO-END COUPLING: the tests above pin the mechanism (registry ->
//  mirror -> AgentEntry.focusSurfaceID), but the thing a row's click
//  actually resolves through is AgentRowFocusTarget.resolve
//  (AgentStatusView.swift). One test below drives a bridge registration
//  through this file's real applySnapshot and asserts resolve(...) on
//  the resulting row equals the bridged Calyx surface, so a future
//  change to resolve's own priority order that silently stopped
//  honoring focusSurfaceID would fail here even with every
//  mechanism-level test above still green.
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

    /// The HerdrPaneRef a bridged `paneID` on this file's own `socketPath`
    /// would be registered under.
    private func paneRef(paneID: String) -> HerdrPaneRef {
        HerdrPaneRef(socketPath: socketPath, paneID: paneID)
    }

    // MARK: - applySnapshot: creates a row with correct fields

    func test_applySnapshot_createsExternalRow_withCorrectKindStateCwdAndSource() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
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
        XCTAssertNil(
            entry?.focusSurfaceID,
            "a pane the pane registry has no bridge entry for must produce a row with a nil focusSurfaceID -- " +
            "this pane registry never registered \"w1:p1\", so it stays unbridged for this whole test"
        )
    }

    // MARK: - applySnapshot: removes a row missing from a later snapshot

    func test_applySnapshot_secondSnapshotMissingAnAgent_removesThatRow() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p9")
        XCTAssertNil(registry.externalEntries[id], "Precondition: no row exists yet for this pane")

        mirror.apply(event: statusChangedEvent(paneID: "w1:p9", status: .working, agent: "claude"), socketPath: socketPath)

        let entry = registry.externalEntries[id]
        XCTAssertEqual(entry?.state, .working, "a paneAgentStatusChanged event must create a row when none existed")
        XCTAssertEqual(entry?.kind, AgentEntry.claudeCodeKind)
        XCTAssertEqual(entry?.source, .external)
        XCTAssertNil(entry?.cwd, "an event-created row has no cwd -- the event payload carries no cwd field")
    }

    // MARK: - nil cwd/agent on an update preserves the previous value

    func test_applySnapshot_secondSnapshotNilCwd_preservesPreviousCwd() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude")]), socketPath: socketPath)

        XCTAssertEqual(registry.externalEntries[id]?.kind, AgentEntry.claudeCodeKind)
    }

    func test_applySnapshot_passesThroughUnrecognizedKind_unchanged() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())

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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        mirror.apply(event: .paneCreated(paneRecord(paneID: "w1:p1")), socketPath: socketPath)

        XCTAssertNil(registry.externalEntries[id], "paneCreated alone must never create an agent row")
    }

    // MARK: - unknown(eventType:) is ignored

    func test_apply_unknownEvent_isIgnored() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        let before = registry.externalEntries
        XCTAssertFalse(before.isEmpty, "Precondition")

        mirror.apply(event: .unknown(eventType: "layout_updated"), socketPath: socketPath)

        XCTAssertEqual(registry.externalEntries, before, "an unknown(eventType:) event must never change any row")
    }

    // MARK: - paneClosed / paneExited remove the row immediately

    func test_apply_paneClosed_removesExistingRow_immediately() {
        let registry = AgentRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
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
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: HerdrPaneRegistry())
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        let before = registry.externalEntries
        XCTAssertFalse(before.isEmpty, "Precondition")

        mirror.apply(event: .paneExited(paneID: "w1:neverExisted"), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries, before,
            "a paneExited event for a pane id with no existing row must be a harmless no-op"
        )
    }

    // MARK: - focusSurfaceID resolution: bridged pane, creation paths

    func test_applySnapshot_bridgedPane_createsRowWithFocusSurfaceIDFromRegistry() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))

        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude", status: .working)]),
            socketPath: socketPath
        )

        XCTAssertEqual(
            registry.externalEntries[id]?.focusSurfaceID, calyxSurfaceID,
            "applySnapshot's main upsert must resolve focusSurfaceID from the pane registry for a bridged pane"
        )
    }

    func test_apply_paneAgentStatusChanged_bridgedPane_createsRowWithFocusSurfaceIDFromRegistry() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p9")
        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p9"))
        XCTAssertNil(registry.externalEntries[id], "Precondition: no row exists yet for this pane")

        mirror.apply(event: statusChangedEvent(paneID: "w1:p9", status: .working, agent: "claude"), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries[id]?.focusSurfaceID, calyxSurfaceID,
            "paneAgentStatusChanged's create path must resolve focusSurfaceID from the pane registry for a " +
            "bridged pane"
        )
    }

    // MARK: - focusSurfaceID resolution: self-healing

    func test_applySnapshot_selfHeals_focusSurfaceIDBecomesNonNil_oncePaneBecomesBridged() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")

        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        XCTAssertNil(
            registry.externalEntries[id]?.focusSurfaceID,
            "Precondition: an unbridged pane's row has no focus surface"
        )

        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries[id]?.focusSurfaceID, calyxSurfaceID,
            "a pane bridged after its row already exists must self-heal to a non-nil focusSurfaceID the next " +
            "time applySnapshot runs"
        )
    }

    // MARK: - focusSurfaceID resolution: absent-agent terminal paths

    /// Both terminal branches (this test, and the paneAgentStatusChanged
    /// equivalent below) build their updated row from `var updated =
    /// existing`, so a focusSurfaceID already on the row would carry
    /// over by copy alone. Starting the row UNBRIDGED and bridging it
    /// only right before the terminal transition rules that out: this
    /// only passes if the terminal path itself re-resolves
    /// focusSurfaceID from the pane registry.
    func test_applySnapshot_absentAgentTerminalPath_bridgedPane_resolvesFocusSurfaceID() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude", status: .idle)]),
            socketPath: socketPath
        )
        XCTAssertNil(registry.externalEntries[id]?.focusSurfaceID, "Precondition: the row starts unbridged")

        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: nil, status: .idle)]),
            socketPath: socketPath
        )

        XCTAssertEqual(
            registry.externalEntries[id]?.state, .done,
            "Precondition: this update must land on the absent-agent terminal path"
        )
        XCTAssertEqual(
            registry.externalEntries[id]?.focusSurfaceID, calyxSurfaceID,
            "applySnapshot's absent-agent terminal path must resolve focusSurfaceID from the pane registry, " +
            "not merely leave the row's previous (nil) value in place"
        )
    }

    func test_apply_paneAgentStatusChanged_absentAgentTerminalPath_bridgedPane_resolvesFocusSurfaceID() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude", status: .idle)]),
            socketPath: socketPath
        )
        XCTAssertNil(registry.externalEntries[id]?.focusSurfaceID, "Precondition: the row starts unbridged")

        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))
        mirror.apply(event: statusChangedEvent(paneID: "w1:p1", status: .idle, agent: nil), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries[id]?.state, .done,
            "Precondition: this update must land on the absent-agent terminal path"
        )
        XCTAssertEqual(
            registry.externalEntries[id]?.focusSurfaceID, calyxSurfaceID,
            "paneAgentStatusChanged's absent-agent terminal path must resolve focusSurfaceID from the pane " +
            "registry, not merely leave the row's previous (nil) value in place"
        )
    }

    // MARK: - focusSurfaceID resolution: paneAgentStatusChanged's plain update branch

    /// Not called out by name in this feature's own test list, but
    /// `HerdrAgentMirror.swift`'s header documents five row-write sites
    /// total; this is the one remaining site (the non-terminal update
    /// branch) the tests above don't already exercise. Same
    /// carry-by-copy risk as the absent-agent terminal paths above (this
    /// branch also builds from `var updated = existing`), so the row
    /// starts unbridged and is bridged only right before the update.
    func test_apply_paneAgentStatusChanged_updateBranch_bridgedPane_resolvesFocusSurfaceID() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude", status: .idle)]),
            socketPath: socketPath
        )
        XCTAssertNil(registry.externalEntries[id]?.focusSurfaceID, "Precondition: the row starts unbridged")

        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))
        mirror.apply(event: statusChangedEvent(paneID: "w1:p1", status: .blocked, agent: "claude"), socketPath: socketPath)

        XCTAssertEqual(
            registry.externalEntries[id]?.state, .blocked,
            "Precondition: this update must land on the plain update branch, not the absent-agent terminal path"
        )
        XCTAssertEqual(
            registry.externalEntries[id]?.focusSurfaceID, calyxSurfaceID,
            "paneAgentStatusChanged's update branch must resolve focusSurfaceID from the pane registry, not " +
            "merely leave the row's previous (nil) value in place"
        )
    }

    // MARK: - Bridge observer conformance (HerdrPaneBridgeObserver)

    func test_bridgeObserver_register_updatesExistingRowsFocusSurfaceID_withoutTouchingLastEventAtOrAnUnrelatedRow() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        paneRegistry.setBridgeObserver(mirror)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        // A second, unrelated row -- proves the write below is scoped to
        // the row matching the changed ref's own pane, not applied to
        // every row this mirror owns (an implementation that ignored
        // `ref` and wrote into every entry would otherwise still pass
        // this test with only one row present).
        let unrelatedID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p2")
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working), agentRecord(paneID: "w1:p2", status: .working)]),
            socketPath: socketPath
        )
        guard let rowBefore = registry.externalEntries[id] else {
            XCTFail("Precondition: applySnapshot must have created the row")
            return
        }
        XCTAssertNil(rowBefore.focusSurfaceID, "Precondition: the row starts unbridged")
        XCTAssertNil(
            registry.externalEntries[unrelatedID]?.focusSurfaceID, "Precondition: the unrelated row starts unbridged too"
        )

        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))

        let rowAfter = registry.externalEntries[id]
        XCTAssertEqual(
            rowAfter?.focusSurfaceID, calyxSurfaceID,
            "the bridge observer callback must set the existing row's focusSurfaceID to the newly registered " +
            "surfaceID"
        )
        XCTAssertEqual(
            rowAfter?.lastEventAt, rowBefore.lastEventAt,
            "the bridge observer callback must never touch lastEventAt"
        )
        XCTAssertNil(
            registry.externalEntries[unrelatedID]?.focusSurfaceID,
            "the bridge observer callback must only update the row matching the changed ref's own pane, never an " +
            "unrelated row"
        )
    }

    func test_bridgeObserver_unregister_clearsExistingRowsFocusSurfaceID_withoutTouchingLastEventAtOrAnUnrelatedRow() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        paneRegistry.setBridgeObserver(mirror)
        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        // A second, unrelated row, independently bridged -- proves the
        // clear below is scoped to the row matching the unregistered
        // surfaceID's own pane, not applied to every bridged row (an
        // implementation that ignored `ref` and cleared every entry
        // would otherwise still pass this test with only one row
        // present).
        let unrelatedID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p2")
        let calyxSurfaceID = UUID()
        let unrelatedSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))
        paneRegistry.register(surfaceID: unrelatedSurfaceID, ref: paneRef(paneID: "w1:p2"))
        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working), agentRecord(paneID: "w1:p2", status: .working)]),
            socketPath: socketPath
        )
        guard let rowBefore = registry.externalEntries[id] else {
            XCTFail("Precondition: applySnapshot must have created the row")
            return
        }
        XCTAssertEqual(rowBefore.focusSurfaceID, calyxSurfaceID, "Precondition: the row starts bridged")
        XCTAssertEqual(
            registry.externalEntries[unrelatedID]?.focusSurfaceID, unrelatedSurfaceID,
            "Precondition: the unrelated row starts bridged too"
        )

        paneRegistry.unregister(surfaceID: calyxSurfaceID)

        let rowAfter = registry.externalEntries[id]
        XCTAssertNil(
            rowAfter?.focusSurfaceID,
            "the bridge observer callback must clear the existing row's focusSurfaceID back to nil once its " +
            "pane is unregistered"
        )
        XCTAssertEqual(
            rowAfter?.lastEventAt, rowBefore.lastEventAt,
            "the bridge observer callback must never touch lastEventAt"
        )
        XCTAssertEqual(
            registry.externalEntries[unrelatedID]?.focusSurfaceID, unrelatedSurfaceID,
            "unregistering one surface's bridge must only clear the row matching that surface's own pane, never " +
            "an unrelated row's focusSurfaceID"
        )
    }

    func test_bridgeObserver_register_forPaneWithNoExistingRow_doesNotCreateARow_andLeavesAnUnrelatedRowUntouched() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        paneRegistry.setBridgeObserver(mirror)
        // "w1:p99" (not "w1:neverSeen"): HerdrPaneRef.isValidPaneID
        // requires "p" immediately after the colon, and both production
        // register(surfaceID:ref:) call sites are gated on that
        // validator, so an invalid id could never reach this callback
        // for real.
        let neverSeenID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p99")
        XCTAssertNil(registry.externalEntries[neverSeenID], "Precondition: no row exists for this pane")

        // An existing, unrelated row -- registering the never-seen
        // pane's bridge below must not create OR touch it either.
        let rowID = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        mirror.applySnapshot(snapshot(agents: [agentRecord(paneID: "w1:p1", status: .working)]), socketPath: socketPath)
        XCTAssertNil(registry.externalEntries[rowID]?.focusSurfaceID, "Precondition: the unrelated row starts unbridged")

        paneRegistry.register(surfaceID: UUID(), ref: paneRef(paneID: "w1:p99"))

        XCTAssertNil(
            registry.externalEntries[neverSeenID],
            "the bridge observer callback must never create a row for a pane with no pre-existing row"
        )
        XCTAssertNil(
            registry.externalEntries[rowID]?.focusSurfaceID,
            "registering a bridge for a pane with no row of its own must not touch a different pane's existing row"
        )

        // Positive proof the observer is genuinely wired and firing:
        // every assertion above would also pass if setBridgeObserver's
        // callback never ran at all, so only registering a bridge for a
        // pane that DOES have a row, and seeing that row actually
        // change, distinguishes "the no-create guard ran" from "the
        // callback never fired".
        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))

        XCTAssertEqual(
            registry.externalEntries[rowID]?.focusSurfaceID, calyxSurfaceID,
            "registering a bridge for a pane that DOES have a row must set that row's focusSurfaceID, proving " +
            "the bridge observer is genuinely wired and firing"
        )
    }

    // MARK: - End-to-end: a bridged pane resolves through AgentRowFocusTarget

    /// Every test above pins that a bridged pane's row gets a non-nil
    /// `focusSurfaceID` -- this test instead follows that value through
    /// `AgentRowFocusTarget.resolve` (AgentStatusView.swift), the exact
    /// function `AgentRowView.body` calls to decide what a click on the
    /// row does. Coupling the two files only by convention would let a
    /// future change to `resolve`'s own priority order silently stop
    /// honoring `focusSurfaceID` while every test above stayed green.
    func test_bridgedPane_afterApplySnapshot_resolvesThroughAgentRowFocusTarget_toTheCalyxSurface() {
        let registry = AgentRegistry()
        let paneRegistry = HerdrPaneRegistry()
        let mirror = HerdrAgentMirror(registry: registry, paneRegistry: paneRegistry)
        let calyxSurfaceID = UUID()
        paneRegistry.register(surfaceID: calyxSurfaceID, ref: paneRef(paneID: "w1:p1"))

        mirror.applySnapshot(
            snapshot(agents: [agentRecord(paneID: "w1:p1", agent: "claude", status: .working)]),
            socketPath: socketPath
        )

        let id = HerdrStableID.make(socketPath: socketPath, paneID: "w1:p1")
        guard let row = registry.externalEntries[id] else {
            XCTFail("Precondition: applySnapshot must have created the row")
            return
        }
        let resolved = AgentRowFocusTarget.resolve(
            source: row.source, surfaceID: row.surfaceID, focusSurfaceID: row.focusSurfaceID
        )

        XCTAssertEqual(
            resolved, calyxSurfaceID,
            "a bridged herdr pane's row must resolve, through the exact function AgentRowView.body calls on a " +
            "click, to the Calyx surface HerdrPaneRegistry registered for it -- not merely have a non-nil " +
            "focusSurfaceID field"
        )
    }
}
