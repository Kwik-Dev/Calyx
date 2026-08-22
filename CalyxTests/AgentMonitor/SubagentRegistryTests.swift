//
//  SubagentRegistryTests.swift
//  CalyxTests
//
//  Covers SubagentRegistry, the storage side effect AgentRegistry.
//  handleHookEvent forwards a subagent hook event to: it owns child rows
//  keyed by (parentSurfaceID, agentID), reusing
//  AgentStateResolver.resultingState(for:) for state so no
//  child-specific vocabulary is ever duplicated. SubagentRegistry itself
//  no longer knows any parent event name or compares sessionIDs -- a
//  parent-scoped SessionEnd/SessionStart's children-retiring effect (a
//  same-session parent Stop no longer retires children at all), and a
//  session-mismatch row replacement's identical effect, are decided by
//  AgentStateResolver.resolveHook (AgentResolution.retiresChildren) and
//  carried out by AgentRegistry.apply, so those tests live in
//  AgentRegistryTests.swift instead, driving the pipeline through
//  AgentRegistry.handleHookEvent rather than this type directly.
//
//  Coverage:
//  - SubagentStart creates a child at .working with its agentType
//  - An event with an unknown agentID creates a child (a reported fact)
//  - PreToolUse / PostToolUse update lastToolName; other events don't
//  - state follows resultingState(for:); an event mapping to nil leaves
//    state alone
//  - agentType is overwritten only when non-nil
//  - SubagentStop removes only that agentID
//  - A subagent-scoped SessionEnd (a child's own teardown) removes only
//    that agentID, exactly as SubagentStop does; it creates nothing for
//    an agentID already removed
//  - AgentRegistry.handleSurfaceDestroyed removes that parent's children
//  - AgentRegistry.reset() removes every child
//  - A SubagentStop with no agentID removes nothing
//  - children(of:) returns a stable order across calls
//  - Children never appear in AgentRegistry.entries or externalEntries
//  - startedAt is stamped once at creation and never restamped by a
//    later event for that child, even while state/lastToolName/agentType
//    do update
//

import XCTest
@testable import Calyx

@MainActor
final class SubagentRegistryTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        _ name: String,
        sessionID: String? = "parent-session",
        cwd: String? = nil,
        agentID: String? = "sub-1",
        agentType: String? = "explore",
        toolName: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            hookEventName: name, sessionID: sessionID, cwd: cwd, message: nil,
            agentID: agentID, agentType: agentType, toolName: toolName
        )
    }

    // MARK: - Creation

    func test_subagentStart_createsChildAtWorkingWithAgentType() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1", agentType: "explore"), parentSurfaceID: parent)

        let children = registry.children(of: parent)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.agentID, "sub-1")
        XCTAssertEqual(children.first?.agentType, "explore")
        XCTAssertEqual(children.first?.state, .working, "SubagentStart maps to no AgentState, but a child " +
                       "the CLI just reported starting begins at .working")
        XCTAssertEqual(children.first?.parentSurfaceID, parent)
    }

    func test_unknownAgentID_createsAChild() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("PreToolUse", agentID: "sub-9", toolName: "Bash"), parentSurfaceID: parent)

        let children = registry.children(of: parent)
        XCTAssertEqual(children.count, 1,
                       "An event with an unknown agentID is a reported fact the child exists, not an invention")
        XCTAssertEqual(children.first?.agentID, "sub-9")
    }

    // MARK: - lastToolName

    func test_preToolUseAndPostToolUse_updateLastToolName() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart"), parentSurfaceID: parent)
        registry.handleHookEvent(event("PreToolUse", toolName: "Bash"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Bash")

        registry.handleHookEvent(event("PostToolUse", toolName: "Read"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Read")
    }

    func test_otherEvents_leaveLastToolNameAlone() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("PreToolUse", toolName: "Bash"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Bash")

        registry.handleHookEvent(event("Notification", toolName: nil), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Bash",
                       "An event that carries no tool_name must not clear a previously recorded one")
    }

    func test_postToolUseWithNoToolName_leavesThePreviouslyRecordedToolNameInPlace() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("PreToolUse", toolName: "Bash"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Bash")

        // OpenCode's permission.replied maps to PostToolUse with no tool
        // name -- it must not blank the tool the child was last known to
        // be running.
        registry.handleHookEvent(event("PostToolUse", toolName: nil), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Bash",
                       "A PostToolUse carrying no tool name must not erase a previously recorded tool name")
    }

    func test_preToolUseWithToolName_stillReplacesThePreviousToolName() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("PreToolUse", toolName: "Bash"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Bash")

        registry.handleHookEvent(event("PreToolUse", toolName: "Read"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.lastToolName, "Read",
                       "A PreToolUse carrying a tool name must still replace the previous one")
    }

    // MARK: - state via resultingState(for:)

    func test_state_followsTheSameMappingTheParentUses() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.state, .working)

        registry.handleHookEvent(event("PermissionRequest"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.state, .blocked)

        registry.handleHookEvent(event("Stop"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.state, .idle)
    }

    func test_eventMappingToNilState_leavesStateAlone() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("PreToolUse"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.state, .working)

        // A Notification with no message resolves to .blocked in
        // resultingState -- use one with an unrelated message instead, so
        // it maps to nil and must leave state untouched.
        registry.handleHookEvent(
            AgentEvent(
                hookEventName: "Notification", sessionID: "parent-session", cwd: nil,
                message: "unrelated", agentID: "sub-1", agentType: "explore"
            ),
            parentSurfaceID: parent
        )

        XCTAssertEqual(registry.children(of: parent).first?.state, .working,
                       "An event resultingState(for:) maps to nil must leave the child's state unchanged")
    }

    // MARK: - agentType overwritten only when non-nil

    func test_agentType_overwrittenOnlyWhenNonNil() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1", agentType: "explore"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.agentType, "explore")

        registry.handleHookEvent(event("PreToolUse", agentID: "sub-1", agentType: nil), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.agentType, "explore",
                       "A nil agentType on a later event must not blank out a previously known one")

        registry.handleHookEvent(event("PostToolUse", agentID: "sub-1", agentType: "reviewer"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).first?.agentType, "reviewer",
                       "A non-nil agentType overwrites the previous value")
    }

    // MARK: - Removal: SubagentStop

    func test_subagentStop_removesOnlyThatAgentID() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), parentSurfaceID: parent)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-2"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).count, 2)

        registry.handleHookEvent(event("SubagentStop", agentID: "sub-1"), parentSurfaceID: parent)

        let remaining = registry.children(of: parent)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.agentID, "sub-2")
    }

    // MARK: - AgentRegistry-level removal triggers

    func test_agentRegistry_handleSurfaceDestroyed_removesThatParentsChildren() {
        let registry = AgentRegistry()
        let parentA = UUID()
        let parentB = UUID()

        // A child is only ever tracked under a live row -- give each
        // parent one before its SubagentStart.
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil),
            surfaceID: parentA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-b", cwd: nil, message: nil),
            surfaceID: parentB
        )
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), surfaceID: parentA)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-2"), surfaceID: parentB)
        XCTAssertEqual(registry.subagentRegistry.children(of: parentA).count, 1, "Precondition: a live child")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1, "Precondition: a live child")

        registry.handleSurfaceDestroyed(surfaceID: parentA)

        XCTAssertTrue(registry.subagentRegistry.children(of: parentA).isEmpty,
                      "Destroying a pane must remove that parent's children")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1,
                       "A different (still-live) parent's children must be untouched")
    }

    func test_agentRegistry_reset_removesEveryChild() {
        let registry = AgentRegistry()
        let parentA = UUID()
        let parentB = UUID()

        // A child is only ever tracked under a live row -- give each
        // parent one before its SubagentStart.
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil),
            surfaceID: parentA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-b", cwd: nil, message: nil),
            surfaceID: parentB
        )
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), surfaceID: parentA)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-2"), surfaceID: parentB)
        XCTAssertEqual(registry.subagentRegistry.children(of: parentA).count, 1, "Precondition: a live child")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1, "Precondition: a live child")

        registry.reset()

        XCTAssertTrue(registry.subagentRegistry.children(of: parentA).isEmpty)
        XCTAssertTrue(registry.subagentRegistry.children(of: parentB).isEmpty)
    }

    // MARK: - Degrade case: SubagentStop with no agentID
    //
    // The other half of this degrade case -- the lingering child still
    // going away once an ACCEPTED parent SessionEnd or SessionStart
    // retires it -- needs the full AgentRegistry pipeline
    // (AgentStateResolver.resolveHook's retiresChildren decision) and
    // lives in AgentRegistryTests.swift's "Parent-scoped sweep" section
    // instead. An accepted parent Stop no longer retires children at
    // all, so a lingering child now survives its parent's own Stop and
    // only goes away on SessionEnd/SessionStart, pane exit, or the
    // parent row settling to .done.

    func test_subagentStopWithNoAgentID_removesNothing() {
        let registry = SubagentRegistry()
        let parent = UUID()
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), parentSurfaceID: parent)

        // A SubagentStop that carries no agentID is not a subagent event
        // (isSubagentEvent == false) and must remove nothing.
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStop", sessionID: "parent-session", cwd: nil, message: nil, agentID: nil),
            parentSurfaceID: parent
        )
        XCTAssertEqual(registry.children(of: parent).count, 1,
                       "A SubagentStop with no agentID identifies no child, so nothing may be removed")
    }

    // MARK: - Removal: a child's own SessionEnd (subagent-scoped)

    func test_subagentScopedSessionEnd_removesOnlyThatChild() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), parentSurfaceID: parent)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-2"), parentSurfaceID: parent)
        XCTAssertEqual(registry.children(of: parent).count, 2)

        registry.handleHookEvent(event("SessionEnd", agentID: "sub-1"), parentSurfaceID: parent)

        let remaining = registry.children(of: parent)
        XCTAssertEqual(remaining.count, 1,
                       "A subagent-scoped SessionEnd reports that child's own teardown and must remove only it")
        XCTAssertEqual(remaining.first?.agentID, "sub-2")
    }

    func test_subagentScopedSessionEnd_forAlreadyRemovedAgentID_createsNothing() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), parentSurfaceID: parent)
        registry.handleHookEvent(event("SubagentStop", agentID: "sub-1"), parentSurfaceID: parent)
        XCTAssertTrue(registry.children(of: parent).isEmpty)

        // The child's own SessionEnd arrives after SubagentStop already
        // removed it. It must not resurrect a stale .done row.
        registry.handleHookEvent(event("SessionEnd", agentID: "sub-1"), parentSurfaceID: parent)

        XCTAssertTrue(registry.children(of: parent).isEmpty,
                      "A subagent-scoped SessionEnd for an already-removed agentID must create nothing")
    }

    // MARK: - children(of:) stable order

    func test_childrenOf_returnsStableOrderAcrossCalls() {
        let registry = SubagentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), parentSurfaceID: parent)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-2"), parentSurfaceID: parent)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-3"), parentSurfaceID: parent)

        let first = registry.children(of: parent).map(\.agentID)
        let second = registry.children(of: parent).map(\.agentID)
        let third = registry.children(of: parent).map(\.agentID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
    }

    // MARK: - Children never leak into AgentRegistry.entries / externalEntries

    func test_children_neverAppearInAgentRegistryEntriesOrExternalEntries() {
        let registry = AgentRegistry()
        let parent = UUID()

        registry.handleHookEvent(event("SessionStart", sessionID: "parent-session", agentID: nil, agentType: nil), surfaceID: parent)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), surfaceID: parent)

        XCTAssertEqual(registry.entries.count, 1, "Only the parent's own row may exist in entries")
        XCTAssertNil(registry.entries[UUID()], "Sanity: a random UUID has no entry")
        for entry in registry.entries.values {
            XCTAssertEqual(entry.surfaceID, parent, "No child-keyed row may appear in entries")
        }
        XCTAssertTrue(registry.externalEntries.isEmpty, "A child must never appear in externalEntries either")
    }

    // MARK: - A parent row settling to .done outside the hook path clears its children

    func test_handlePaneCommandFinished_settlingAParentToDone_clearsThatParentsChildren_andOnlyThatParents() {
        let registry = AgentRegistry()
        let parentA = UUID()
        let parentB = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil),
            surfaceID: parentA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-b", cwd: nil, message: nil),
            surfaceID: parentB
        )
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), surfaceID: parentA)
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-2"), surfaceID: parentB)
        XCTAssertEqual(registry.subagentRegistry.children(of: parentA).count, 1)
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1)

        registry.handlePaneCommandFinished(surfaceID: parentA)

        XCTAssertEqual(registry.entries[parentA]?.state, .done)
        XCTAssertTrue(registry.subagentRegistry.children(of: parentA).isEmpty,
                      "A parent row settled to .done by a pane-exit signal must have its children cleared")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1,
                       "A different parent's children must be untouched")
    }

    // MARK: - A parent row removed entirely clears its children

    func test_parentRowRemovedEntirely_clearsItsChildren() {
        let registry = AgentRegistry()
        let parent = UUID()

        // A .titleHeuristic row -- the only row source AgentStateResolver
        // ever fully removes, via resolveScreen's miss-streak retirement.
        registry.handleScreenClassification(surfaceID: parent, state: .working)
        XCTAssertEqual(registry.entries[parent]?.source, .titleHeuristic)

        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), surfaceID: parent)
        XCTAssertEqual(registry.subagentRegistry.children(of: parent).count, 1)

        // Five consecutive nil screen classifications retire the row.
        for _ in 0..<5 {
            registry.handleScreenClassification(surfaceID: parent, state: nil)
        }

        XCTAssertNil(registry.entries[parent], "Sanity: the row was actually removed")
        XCTAssertTrue(registry.subagentRegistry.children(of: parent).isEmpty,
                      "A parent row removed entirely must have its children cleared")
    }

    // MARK: - The staleness sweep's .working -> .idle downgrade does not clear children

    func test_staleSweepWorkingToIdleDowngrade_doesNotClearChildren() {
        let registry = AgentRegistry()
        let parent = UUID()
        let base = Date()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil),
            surfaceID: parent, now: base
        )
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), surfaceID: parent, now: base)
        XCTAssertEqual(registry.entries[parent]?.state, .working)
        XCTAssertEqual(registry.subagentRegistry.children(of: parent).count, 1)

        registry.sweepStaleEntries(now: base.addingTimeInterval(16 * 60))

        XCTAssertEqual(registry.entries[parent]?.state, .idle,
                       "Sanity: the staleness sweep actually downgraded the row")
        XCTAssertEqual(registry.subagentRegistry.children(of: parent).count, 1,
                       "A .working -> .idle staleness downgrade must not clear children -- .idle is still a " +
                       "live row")
    }

    // MARK: - startedAt is stamped once and never restamped

    /// A child's startedAt is set once when it is created and must never
    /// be restamped by any later event for that child, unlike state /
    /// lastToolName / agentType which do keep updating.
    func test_startedAt_isStampedOnceAtCreation_neverRestampedByLaterEvents() {
        let registry = SubagentRegistry()
        let parent = UUID()
        let creationTime = Date(timeIntervalSince1970: 1_000)
        let laterTime = Date(timeIntervalSince1970: 2_000)
        let evenLaterTime = Date(timeIntervalSince1970: 3_000)

        registry.handleHookEvent(
            event("SubagentStart", agentID: "sub-1", agentType: "explore"), parentSurfaceID: parent, now: creationTime
        )
        let created = registry.children(of: parent).first
        XCTAssertEqual(created?.startedAt, creationTime, "startedAt must be set to the creation event's own time")

        registry.handleHookEvent(
            event("PreToolUse", agentID: "sub-1", toolName: "Bash"), parentSurfaceID: parent, now: laterTime
        )
        let afterPreToolUse = registry.children(of: parent).first
        XCTAssertEqual(afterPreToolUse?.startedAt, creationTime,
                       "A later PreToolUse must not restamp startedAt")
        XCTAssertEqual(afterPreToolUse?.lastToolName, "Bash", "Sanity: lastToolName does still update")

        registry.handleHookEvent(
            event("PostToolUse", agentID: "sub-1", agentType: "reviewer", toolName: "Read"),
            parentSurfaceID: parent, now: evenLaterTime
        )
        let afterPostToolUse = registry.children(of: parent).first
        XCTAssertEqual(afterPostToolUse?.startedAt, creationTime,
                       "A later PostToolUse must not restamp startedAt either")
        XCTAssertEqual(afterPostToolUse?.agentType, "reviewer", "Sanity: agentType does still update")

        registry.handleHookEvent(
            event("PermissionRequest", agentID: "sub-1"), parentSurfaceID: parent, now: evenLaterTime
        )
        let afterStateChange = registry.children(of: parent).first
        XCTAssertEqual(afterStateChange?.startedAt, creationTime,
                       "A state-changing event must not restamp startedAt")
        XCTAssertEqual(afterStateChange?.state, .blocked, "Sanity: state does still update")
    }

    // MARK: - Moving between live states never clears children

    func test_parentRowMovingBetweenLiveStates_neverClearsChildren() {
        let registry = AgentRegistry()
        let parent = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil),
            surfaceID: parent
        )
        registry.handleHookEvent(event("SubagentStart", agentID: "sub-1"), surfaceID: parent)
        XCTAssertEqual(registry.entries[parent]?.state, .working)
        XCTAssertEqual(registry.subagentRegistry.children(of: parent).count, 1)

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PermissionRequest", sessionID: "session-a", cwd: nil, message: nil),
            surfaceID: parent
        )
        XCTAssertEqual(registry.entries[parent]?.state, .blocked)
        XCTAssertEqual(registry.subagentRegistry.children(of: parent).count, 1,
                       "Moving to .blocked must not clear children")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PostToolUse", sessionID: "session-a", cwd: nil, message: nil),
            surfaceID: parent
        )
        XCTAssertEqual(registry.entries[parent]?.state, .working)
        XCTAssertEqual(registry.subagentRegistry.children(of: parent).count, 1,
                       "Moving back to .working must not clear children")
    }
}
