//
//  CalyxWindowControllerCloseTabTests.swift
//  CalyxTests
//
//  TDD RED phase, missing-observer investigation: `GhosttyActionRouter
//  .handleCloseTab` (GhosttyAction.swift) posts `.ghosttyCloseTab` for
//  every `GHOSTTY_ACTION_CLOSE_TAB` action, but no observer has ever been
//  registered for it — ghostty's default close_tab keybind (Cmd+Opt+W)
//  is silently inert. `CalyxWindowController.processCloseTab(tab:group:
//  mode:)` is the intended receiver once that observer exists; today it
//  is an intentional no-op stub (see its own doc comment in
//  CalyxWindowController.swift), so every test below fails because
//  `group.tabs` never changes.
//
//  `mode` (`ghostty_action_close_tab_mode_e`,
//  GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h) has three
//  cases: `GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS`,
//  `GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER`,
//  `GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT` — confirmed by reading the
//  header directly (NOT `GHOSTTY_CLOSE_TAB_THIS`/etc., an earlier guess).
//
//  Fixtures use plain, leaf-less `Tab(title:)` tabs (mirrors
//  `CalyxWindowControllerCloseArmsTests`'s established style): these
//  tests only exercise `group.tabs` membership/order, no live (or
//  `_testInsert`-only) surface is needed.
//
//  `processCloseTab` is called directly, not via a posted
//  `.ghosttyCloseTab` notification: its signature already carries the
//  resolved `tab`/`group`, decoupled from notification routing (that
//  routing, via `findTab(for:)`, is Green-phase work for the
//  not-yet-written `handleCloseTabNotification`).
//
//  Coverage-gap follow-up (code review): the mode tests above only ever
//  call `processCloseTab` directly, never exercising
//  `handleCloseTabNotification`'s own `findTab(for:)`-based routing / the
//  real `.ghosttyCloseTab` notification wiring. The "Notification post"
//  section below closes that gap the same way
//  `CalyxWindowControllerCloseWindowTests`/`ToggleFullscreenTests` do for
//  their own actions: a `SurfaceView`-owning fixture (`findTab(for:)`
//  needs a real registry entry, unlike the plain `Tab(title:)` fixture
//  above), an "own surface" positive test, and an "other window's
//  surface" regression guard. `processCloseTab`/`closeTab(id:)` have no
//  `#if DEBUG` test hook (unlike `processCloseWindow`/
//  `processToggleFullscreen`): closing one of 2+ tabs in a single group
//  never reaches the dangerous last-tab-in-last-window path
//  (`closeLastWindow()`/`NSApp.terminate`), so it's already safe to let
//  a second, legitimately-owning fixture controller react for real, no
//  hook needed — confirmed by tracing `closeTab(id:)` and cross-checked
//  against `SurfaceRegistry.destroySurface`'s own doc comment, which
//  explicitly documents `_testInsert`-only entries as safe to tear down.

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseTabTests: XCTestCase {

    // MARK: - Fixture

    private struct GroupFixture {
        let controller: CalyxWindowController
        let group: TabGroup
        let tabs: [Tab]
    }

    /// A single group holding `tabCount` plain tabs (titled "Tab 0", "Tab
    /// 1", ... in order), inside a single-group `WindowSession`.
    /// `restoring: true` skips `setupTerminalSurface` (no live ghostty
    /// app in the unit-test host — see `SurfaceLocator.swift`'s header
    /// comment on why that would hang the process).
    private func makeGroupFixture(tabCount: Int) -> GroupFixture {
        let tabs = (0..<tabCount).map { Tab(title: "Tab \($0)") }
        let group = TabGroup(name: "Default", tabs: tabs, activeTabID: tabs.first?.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return GroupFixture(controller: controller, group: group, tabs: tabs)
    }

    // MARK: - THIS

    /// `GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS` must close only the target
    /// tab. By hand: starting tabs are [tab0, tab1]; closing tab0 with
    /// THIS must leave exactly [tab1]. Against the current no-op stub,
    /// `group.tabs` never changes, so this fails.
    func test_processCloseTab_thisMode_closesOnlyTheTargetTab() {
        let fixture = makeGroupFixture(tabCount: 2)
        let target = fixture.tabs[0]
        let survivor = fixture.tabs[1]

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [survivor.id],
            "THIS must close only the target tab, leaving every other tab (here just one) untouched"
        )
    }

    // MARK: - OTHER

    /// `GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER` with 3 tabs must close the
    /// 2 non-target tabs, leaving only the target. By hand: starting
    /// tabs are [tab0, tab1, tab2], target = tab1 (the middle one);
    /// OTHER must leave exactly [tab1]. This is also the MINIMAL
    /// reproduction of the index-out-of-range crash risk documented on
    /// `processCloseTab` (2 sequential removals against a fixed-size-3
    /// index range) — see `test_processCloseTab_otherMode_withFiveTabs
    /// _doesNotCrash_andClosesAllExceptTarget` below for a second,
    /// larger-N instance of the same risk.
    func test_processCloseTab_otherMode_closesTheTwoNonTargetTabs() {
        let fixture = makeGroupFixture(tabCount: 3)
        let target = fixture.tabs[1]

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [target.id],
            "OTHER must close every tab except the target, leaving only the target behind"
        )
    }

    /// Regression/crash guard (r6-fix-spec.md-style "most important"
    /// callout in the investigation): OTHER with MORE than 3 tabs, target
    /// at index 0 (a different position than the "3 tabs, middle target"
    /// test above, so this is not a duplicate of it). By hand: starting
    /// tabs are [tab0..tab4] (5 tabs), target = tab0; OTHER must leave
    /// exactly [tab0]. An implementation that iterates a FIXED `0..<group
    /// .tabs.count` index range while calling `closeTab(id:)` (which
    /// mutates `group.tabs`) inside the loop crashes with an
    /// out-of-range index partway through; this test's assertion is what
    /// a correct implementation must satisfy once that bug is avoided.
    func test_processCloseTab_otherMode_withFiveTabs_doesNotCrash_andClosesAllExceptTarget() {
        let fixture = makeGroupFixture(tabCount: 5)
        let target = fixture.tabs[0]

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [target.id],
            "OTHER with more than 3 tabs must still close every non-target tab, without crashing, leaving " +
            "only the target behind"
        )
    }

    // MARK: - RIGHT

    /// `GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT` with a middle target must
    /// close only the tab(s) positioned AFTER it, leaving the target and
    /// everything to its left. By hand: starting tabs are [tab0, tab1,
    /// tab2], target = tab1; RIGHT must leave exactly [tab0, tab1] (tab2
    /// closes, tab0 survives).
    func test_processCloseTab_rightMode_closesOnlyTabsToTheRightOfTarget() {
        let fixture = makeGroupFixture(tabCount: 3)
        let left = fixture.tabs[0]
        let target = fixture.tabs[1]

        fixture.controller.processCloseTab(tab: target, group: fixture.group, mode: GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT)

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [left.id, target.id],
            "RIGHT must close every tab positioned after the target, leaving the target and every tab to its left"
        )
    }

    // MARK: - Notification post ("Tactic A")

    private struct SurfaceOwningGroupFixture {
        let controller: CalyxWindowController
        let group: TabGroup
        let targetTab: Tab
        let targetSurfaceView: SurfaceView
        let otherTab: Tab
    }

    /// Two tabs in a single group: `targetTab` owns a `_testInsert`-only
    /// `SurfaceView` (so `findTab(for:)` can resolve it — the plain
    /// `Tab(title:)` fixture above never satisfies that), `otherTab` is an
    /// ordinary leaf-less tab, present only so THIS mode's close never
    /// hits the last-tab-in-last-group `closeLastWindow()` path.
    private func makeSurfaceOwningGroupFixture() -> SurfaceOwningGroupFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let targetTab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let otherTab = Tab(title: "Other")
        let group = TabGroup(name: "Default", tabs: [targetTab, otherTab], activeTabID: targetTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SurfaceOwningGroupFixture(
            controller: controller, group: group, targetTab: targetTab, targetSurfaceView: surfaceView, otherTab: otherTab
        )
    }

    /// Posting the real `.ghosttyCloseTab` notification for a surface THIS
    /// window owns must close that surface's owning tab — exercises
    /// `handleCloseTabNotification`'s `findTab(for:)` routing and
    /// `userInfo["mode"]` extraction end to end, not just `processCloseTab`
    /// called directly.
    func test_ghosttyCloseTab_postedForOwnSurface_closesTargetTab() {
        let fixture = makeSurfaceOwningGroupFixture()

        NotificationCenter.default.post(
            name: .ghosttyCloseTab,
            object: fixture.targetSurfaceView,
            userInfo: ["mode": GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS]
        )

        XCTAssertEqual(
            fixture.group.tabs.map(\.id),
            [fixture.otherTab.id],
            "Posting .ghosttyCloseTab (THIS) for a surface this window owns must close that surface's owning tab"
        )
    }

    /// Regression guard: posting `.ghosttyCloseTab` for a surface owned by
    /// a DIFFERENT window must never close any of THIS window's tabs.
    /// `otherFixture.controller` legitimately owns `otherFixture
    /// .targetSurfaceView` and correctly reacts for real (no `#if DEBUG`
    /// hook exists for `processCloseTab`, and none is needed — see this
    /// file's header for why that's safe), so this only asserts
    /// `ownFixture` itself is untouched.
    func test_ghosttyCloseTab_postedForOtherWindowsSurface_doesNotCloseAnyTabInThisWindow() {
        let ownFixture = makeSurfaceOwningGroupFixture()
        let otherFixture = makeSurfaceOwningGroupFixture()
        let expectedIDs = ownFixture.group.tabs.map(\.id)

        NotificationCenter.default.post(
            name: .ghosttyCloseTab,
            object: otherFixture.targetSurfaceView,
            userInfo: ["mode": GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS]
        )

        XCTAssertEqual(
            ownFixture.group.tabs.map(\.id),
            expectedIDs,
            "Posting .ghosttyCloseTab for a surface owned by a DIFFERENT window must not close any tab in THIS window"
        )
    }
}
