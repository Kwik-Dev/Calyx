//
//  AgentSidebarRowsTests.swift
//  CalyxTests
//
//  Tests: AgentSidebarRows.build, the pure function that flattens a
//  parent/child agent tree into the flat row list AgentStatusView's
//  ForEach renders. Flat is required, not stylistic:
//  .accessibilityElement(children: .combine) makes one row exactly one
//  VoiceOver stop, so children must be siblings, never nested inside a
//  parent row. Mirrors AgentSidebarGateTests' shape: a plain
//  (non-@MainActor) XCTestCase directly calling a pure, already-computed
//  static function.
//
//  Coverage:
//  - A parent with no children yields exactly one .parent row with
//    childCount: 0
//  - A collapsed parent with children yields one .parent row with the
//    right childCount and no child rows
//  - An expanded parent yields its .parent row immediately followed by
//    its children, in children(of:) order
//  - Several parents keep entries' order, and each parent's children
//    stay attached to that parent
//  - Expansion recorded for a surfaceID with no entry is ignored
//  - Row.tickAnchor: a .parent row's anchor is its entry's lastEventAt,
//    a .child row's anchor is its child's startedAt, and build() keeps
//    each row's anchor attached to its own origin rather than the
//    other row's
//  - PeriodicTimelineSchedule(from:by:).entries(from:mode:) keeps the
//    phase of a fractional-second anchor: every entry lands on an exact
//    integer-second offset from that anchor, which is the property the
//    per-row TimelineView fix depends on
//

import SwiftUI
import XCTest
@testable import Calyx

final class AgentSidebarRowsTests: XCTestCase {

    // MARK: - Helpers

    private func entry(surfaceID: UUID, state: AgentState = .idle, lastEventAt: Date = Date()) -> AgentEntry {
        AgentEntry(
            surfaceID: surfaceID, sessionID: "session", source: .hooks, state: state,
            cwd: "/Users/dev/repo", kind: AgentEntry.claudeCodeKind, lastEventAt: lastEventAt
        )
    }

    private func child(parentSurfaceID: UUID, agentID: String, startedAt: Date = Date()) -> SubagentEntry {
        SubagentEntry(
            parentSurfaceID: parentSurfaceID, agentID: agentID, agentType: "explore",
            state: .working, lastToolName: nil, startedAt: startedAt
        )
    }

    // MARK: - No children

    func test_parentWithNoChildren_yieldsExactlyOneParentRowWithZeroChildCount() {
        let surfaceID = UUID()
        let rows = AgentSidebarRows.build(
            entries: [entry(surfaceID: surfaceID)], children: { _ in [] }, expanded: []
        )

        XCTAssertEqual(rows.count, 1)
        guard case .parent(let row, let childCount, let isExpanded) = rows[0] else {
            return XCTFail("expected a single .parent row")
        }
        XCTAssertEqual(row.surfaceID, surfaceID)
        XCTAssertEqual(childCount, 0)
        XCTAssertFalse(isExpanded)
    }

    // MARK: - Collapsed parent with children

    func test_collapsedParentWithChildren_yieldsOneParentRowWithChildCount_noChildRows() {
        let surfaceID = UUID()
        let kids = [child(parentSurfaceID: surfaceID, agentID: "sub-1"), child(parentSurfaceID: surfaceID, agentID: "sub-2")]

        let rows = AgentSidebarRows.build(
            entries: [entry(surfaceID: surfaceID)], children: { $0 == surfaceID ? kids : [] }, expanded: []
        )

        XCTAssertEqual(rows.count, 1, "A collapsed parent must not emit any .child rows")
        guard case .parent(_, let childCount, let isExpanded) = rows[0] else {
            return XCTFail("expected a single .parent row")
        }
        XCTAssertEqual(childCount, 2)
        XCTAssertFalse(isExpanded)
    }

    // MARK: - Expanded parent

    func test_expandedParent_yieldsParentRowImmediatelyFollowedByItsChildrenInOrder() {
        let surfaceID = UUID()
        let kids = [child(parentSurfaceID: surfaceID, agentID: "sub-1"), child(parentSurfaceID: surfaceID, agentID: "sub-2")]

        let rows = AgentSidebarRows.build(
            entries: [entry(surfaceID: surfaceID)],
            children: { $0 == surfaceID ? kids : [] },
            expanded: [surfaceID]
        )

        XCTAssertEqual(rows.count, 3)
        guard case .parent(_, let childCount, let isExpanded) = rows[0] else {
            return XCTFail("row 0 must be the .parent row")
        }
        XCTAssertEqual(childCount, 2)
        XCTAssertTrue(isExpanded)

        guard case .child(let first) = rows[1], case .child(let second) = rows[2] else {
            return XCTFail("rows 1 and 2 must be .child rows, in children(of:) order")
        }
        XCTAssertEqual(first.agentID, "sub-1")
        XCTAssertEqual(second.agentID, "sub-2")
    }

    // MARK: - Several parents: order preserved, children stay attached

    func test_severalParents_keepEntriesOrder_childrenStayAttachedToTheirOwnParent() {
        let parentA = UUID()
        let parentB = UUID()
        let parentC = UUID()
        let childOfA = child(parentSurfaceID: parentA, agentID: "a-1")
        let childOfC = child(parentSurfaceID: parentC, agentID: "c-1")

        let rows = AgentSidebarRows.build(
            entries: [entry(surfaceID: parentA), entry(surfaceID: parentB), entry(surfaceID: parentC)],
            children: { surfaceID in
                switch surfaceID {
                case parentA: return [childOfA]
                case parentC: return [childOfC]
                default: return []
                }
            },
            expanded: [parentA, parentB, parentC]
        )

        // parentA (parent + 1 child), parentB (parent, 0 children), parentC (parent + 1 child)
        XCTAssertEqual(rows.count, 5)

        guard case .parent(let a, _, _) = rows[0] else { return XCTFail("row 0 must be parentA") }
        XCTAssertEqual(a.surfaceID, parentA)
        guard case .child(let aChild) = rows[1] else { return XCTFail("row 1 must be parentA's own child") }
        XCTAssertEqual(aChild.agentID, "a-1")
        XCTAssertEqual(aChild.parentSurfaceID, parentA)

        guard case .parent(let b, let bChildCount, _) = rows[2] else { return XCTFail("row 2 must be parentB") }
        XCTAssertEqual(b.surfaceID, parentB)
        XCTAssertEqual(bChildCount, 0)

        guard case .parent(let c, _, _) = rows[3] else { return XCTFail("row 3 must be parentC") }
        XCTAssertEqual(c.surfaceID, parentC)
        guard case .child(let cChild) = rows[4] else { return XCTFail("row 4 must be parentC's own child") }
        XCTAssertEqual(cChild.agentID, "c-1")
        XCTAssertEqual(cChild.parentSurfaceID, parentC)
    }

    // MARK: - Expansion for a surfaceID with no entry is ignored

    func test_expansionForSurfaceIDWithNoEntry_isIgnored() {
        let surfaceID = UUID()
        let phantomSurfaceID = UUID()

        let rows = AgentSidebarRows.build(
            entries: [entry(surfaceID: surfaceID)],
            children: { _ in [] },
            expanded: [phantomSurfaceID]
        )

        XCTAssertEqual(rows.count, 1,
                       "An expansion entry for a surfaceID with no corresponding AgentEntry must be a no-op")
        guard case .parent(let row, _, let isExpanded) = rows[0] else {
            return XCTFail("expected a single .parent row")
        }
        XCTAssertEqual(row.surfaceID, surfaceID)
        XCTAssertFalse(isExpanded, "The real parent's own expansion is unaffected by an unrelated phantom entry")
    }

    // MARK: - Row.tickAnchor

    func test_parentRow_tickAnchorIsEntrysLastEventAt() {
        let surfaceID = UUID()
        let parentAnchor = Date(timeIntervalSinceReferenceDate: 700_000_000.111)

        let rows = AgentSidebarRows.build(
            entries: [entry(surfaceID: surfaceID, lastEventAt: parentAnchor)], children: { _ in [] }, expanded: []
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tickAnchor, parentAnchor)
    }

    func test_childRow_tickAnchorIsChildsStartedAt() {
        let surfaceID = UUID()
        let childAnchor = Date(timeIntervalSinceReferenceDate: 700_000_100.222)
        let kids = [child(parentSurfaceID: surfaceID, agentID: "sub-1", startedAt: childAnchor)]

        let rows = AgentSidebarRows.build(
            entries: [entry(surfaceID: surfaceID)],
            children: { $0 == surfaceID ? kids : [] },
            expanded: [surfaceID]
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].tickAnchor, childAnchor)
    }

    func test_build_keepsEachRowsTickAnchorAttachedToItsOwnOrigin_notTheOtherRows() {
        let parentA = UUID()
        let parentB = UUID()
        let parentAAnchor = Date(timeIntervalSinceReferenceDate: 701_000_000.333)
        let parentBAnchor = Date(timeIntervalSinceReferenceDate: 702_000_000.444)
        let childOfAAnchor = Date(timeIntervalSinceReferenceDate: 701_000_050.555)
        let childOfBAnchor = Date(timeIntervalSinceReferenceDate: 702_000_050.666)
        let childOfA = child(parentSurfaceID: parentA, agentID: "a-1", startedAt: childOfAAnchor)
        let childOfB = child(parentSurfaceID: parentB, agentID: "b-1", startedAt: childOfBAnchor)

        let rows = AgentSidebarRows.build(
            entries: [
                entry(surfaceID: parentA, lastEventAt: parentAAnchor),
                entry(surfaceID: parentB, lastEventAt: parentBAnchor)
            ],
            children: { surfaceID in
                switch surfaceID {
                case parentA: return [childOfA]
                case parentB: return [childOfB]
                default: return []
                }
            },
            expanded: [parentA, parentB]
        )

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].tickAnchor, parentAAnchor, "parentA's row must anchor on its own lastEventAt")
        XCTAssertEqual(rows[1].tickAnchor, childOfAAnchor, "parentA's child must anchor on its own startedAt")
        XCTAssertEqual(rows[2].tickAnchor, parentBAnchor, "parentB's row must anchor on its own lastEventAt, not parentA's")
        XCTAssertEqual(rows[3].tickAnchor, childOfBAnchor, "parentB's child must anchor on its own startedAt, not childOfA's")
    }

    // MARK: - PeriodicTimelineSchedule phase-alignment (what the tickAnchor fix relies on)

    @MainActor
    func test_periodicTimelineSchedule_keepsPhaseOfAFractionalSecondAnchor() {
        // A deliberately messy anchor (current-time magnitude, non-zero
        // fractional second) rather than a round Date: the fix depends
        // on subtracting this exact anchor from a later tick landing on
        // a whole number of seconds, which a round anchor can't expose.
        let anchor = Date(timeIntervalSinceReferenceDate: 778_000_000.317)
        let schedule = PeriodicTimelineSchedule(from: anchor, by: 1)
        var iterator = schedule.entries(from: anchor.addingTimeInterval(0.3), mode: .normal).makeIterator()

        guard let first = iterator.next(), let second = iterator.next(), let third = iterator.next() else {
            return XCTFail("expected at least three schedule entries")
        }

        let firstOffset = first.timeIntervalSince(anchor)
        XCTAssertEqual(firstOffset, firstOffset.rounded(), accuracy: 0,
                        "every entry must land on a whole-number-of-seconds offset from the anchor")
        XCTAssertEqual(second.timeIntervalSince(anchor), firstOffset + 1)
        XCTAssertEqual(third.timeIntervalSince(anchor), firstOffset + 2)

        // Pinned against `third`, not `first`: at offset 0 a phase error
        // that lands epsilon below the integer boundary still truncates
        // to "0s" (elapsedLabel clamps a negative interval to zero), so
        // the assertion could pass even with the bug this test exists to
        // catch. At n + 2 the same phase error truncates to "n + 1", a
        // value this assertion actually rejects.
        let n = Int(firstOffset)
        XCTAssertEqual(AgentRowDisplay.elapsedLabel(since: anchor, now: third), "\(n + 2)s",
                       "elapsedLabel must read exactly the integer second the schedule landed on, not one less")
    }
}
