//
//  GroupControllerFixture.swift
//  CalyxTests
//
//  Shared `CalyxWindowController` fixtures for controller tests that
//  exercise only group membership, tab order and `activeTabID`, over
//  plain, leaf-less `Tab(title:)` tabs (no live ghostty surface),
//  mirroring `TwoPaneSessionFixture.swift`'s own shared-fixture shape.
//

import XCTest
import AppKit
@testable import Calyx

/// Builds the `CalyxWindowController` shared by every fixture below: a
/// throwaway `CalyxWindow` and `restoring: true` (no live ghostty
/// surface: skips `setupTerminalSurface`).
@MainActor
private func makeController(session: WindowSession) -> CalyxWindowController {
    let window = CalyxWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    return CalyxWindowController(window: window, windowSession: session, restoring: true)
}

/// A `CalyxWindowController` over plain, leaf-less `Tab(title:)` tabs.
/// For controller tests that exercise only group membership, tab order
/// and `activeTabID`.
@MainActor
struct GroupFixture {
    let controller: CalyxWindowController
    let session: WindowSession
    let group: TabGroup
    let tabs: [Tab]

    /// One group of `tabCount` tabs titled "Tab 0", "Tab 1", ...; the
    /// first tab is active and the group is the window's active group.
    static func make(tabCount: Int) -> GroupFixture {
        let tabs = (0..<tabCount).map { Tab(title: "Tab \($0)") }
        let group = TabGroup(name: "Default", tabs: tabs, activeTabID: tabs.first?.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let controller = makeController(session: session)
        return GroupFixture(controller: controller, session: session, group: group, tabs: tabs)
    }
}

/// Two groups in one window: A (tabs "A0", "A1"; active a0; the window's
/// active group) and B (tabs "B0", "B1", "B2"; active b0).
@MainActor
struct TwoGroupFixture {
    let controller: CalyxWindowController
    let session: WindowSession
    let groupA: TabGroup
    let tabsA: [Tab]
    let groupB: TabGroup
    let tabsB: [Tab]

    static func make() -> TwoGroupFixture {
        let tabsA = [Tab(title: "A0"), Tab(title: "A1")]
        let groupA = TabGroup(name: "A", tabs: tabsA, activeTabID: tabsA[0].id)
        let tabsB = [Tab(title: "B0"), Tab(title: "B1"), Tab(title: "B2")]
        let groupB = TabGroup(name: "B", tabs: tabsB, activeTabID: tabsB[0].id)
        let session = WindowSession(groups: [groupA, groupB], activeGroupID: groupA.id)
        let controller = makeController(session: session)
        return TwoGroupFixture(
            controller: controller, session: session, groupA: groupA, tabsA: tabsA, groupB: groupB, tabsB: tabsB
        )
    }
}

/// Three groups in one window: A (tabs "a0", "a1"; active a0; the
/// window's active group), B (tabs "b0", "b1", "b2"; active b0) and C
/// (tab "c0"; active c0).
@MainActor
struct ThreeGroupFixture {
    let controller: CalyxWindowController
    let session: WindowSession
    let groupA: TabGroup
    let tabsA: [Tab]
    let groupB: TabGroup
    let tabsB: [Tab]
    let groupC: TabGroup
    let tabsC: [Tab]

    static func make() -> ThreeGroupFixture {
        let tabsA = [Tab(title: "a0"), Tab(title: "a1")]
        let groupA = TabGroup(name: "A", tabs: tabsA, activeTabID: tabsA[0].id)
        let tabsB = [Tab(title: "b0"), Tab(title: "b1"), Tab(title: "b2")]
        let groupB = TabGroup(name: "B", tabs: tabsB, activeTabID: tabsB[0].id)
        let tabsC = [Tab(title: "c0")]
        let groupC = TabGroup(name: "C", tabs: tabsC, activeTabID: tabsC[0].id)
        let session = WindowSession(groups: [groupA, groupB, groupC], activeGroupID: groupA.id)
        let controller = makeController(session: session)
        return ThreeGroupFixture(
            controller: controller, session: session,
            groupA: groupA, tabsA: tabsA,
            groupB: groupB, tabsB: tabsB,
            groupC: groupC, tabsC: tabsC
        )
    }
}
