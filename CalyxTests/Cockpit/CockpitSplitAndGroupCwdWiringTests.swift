//
//  CockpitSplitAndGroupCwdWiringTests.swift
//  CalyxTests
//
//  Regression coverage for issue #43's `sessionFallbackCwd:
//  livePaneCwd(of:in:)` wiring (Calyx/Views/MainWindow/
//  CalyxWindowController.swift's `createManagedSurface`) at the TWO
//  call sites `CockpitTabCreateCwdWiringTests.swift` does not cover:
//  `performSplit` (CalyxWindowController.swift:1468) and
//  `performCreateNewGroup` (:1859). Sibling file rather than an extension of
//  that one: its header/structure is built entirely around its own
//  five-case (a-e) `performCreateNewTab`-specific table, tightly
//  cross-referenced by letter; folding two more call sites into it
//  would force either an awkward re-lettering or a second, unrelated
//  table bolted on underneath the first. This file instead mirrors that
//  one's PATTERN (settings-suite isolation, `SurfacePropertyStore
//  .shared`/`SurfaceLocator.shared` teardown,
//  `_createManagedSurfaceHookForTesting`/
//  `_createManagedSurfacePwdObserverForTesting`) without inheriting its
//  table. See that file's own header for the shared root-cause story
//  this diff fixed; this file only adds coverage for the two additional
//  call sites its own header points here for.
//
//  CURRENT API (see `createManagedSurface`'s own doc comment in
//  CalyxWindowController.swift for the authoritative, fully-reasoned
//  version -- not duplicated here beyond the summary below, to avoid
//  the exact doc-rot `CockpitTabCreateCwdWiringTests.swift`'s own header
//  explicitly calls out and fixes for a verbatim-formula copy):
//  `explicitCwd` (an explicit directive, honored by both `.passthrough`/
//  `.persistent`) and `sessionFallbackCwd` (consulted by `.persistent`
//  only, since `.passthrough` has real FFI-level OSC-7 inheritance to
//  fall back on instead) combine ONCE into `sessionCwd = explicitCwd ??
//  sessionFallbackCwd ?? NSHomeDirectory()`.
//  `_createManagedSurfacePwdObserverForTesting` (this file's assertion
//  target, exactly like `CockpitTabCreateCwdWiringTests`'s) fires with
//  `explicitCwd` on `.passthrough`, `sessionCwd` on `.persistent`,
//  immediately before `_createManagedSurfaceHookForTesting`'s
//  short-circuit -- installed in the test below for the same
//  crash/hang reason documented in `CockpitTabCreateCwdWiringTests`'s/
//  `AppDelegateAttachWindowTests`' headers.
//
//  REACHING `.persistent` HERE -- CLOSED GAP: this file used to report
//  `.persistent` as unreachable, and each call site's `sessionFallbackCwd`
//  distinction as unobservable even in principle, for BOTH call sites
//  below. No longer true. What is STILL true, unchanged by the fix:
//  neither `performSplit` nor `performCreateNewGroup` has a `host:`
//  parameter at all -- grep confirms no call site anywhere in this
//  codebase passes one to either (`performSplit`'s only two production
//  call sites: CockpitAppAccess.swift:190,
//  CalyxWindowController.swift:2336; `performCreateNewGroup`'s only
//  caller: `createNewGroup()`'s own thin wrapper, :1811), and neither
//  has a remote-host entry point analogous to `performCreateNewTab`'s
//  own `AppDelegate.spawnRemoteSessionTab(host:)` to justify adding
//  one. So every `SessionSpawnContext` either method builds is still
//  unconditionally LOCAL (`context.host == nil`), and
//  `SessionSpawnPlanner.plan` still always evaluates its LOCAL-only
//  `guard let binaryPath = resolver.resolve() else { return
//  .passthrough }` for both -- UNCHANGED.
//
//  What changed is WHICH resolver that guard consults. Both methods now
//  take a `resolver: SessionBinaryResolverProtocol = SessionBinaryResolver()`
//  parameter (`performSplit`: CalyxWindowController.swift:1468;
//  `performCreateNewGroup`: :1859), forwarded verbatim into their own
//  `createManagedSurface(resolver:)` call, which forwards it again into
//  `SessionSpawnPlanner.plan(for:resolver:)` -- the exact same
//  already-established defaulted-protocol seam `SessionSpawnPlannerTests`/
//  `SessionSpawnPlannerRemoteHostTests`/`SessionBinaryResolverTests`
//  already drive with fakes (read those first; see `createManagedSurface`'s
//  own doc comment in CalyxWindowController.swift for the full
//  rationale of extending that seam up to this level, not restated
//  here). The always-DEFAULTED `SessionBinaryResolver()` still ALWAYS
//  resolves `nil` in the `CalyxTests` host (no `CALYX_SESSION_BIN`, no
//  bundled `Resources/bin/calyx-session`; see
//  `CockpitTabCreateCwdWiringTests`'s header for the full reasoning,
//  identical here) -- but a test overriding the new `resolver:`
//  parameter with a `FakeBinaryResolver` (reused below from
//  `SessionSpawnPlannerTests`'/`SessionBinaryResolverTests`' identical
//  private fake -- see those files first) that DOES resolve now
//  satisfies that LOCAL guard directly, with no `host:` involved at
//  all. This is a DIFFERENT seam than `CockpitTabCreateCwdWiringTests`'
//  tests d/e use to reach the same `.persistent` branch for
//  `performCreateNewTab`: those give `context.host` a non-nil value
//  instead, which skips the local-resolver guard entirely (see
//  `SessionSpawnPlanner.plan`'s own doc comment) -- not an option here,
//  since neither method below has a `host:` parameter to set. `host:`
//  was deliberately NOT added to either method purely for test
//  reachability -- rejected for the identical reason
//  `createManagedSurface`'s own doc comment gives for that same
//  rejected alternative: no production caller would ever supply one, so
//  it would be a permanently-defaulted, never-argued parameter, unlike
//  a resolver, which is the real dependency this decision already has,
//  merely un-injectable one level too high before this change.
//
//  CRITICAL, exactly like `CockpitTabCreateCwdWiringTests`'s identical
//  warning about its own host/settings combination: reaching
//  `.persistent` below needs BOTH `SessionSettings
//  .persistentSessionsEnabled = true` AND an injected resolver that
//  resolves -- either alone still silently falls back to
//  `.passthrough`. Unlike that file's own risk (an assertion that would
//  pass VACUOUSLY on the wrong branch), a misconfigured test here would
//  still FAIL, just for a less specific reason: `.passthrough`'s
//  observer call receives `explicitCwd`, unconditionally `nil` for both
//  call sites, which matches neither of the distinct seeded values the
//  two `.persistent` tests below set up. Even so, each one additionally
//  asserts a `sessionRefs` entry was actually recorded for the new
//  surface before trusting the observed pwd, so a real failure is
//  diagnosed as "never reached .persistent" rather than a confusing pwd
//  mismatch -- do not rely on the pwd assertion alone to catch a
//  missing `persistentSessionsEnabled = true` or a non-resolving
//  resolver.
//
//  Coverage:
//  - performSplit(explicitCwd: nil, sessionFallbackCwd:
//    livePaneCwd(of: surfaceID, in: tab)) -- CalyxWindowController
//    .swift:1484.
//    - `.passthrough` (persistentSessionsEnabled = false):
//      `test_passthroughBranch_split_explicitCwdStaysNil_preservesLibghosttyInheritance`.
//      `explicitCwd` must stay `nil` for an ordinary split, exactly
//      like an override-less new tab, preserving `.passthrough`'s live
//      OSC-7-based inheritance.
//    - `.persistent` (persistentSessionsEnabled = true, injected
//      resolving resolver -- CLOSED GAP, see above):
//      `test_persistentBranch_split_usesSourcePaneLiveCwd_notStaleTabPwd`.
//      Pins the same distinction `CockpitTabCreateCwdWiringTests` case
//      (e) pins for `performCreateNewTab`: the observed pwd must be the
//      SOURCE leaf being split (`surfaceID`, not just "the tab")'s own
//      live `SurfacePropertyStore` cwd, not the owning tab's stale
//      `pwd` field.
//  - performCreateNewGroup -- CalyxWindowController.swift:1811
//    (`createNewGroup()`'s thin wrapper), :1859 (the extracted body),
//    :1872 (its `explicitCwd`/`sessionFallbackCwd` call). Previously
//    untestable at all: `createNewGroup()` used to guard directly on
//    `GhosttyAppController.shared.app` (always `nil` in `CalyxTests`)
//    and return before ever reaching `createManagedSurface` -- this gap
//    closed once `createNewGroup()` gained this `performCreateNewGroup
//    (app: ghostty_app_t, resolver:)` sibling, mirroring
//    `performCreateNewTab`'s/`performSplit`'s own "un-privated,
//    app-taking extraction; `self.window` still resolved internally"
//    precedent.
//    - `.passthrough` (persistentSessionsEnabled = false):
//      `test_passthroughBranch_createNewGroup_explicitCwdStaysNil_preservesLibghosttyInheritance`.
//      `explicitCwd` must stay `nil` for a new group's first pane,
//      exactly like `performSplit`'s.
//    - `.persistent` (persistentSessionsEnabled = true, injected
//      resolving resolver -- CLOSED GAP, see above):
//      `test_persistentBranch_createNewGroup_usesFocusedPaneLiveCwd_notStaleTabPwd`.
//      Pins the identical distinction, sourced from the OLD active
//      tab's FOCUSED leaf (`activeTab?.splitTree.focusedLeafID`) rather
//      than a split's own source surface: the observed pwd must be that
//      leaf's own live `SurfacePropertyStore` cwd, not the OLD active
//      tab's stale `pwd` field.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

/// Reused verbatim from `SessionSpawnPlannerTests`'/
/// `SessionBinaryResolverTests`' identical private fake (see either for
/// precedent) -- the `.persistent`-branch tests below only need
/// `resolve()` to return non-nil to satisfy `SessionSpawnPlanner.plan`'s
/// LOCAL-context guard, exactly like those files' own usage; nothing
/// here executes the synthesized command (`_createManagedSurfaceHookForTesting`
/// short-circuits before that), so `path` need not point at a real
/// binary.
private struct FakeBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

@MainActor
final class CockpitSplitAndGroupCwdWiringTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.CockpitSplitAndGroupCwdWiringTests"

    /// Never dereferenced -- see `CockpitTabCreateCwdWiringTests`'
    /// identical `dummyApp` for why (`_createManagedSurfaceHookForTesting`
    /// intercepts every surface creation below before the real ghostty
    /// FFI call that would otherwise dereference this).
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    /// `SurfacePropertyStore.shared._stopObserving()` below is NOT
    /// optional: all four tests below call `SurfacePropertyStore.shared
    /// .startObserving()` directly on the real, process-wide singleton
    /// (see `CockpitTabCreateCwdWiringTests`'s own tearDown comment for
    /// the full hazard this guards against -- `_testReset()` only
    /// clears recorded entries, it does NOT touch the NotificationCenter
    /// registration `_stopObserving()` removes). Skipping this would
    /// leave `SurfacePropertyStore.shared` still subscribed to
    /// `.ghosttySetTitle`/`.ghosttySetPwd`/`.calyxSurfaceDestroyed` for
    /// the rest of the `CalyxTests` process, silently populating it from
    /// any later, unrelated test's `SurfaceRegistry._testInsert`/
    /// `createSurface` + notification-post pattern.
    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        SurfacePropertyStore.shared._stopObserving()
        SurfacePropertyStore.shared._testReset()
        SurfaceLocator.shared._testReset()
        super.tearDown()
    }

    private func makeController() -> (controller: CalyxWindowController, tab: Tab) {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return (controller, tab)
    }

    /// `performCreateNewGroup` creates its new tab as a private, freshly
    /// constructed `Tab()` and never hands a reference back to the
    /// caller -- this recovers it via `windowSession.activeGroup
    /// .activeTab`, which IS that new tab once `performCreateNewGroup`
    /// has run to completion (`group.activeTabID = tab.id` is set at
    /// construction, and `windowSession.activeGroupID = group.id` is
    /// one of the method's last steps), purely so the
    /// `.persistent`-branch test below can look up the `sessionRefs`
    /// entry keyed by the surfaceID its own
    /// `_createManagedSurfaceHookForTesting` hook returned, to
    /// unregister it from `SessionSurfaceMap.shared` afterward --
    /// mirrors `CockpitTabCreateCwdWiringTests`' identical
    /// `createdSessionID(controller:surfaceID:)` for
    /// `performCreateNewTab` (the same shape: a fresh internal `Tab()`
    /// the caller never sees directly). `performSplit`'s own
    /// `.persistent` test needs no equivalent: it operates on the `tab`
    /// the caller already holds a reference to, exactly like
    /// `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests`'
    /// direct `tab.sessionRefs[...]` reads. Returns `nil` harmlessly if
    /// `performCreateNewGroup` never actually reached that point (e.g.
    /// an early-return bug), since a never-run `.persistent` branch
    /// never registered anything to clean up either.
    private func createdSessionID(controller: CalyxWindowController, surfaceID: UUID) -> String? {
        controller.windowSession.activeGroup?.activeTab?.sessionRefs[surfaceID]?.sessionID
    }

    // MARK: - performSplit (see file header for how the resolver: DI
    // seam closed .persistent's reachability gap for this call site)

    /// Pins `performSplit`'s `explicitCwd: nil` (CalyxWindowController
    /// .swift:1433): a split carries no user-supplied cwd directive of
    /// its own, so it must always leave `explicitCwd` unset, exactly
    /// like an override-less new tab (`CockpitTabCreateCwdWiringTests`
    /// case b) -- preserving `.passthrough`'s live OSC-7-based
    /// inheritance for the new pane. `tab.pwd` and the SOURCE surface's
    /// own live `SurfacePropertyStore` cwd are both deliberately seeded
    /// to distinct, non-nil, non-matching values before the split: since
    /// `.passthrough`'s observer call receives exactly whatever
    /// `performSplit` passes as `explicitCwd` (see file header), this is
    /// what makes the assertion below able to actually fail -- a
    /// regression that wired `explicitCwd:` to `tab.pwd` (mirroring
    /// `setupTerminalSurface`'s differently-justified use of it) OR to
    /// `sessionFallbackCwd`'s value (e.g. a `??` collapsed one step too
    /// early) would surface one of these two seeded strings here
    /// instead of `nil`.
    func test_passthroughBranch_split_explicitCwdStaysNil_preservesLibghosttyInheritance() {
        SessionSettings.persistentSessionsEnabled = false
        let (controller, tab) = makeController()
        tab.pwd = "/Users/dev/stale-tab-pwd"

        let sourceSurfaceID = UUID()
        let sourceView = SurfaceView(frame: .zero)
        tab.registry._testInsert(view: sourceView, id: sourceSurfaceID)
        tab.splitTree = SplitTree(leafID: sourceSurfaceID)

        SurfacePropertyStore.shared.startObserving()
        NotificationCenter.default.post(
            name: .ghosttySetPwd, object: sourceView, userInfo: ["pwd": "/Users/dev/live-source-pane-cwd"]
        )
        XCTAssertEqual(SurfacePropertyStore.shared.cwd(for: sourceSurfaceID), "/Users/dev/live-source-pane-cwd",
                       "precondition: the source leaf's own live cwd must be recorded before driving performSplit")

        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        let result = controller.performSplit(surfaceID: sourceSurfaceID, direction: .horizontal, app: dummyApp)

        XCTAssertEqual(result, newSurfaceID as UUID?,
                       "precondition: performSplit must actually create the new surface for this assertion to mean anything")
        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performSplit must reach createManagedSurface exactly once for an ordinary split")
        XCTAssertNil(observedPwd,
                    "a split's explicitCwd must stay nil so libghostty performs its own live OSC-7-based " +
                    "working-directory inheritance for the new pane -- neither the tab's stale pwd field nor the " +
                    "source pane's own live cwd (both seeded to distinct, non-nil values above) may leak into it")
    }

    /// Pins `performSplit`'s `.persistent`-branch `sessionFallbackCwd:
    /// livePaneCwd(of: surfaceID, in: tab)` (CalyxWindowController
    /// .swift:1484) -- CLOSED GAP, see file header for the `resolver:`
    /// DI seam that made this reachable at all. `SessionSettings
    /// .persistentSessionsEnabled = true` plus an injected resolver that
    /// DOES resolve (`FakeBinaryResolver`, reused above from
    /// `SessionSpawnPlannerTests`'/`SessionBinaryResolverTests`'
    /// identical private fake) makes `SessionSpawnPlanner.plan` return
    /// `.persistent` for this LOCAL (`context.host == nil`) split, so
    /// `_createManagedSurfacePwdObserverForTesting` now fires with
    /// `sessionCwd` -- `explicitCwd ?? sessionFallbackCwd ??
    /// NSHomeDirectory()`, with `explicitCwd` always `nil` for a split
    /// -- rather than `.passthrough`'s `explicitCwd` alone, so
    /// `sessionCwd` reduces to exactly `sessionFallbackCwd` here. The
    /// SOURCE leaf being split (`sourceSurfaceID`, NOT just "the tab")
    /// and the owning tab's own `pwd` are seeded to distinct, non-nil
    /// values before the split, exactly like the `.passthrough` test
    /// above: this is what makes the assertion below able to actually
    /// fail -- a regression wiring `sessionFallbackCwd:` back to plain
    /// `tab.pwd` (`livePaneCwd`'s own last-resort fallback, only correct
    /// when `SurfacePropertyStore` has no entry for the source surface
    /// at all -- not the case here, since this test seeds one below)
    /// would surface the STALE tab-level string here instead of the
    /// source pane's own live one.
    func test_persistentBranch_split_usesSourcePaneLiveCwd_notStaleTabPwd() {
        SessionSettings.persistentSessionsEnabled = true
        let (controller, tab) = makeController()
        tab.pwd = "/Users/dev/stale-tab-pwd"

        let sourceSurfaceID = UUID()
        let sourceView = SurfaceView(frame: .zero)
        tab.registry._testInsert(view: sourceView, id: sourceSurfaceID)
        tab.splitTree = SplitTree(leafID: sourceSurfaceID)

        SurfacePropertyStore.shared.startObserving()
        NotificationCenter.default.post(
            name: .ghosttySetPwd, object: sourceView, userInfo: ["pwd": "/Users/dev/live-source-pane-cwd"]
        )
        XCTAssertEqual(SurfacePropertyStore.shared.cwd(for: sourceSurfaceID), "/Users/dev/live-source-pane-cwd",
                       "precondition: the source leaf's own live cwd must be recorded before driving performSplit")

        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        let result = controller.performSplit(
            surfaceID: sourceSurfaceID, direction: .horizontal, app: dummyApp,
            resolver: FakeBinaryResolver(path: "/dummy/calyx-session")
        )
        defer {
            if let sessionID = tab.sessionRefs[newSurfaceID]?.sessionID {
                SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            }
        }

        XCTAssertEqual(result, newSurfaceID as UUID?,
                       "precondition: performSplit must actually create the new surface for this assertion to mean anything")
        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performSplit must reach createManagedSurface exactly once for an ordinary split")
        XCTAssertNotNil(tab.sessionRefs[newSurfaceID],
                        "precondition: the injected resolving resolver must actually reach the .persistent branch " +
                        "(recording a sessionRefs entry) -- otherwise this test silently exercises .passthrough " +
                        "instead and proves nothing about sessionFallbackCwd")
        XCTAssertEqual(observedPwd, "/Users/dev/live-source-pane-cwd",
                    "a persistent split with no explicit cwd directive must fall back to the SOURCE pane's own " +
                    "live SurfacePropertyStore cwd, not the owning tab's stale pwd field (seeded to a distinct " +
                    "value above)")
    }

    // MARK: - createNewGroup (see file header for how the resolver: DI
    // seam closed .persistent's reachability gap for this call site)

    /// Pins `performCreateNewGroup`'s `explicitCwd: nil`
    /// (CalyxWindowController.swift:1799): a new group's first pane
    /// carries no user-supplied cwd directive of its own, so it must
    /// always leave `explicitCwd` unset, exactly like an override-less
    /// new tab (`CockpitTabCreateCwdWiringTests` case b) or an ordinary
    /// split (`test_passthroughBranch_split_explicitCwdStaysNil_...`
    /// above) -- preserving `.passthrough`'s live OSC-7-based
    /// inheritance for the new pane. The OLD active tab's `pwd` and its
    /// FOCUSED leaf's own live `SurfacePropertyStore` cwd are both
    /// deliberately seeded to distinct, non-nil, non-matching values
    /// before the call: since `.passthrough`'s observer call receives
    /// exactly whatever `performCreateNewGroup` passes as `explicitCwd`
    /// (see file header), this is what makes the assertion below able
    /// to actually fail -- a regression that wired `explicitCwd:` to
    /// `activeTab?.pwd` (mirroring `setupTerminalSurface`'s
    /// differently-justified use of a tab's own `pwd`) OR to
    /// `sessionFallbackCwd`'s resolved value (e.g. a `??` collapsed one
    /// step too early -- the exact class of bug #43, and the naive
    /// shape of the rejected #41 fix) would surface one of these two
    /// seeded strings here instead of `nil`.
    func test_passthroughBranch_createNewGroup_explicitCwdStaysNil_preservesLibghosttyInheritance() {
        SessionSettings.persistentSessionsEnabled = false
        let (controller, tab) = makeController()
        tab.pwd = "/Users/dev/stale-tab-pwd"

        let focusedSurfaceID = UUID()
        let focusedView = SurfaceView(frame: .zero)
        tab.registry._testInsert(view: focusedView, id: focusedSurfaceID)
        tab.splitTree = SplitTree(leafID: focusedSurfaceID)

        SurfacePropertyStore.shared.startObserving()
        NotificationCenter.default.post(
            name: .ghosttySetPwd, object: focusedView, userInfo: ["pwd": "/Users/dev/live-focused-pane-cwd"]
        )
        XCTAssertEqual(SurfacePropertyStore.shared.cwd(for: focusedSurfaceID), "/Users/dev/live-focused-pane-cwd",
                       "precondition: the focused leaf's own live cwd must be recorded before driving performCreateNewGroup")

        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        let groupCountBefore = controller.windowSession.groups.count
        controller.performCreateNewGroup(app: dummyApp)

        XCTAssertEqual(controller.windowSession.groups.count, groupCountBefore + 1,
                       "precondition: performCreateNewGroup must actually create the new group/surface for this assertion to mean anything")
        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performCreateNewGroup must reach createManagedSurface exactly once for an ordinary new group")
        XCTAssertNil(observedPwd,
                    "a new group's explicitCwd must stay nil so libghostty performs its own live OSC-7-based " +
                    "working-directory inheritance for its first pane -- neither the old active tab's stale pwd " +
                    "field nor its focused leaf's own live cwd (both seeded to distinct, non-nil values above) " +
                    "may leak into it")
    }

    /// Pins `performCreateNewGroup`'s `.persistent`-branch
    /// `sessionFallbackCwd: livePaneCwd(of: activeTab?.splitTree
    /// .focusedLeafID, in: activeTab)` (CalyxWindowController.swift:1872)
    /// -- CLOSED GAP, see file header for the `resolver:` DI seam that
    /// made this reachable at all. Same setup shape as the split test
    /// above, sourced from the OLD active tab's FOCUSED leaf rather than
    /// a split's own source surface -- exactly mirroring
    /// `CockpitTabCreateCwdWiringTests` case (e)'s identical
    /// `performCreateNewTab` setup, just reaching `.persistent` via an
    /// injected resolver instead of a non-nil `host`
    /// (`performCreateNewGroup` has no `host:` parameter -- see file
    /// header). The OLD active tab's `pwd` and its FOCUSED leaf's own
    /// live `SurfacePropertyStore` cwd are seeded to distinct, non-nil
    /// values before the call: this is what makes the assertion below
    /// able to actually fail -- a regression wiring `sessionFallbackCwd:`
    /// back to plain `activeTab?.pwd` would surface the STALE tab-level
    /// string here instead of the focused pane's own live one.
    func test_persistentBranch_createNewGroup_usesFocusedPaneLiveCwd_notStaleTabPwd() {
        SessionSettings.persistentSessionsEnabled = true
        let (controller, tab) = makeController()
        tab.pwd = "/Users/dev/stale-tab-pwd"

        let focusedSurfaceID = UUID()
        let focusedView = SurfaceView(frame: .zero)
        tab.registry._testInsert(view: focusedView, id: focusedSurfaceID)
        tab.splitTree = SplitTree(leafID: focusedSurfaceID)

        SurfacePropertyStore.shared.startObserving()
        NotificationCenter.default.post(
            name: .ghosttySetPwd, object: focusedView, userInfo: ["pwd": "/Users/dev/live-focused-pane-cwd"]
        )
        XCTAssertEqual(SurfacePropertyStore.shared.cwd(for: focusedSurfaceID), "/Users/dev/live-focused-pane-cwd",
                       "precondition: the focused leaf's own live cwd must be recorded before driving performCreateNewGroup")

        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        let groupCountBefore = controller.windowSession.groups.count
        controller.performCreateNewGroup(app: dummyApp, resolver: FakeBinaryResolver(path: "/dummy/calyx-session"))
        defer {
            if let sessionID = createdSessionID(controller: controller, surfaceID: newSurfaceID) {
                SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            }
        }

        XCTAssertEqual(controller.windowSession.groups.count, groupCountBefore + 1,
                       "precondition: performCreateNewGroup must actually create the new group/surface for this assertion to mean anything")
        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performCreateNewGroup must reach createManagedSurface exactly once for an ordinary new group")
        XCTAssertNotNil(createdSessionID(controller: controller, surfaceID: newSurfaceID),
                        "precondition: the injected resolving resolver must actually reach the .persistent branch " +
                        "(recording a sessionRefs entry) -- otherwise this test silently exercises .passthrough " +
                        "instead and proves nothing about sessionFallbackCwd")
        XCTAssertEqual(observedPwd, "/Users/dev/live-focused-pane-cwd",
                    "a persistent new group with no explicit cwd directive must fall back to the OLD active tab's " +
                    "FOCUSED pane's own live SurfacePropertyStore cwd, not that tab's stale pwd field (seeded to " +
                    "a distinct value above)")
    }
}
