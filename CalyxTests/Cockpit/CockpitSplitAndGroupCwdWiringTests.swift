//
//  CockpitSplitAndGroupCwdWiringTests.swift
//  CalyxTests
//
//  Regression coverage for issue #43's `sessionFallbackCwd:
//  livePaneCwd(of:in:)` wiring (Calyx/Views/MainWindow/
//  CalyxWindowController.swift's `createManagedSurface`) at the TWO
//  call sites `CockpitTabCreateCwdWiringTests.swift` does not cover:
//  `performSplit` and `performCreateNewGroup`. Sibling file rather than
//  an extension of that one: its header/structure is built entirely
//  around its own
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
//  REACHING `.persistent` HERE -- CLOSED GAP, VIA AN ENV VAR, NOT A
//  PRODUCTION PARAMETER: this file used to report `.persistent` as
//  unreachable, and each call site's `sessionFallbackCwd` distinction
//  as unobservable even in principle, for BOTH call sites below. Still
//  true, unchanged by anything below: neither `performSplit` nor
//  `performCreateNewGroup` has a `host:` parameter at all -- grep
//  confirms no call site anywhere in this codebase passes one to either
//  (`performSplit`'s only two production call sites:
//  `LiveCockpitAppAccess.splitPane`,
//  `CalyxWindowController.handleNewSplitNotification`;
//  `performCreateNewGroup`'s only caller: `createNewGroup()`'s own thin
//  wrapper), and neither has a remote-host entry point analogous to
//  `performCreateNewTab`'s own `AppDelegate.spawnRemoteSessionTab(host:)`
//  to justify adding one. So every `SessionSpawnContext` either method
//  builds is still unconditionally LOCAL (`context.host == nil`), and
//  `SessionSpawnPlanner.plan` still always evaluates its LOCAL-only
//  `guard let binaryPath = resolver.resolve() else { return
//  .passthrough }` for both -- UNCHANGED.
//
//  What DID change, twice. First attempt (since reverted): this gap was
//  closed by giving `performSplit`/`performCreateNewGroup` (and
//  `createManagedSurface`) their own defaulted `resolver:
//  SessionBinaryResolverProtocol = SessionBinaryResolver()` parameter,
//  forwarded verbatim down into `SessionSpawnPlanner.plan(for:resolver:)`
//  -- the same already-established defaulted-protocol seam
//  `SessionSpawnPlannerTests`/`SessionSpawnPlannerRemoteHostTests`/
//  `SessionBinaryResolverTests` drive directly with fakes. That
//  parameter has SINCE BEEN REMOVED from production, and this file's
//  two `.persistent` tests below no longer use it: `resolver` genuinely
//  is `SessionSpawnPlanner.plan`'s own real dependency at THAT layer
//  (and remains defaulted there, untouched, for exactly those three
//  files to keep driving), but no production caller of
//  `performSplit`/`performCreateNewGroup` ever supplied anything but
//  the default two/three layers further up -- exactly the same shape a
//  `host:` parameter added to these two methods purely for test
//  reachability would have been (see the paragraph above), regardless
//  of whether the injected type happens to be "real" one layer down. A
//  parameter no production caller ever passes is production code
//  written for tests, which this project's rules forbid.
//
//  The two `.persistent` tests below instead reach it the way several
//  other files in this suite already do (this file's own two tests
//  copy `SessionReconnectAttemptResetTimingTests`'s exact save/restore
//  shape): a `CALYX_SESSION_BIN` environment-variable override,
//  `setenv` before driving the call and restored via `defer`
//  immediately after. This needs NO changes to `createManagedSurface`
//  at all -- it already calls `SessionSpawnPlanner.plan(for: context)`
//  using that method's own defaulted `resolver:` parameter above, and
//  the concrete `SessionBinaryResolver()` that default constructs reads
//  `environment["CALYX_SESSION_BIN"]` first (`environment` itself
//  defaulting to `ProcessInfo.processInfo.environment`), which observes
//  a same-process `setenv()` call live -- no construction-time
//  injection required. Unlike the removed `resolver:` parameter,
//  `CALYX_SESSION_BIN` is not a seam invented for this test file at
//  all: it is `SessionBinaryResolver`'s own pre-existing, documented
//  PRODUCTION capability (its own doc comment: "dev workflow / test
//  injection"), so overriding it here drives `performSplit`/
//  `performCreateNewGroup` through genuinely real, unmodified
//  production code all the way down to the actual resolver
//  construction -- the test merely exercises an existing knob, rather
//  than the production code exposing one that only a test would ever
//  turn. The path need not exist: exactly like every other file using
//  this idiom, `_createManagedSurfaceHookForTesting`'s short-circuit
//  (installed in every test below) means nothing synthesized from it
//  ever actually runs. `host:` remains, as before, deliberately NOT
//  added to either method purely for test reachability: neither method
//  has one to give `context.host` a non-nil value the way
//  `CockpitTabCreateCwdWiringTests` tests d/e do for
//  `performCreateNewTab` -- the `CALYX_SESSION_BIN` override above is
//  the only route to `.persistent` available here.
//
//  CRITICAL, exactly like `CockpitTabCreateCwdWiringTests`'s identical
//  warning about its own host/settings combination: reaching
//  `.persistent` below still needs BOTH `SessionSettings
//  .persistentSessionsEnabled = true` AND `CALYX_SESSION_BIN` actually
//  resolving to a non-empty path for the duration of the call -- either
//  alone still silently falls back to `.passthrough`. Unlike that
//  file's own risk (an assertion that would pass VACUOUSLY on the wrong
//  branch), a misconfigured test here would still FAIL, just for a less
//  specific reason: `.passthrough`'s observer call receives
//  `explicitCwd`, unconditionally `nil` for both call sites, which
//  matches neither of the distinct seeded values the two `.persistent`
//  tests below set up. Even so, each one additionally asserts a
//  `sessionRefs` entry was actually recorded for the new surface before
//  trusting the observed pwd, so a real failure is diagnosed as "never
//  reached .persistent" rather than a confusing pwd mismatch -- do not
//  rely on the pwd assertion alone to catch a missing
//  `persistentSessionsEnabled = true` or a `CALYX_SESSION_BIN` override
//  that didn't take effect.
//
//  That `sessionRefs` precondition matters MORE here than it did under
//  the removed `resolver:` DI seam: a directly constructed
//  `FakeBinaryResolver` either resolved or it didn't, deterministically,
//  by construction -- there was no live external state that had to
//  successfully propagate for that. An environment variable is
//  different: a same-process, mutable, ambient global that this file's
//  own `setenv()` call (below, in each `.persistent` test) has to
//  actually reach `SessionBinaryResolver`'s live
//  `ProcessInfo.processInfo.environment` read for `.persistent` to be
//  reachable at all. If that `setenv()` call somehow failed to take
//  effect, `SessionBinaryResolver().resolve()` would quietly return
//  `nil`, `SessionSpawnPlanner.plan` would quietly fall back to
//  `.passthrough`, and -- exactly as the paragraph above already
//  establishes for any misconfiguration -- the pwd assertion would
//  still fail (observing `nil` instead of the expected live-pane cwd),
//  but non-specifically. The `sessionRefs` assertion is what turns that
//  failure into an unambiguous "never reached .persistent" diagnosis
//  instead of a confusing pwd mismatch, which is exactly why it must
//  never be weakened or removed.
//
//  Coverage:
//  - performSplit(explicitCwd: nil, sessionFallbackCwd:
//    livePaneCwd(of: surfaceID, in: tab)).
//    - `.passthrough` (persistentSessionsEnabled = false):
//      `test_passthroughBranch_split_explicitCwdStaysNil_preservesLibghosttyInheritance`.
//      `explicitCwd` must stay `nil` for an ordinary split, exactly
//      like an override-less new tab, preserving `.passthrough`'s live
//      OSC-7-based inheritance.
//    - `.persistent` (persistentSessionsEnabled = true, `CALYX_SESSION_BIN`
//      override resolving -- CLOSED GAP, see above):
//      `test_persistentBranch_split_usesSourcePaneLiveCwd_notStaleTabPwd`.
//      Pins the same distinction `CockpitTabCreateCwdWiringTests` case
//      (e) pins for `performCreateNewTab`: the observed pwd must be the
//      SOURCE leaf being split (`surfaceID`, not just "the tab")'s own
//      live `SurfacePropertyStore` cwd, not the owning tab's stale
//      `pwd` field.
//  - performCreateNewGroup (`createNewGroup()`'s thin wrapper, and the
//    extracted body's own `explicitCwd`/`sessionFallbackCwd` call).
//    Previously untestable at all: `createNewGroup()` used to guard
//    directly on `GhosttyAppController.shared.app` (always `nil` in
//    `CalyxTests`) and return before ever reaching `createManagedSurface`
//    -- this gap closed once `createNewGroup()` gained this
//    `performCreateNewGroup(app: ghostty_app_t)` sibling, mirroring
//    `performCreateNewTab`'s/`performSplit`'s own "un-privated,
//    app-taking extraction; `self.window` still resolved internally"
//    precedent.
//    - `.passthrough` (persistentSessionsEnabled = false):
//      `test_passthroughBranch_createNewGroup_explicitCwdStaysNil_preservesLibghosttyInheritance`.
//      `explicitCwd` must stay `nil` for a new group's first pane,
//      exactly like `performSplit`'s.
//    - `.persistent` (persistentSessionsEnabled = true, `CALYX_SESSION_BIN`
//      override resolving -- CLOSED GAP, see above):
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

    // MARK: - performSplit (see file header for how the CALYX_SESSION_BIN
    // env-var override closes .persistent's reachability gap for this call site)

    /// Pins `performSplit`'s `explicitCwd: nil`: a split carries no
    /// user-supplied cwd directive of its own, so it must always leave
    /// `explicitCwd` unset, exactly
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
    /// livePaneCwd(of: surfaceID, in: tab)` -- CLOSED GAP, see file
    /// header for the `CALYX_SESSION_BIN` env-var override that makes
    /// this reachable at all. `SessionSettings.persistentSessionsEnabled
    /// = true` plus the `CALYX_SESSION_BIN` override below (which the
    /// default `SessionBinaryResolver()` `createManagedSurface` hands
    /// `SessionSpawnPlanner.plan` resolves to a non-nil path) makes
    /// `SessionSpawnPlanner.plan` return `.persistent` for this LOCAL
    /// (`context.host == nil`) split, so
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

        // CALYX_SESSION_BIN env override (SessionBinaryResolver's own
        // documented production test-injection seam, see file header)
        // makes the default SessionBinaryResolver() createManagedSurface
        // hands SessionSpawnPlanner.plan resolve to a non-nil path,
        // without which this LOCAL split would silently fall back to
        // .passthrough -- the sessionRefs precondition below exists
        // precisely to catch that if it ever happens. The path need not
        // exist: _createManagedSurfaceHookForTesting below intercepts
        // before any command is ever actually executed.
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        let result = controller.performSplit(surfaceID: sourceSurfaceID, direction: .horizontal, app: dummyApp)
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
                        "precondition: the CALYX_SESSION_BIN override must actually reach the .persistent branch " +
                        "(recording a sessionRefs entry) -- otherwise this test silently exercises .passthrough " +
                        "instead and proves nothing about sessionFallbackCwd")
        XCTAssertEqual(observedPwd, "/Users/dev/live-source-pane-cwd",
                    "a persistent split with no explicit cwd directive must fall back to the SOURCE pane's own " +
                    "live SurfacePropertyStore cwd, not the owning tab's stale pwd field (seeded to a distinct " +
                    "value above)")
    }

    // MARK: - createNewGroup (see file header for how the CALYX_SESSION_BIN
    // env-var override closes .persistent's reachability gap for this call site)

    /// Pins `performCreateNewGroup`'s `explicitCwd: nil`: a new group's
    /// first pane carries no user-supplied cwd directive of its own, so it must
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
    /// .focusedLeafID, in: activeTab)` -- CLOSED GAP, see file header
    /// for the `CALYX_SESSION_BIN` env-var override that made this
    /// reachable at all. Same setup shape as the split test above,
    /// sourced from the OLD active tab's FOCUSED leaf rather than a
    /// split's own source surface -- exactly mirroring
    /// `CockpitTabCreateCwdWiringTests` case (e)'s identical
    /// `performCreateNewTab` setup, just reaching `.persistent` via a
    /// `CALYX_SESSION_BIN` override instead of a non-nil `host`
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

        // CALYX_SESSION_BIN env override -- see the split test above and
        // the file header for the full mechanism and why this replaced
        // the removed resolver: DI parameter. The path need not exist:
        // _createManagedSurfaceHookForTesting below intercepts before
        // any command is ever actually executed.
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

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
                        "precondition: the CALYX_SESSION_BIN override must actually reach the .persistent branch " +
                        "(recording a sessionRefs entry) -- otherwise this test silently exercises .passthrough " +
                        "instead and proves nothing about sessionFallbackCwd")
        XCTAssertEqual(observedPwd, "/Users/dev/live-focused-pane-cwd",
                    "a persistent new group with no explicit cwd directive must fall back to the OLD active tab's " +
                    "FOCUSED pane's own live SurfacePropertyStore cwd, not that tab's stale pwd field (seeded to " +
                    "a distinct value above)")
    }
}
