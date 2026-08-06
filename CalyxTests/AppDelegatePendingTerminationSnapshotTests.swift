//
//  AppDelegatePendingTerminationSnapshotTests.swift
//  CalyxTests
//
//  TDD Red phase (save-reliability C2 -- terminate-path snapshot capture).
//  ORIGINAL ROOT CAUSE (confirmed live-incident narrative: 3 windows
//  genuinely open, sessions.json read back as {"windows":[]}), from
//  BEFORE the window-lifetime redesign (see
//  AppDelegateLastWindowClosedDoesNotTerminateTests) made closing a
//  window incapable of cascading into termination at all: closing the
//  LAST managed window used to be able to confirm quit and terminate the
//  app in the same stroke, and by the time applicationWillTerminate ran,
//  removeWindowController had already emptied windowControllers/
//  appSession, so its own guard skipped the save entirely and nothing
//  with real content ever reached disk.
//
//  THE FIX: capture the CURRENT (pre-teardown) window state the moment
//  termination is CONFIRMED (before any teardown can empty
//  windowControllers/appSession), and have the termination-time save
//  consult that captured snapshot instead of re-deriving from the
//  (by-then-emptied) live windowControllers/appSession. This mechanism
//  (`AppDelegate.pendingTerminationSnapshot`, `.saveForTermination()`)
//  survived the window-lifetime redesign unchanged -- see each symbol's
//  own doc comment in AppDelegate.swift -- only WHERE the capture is
//  triggered moved: originally on `isTerminationConfirmed`'s didSet
//  (covering both the close-path confirm-quit prompt and Cmd+Q), now as
//  an explicit line inside `applicationShouldTerminate` itself (the only
//  termination route left, since closing a window never terminates the
//  app any more).
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): this file drives
//  saveForTermination() directly against a bare AppDelegate() with
//  _testInsertWindowController-seeded fixture controllers (mirrors
//  CalyxWindowControllerLastWindowCloseSaveTests' own no-live-ghostty-
//  surface fixture) and a temp-dir-backed SessionPersistenceActor
//  (mirrors AppDelegateRecoveryCounterResetTests' own pattern), so it CAN
//  pin saveForTermination()'s snapshot-preference contract exactly. It
//  CANNOT pin that applicationShouldTerminate's own body actually
//  captures pendingTerminationSnapshot at its call site, or that
//  applicationWillTerminate's own body actually calls
//  saveForTermination() at ITS call site -- both are gated behind
//  LaunchEnvironmentPolicy.isUnitTestHost() (the latter) or otherwise
//  unreachable without a real Cmd+Q (the former) in this process. Code
//  review must verify both call sites by reading the diff; no test in
//  this file substitutes for that reading.
//
//  Coverage:
//  - saveForTermination() with a pending snapshot present saves THAT
//    content, not a fresh (empty) rebuild from live (empty)
//    windowControllers
//  - saveForTermination() with NO pending snapshot falls back to a live
//    buildSnapshot() rebuild, unchanged from applicationWillTerminate's
//    existing Cmd+Q-with-no-race behavior
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegatePendingTerminationSnapshotTests: XCTestCase {

    // MARK: - Fixtures / Helpers

    /// Mirrors AppDelegateRecoveryCounterResetTests.makeSessionDirActor()'s
    /// per-test-method teardown-block convention.
    private func makeSessionDirActor() throws -> SessionPersistenceActor {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegatePendingTerminationSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let dir = raw.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", dir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return SessionPersistenceActor()
    }

    /// Single-tab/single-group window, no live ghostty surface -- mirrors
    /// CalyxWindowControllerLastWindowCloseSaveTests.makeFixture()
    /// exactly, parameterized by title so multiple fixture controllers
    /// are distinguishable in a captured snapshot.
    private func makeFixtureController(title: String) -> CalyxWindowController {
        let tab = Tab(title: title)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    // MARK: - 4. saveForTermination() prefers the captured snapshot over a live rebuild

    func test_saveForTermination_pendingSnapshotPresent_savesPendingSnapshotNotLiveEmptyState() async throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        // windowControllers is deliberately left EMPTY (never inserted),
        // so buildSnapshot() would yield SessionSnapshot(windows: []) --
        // simulating the exact post-teardown race (removeWindowController
        // already emptied everything) the root cause above traces.
        let windowID = UUID()
        let pending = SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 1, y: 2, width: 3, height: 4))])
        appDelegate._setPendingTerminationSnapshotForTesting(pending)

        appDelegate.saveForTermination()

        let restored = await actor.restore()
        XCTAssertEqual(restored, SessionSnapshot.migrate(pending),
                       "saveForTermination() must save the CAPTURED pendingTerminationSnapshot, not " +
                       "an empty rebuild from the live (already-emptied) windowControllers")
        XCTAssertEqual(restored?.windows.first?.id, windowID)
    }

    // MARK: - 5. saveForTermination() falls back to a live rebuild when nothing was captured

    func test_saveForTermination_noPendingSnapshot_fallsBackToLiveBuildSnapshot() async throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        let controller = makeFixtureController(title: "Only")
        appDelegate._testInsertWindowController(controller)

        XCTAssertNil(appDelegate.pendingTerminationSnapshot,
                     "precondition: nothing was ever captured, since this test drives saveForTermination() " +
                     "directly without going through applicationShouldTerminate's own capture line")

        appDelegate.saveForTermination()

        let restored = await actor.restore()
        let expected = SessionSnapshot(windows: [controller.windowSnapshot()])
        XCTAssertEqual(restored, SessionSnapshot.migrate(expected),
                       "with no captured snapshot, saveForTermination() must fall back to a live " +
                       "buildSnapshot() rebuild, unchanged from today's applicationWillTerminate " +
                       "behavior for a race-free termination")
    }
}
