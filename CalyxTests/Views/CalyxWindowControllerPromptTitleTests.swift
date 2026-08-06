//
//  CalyxWindowControllerPromptTitleTests.swift
//  CalyxTests
//
//  TDD RED phase: GHOSTTY_ACTION_PROMPT_TITLE (GitHub issue #42,
//  prompt_tab_title/prompt_surface_title keybinds). `GhosttyAction.swift`
//  still buckets `GHOSTTY_ACTION_PROMPT_TITLE` under "Known but
//  unimplemented" (returns `false`, so the keybind stays silently inert).
//  `CalyxWindowController.renameHost(for:in:)` and `.processPromptTitle
//  (surfaceView:scope:)` are the intended receivers; today both are
//  intentional no-op stubs (see their own doc comments in
//  CalyxWindowController.swift), so every test below that expects a
//  `TabRenameHost` result or a `tab.renameRequest` mutation fails.
//
//  `ghostty_action_prompt_title_e` (ghostty.h) has two cases,
//  `GHOSTTY_PROMPT_TITLE_SURFACE` / `_TAB` (union member `prompt_title`).
//  v1 has no per-pane title UI (`SurfacePropertyStore.title(for:)` is
//  Cockpit's read-only `pane_list` projection, not an editor), so BOTH
//  degrade to the same tab-level inline rename -- `TitlePromptScope`
//  mirrors the C enum's two cases for that reason, not because Calyx
//  treats them differently yet.
//
//  Double-open hazard (the reason `renameHost`/`TabRenameRequest.host`
//  exist at all): `TabBarContentView`'s `TabItemButton` and
//  `SidebarContentView`'s `TabRowItemView` each carry their OWN, separate
//  `@State private var isEditing`, and `MainContentView` can render both
//  for the very same `Tab` at once (tab bar: always the active group's
//  tabs; sidebar: every group's tabs while shown and uncollapsed). A
//  naive "set a flag on Tab, have both views watch it" design would open
//  two `InlineTextField`s for one keybind; per `InlineTextField`'s own
//  `controlTextDidEndEditing`/`finish(commit:)`, the SECOND one to commit
//  overwrites the tab's `titleOverride` with whatever it still held,
//  silently clobbering the user's freshly typed title from the first.
//  `renameHost(for:in:)` picks exactly one host up front instead of
//  letting both views watch the same flag.
//
//  `processPromptTitle`/`renameHost` are called directly, not via a
//  posted notification: no `.ghosttyPromptTitle` Notification.Name/
//  addObserver exists yet (that routing is later-pass work), mirrors
//  `CalyxWindowControllerSetTabTitleTests`' own "processX called
//  directly, Notification post is a later Tactic A" split, and matches
//  `processPromptTitle`'s own "Not `private`" doc comment (bypasses
//  `belongsToThisWindow`, mirroring `CalyxWindowControllerChildExitedTasksTests`'
//  `processChildExited` precedent) so a `_testInsert`-only `SurfaceView`
//  never attached to a real window works.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerPromptTitleTests: XCTestCase {

    // MARK: - renameHost(for:in:) -- pure decision function

    /// `renameHost` reads only `windowSession.activeGroupID`/`showSidebar`
    /// (plus the passed-in `group`'s own `isCollapsed`) -- the `tab`/
    /// `group` pair under test need not belong to `windowSession.groups`
    /// at all. `windowSession` still carries one placeholder group/tab
    /// (mirrors `CalyxWindowControllerRendererHealthTests.makeController()`'s
    /// shape exactly) rather than an empty `groups: []`, so this fixture
    /// stays on the same well-exercised construction path as every other
    /// controller fixture in this file/suite.
    private func makeController(activeGroupID: UUID?, showSidebar: Bool) -> CalyxWindowController {
        let placeholderTab = Tab(title: "Placeholder")
        let placeholderGroup = TabGroup(name: "Placeholder", tabs: [placeholderTab], activeTabID: placeholderTab.id)
        let session = WindowSession(groups: [placeholderGroup], activeGroupID: activeGroupID, showSidebar: showSidebar)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    /// `group.id == windowSession.activeGroupID` must resolve to `.tabBar`
    /// even with the sidebar hidden -- the tab bar is the only host that
    /// could possibly be showing this tab in that configuration.
    func test_renameHost_forActiveGroup_withSidebarHidden_returnsTabBar() {
        let group = TabGroup()
        let tab = Tab()
        let controller = makeController(activeGroupID: group.id, showSidebar: false)

        XCTAssertEqual(controller.renameHost(for: tab, in: group), .tabBar)
    }

    /// The active-group branch must be checked BEFORE the sidebar branch:
    /// when `group` is BOTH the active group AND (hypothetically) shown
    /// uncollapsed in the sidebar at the same time, the tab bar must still
    /// win -- otherwise both hosts would open for the same tab (see this
    /// file's header comment on the double-open hazard). A `renameHost`
    /// that checked the sidebar condition first would return `.sidebar`
    /// here instead, so this specifically catches that ordering bug.
    func test_renameHost_forActiveGroup_evenWhenSidebarAlsoShowsIt_returnsTabBar() {
        let group = TabGroup(isCollapsed: false)
        let tab = Tab()
        let controller = makeController(activeGroupID: group.id, showSidebar: true)

        XCTAssertEqual(controller.renameHost(for: tab, in: group), .tabBar)
    }

    /// A non-active, uncollapsed group with the sidebar shown is rendered
    /// ONLY by the sidebar (the tab bar never shows a non-active group's
    /// tabs -- see `MainContentView`), so `renameHost` must resolve to
    /// `.sidebar`.
    func test_renameHost_forNonActiveUncollapsedGroup_withSidebarShown_returnsSidebar() {
        let group = TabGroup(isCollapsed: false)
        let tab = Tab()
        let controller = makeController(activeGroupID: UUID(), showSidebar: true)

        XCTAssertEqual(controller.renameHost(for: tab, in: group), .sidebar)
    }

    /// Regression guard: a non-active group with the sidebar hidden is
    /// rendered by NEITHER host, so `renameHost` must return `nil` rather
    /// than defaulting to some host that isn't actually showing the tab.
    func test_renameHost_forNonActiveGroup_withSidebarHidden_returnsNil() {
        let group = TabGroup(isCollapsed: false)
        let tab = Tab()
        let controller = makeController(activeGroupID: UUID(), showSidebar: false)

        XCTAssertNil(controller.renameHost(for: tab, in: group))
    }

    /// Regression guard: a non-active, COLLAPSED group is not rendered by
    /// the sidebar even while `showSidebar` is true (a collapsed group's
    /// own tabs are hidden), so `renameHost` must return `nil`.
    func test_renameHost_forNonActiveCollapsedGroup_withSidebarShown_returnsNil() {
        let group = TabGroup(isCollapsed: true)
        let tab = Tab()
        let controller = makeController(activeGroupID: UUID(), showSidebar: true)

        XCTAssertNil(controller.renameHost(for: tab, in: group))
    }

    // MARK: - processPromptTitle(surfaceView:scope:) -- integration

    /// Two independent tab groups in one window: `activeGroup` is
    /// `windowSession.activeGroupID` (so the tab bar always shows
    /// `activeTab`); `backgroundGroup` is a second, non-active group whose
    /// visibility in the sidebar is controlled by `showSidebar`/
    /// `backgroundGroupCollapsed`. Each tab gets its OWN `SurfaceRegistry`
    /// (mirrors `CalyxWindowControllerChildExitedTasksTests
    /// .makeOrdinaryPaneFixture()`): sharing one registry between two tabs
    /// would make `findTab(for:)` ambiguous.
    private struct TwoGroupFixture {
        let controller: CalyxWindowController
        let activeGroup: TabGroup
        let activeTab: Tab
        let activeTabSurfaceView: SurfaceView
        let backgroundGroup: TabGroup
        let backgroundTab: Tab
        let backgroundTabSurfaceView: SurfaceView
    }

    private func makeTwoGroupFixture(showSidebar: Bool, backgroundGroupCollapsed: Bool) -> TwoGroupFixture {
        let activeRegistry = SurfaceRegistry()
        let activeLeafID = UUID()
        let activeTabSurfaceView = SurfaceView(frame: .zero)
        activeRegistry._testInsert(view: activeTabSurfaceView, id: activeLeafID)
        let activeTab = Tab(title: "Active Tab", splitTree: SplitTree(leafID: activeLeafID), registry: activeRegistry)
        let activeGroup = TabGroup(name: "Active Group", tabs: [activeTab], activeTabID: activeTab.id)

        let backgroundRegistry = SurfaceRegistry()
        let backgroundLeafID = UUID()
        let backgroundTabSurfaceView = SurfaceView(frame: .zero)
        backgroundRegistry._testInsert(view: backgroundTabSurfaceView, id: backgroundLeafID)
        let backgroundTab = Tab(title: "Background Tab", splitTree: SplitTree(leafID: backgroundLeafID), registry: backgroundRegistry)
        let backgroundGroup = TabGroup(
            name: "Background Group",
            isCollapsed: backgroundGroupCollapsed,
            tabs: [backgroundTab],
            activeTabID: backgroundTab.id
        )

        let session = WindowSession(
            groups: [activeGroup, backgroundGroup],
            activeGroupID: activeGroup.id,
            showSidebar: showSidebar
        )
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return TwoGroupFixture(
            controller: controller,
            activeGroup: activeGroup,
            activeTab: activeTab,
            activeTabSurfaceView: activeTabSurfaceView,
            backgroundGroup: backgroundGroup,
            backgroundTab: backgroundTab,
            backgroundTabSurfaceView: backgroundTabSurfaceView
        )
    }

    /// A surface owned by the ACTIVE group's tab must resolve to `.tabBar`
    /// -- the tab bar always shows the active group's tabs, regardless of
    /// `scope`.
    func test_processPromptTitle_forActiveGroupTabSurface_scopeTab_setsTabBarRenameRequest() {
        let fixture = makeTwoGroupFixture(showSidebar: true, backgroundGroupCollapsed: false)

        fixture.controller.processPromptTitle(surfaceView: fixture.activeTabSurfaceView, scope: .tab)

        XCTAssertEqual(
            fixture.activeTab.renameRequest?.host,
            .tabBar,
            "A surface owned by the active group's tab must set a .tabBar renameRequest"
        )
    }

    /// v1 has no per-pane title editor, so `scope: .surface` must degrade
    /// to the exact same tab-level rename as `scope: .tab` -- NOT a no-op
    /// and NOT some other host. Named/asserted separately from the
    /// `scope: .tab` case above to pin down this degeneracy explicitly,
    /// rather than leaving it as an unstated assumption a future per-pane
    /// title feature could quietly break.
    func test_processPromptTitle_scopeSurface_forActiveGroupTab_degradesToSameTabBarRenameRequest_asScopeTab() {
        let fixture = makeTwoGroupFixture(showSidebar: true, backgroundGroupCollapsed: false)

        fixture.controller.processPromptTitle(surfaceView: fixture.activeTabSurfaceView, scope: .surface)

        XCTAssertEqual(
            fixture.activeTab.renameRequest?.host,
            .tabBar,
            "scope: .surface must degrade to the same tab-level .tabBar renameRequest as scope: .tab in v1"
        )
    }

    /// A surface owned by a NON-active group's tab, with the sidebar
    /// shown and that group uncollapsed, is rendered only by the sidebar
    /// -- must resolve to `.sidebar`.
    func test_processPromptTitle_forNonActiveUncollapsedGroupTabSurface_withSidebarShown_setsSidebarRenameRequest() {
        let fixture = makeTwoGroupFixture(showSidebar: true, backgroundGroupCollapsed: false)

        fixture.controller.processPromptTitle(surfaceView: fixture.backgroundTabSurfaceView, scope: .tab)

        XCTAssertEqual(
            fixture.backgroundTab.renameRequest?.host,
            .sidebar,
            "A surface owned by a non-active, uncollapsed group's tab, with the sidebar shown, must set a .sidebar renameRequest"
        )
    }

    /// Regression guard: with the sidebar hidden, a non-active group's tab
    /// is rendered by neither host, so `renameRequest` must stay `nil`.
    func test_processPromptTitle_forNonActiveGroupTabSurface_withSidebarHidden_leavesRenameRequestNil() {
        let fixture = makeTwoGroupFixture(showSidebar: false, backgroundGroupCollapsed: false)

        fixture.controller.processPromptTitle(surfaceView: fixture.backgroundTabSurfaceView, scope: .tab)

        XCTAssertNil(
            fixture.backgroundTab.renameRequest,
            "A non-active group's tab must not get a renameRequest while the sidebar is hidden"
        )
    }

    /// Regression guard: a COLLAPSED non-active group's tab is hidden from
    /// the sidebar too (even while `showSidebar` is true), so
    /// `renameRequest` must stay `nil`.
    func test_processPromptTitle_forNonActiveCollapsedGroupTabSurface_withSidebarShown_leavesRenameRequestNil() {
        let fixture = makeTwoGroupFixture(showSidebar: true, backgroundGroupCollapsed: true)

        fixture.controller.processPromptTitle(surfaceView: fixture.backgroundTabSurfaceView, scope: .tab)

        XCTAssertNil(
            fixture.backgroundTab.renameRequest,
            "A collapsed non-active group's tab must not get a renameRequest even while the sidebar is shown"
        )
    }

    /// `.onChange(of: tab.renameRequest)` (the eventual View-layer wiring)
    /// only re-fires when the observed value actually changes. Two
    /// keybind presses in a row must therefore produce two DIFFERENT
    /// `renameRequest.id`s -- an unchanged `id` on repeat would look
    /// identical to SwiftUI and never re-open the editor on the second
    /// press.
    func test_processPromptTitle_calledTwiceInARow_producesDistinctRenameRequestIDs() {
        let fixture = makeTwoGroupFixture(showSidebar: true, backgroundGroupCollapsed: false)

        fixture.controller.processPromptTitle(surfaceView: fixture.activeTabSurfaceView, scope: .tab)
        let firstID = fixture.activeTab.renameRequest?.id
        XCTAssertNotNil(firstID, "processPromptTitle must set a renameRequest as a precondition for this test")

        fixture.controller.processPromptTitle(surfaceView: fixture.activeTabSurfaceView, scope: .tab)
        let secondID = fixture.activeTab.renameRequest?.id
        XCTAssertNotNil(secondID, "processPromptTitle must set a renameRequest as a precondition for this test")

        XCTAssertNotEqual(
            firstID,
            secondID,
            "renameRequest.id must change on every call so SwiftUI's onChange re-fires even for a same-host repeat"
        )
    }

    /// Regression guard: a surface neither tab's registry recognizes must
    /// leave EVERY tab in the window untouched -- guards against a future
    /// implementation that, on a failed lookup, defaults to the active tab
    /// (or some other fallback) instead of doing nothing.
    func test_processPromptTitle_forSurfaceThisWindowDoesNotOwn_leavesEveryTabRenameRequestNil() {
        let fixture = makeTwoGroupFixture(showSidebar: true, backgroundGroupCollapsed: false)
        let orphanSurfaceView = SurfaceView(frame: .zero)

        fixture.controller.processPromptTitle(surfaceView: orphanSurfaceView, scope: .tab)

        XCTAssertNil(fixture.activeTab.renameRequest, "An unowned surface must not set the active tab's renameRequest")
        XCTAssertNil(fixture.backgroundTab.renameRequest, "An unowned surface must not set the background tab's renameRequest")
    }

    // MARK: - Notification post ("Tactic A")
    //
    // Every test above calls `renameHost`/`processPromptTitle` directly.
    // That is deliberate (see this file's own header comment), but it also
    // means none of them would catch the ACTUAL historical bug this whole
    // keybind-wiring pass exists to fix: `GhosttyActionRouter` posting a
    // notification nobody observes. `registerNotificationObservers()`
    // registering `handlePromptTitleNotification` for `.ghosttyPromptTitle`
    // is exactly as load-bearing as `processPromptTitle` having a real
    // body -- this section exercises that registration with a real
    // `NotificationCenter.default.post`, mirroring
    // `CalyxWindowControllerRendererHealthTests`/
    // `CalyxWindowControllerSetTabTitleTests`'s own identically-named
    // sections.

    /// Unlike `makeTwoGroupFixture` above, `findTab(for:)` needs a real
    /// `SurfaceRegistry` entry -- mirrors
    /// `CalyxWindowControllerRendererHealthTests.SurfaceOwningFixture` /
    /// `CalyxWindowControllerSetTabTitleTests.SurfaceOwningFixture`. A
    /// single tab that is its (only, therefore active) group's active tab
    /// suffices: this section proves the notification reaches
    /// `processPromptTitle` at all, not `renameHost`'s own host-selection
    /// logic (already covered above).
    private struct SurfaceOwningFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
        let tab: Tab
    }

    private func makeSurfaceOwningFixture() -> SurfaceOwningFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SurfaceOwningFixture(controller: controller, surfaceView: surfaceView, tab: tab)
    }

    /// Posting the real `.ghosttyPromptTitle` notification for a surface
    /// THIS window owns must set that surface's owning tab's
    /// `renameRequest` to `.tabBar` -- exercises
    /// `registerNotificationObservers()`'s `.ghosttyPromptTitle`
    /// registration and `handlePromptTitleNotification`'s
    /// `userInfo["scope"]` decoding end to end, not just
    /// `processPromptTitle` called directly (every test above this
    /// section does exactly that).
    func test_ghosttyPromptTitle_postedForOwnSurface_setsTabBarRenameRequest() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertNil(fixture.tab.renameRequest, "Precondition: fixture tab starts with no renameRequest")

        NotificationCenter.default.post(
            name: .ghosttyPromptTitle,
            object: fixture.surfaceView,
            userInfo: ["scope": TitlePromptScope.tab.rawValue]
        )

        XCTAssertEqual(
            fixture.tab.renameRequest?.host,
            .tabBar,
            "Posting .ghosttyPromptTitle for a surface this window owns must set that surface's owning tab's renameRequest to .tabBar"
        )
    }

    /// Regression guard: posting `.ghosttyPromptTitle` for a surface NO
    /// controller's `windowSession` owns (never `_testInsert`ed into any
    /// registry) must leave the fixture's tab `renameRequest` untouched.
    /// An orphan surface, not some OTHER window's owned surface, is the
    /// right shape here -- it structurally guarantees no other live
    /// controller (this suite's own, or one left over from another test)
    /// can react and make the assertion pass for the wrong reason; see
    /// `CalyxWindowControllerRendererHealthTests`'s identical choice.
    func test_ghosttyPromptTitle_postedForSurfaceNoWindowOwns_leavesRenameRequestNil() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if the observer were never
        // registered at all.
        let fixture = makeSurfaceOwningFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)

        NotificationCenter.default.post(
            name: .ghosttyPromptTitle,
            object: orphanSurfaceView,
            userInfo: ["scope": TitlePromptScope.tab.rawValue]
        )

        XCTAssertNil(
            fixture.tab.renameRequest,
            "Posting .ghosttyPromptTitle for a surface no window owns must not change any tab's renameRequest"
        )
    }

    // MARK: - Persistence isolation

    /// `renameRequest` is transient UI-routing state and must never reach
    /// `TabSnapshot`. Drives `Tab.renameRequest` directly (bypassing the
    /// still-stubbed `processPromptTitle`) so this exercises the REAL,
    /// already-implemented `Tab.snapshot()`, not the stub -- a genuine
    /// (not stub-dependent) regression guard against a future change that
    /// accidentally threads `renameRequest` through `TabSnapshot`.
    func test_renameRequest_isExcludedFromTabSnapshot_persistenceIsolation() {
        let tab = Tab(title: "Shell", pwd: "/tmp")
        let baselineSnapshot = tab.snapshot()

        tab.renameRequest = TabRenameRequest(id: UUID(), host: .tabBar)

        XCTAssertEqual(
            tab.snapshot(),
            baselineSnapshot,
            "Setting tab.renameRequest must not change tab.snapshot() -- it is transient UI state, never persisted"
        )
    }
}
