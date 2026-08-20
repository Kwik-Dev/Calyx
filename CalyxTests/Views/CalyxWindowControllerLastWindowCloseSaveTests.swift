//
//  CalyxWindowControllerLastWindowCloseSaveTests.swift
//  CalyxTests
//
//  Covers the last-window-close session-loss bug (root-caused
//  from a real user incident): quitting the app by closing the last
//  window (the red button) loses the session snapshot, so the next
//  launch cannot reattach and instead creates fresh sessions, leaving
//  the previous ones running as orphans.
//
//  ROOT CAUSE: windowWillClose's `appDelegate.saveImmediately()` call
//  (CalyxWindowController.swift, guarded only by
//  `appDelegate.isClosingLastManagedWindow(self)`) fires whenever this
//  is the last managed window, with no regard for whether the close is
//  actually part of app termination. `saveImmediately()` is the SAME
//  "user deliberately emptied every window" save
//  `AppDelegate.applicationWillTerminate`'s own `saveAtTermination`
//  guard exists to protect against (see
//  SessionPersistenceActorTerminationSaveTests's header): it is
//  legitimate ONLY for a close that does not terminate the app (e.g.
//  the last managed window closes but a quick terminal keeps the app
//  alive). For a genuinely terminating close, this call fires from
//  inside windowWillClose, using AppDelegate.buildSnapshot()
//  (`windowControllers.map { $0.windowSnapshot() }`) at that moment --
//  any tab state that differs from the last known-good periodic
//  snapshot already on disk overwrites it, and
//  applicationWillTerminate's own saveAtTermination protection never
//  gets a chance to help, because it only refuses an EMPTY snapshot,
//  not one already written moments earlier by this exact call.
//
//  THE FIX must gate this save on the SAME canonical "is the app
//  actually terminating" discriminator windowWillClose's own destroy
//  loop already uses two lines below it (`isAppActuallyTerminating`, a
//  thin forward to `AppDelegate.isApplicationTerminating`, that
//  property's own doc comment) -- NOT on the per-window
//  `isClosingForShutdown` flag alone: `closeLastWindow` sets that flag
//  even for a non-terminating close (a quick terminal keeps the app
//  alive, see that flag's own doc comment), so gating on it directly
//  would incorrectly skip the save for that legitimate case too --
//  exactly the discriminator-mismatch class earlier fixes already
//  fought (see isAppActuallyTerminating's own doc comment).
//
//  Drives windowWillClose(_:) directly with a bare Notification, mirrors
//  CalyxWindowControllerNonLastWindowCloseTests' established pattern
//  (itself mirroring CalyxWindowControllerFullScreenTests): a
//  _testInsert-only, no-live-ghostty-surface fixture (plain Tab(title:)
//  tabs, no SurfaceRegistry surfaces, matching
//  CalyxWindowControllerCloseArmsTests' makeSingleTabFixture), NSApp
//  .delegate swapped for a removeWindowController-no-op AppDelegate
//  subclass (ConfirmQuitMockAppDelegate) for test-process safety, with
//  saveImmediately further overridden to observe the save call without
//  hitting the real SessionPersistenceActor.shared (which would write to
//  the developer's actual ~/.calyx).
//
//  Window-lifetime redesign (see AppDelegateLastWindowClosedDoesNotTerminateTests):
//  the fix this file originally drove moved AGAIN, from windowWillClose's
//  own gated save into AppDelegate.removeWindowController, once the
//  controller is actually removed from windowControllers -- windowWillClose
//  must now never call saveImmediately() at all, in any scenario. The
//  narrative above is kept as the root-cause history that motivated
//  gating on isAppActuallyTerminating in the first place; only the save
//  call's OWN location moved, not that underlying discriminator lesson.
//
//  Coverage:
//  - genuinely terminating (isApplicationTerminating true, with
//    isClosingForShutdown also true -- the real state every controller
//    is in by then, see markAllControllersClosingForShutdown): the
//    windowWillClose save must be SKIPPED entirely
//  - NOT terminating, but isClosingForShutdown is (unconditionally, per
//    closeLastWindow) true anyway (quick-terminal-alive case): the save
//    must ALSO be skipped now (window-lifetime redesign; this used to be
//    the opposite -- a regression guard AND discriminator trap for the
//    windowWillClose-based fix -- see the superseded test this one
//    replaced, deleted along with this comment's own update)
//  - an ordinary close (neither terminating nor isClosingForShutdown
//    set): sanity guard, unaffected by this fix -- the save must never
//    fire in this, the most common, case either
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerLastWindowCloseSaveTests: XCTestCase {

    // MARK: - Fixture

    private struct SingleTabFixture {
        let controller: CalyxWindowController
    }

    /// Single-tab/single-group window, no live ghostty surface -- this
    /// file only asserts on whether `saveImmediately()` was called, so
    /// (mirrors CalyxWindowControllerCloseArmsTests.makeSingleTabFixture)
    /// tab/session content is irrelevant.
    private func makeFixture() -> SingleTabFixture {
        let tab = Tab(title: "Only")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SingleTabFixture(controller: controller)
    }

    // MARK: - Mock

    /// Spies on `saveImmediately()` WITHOUT calling through to the real
    /// implementation, which would hit SessionPersistenceActor.shared
    /// and write to the developer's actual ~/.calyx.
    private final class SaveOnCloseSpyAppDelegate: ConfirmQuitMockAppDelegate {
        private(set) var saveImmediatelyCallCount = 0

        override func saveImmediately() {
            saveImmediatelyCallCount += 1
        }
    }

    private func withMockAppDelegate(_ mock: SaveOnCloseSpyAppDelegate, _ body: () -> Void) {
        let original = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = original }
        withExtendedLifetime(mock) {
            body()
        }
    }

    // MARK: - Tests

    /// While the app is genuinely terminating -- `isApplicationTerminating`
    /// true, with `isClosingForShutdown` also true, the real state
    /// `markAllControllersClosingForShutdown` puts every controller in
    /// before termination begins (see that method's own doc comment) --
    /// `windowWillClose` must not call `saveImmediately()` at all: the
    /// last periodic save already on disk must survive untouched, so the
    /// next launch can reattach every detached session instead of
    /// creating fresh ones.
    func test_windowWillClose_terminating_doesNotSaveImmediately() {
        let fixture = makeFixture()
        let mock = SaveOnCloseSpyAppDelegate()
        mock._setApplicationTerminatingForTesting(true)
        fixture.controller.isClosingForShutdown = true

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(mock.saveImmediatelyCallCount, 0,
                      "While the app is genuinely terminating, windowWillClose must not call " +
                      "saveImmediately() at all -- the last periodic save already on disk must survive " +
                      "untouched, so the next launch can reattach every detached session instead of " +
                      "creating fresh ones")
    }

    /// Window-lifetime redesign: the last-window save this file's header
    /// describes has moved OUT of `windowWillClose` entirely, into
    /// `AppDelegate.removeWindowController` instead, once the controller
    /// is actually removed from the (now-empty) `windowControllers` list
    /// (see `AppDelegateLastWindowClosedDoesNotTerminateTests`).
    /// `windowWillClose` must never call `saveImmediately()` at all, in
    /// ANY scenario -- including "not terminating, isClosingForShutdown
    /// set" (a quick terminal keeps the app alive, see that flag's own
    /// doc comment), which a since-deleted sibling test used to protect
    /// with the OPPOSITE expectation (count 1) before this move.
    func test_windowWillClose_neverCallsSaveImmediately_savingMovesToRemoveWindowController() {
        let fixture = makeFixture()
        let mock = SaveOnCloseSpyAppDelegate()
        fixture.controller.isClosingForShutdown = true

        XCTAssertFalse(mock.isApplicationTerminating, "Precondition: the app is not terminating in this scenario")

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(mock.saveImmediatelyCallCount, 0,
                      "windowWillClose must never call saveImmediately directly any more -- saving the " +
                      "now-window-less state is AppDelegate.removeWindowController's job once this " +
                      "controller is actually removed from windowControllers, not windowWillClose's")
    }

    /// Sanity guard: an ordinary window close -- not terminating, and
    /// `isClosingForShutdown` left at its natural default (`false`) --
    /// must never trigger this save either. This replaces what used to be
    /// a "not the last managed window" scenario, driven by forcing
    /// `AppDelegate.isClosingLastManagedWindow` to return false: that
    /// mechanism (and the base method it overrode) is gone along with
    /// `windowWillClose`'s own last-window save gate (see
    /// `test_windowWillClose_neverCallsSaveImmediately_savingMovesToRemoveWindowController`),
    /// so it is no longer a state this fixture can distinguish. This is
    /// the one (isTerminating, isClosingForShutdown) corner the two tests
    /// above don't already cover, and the only one reachable in
    /// practice -- `markAllControllersClosingForShutdown` always sets
    /// every controller's `isClosingForShutdown` before
    /// `isApplicationTerminating` flips true, so "terminating but not
    /// closing-for-shutdown" is not a real state.
    func test_windowWillClose_ordinaryClose_neverSavesImmediately() {
        let fixture = makeFixture()
        let mock = SaveOnCloseSpyAppDelegate()

        XCTAssertFalse(mock.isApplicationTerminating, "Precondition: the app is not terminating in this scenario")
        XCTAssertFalse(fixture.controller.isClosingForShutdown, "Precondition: this controller is not closing for shutdown in this scenario")

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(mock.saveImmediatelyCallCount, 0,
                      "An ordinary window close -- not terminating, not closing for shutdown -- must never " +
                      "trigger windowWillClose's save path either")
    }
}
