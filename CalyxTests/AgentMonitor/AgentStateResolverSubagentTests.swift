//
//  AgentStateResolverSubagentTests.swift
//  CalyxTests
//
//  Pins the child-event branch AgentStateResolver.resolveHookRow places
//  FIRST, ahead of every other clause including SessionStart:
//  AgentEvent.isSubagentEvent (agentID != nil) is the ONLY subagent
//  predicate, and a subagent event must never create, replace, or
//  promote a row -- no event name, SessionStart included, is an
//  exception -- and must never rewrite an existing row's
//  sessionID / cwd / kind.
//
//  Driven directly through AgentStateResolver.resolve(.hook(...)),
//  bypassing AgentRegistry, per the design note that row-state decisions
//  live exclusively in the resolver -- AgentRegistry owns only storage
//  and side effects.
//
//  Coverage:
//  - No current row -> no row created (.keep)
//  - A session-mismatched subagent event does not replace the row, even
//    for a forward-moving event name that would trigger a mismatch
//    replace for an ordinary (non-subagent) event
//  - sessionID / cwd / kind are never rewritten by a subagent event
//  - A subagent PreToolUse on an existing .hooks row updates only state
//    and lastEventAt
//  - A subagent event never promotes a .titleHeuristic or .mcpConnection
//    row to .hooks
//  - A subagent event leaves a .done row alone
//  - SubagentStart / SubagentStop map to no AgentState, so they leave
//    the parent row's state (and the whole row) unchanged
//  - A subagent PermissionRequest still blocks the parent row -- the
//    settled decision that a child's approval prompt blocks the parent
//  - The existing blockedSince PreToolUse race guard still applies to a
//    subagent PreToolUse
//  - A subagent-scoped SessionStart leaves a .working parent row
//    completely untouched, both with its own sessionID set and with it
//    stripped to nil (the Grok adapter's shape), and creates no row when
//    none exists
//  - The parent's own SessionStart still behaves exactly as before: a
//    fresh session replaces the row, and a same-session re-send
//    preserves state and revives a .done row
//

import XCTest
@testable import Calyx

final class AgentStateResolverSubagentTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        _ name: String,
        sessionID: String? = "parent-session",
        cwd: String? = "/Users/dev/project",
        message: String? = nil,
        agentID: String? = "sub-1",
        agentType: String? = "explore",
        toolName: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            hookEventName: name, sessionID: sessionID, cwd: cwd, message: message,
            agentID: agentID, agentType: agentType, toolName: toolName
        )
    }

    private func hooksEntry(
        surfaceID: UUID,
        sessionID: String? = "parent-session",
        cwd: String? = "/Users/dev/project",
        state: AgentState = .idle,
        kind: String = AgentEntry.claudeCodeKind,
        lastEventAt: Date = Date()
    ) -> AgentEntry {
        AgentEntry(
            surfaceID: surfaceID, sessionID: sessionID, source: .hooks, state: state,
            cwd: cwd, kind: kind, lastEventAt: lastEventAt
        )
    }

    private func resolve(
        _ event: AgentEvent,
        current: AgentEntry?,
        kind: String = AgentEntry.claudeCodeKind,
        evidence: AgentEvidence = AgentEvidence(),
        now: Date = Date()
    ) -> AgentResolution {
        AgentStateResolver.resolve(
            .hook(event, kind: kind),
            surfaceID: UUID(),
            current: current,
            evidence: evidence,
            context: ResolverContext(isServerRunning: true, calyxShellIntegrationSeen: false),
            now: now
        )
    }

    private func writtenEntry(_ resolution: AgentResolution) -> AgentEntry? {
        guard case .write(let entry) = resolution.row else { return nil }
        return entry
    }

    // MARK: - No current row

    func test_subagentEvent_noCurrentRow_createsNoRow() {
        let resolution = resolve(event("PreToolUse"), current: nil)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event with no existing row must never create one -- got \(resolution.row)")
        }
    }

    // MARK: - Session mismatch never replaces

    func test_subagentEvent_sessionMismatch_doesNotReplaceTheRow() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, sessionID: "real-parent-session", state: .idle)

        // UserPromptSubmit is forward-moving: for an ORDINARY event with a
        // mismatched session this would replace the row. A subagent event
        // whose sessionID has been stripped (e.g. Grok) or otherwise
        // differs must never reach that path at all.
        let resolution = resolve(
            event("UserPromptSubmit", sessionID: nil), current: existing
        )

        if case .write(let entry) = resolution.row {
            XCTAssertEqual(entry.sessionID, existing.sessionID,
                           "A subagent event must never replace the row with one carrying a different sessionID")
        }
        // .keep is also an acceptable outcome here; the load-bearing fact
        // is that no replacement with a different sessionID occurred.
    }

    // MARK: - sessionID / cwd / kind are never rewritten

    func test_subagentEvent_neverRewritesSessionIDCwdOrKind() {
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project",
            state: .idle, kind: AgentEntry.codexKind
        )

        let resolution = resolve(event("PreToolUse", sessionID: nil, cwd: nil), current: existing)

        let updated = writtenEntry(resolution)
        XCTAssertEqual(updated?.sessionID, existing.sessionID)
        XCTAssertEqual(updated?.cwd, existing.cwd)
        XCTAssertEqual(updated?.kind, existing.kind)
    }

    // MARK: - Updates only state and lastEventAt

    func test_subagentPreToolUse_existingHooksRow_updatesOnlyStateAndLastEventAt() throws {
        let surfaceID = UUID()
        let base = Date()
        let existing = hooksEntry(surfaceID: surfaceID, state: .idle, lastEventAt: base)
        let now = base.addingTimeInterval(5)

        let resolution = resolve(event("PreToolUse"), current: existing, now: now)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .working)
        XCTAssertEqual(updated.lastEventAt, now)
        XCTAssertEqual(updated.sessionID, existing.sessionID)
        XCTAssertEqual(updated.cwd, existing.cwd)
        XCTAssertEqual(updated.kind, existing.kind)
        XCTAssertEqual(updated.source, .hooks)
    }

    // MARK: - Never promotes a non-.hooks row

    func test_subagentEvent_doesNotPromoteTitleHeuristicRowToHooks() {
        let surfaceID = UUID()
        let existing = AgentEntry(
            surfaceID: surfaceID, sessionID: nil, source: .titleHeuristic, state: .idle,
            cwd: nil, kind: AgentEntry.claudeCodeKind, lastEventAt: Date()
        )

        let resolution = resolve(event("PreToolUse"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event must never promote a .titleHeuristic row -- got \(resolution.row)")
        }
    }

    func test_subagentEvent_doesNotPromoteMCPConnectionRowToHooks() {
        let surfaceID = UUID()
        let existing = AgentEntry(
            surfaceID: surfaceID, sessionID: nil, source: .mcpConnection, state: .idle,
            cwd: nil, kind: AgentEntry.codexKind, lastEventAt: Date()
        )

        let resolution = resolve(event("PreToolUse"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event must never promote a .mcpConnection row -- got \(resolution.row)")
        }
    }

    // MARK: - .done row left alone

    func test_subagentEvent_doneRow_isLeftAlone() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .done)

        let resolution = resolve(event("PreToolUse"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event must leave a .done row untouched -- got \(resolution.row)")
        }
    }

    // MARK: - SubagentStart / SubagentStop leave the parent row unchanged

    func test_subagentStart_leavesParentRowUnchanged() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .idle)

        let resolution = resolve(event("SubagentStart"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("SubagentStart maps to no AgentState, so the parent row must stay unchanged -- got \(resolution.row)")
        }
    }

    func test_subagentStop_leavesParentRowUnchanged() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("SubagentStop"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("SubagentStop maps to no AgentState, so the parent row must stay unchanged -- got \(resolution.row)")
        }
    }

    // MARK: - A child's PermissionRequest still blocks the parent

    func test_subagentPermissionRequest_stillBlocksTheParentRow() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("PermissionRequest"), current: existing)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .blocked,
                       "The settled decision: a child-sourced PermissionRequest still blocks the parent row")
    }

    // MARK: - blockedSince PreToolUse race guard still applies

    func test_subagentPreToolUse_withinRaceWindowOfBlocked_isDropped() {
        let surfaceID = UUID()
        let base = Date()
        let existing = hooksEntry(surfaceID: surfaceID, state: .blocked, lastEventAt: base)
        var evidence = AgentEvidence()
        evidence.blockedSince = base

        let resolution = resolve(
            event("PreToolUse"), current: existing, evidence: evidence, now: base.addingTimeInterval(0.5)
        )

        guard case .keep = resolution.row else {
            return XCTFail("A subagent PreToolUse within the 1.5s race window of blockedSince must be " +
                           "dropped like any other PreToolUse -- got \(resolution.row)")
        }
    }

    func test_subagentPreToolUse_outsideRaceWindowOfBlocked_clearsBlocked() throws {
        let surfaceID = UUID()
        let base = Date()
        let existing = hooksEntry(surfaceID: surfaceID, state: .blocked, lastEventAt: base)
        var evidence = AgentEvidence()
        evidence.blockedSince = base

        let resolution = resolve(
            event("PreToolUse"), current: existing, evidence: evidence, now: base.addingTimeInterval(2.0)
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .working,
                       "Outside the race window, a subagent PreToolUse clears blocked exactly like an " +
                       "ordinary one")
    }

    // MARK: - A child's own turn/session ending must never retire the parent row

    func test_subagentSessionEnd_leavesAWorkingParentRowWorking() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("SessionEnd"), current: existing)

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry.state, .working,
                           "A child's own SessionEnd must never report the parent's session as .done")
        case .remove:
            XCTFail("A subagent-scoped SessionEnd must never remove the parent row")
        }
    }

    func test_subagentSessionEnd_doesNotPoisonTheRowAgainstLaterParentEvents() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let childResolution = resolve(event("SessionEnd"), current: existing)
        let afterChildEvent: AgentEntry
        switch childResolution.row {
        case .keep:
            afterChildEvent = existing
        case .write(let entry):
            afterChildEvent = entry
        case .remove:
            return XCTFail("A subagent-scoped SessionEnd must never remove the parent row")
        }

        // A normal parent PreToolUse must still move the row -- proving it
        // was never poisoned into a sticky .done state, which would
        // otherwise swallow every later parent event via resolveHookRow's
        // same-session .done guard.
        let parentResolution = resolve(
            event("PreToolUse", agentID: nil, agentType: nil), current: afterChildEvent
        )
        let updated = try XCTUnwrap(writtenEntry(parentResolution))
        XCTAssertEqual(updated.state, .working,
                       "A normal parent PreToolUse must still move the row after a child's SessionEnd")
    }

    func test_subagentStop_leavesAWorkingParentRowWorking() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("Stop"), current: existing)

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry.state, .working,
                           "A child's own Stop must never report the parent's turn as .idle")
        case .remove:
            XCTFail("A subagent-scoped Stop must never remove the parent row")
        }
    }

    // MARK: - The parent's own SessionEnd / Stop still settle the row exactly as before

    func test_parentOwnSessionEnd_stillSettlesTheRowToDone() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("SessionEnd", agentID: nil, agentType: nil), current: existing)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .done, "The parent's own SessionEnd must still settle the row to .done")
    }

    func test_parentOwnStop_stillSettlesTheRowToIdle() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("Stop", agentID: nil, agentType: nil), current: existing)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .idle, "The parent's own Stop must still settle the row to .idle")
    }

    // MARK: - A subagent-scoped SessionStart must never replace the parent row

    func test_subagentScopedSessionStart_leavesAWorkingParentRowCompletelyUntouched() {
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project",
            state: .working, kind: AgentEntry.codexKind
        )

        let resolution = resolve(
            event("SessionStart", sessionID: "child-session", agentID: "sub-1"), current: existing
        )

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry, existing,
                           "A subagent-scoped SessionStart must never replace the parent row -- got a write " +
                           "with a different entry")
        case .remove:
            XCTFail("A subagent-scoped SessionStart must never remove the parent row")
        }
    }

    func test_subagentScopedSessionStart_withNilSessionID_leavesAWorkingParentRowCompletelyUntouched() {
        // The Grok adapter's shape: a subagent-scoped SessionStart whose
        // own sessionID has been stripped to nil -- the case that
        // previously reached resolveHookRow's SessionStart replacement
        // path because nil never matches the parent's own sessionID.
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project",
            state: .working
        )

        let resolution = resolve(
            event("SessionStart", sessionID: nil, agentID: "sub-1"), current: existing
        )

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry, existing,
                           "A subagent-scoped SessionStart with a nil sessionID must still never replace " +
                           "the parent row")
        case .remove:
            XCTFail("A subagent-scoped SessionStart must never remove the parent row")
        }
    }

    func test_subagentScopedSessionStart_noExistingRow_createsNoRow() {
        let resolution = resolve(
            event("SessionStart", sessionID: nil, agentID: "sub-1"), current: nil
        )

        guard case .keep = resolution.row else {
            return XCTFail("A subagent-scoped SessionStart with no existing row must never create one -- " +
                           "got \(resolution.row)")
        }
    }

    func test_parentOwnSessionStart_freshSession_stillReplacesTheRow() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "old-session", cwd: "/Users/dev/old", state: .done
        )

        let resolution = resolve(
            event("SessionStart", sessionID: "new-session", cwd: "/Users/dev/new", agentID: nil, agentType: nil),
            current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.sessionID, "new-session")
        XCTAssertEqual(updated.cwd, "/Users/dev/new")
        XCTAssertEqual(updated.state, .idle)
    }

    func test_parentOwnSessionStart_sameSession_preservesStateAndRevivesADoneRow() throws {
        let surfaceID = UUID()
        let existingWorking = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project", state: .working
        )

        let workingResolution = resolve(
            event("SessionStart", sessionID: "parent-session", agentID: nil, agentType: nil),
            current: existingWorking
        )
        let workingUpdated = try XCTUnwrap(writtenEntry(workingResolution))
        XCTAssertEqual(workingUpdated.state, .working,
                       "A re-sent SessionStart for the same session preserves the row's state")

        let existingDone = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project", state: .done
        )
        let doneResolution = resolve(
            event("SessionStart", sessionID: "parent-session", agentID: nil, agentType: nil),
            current: existingDone
        )
        let doneUpdated = try XCTUnwrap(writtenEntry(doneResolution))
        XCTAssertEqual(doneUpdated.state, .idle,
                       "A re-sent SessionStart for the same session revives a .done row to .idle")
    }
}
