//
//  HerdrNativeTabAttacherLiveTests.swift
//  CalyxTests
//
//  Covers HerdrNativeTabAttacherLive (app-layer
//  wiring): the production HerdrNativeTabAttacher conformer that
//  HerdrTabCoordinator drives. Every side-effectful dependency
//  (tabsProvider, attachHook, focusHook, ratioMutationHook,
//  closeLeafHook, sessionKillHook) is an injected closure, mirroring
//  AppDelegateOpenHerdrAttachTabTests' established hook-seam pattern
//  (_openHerdrAttachTabSurfaceCreationHookForTesting et al.) -- this file
//  never touches a real window, a real ghostty surface, or
//  windowControllers.
//
//  Coverage:
//  - attachTab(plan:): builds a Tab whose sessionRefs is EMPTY (herdr
//    session identity must never enter it, the same permanent invariant
//    AppDelegateOpenHerdrAttachTabTests pins for attach path),
//    never registers it in SessionSurfaceMap, sets herdrPaneRefs to
//    EXACTLY plan.paneRefs, builds splitTree.root/focusedLeafID from the
//    plan, then invokes attachHook with that Tab and returns attachHook's
//    own result verbatim (both true and false).
//  - focusExistingTab(withWorkspaceID:socketPath:): scans tabsProvider()
//    for a tab whose herdrPaneRefs contain a ref matching BOTH
//    socketPath AND a paneID prefixed "<workspaceID>:"; invokes
//    focusHook with that tab's id and returns true on a match, else
//    returns false and never invokes focusHook. Two discriminating
//    fixtures: a paneID matching the required prefix but on the WRONG
//    socketPath (must not match), and a colon-boundary trap ("w1" must
//    not match a tab whose only ref is "w11:p1" -- only "w1:p1" does).
//  - updateRatio(leafA:leafB:direction:ratio:): calls ratioMutationHook
//    with the four values verbatim, positionally unswapped, for both
//    SplitDirection cases, and with an unclamped ratio (0.05) to prove
//    this method itself performs no clamping (SplitTree.setRatio's own
//    SplitData.clampRatio is the injected hook's business, not this
//    method's).
//  - closeLeaf(_:): invokes closeLeafHook with the surface id, and NEVER
//    invokes sessionKillHook -- herdr panes carry no calyx-session
//    identity (Tab.sessionRefs stays empty, see attachTab above), so
//    there is never a session to kill; sessionKillHook exists on this
//    type purely so that invariant is provable, mirroring
//    architecture.md's own "SessionCloseKillPolicy must never see herdr
//    identity" invariant.
//

import XCTest
import Foundation
@testable import Calyx

@MainActor
final class HerdrNativeTabAttacherLiveTests: XCTestCase {

    // MARK: - Construction helper

    private func makeAttacher(
        tabsProvider: @escaping () -> [Tab] = { [] },
        attachHook: @escaping (Tab) -> Bool = { _ in true },
        focusHook: @escaping (UUID) -> Void = { _ in },
        ratioMutationHook: @escaping (UUID, UUID, SplitDirection, Double) -> Void = { _, _, _, _ in },
        closeLeafHook: @escaping (UUID) -> Void = { _ in },
        sessionKillHook: @escaping (UUID) -> Void = { _ in }
    ) -> HerdrNativeTabAttacherLive {
        HerdrNativeTabAttacherLive(
            tabsProvider: tabsProvider,
            attachHook: attachHook,
            focusHook: focusHook,
            ratioMutationHook: ratioMutationHook,
            closeLeafHook: closeLeafHook,
            sessionKillHook: sessionKillHook
        )
    }

    private func makeSplitPlan(leafA: UUID, leafB: UUID, socketPath: String, workspaceID: String) -> HerdrNativeTabPlan {
        HerdrNativeTabPlan(
            root: .split(SplitData(
                direction: .horizontal, ratio: 0.5,
                first: .leaf(id: leafA), second: .leaf(id: leafB)
            )),
            focusedLeafID: leafB,
            paneRefs: [
                leafA: HerdrPaneRef(socketPath: socketPath, paneID: "\(workspaceID):p1"),
                leafB: HerdrPaneRef(socketPath: socketPath, paneID: "\(workspaceID):p2"),
            ],
            title: workspaceID
        )
    }

    // MARK: - attachTab: sessionRefs must be empty

    func test_attachTab_buildsTabWithEmptySessionRefs() throws {
        let leafA = UUID()
        let leafB = UUID()
        var observedTab: Tab?
        let attacher = makeAttacher(attachHook: { tab in observedTab = tab; return true })

        _ = attacher.attachTab(plan: makeSplitPlan(leafA: leafA, leafB: leafB, socketPath: socketPath, workspaceID: "wF"))

        let tab = try XCTUnwrap(observedTab, "attachTab must build and invoke attachHook with a Tab")
        XCTAssertTrue(
            tab.sessionRefs.isEmpty,
            "herdr session identity must never enter Tab.sessionRefs -- the same permanent invariant " +
            "openHerdrAttachTab pins"
        )
    }

    // MARK: - attachTab: SessionSurfaceMap must never gain an entry

    func test_attachTab_neverRegistersEitherLeafInSessionSurfaceMap() {
        let leafA = UUID()
        let leafB = UUID()
        let attacher = makeAttacher(attachHook: { _ in true })

        _ = attacher.attachTab(plan: makeSplitPlan(leafA: leafA, leafB: leafB, socketPath: socketPath, workspaceID: "wF"))

        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: leafA), "attachTab must never register a herdr leaf in SessionSurfaceMap")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: leafB), "attachTab must never register a herdr leaf in SessionSurfaceMap")
    }

    // MARK: - attachTab: herdrPaneRefs must equal plan.paneRefs exactly

    func test_attachTab_setsHerdrPaneRefsToExactlyThePlansPaneRefs() throws {
        let leafA = UUID()
        let leafB = UUID()
        var observedTab: Tab?
        let attacher = makeAttacher(attachHook: { tab in observedTab = tab; return true })
        let plan = makeSplitPlan(leafA: leafA, leafB: leafB, socketPath: socketPath, workspaceID: "wF")

        _ = attacher.attachTab(plan: plan)

        let tab = try XCTUnwrap(observedTab)
        XCTAssertEqual(tab.herdrPaneRefs, plan.paneRefs, "the built Tab's herdrPaneRefs must equal plan.paneRefs exactly")
    }

    // MARK: - attachTab: splitTree root/focusedLeafID must match the plan

    func test_attachTab_buildsSplitTreeMatchingThePlansRootAndFocusedLeaf() throws {
        let leafA = UUID()
        let leafB = UUID()
        var observedTab: Tab?
        let attacher = makeAttacher(attachHook: { tab in observedTab = tab; return true })
        // focusedLeafID is deliberately leafB (the split's SECOND leaf), catching an
        // implementation that defaults focus to the tree's first leaf.
        let plan = makeSplitPlan(leafA: leafA, leafB: leafB, socketPath: socketPath, workspaceID: "wF")

        _ = attacher.attachTab(plan: plan)

        let tab = try XCTUnwrap(observedTab)
        XCTAssertEqual(tab.splitTree.root, plan.root, "the built Tab's splitTree.root must equal plan.root exactly")
        XCTAssertEqual(
            tab.splitTree.focusedLeafID, leafB,
            "the built Tab's focusedLeafID must equal plan.focusedLeafID (leafB), not default to the tree's first leaf"
        )
    }

    // MARK: - attachTab: invokes attachHook exactly once, returns its result verbatim (true)

    func test_attachTab_invokesAttachHookExactlyOnce_returnsTrueWhenHookReturnsTrue() {
        let leafA = UUID()
        let leafB = UUID()
        var callCount = 0
        let attacher = makeAttacher(attachHook: { _ in callCount += 1; return true })

        let result = attacher.attachTab(plan: makeSplitPlan(leafA: leafA, leafB: leafB, socketPath: socketPath, workspaceID: "wF"))

        XCTAssertEqual(callCount, 1, "attachTab must invoke attachHook exactly once")
        XCTAssertTrue(result, "attachTab must return attachHook's own result verbatim")
    }

    // MARK: - attachTab: returns false when the hook returns false (discriminates a hardcoded `true`)

    func test_attachTab_invokesAttachHookExactlyOnce_returnsFalseWhenHookReturnsFalse() {
        let leafA = UUID()
        let leafB = UUID()
        var callCount = 0
        let attacher = makeAttacher(attachHook: { _ in callCount += 1; return false })

        let result = attacher.attachTab(plan: makeSplitPlan(leafA: leafA, leafB: leafB, socketPath: socketPath, workspaceID: "wF"))

        XCTAssertEqual(callCount, 1, "attachTab must invoke attachHook exactly once")
        XCTAssertFalse(result, "attachTab must return attachHook's own result verbatim, even when it is false")
    }

    // MARK: - focusExistingTab: match found

    func test_focusExistingTab_matchFound_invokesFocusHookWithTabID_returnsTrue() {
        let matchingTab = Tab(title: "workspace wF")
        matchingTab.herdrPaneRefs = [UUID(): HerdrPaneRef(socketPath: socketPath, paneID: "wF:p1")]
        var focusedTabID: UUID?
        let attacher = makeAttacher(tabsProvider: { [matchingTab] }, focusHook: { focusedTabID = $0 })

        let result = attacher.focusExistingTab(withWorkspaceID: "wF", socketPath: socketPath)

        XCTAssertTrue(result)
        XCTAssertEqual(focusedTabID, matchingTab.id, "focusHook must be invoked with the matching tab's own id")
    }

    // MARK: - focusExistingTab: no match at all

    func test_focusExistingTab_noMatch_returnsFalse_neverInvokesFocusHook() {
        let unrelatedTab = Tab(title: "unrelated")
        unrelatedTab.herdrPaneRefs = [UUID(): HerdrPaneRef(socketPath: socketPath, paneID: "wG:p1")]
        var focusHookCallCount = 0
        let attacher = makeAttacher(tabsProvider: { [unrelatedTab] }, focusHook: { _ in focusHookCallCount += 1 })

        let result = attacher.focusExistingTab(withWorkspaceID: "wF", socketPath: socketPath)

        XCTAssertFalse(result)
        XCTAssertEqual(focusHookCallCount, 0, "focusHook must never be invoked when no tab matches")
    }

    // MARK: - focusExistingTab: socketPath must be checked, not just the paneID prefix

    func test_focusExistingTab_paneIDPrefixMatchesButSocketPathDiffers_isNotAMatch() {
        let wrongSocketTab = Tab(title: "wrong socket")
        wrongSocketTab.herdrPaneRefs = [UUID(): HerdrPaneRef(socketPath: "/tmp/herdr-attacher-test/other.sock", paneID: "wF:p1")]
        var focusHookCallCount = 0
        let attacher = makeAttacher(tabsProvider: { [wrongSocketTab] }, focusHook: { _ in focusHookCallCount += 1 })

        let result = attacher.focusExistingTab(withWorkspaceID: "wF", socketPath: socketPath)

        XCTAssertFalse(result, "a paneID prefix match on the WRONG socketPath must not count as a match")
        XCTAssertEqual(focusHookCallCount, 0)
    }

    // MARK: - focusExistingTab: colon-boundary trap ("w1" must not match "w11:p1"), and scans past a non-matching tab

    func test_focusExistingTab_workspaceIDPrefixRequiresColonBoundary_scansPastNonMatchingTab() {
        let decoyTab = Tab(title: "decoy")
        decoyTab.herdrPaneRefs = [UUID(): HerdrPaneRef(socketPath: socketPath, paneID: "w11:p1")]
        let realTab = Tab(title: "real")
        realTab.herdrPaneRefs = [UUID(): HerdrPaneRef(socketPath: socketPath, paneID: "w1:p1")]
        var focusedTabID: UUID?
        let attacher = makeAttacher(tabsProvider: { [decoyTab, realTab] }, focusHook: { focusedTabID = $0 })

        let result = attacher.focusExistingTab(withWorkspaceID: "w1", socketPath: socketPath)

        XCTAssertTrue(
            result,
            "workspaceID \"w1\" must match paneID \"w1:p1\" (the colon-scoped real tab), scanning past the " +
            "decoy tab's \"w11:p1\" (a bare-prefix false match)"
        )
        XCTAssertEqual(focusedTabID, realTab.id)
    }

    // MARK: - updateRatio: exact, positionally-unswapped pass-through

    func test_updateRatio_callsRatioMutationHookWithExactParameters_horizontal() throws {
        let leafA = UUID()
        let leafB = UUID()
        var captured: (UUID, UUID, SplitDirection, Double)?
        let attacher = makeAttacher(ratioMutationHook: { a, b, direction, ratio in captured = (a, b, direction, ratio) })

        attacher.updateRatio(leafA: leafA, leafB: leafB, direction: .horizontal, ratio: 0.42)

        let call = try XCTUnwrap(captured, "updateRatio must invoke ratioMutationHook")
        XCTAssertEqual(call.0, leafA, "the hook's first UUID must be leafA, not leafB")
        XCTAssertEqual(call.1, leafB, "the hook's second UUID must be leafB, not leafA")
        XCTAssertEqual(call.2, .horizontal)
        XCTAssertEqual(call.3, 0.42, accuracy: 0.0001)
    }

    // MARK: - updateRatio: direction is passed through, not hardcoded to .horizontal

    func test_updateRatio_verticalDirectionIsPassedThrough() {
        let leafA = UUID()
        let leafB = UUID()
        var capturedDirection: SplitDirection?
        let attacher = makeAttacher(ratioMutationHook: { _, _, direction, _ in capturedDirection = direction })

        attacher.updateRatio(leafA: leafA, leafB: leafB, direction: .vertical, ratio: 0.5)

        XCTAssertEqual(capturedDirection, .vertical, "direction must be passed through verbatim, not hardcoded to .horizontal")
    }

    // MARK: - updateRatio: ratio is passed through unclamped

    func test_updateRatio_ratioIsPassedThroughVerbatim_unclamped() {
        let leafA = UUID()
        let leafB = UUID()
        var capturedRatio: Double?
        let attacher = makeAttacher(ratioMutationHook: { _, _, _, ratio in capturedRatio = ratio })

        // 0.05 is outside SplitData's own [0.1, 0.9] clamp range -- this method itself
        // must not clamp; SplitTree.setRatio's own SplitData.clampRatio is the injected
        // hook's business.
        attacher.updateRatio(leafA: leafA, leafB: leafB, direction: .horizontal, ratio: 0.05)

        XCTAssertEqual(capturedRatio ?? -1, 0.05, accuracy: 0.0001, "ratio must reach the hook unclamped")
    }

    // MARK: - closeLeaf: invokes closeLeafHook with the surface id

    func test_closeLeaf_invokesCloseLeafHookWithTheSurfaceID() {
        let surfaceID = UUID()
        var capturedID: UUID?
        let attacher = makeAttacher(closeLeafHook: { capturedID = $0 })

        attacher.closeLeaf(surfaceID)

        XCTAssertEqual(capturedID, surfaceID)
    }

    // MARK: - closeLeaf: NEVER invokes sessionKillHook

    func test_closeLeaf_neverInvokesSessionKillHook() {
        let surfaceID = UUID()
        var sessionKillCalls: [UUID] = []
        let attacher = makeAttacher(closeLeafHook: { _ in }, sessionKillHook: { sessionKillCalls.append($0) })

        attacher.closeLeaf(surfaceID)

        XCTAssertEqual(
            sessionKillCalls, [],
            "closeLeaf must never invoke sessionKillHook -- a herdr pane carries no calyx-session identity, " +
            "there is nothing to kill"
        )
    }
}

private let socketPath = "/tmp/herdr-attacher-test/herdr.sock"
