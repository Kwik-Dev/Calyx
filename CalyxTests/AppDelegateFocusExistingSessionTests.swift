//
//  AppDelegateFocusExistingSessionTests.swift
//  CalyxTests
//
//  Covers the stale-mapping fallback and tab-activation completeness,
//  both in `AppDelegate.focusWindowForExistingSession(sessionID:)`.
//
//  Drives the PUBLIC `attachWindow(sessionID:cwd:)` entry point (matching
//  `AppDelegateAttachWindowTests`'s existing convention) rather than
//  making `focusWindowForExistingSession` itself non-private: its
//  early-return guard (`SessionSurfaceMap.shared.surfaceID(for:) != nil`)
//  is the real production call path into it, and driving through
//  `attachWindow` exercises that guard for real too.
//
//  Two NEW test seams (see their own doc comments in AppDelegate.swift):
//  - `_testInsertWindowController(_:)`, appends a controller straight to
//    `windowControllers`, so a test can give `focusWindowForExistingSession`
//    a genuine, already-registered controller to find, instead of only
//    the "no owning controller anywhere" case
//    `AppDelegateAttachWindowTests`'s existing fixture covers.
//  - `_focusWindowForExistingSessionShowHookForTesting`, replaces the
//    real `wc.showWindow(nil)` call. No test in this suite calls
//    `showWindow` for real (see `AppDelegateAttachWindowTests`'s header
//    comment on why driving a live window/surface hung the XCTest
//    process indefinitely); this avoids the same unverified risk for the
//    "found an existing controller" branch.
//
//  IMPORTANT (interaction with `AppDelegateAttachWindowTests`): this
//  file's stale-mapping test uses the EXACT SAME fixture shape (a
//  registered sessionID pointing at a surfaceID no controller owns) as
//  `AppDelegateAttachWindowTests
//  .test_attachWindow_forAlreadyRegisteredSessionID_neverReachesWindowCreation`,
//  but asserts the OPPOSITE outcome (creation hook DOES fire), per
//  the explicit "unregister the stale mapping and proceed with a
//  fresh attach instead of silently returning" contract. That existing,
//  currently-green test's fixture never gives the mapped surfaceID a
//  genuine owning controller either, so implementing it WILL require
//  updating that test's fixture to include a real owning
//  controller (making it a genuinely LIVE mapping, not a stale one).
//  Flagged here, and in this round's handoff, rather than silently left
//  for the implementer to discover.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateFocusExistingSessionTests: XCTestCase {

    // MARK: - Stale-mapping fallback

    /// Against the CURRENT code, `attachWindow`'s guard
    /// (`SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil`)
    /// unconditionally returns once it calls `focusWindowForExistingSession`,
    /// regardless of whether that method actually found a controller.
    /// So a STALE mapping (registered, but no controller anywhere
    /// contains the surfaceID, e.g. left behind by a non-terminating
    /// window close that never unregistered it, see
    /// `CalyxWindowControllerNonLastWindowCloseTests`) silently does
    /// nothing at all: no window shown, no fresh attach, and the stale
    /// entry is never cleaned up either.
    func test_attachWindow_forStaleSessionSurfaceMapEntry_unregistersStaleMappingAndProceedsWithFreshAttach() {
        let appDelegate = AppDelegate()
        var creationHookCallCount = 0
        appDelegate._attachWindowCreationHookForTesting = { creationHookCallCount += 1 }

        let sessionID = "test-session-\(UUID().uuidString)"
        let staleSurfaceID = UUID()
        // Deliberately registered with NO owning controller in
        // `appDelegate.windowControllers` (empty here), this IS the
        // stale case.
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: staleSurfaceID)
        defer { SessionSurfaceMap.shared.unregister(sessionID: sessionID) }

        appDelegate.attachWindow(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(creationHookCallCount, 1,
                       "A SessionSurfaceMap entry whose surfaceID no controller contains at all is stale, " +
                       "not live, attachWindow must unregister it and proceed to a fresh attach (reaching " +
                       "window/surface creation), instead of silently doing nothing")
        XCTAssertNil(SessionSurfaceMap.shared.surfaceID(for: sessionID),
                    "The stale mapping must be unregistered rather than left pointing at a surfaceID no " +
                    "controller owns")
    }

    // MARK: - Tab-activation completeness

    private struct TwoTabFixture {
        let controller: CalyxWindowController
        let group: TabGroup
        let tabA: Tab
        let tabB: Tab
        let trackedLeafID: UUID
        let sessionID: String
    }

    /// Two-tab, single-group window: `tabA` is active and plain; `tabB`
    /// is a BACKGROUND tab whose sole leaf carries a `SessionRef`,
    /// registered in `SessionSurfaceMap.shared`, the "session's live
    /// surface exists, but in a tab that isn't currently showing" case
    /// this section covers.
    private func makeTwoTabFixture() -> TwoTabFixture {
        let registryB = SurfaceRegistry()
        let trackedLeafID = UUID()
        registryB._testInsert(view: SurfaceView(frame: .zero), id: trackedLeafID)

        let sessionID = "test-session-\(UUID().uuidString)"
        let tabA = Tab(title: "A")
        let tabB = Tab(
            splitTree: SplitTree(leafID: trackedLeafID),
            registry: registryB,
            sessionRefs: [trackedLeafID: SessionRef(sessionID: sessionID)]
        )
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: trackedLeafID)

        let group = TabGroup(name: "Default", tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return TwoTabFixture(
            controller: controller, group: group, tabA: tabA, tabB: tabB,
            trackedLeafID: trackedLeafID, sessionID: sessionID
        )
    }

    /// Against the CURRENT code,
    /// `focusWindowForExistingSession` only calls `wc.showWindow(nil)`.
    /// It never activates the tab/group containing the mapped surface,
    /// so if that surface lives in a BACKGROUND tab, the user sees
    /// whatever tab happened to already be active, not the session they
    /// asked to attach to.
    func test_attachWindow_forSessionInBackgroundTab_activatesContainingTab() {
        let fixture = makeTwoTabFixture()
        let appDelegate = AppDelegate()
        appDelegate._testInsertWindowController(fixture.controller)
        var showHookCallCount = 0
        appDelegate._focusWindowForExistingSessionShowHookForTesting = { _ in showHookCallCount += 1 }
        defer { SessionSurfaceMap.shared.unregister(sessionID: fixture.sessionID) }

        XCTAssertEqual(fixture.group.activeTabID, fixture.tabA.id, "Precondition: tabA starts active")

        appDelegate.attachWindow(sessionID: fixture.sessionID, cwd: nil)

        XCTAssertEqual(showHookCallCount, 1,
                       "attachWindow must focus the controller already hosting this session's live surface " +
                       "exactly once")
        XCTAssertEqual(fixture.group.activeTabID, fixture.tabB.id,
                       "focusWindowForExistingSession must activate the tab/group containing the mapped " +
                       "surface, not just show the window while a different (background) tab stays active")
    }
}
