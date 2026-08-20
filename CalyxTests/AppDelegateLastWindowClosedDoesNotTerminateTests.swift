//
//  AppDelegateLastWindowClosedDoesNotTerminateTests.swift
//  CalyxTests
//
//  Window-lifetime redesign: Calyx must stop terminating
//  the app when the last tab/tab-group/window closes, matching Ghostty's
//  own behavior. Two production entry points must change together:
//
//  1. `applicationShouldTerminateAfterLastWindowClosed` (AppDelegate.swift
//     ~:286) currently returns `quickTerminalController == nil` (`true`
//     whenever no quick terminal is open -- the overwhelmingly common
//     case), telling AppKit to terminate the app once its last window
//     closes. It must always return `false`.
//
//  2. `removeWindowController` (AppDelegate.swift ~:955) currently calls
//     `NSApp.terminate(nil)` directly once `windowControllers` becomes
//     empty (and no quick terminal is open) -- an explicit, redundant
//     termination request on top of (1). It must instead persist the
//     now-window-less state synchronously (`saveImmediately()`, since no
//     window remains whose own `windowWillClose` could save it later)
//     and never request termination at all.
//
//  SAFETY: `NSApp.terminate(nil)` can kill this test process outright.
//  `NSApplication.terminate(_:)` synchronously asks `NSApp.delegate`'s
//  `applicationShouldTerminate(_:)` before doing anything destructive, so
//  `RemoveWindowControllerTerminationSpyAppDelegate` below overrides that
//  method to unconditionally return `.terminateCancel`, aborting any
//  stray `NSApp.terminate(nil)` call harmlessly -- while still recording
//  whether it was called at all, which is this file's primary
//  signal for (2). `saveImmediately()`/`requestSave()` are both overridden
//  to pure spies (never calling through), since the real implementations
//  reach `SessionPersistenceActor.shared` and would write to the
//  developer's actual `~/.calyx` (mirrors
//  `CalyxWindowControllerLastWindowCloseSaveTests.SaveOnCloseSpyAppDelegate`'s
//  identical reasoning).
//
//  Controllers are registered via the DEBUG-only `_testInsertWindowController`
//  seam rather than any real window-creation path (no live Ghostty surface
//  needed, matching this codebase's established lightweight-fixture
//  convention, e.g. `CalyxWindowControllerCloseArmsTests.makeSingleTabFixture`).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateLastWindowClosedDoesNotTerminateTests: XCTestCase {

    // MARK: - applicationShouldTerminateAfterLastWindowClosed

    /// Against the CURRENT code, a fresh `AppDelegate()` has no quick
    /// terminal open (`quickTerminalController == nil`, the default), so
    /// this returns `true` -- telling AppKit the last window closing
    /// should terminate the app. It must always return `false`.
    func test_applicationShouldTerminateAfterLastWindowClosed_alwaysReturnsFalse() {
        let appDelegate = AppDelegate()

        XCTAssertFalse(
            appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApp),
            "Closing the last window must never terminate Calyx any more, matching Ghostty's own " +
            "last-window-doesn't-quit behavior"
        )
    }

    // MARK: - removeWindowController

    /// Test-only spy: see this file's header comment for the full safety
    /// rationale (`.terminateCancel` neutralizes any stray
    /// `NSApp.terminate(nil)`; `saveImmediately`/`requestSave` never call
    /// through to the real `SessionPersistenceActor.shared`).
    private final class RemoveWindowControllerTerminationSpyAppDelegate: AppDelegate {
        private(set) var applicationShouldTerminateCallCount = 0
        private(set) var saveImmediatelyCallCount = 0
        private(set) var requestSaveCallCount = 0

        override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            applicationShouldTerminateCallCount += 1
            return .terminateCancel
        }

        override func saveImmediately() {
            saveImmediatelyCallCount += 1
        }

        override func requestSave() {
            requestSaveCallCount += 1
        }
    }

    private func makeFixtureController() -> CalyxWindowController {
        let tab = Tab(title: "Only")
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

    private func withMockAppDelegate(
        _ mock: RemoveWindowControllerTerminationSpyAppDelegate, _ body: () -> Void
    ) {
        let original = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = original }
        withExtendedLifetime(mock) {
            body()
        }
    }

    /// PRIMARY assertion pinning (2): before the fix,
    /// removing the last window controller falls into
    /// `removeWindowController`'s `else if quickTerminalController == nil`
    /// branch and calls `NSApp.terminate(nil)` directly, which
    /// synchronously reaches `applicationShouldTerminate` (see this
    /// file's header comment) -- so the call count is 1, not 0.
    func test_removeWindowController_lastController_neverCallsApplicationShouldTerminate() {
        let mock = RemoveWindowControllerTerminationSpyAppDelegate()
        let controller = makeFixtureController()
        mock._testInsertWindowController(controller)

        withMockAppDelegate(mock) {
            mock.removeWindowController(controller)
        }

        XCTAssertEqual(
            mock.applicationShouldTerminateCallCount, 0,
            "Removing the last window controller must never (even indirectly, via NSApp.terminate) " +
            "request app termination any more"
        )
    }

    /// Against the CURRENT code, `removeWindowController` never calls
    /// `saveImmediately()` at all (it calls `NSApp.terminate(nil)`
    /// instead, expecting `applicationWillTerminate`'s own save to run) --
    /// so this count is 0, not 1.
    func test_removeWindowController_lastController_callsSaveImmediately() {
        let mock = RemoveWindowControllerTerminationSpyAppDelegate()
        let controller = makeFixtureController()
        mock._testInsertWindowController(controller)

        withMockAppDelegate(mock) {
            mock.removeWindowController(controller)
        }

        XCTAssertEqual(
            mock.saveImmediatelyCallCount, 1,
            "Removing the last window controller must synchronously persist the now-window-less state " +
            "itself, exactly once -- with the app no longer terminating, no windowWillClose-driven save " +
            "or applicationWillTerminate save will run later to do it instead"
        )
    }

    /// Regression guard, not an assertion that pins the fix on its own
    /// (matching this codebase's convention of pairing a "last
    /// controller" test with a "not the last controller" sanity guard, see
    /// `CalyxWindowControllerLastWindowCloseSaveTests`'s identical
    /// pairing): removing a controller while another window remains open
    /// must keep going through the existing `requestSave()` path, not the
    /// new last-window `saveImmediately()` path, and must never request
    /// termination either. Already true today.
    func test_removeWindowController_notLastController_takesRequestSavePathNotSaveImmediately() {
        let mock = RemoveWindowControllerTerminationSpyAppDelegate()
        let controllerToRemove = makeFixtureController()
        let remainingController = makeFixtureController()
        mock._testInsertWindowController(controllerToRemove)
        mock._testInsertWindowController(remainingController)

        withMockAppDelegate(mock) {
            mock.removeWindowController(controllerToRemove)
        }

        XCTAssertEqual(mock.requestSaveCallCount, 1,
                      "With another window still open, removing a controller must still go through the " +
                      "ordinary requestSave() path")
        XCTAssertEqual(mock.saveImmediatelyCallCount, 0,
                      "...and must not also take the last-window saveImmediately() path")
        XCTAssertEqual(mock.applicationShouldTerminateCallCount, 0,
                      "...and must never request termination")
    }
}
