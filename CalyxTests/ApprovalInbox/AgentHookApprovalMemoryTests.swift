//
//  AgentHookApprovalMemoryTests.swift
//  CalyxTests
//
//  Covers AgentHookApprovalMemory, the per-session "Always Allow" memory
//  that lets a human's Always-Allow click on an agent-hook approval
//  request (see ApprovalRequest.Source.agentHook) skip the inbox
//  entirely on a later matching request, without touching the blanket
//  CockpitSettings.autoApproveEnabled toggle.
//
//  One scope: PANE (rememberPane) -- auto-allows only the exact
//  (surfaceID, kind, toolName) tuple that was recorded, i.e. "always
//  allow THIS tool in THIS pane".
//
//  Mirrors ApprovalInboxStore's singleton convention (`static let
//  shared`, plain `init()` so a test can construct an isolated instance)
//  and its own file header's warning: init() must never construct
//  another singleton in a stored property.
//
//  Coverage:
//  - empty memory: isAutoAllowed is false for anything
//  - rememberPane: allowed only for that EXACT (surfaceID, kind,
//    toolName) tuple -- a different surface, kind, or tool each
//    independently miss
//  - clearPaneEntries(surfaceID:) removes only that surface's pane
//    entries, leaving other panes' entries untouched
//  - clearAll() clears pane memory entirely
//

import XCTest
@testable import Calyx

@MainActor
final class AgentHookApprovalMemoryTests: XCTestCase {

    private let kind = AgentEntry.claudeCodeKind
    private let toolName = "Bash"

    // MARK: - Empty memory

    func test_isAutoAllowed_emptyMemory_returnsFalse() {
        let memory = AgentHookApprovalMemory()

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: toolName),
                       "a memory that has never recorded anything must never auto-allow")
    }

    // MARK: - rememberPane

    func test_rememberPane_allowsOnlyExactSurfaceKindToolTuple() {
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: kind, toolName: toolName)

        XCTAssertTrue(memory.isAutoAllowed(surfaceID: surfaceID, kind: kind, toolName: toolName),
                     "the exact remembered (surfaceID, kind, toolName) tuple must be auto-allowed")

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: toolName),
                       "a DIFFERENT surfaceID must not be auto-allowed by a pane-scoped memory")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.codexKind, toolName: toolName),
                       "a DIFFERENT kind on the SAME surface/tool must not be auto-allowed")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: kind, toolName: "Write"),
                       "a DIFFERENT toolName on the SAME surface/kind must not be auto-allowed")
    }

    // MARK: - clearPaneEntries

    func test_clearPaneEntries_removesOnlyThatSurfacesPaneEntries_keepsOtherPanes() {
        let memory = AgentHookApprovalMemory()
        let clearedSurfaceID = UUID()
        let otherSurfaceID = UUID()

        memory.rememberPane(surfaceID: clearedSurfaceID, kind: kind, toolName: toolName)
        memory.rememberPane(surfaceID: otherSurfaceID, kind: kind, toolName: toolName)

        memory.clearPaneEntries(surfaceID: clearedSurfaceID)

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: clearedSurfaceID, kind: kind, toolName: toolName),
                       "clearPaneEntries(surfaceID:) must remove the cleared surface's own pane entry")
        XCTAssertTrue(memory.isAutoAllowed(surfaceID: otherSurfaceID, kind: kind, toolName: toolName),
                     "clearPaneEntries(surfaceID:) must leave a DIFFERENT surface's pane entry untouched")
    }

    // MARK: - clearAll

    func test_clearAll_clearsPaneMemory() {
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: kind, toolName: toolName)

        memory.clearAll()

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: kind, toolName: toolName),
                       "clearAll() must clear pane-scoped memory")
    }
}
