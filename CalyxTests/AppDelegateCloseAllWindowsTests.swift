//
//  AppDelegateCloseAllWindowsTests.swift
//  CalyxTests
//
//  TDD Red phase: GHOSTTY_ACTION_CLOSE_ALL_WINDOWS keybind wiring
//  (app-scoped action wiring, phase 1). `AppDelegate.closeAllWindows()`
//  is currently an empty do-nothing stub — `GhosttyActionRouter
//  .handleAction` has no case for `GHOSTTY_ACTION_CLOSE_ALL_WINDOWS` yet.
//
//  Real behavior under test (per this cycle's implementation spec):
//
//      let targets = windowControllers
//      guard !targets.isEmpty else { return }
//      guard confirmQuitIfNeeded() else { return }
//      isTerminationConfirmed = true
//      for wc in targets { wc.isClosingForShutdown = true }
//      for wc in targets { wc.window?.close() }
//      if !windowControllers.isEmpty || quickTerminalController != nil {
//          isTerminationConfirmed = false
//      }
//
//  DANGER, confirmed twice in this project's history (see this cycle's
//  task brief): closing a REAL window cascades window?.close() ->
//  windowWillClose -> AppDelegate.removeWindowController ->
//  NSApp.terminate(nil) once windowControllers is empty, which kills the
//  XCTest host process. Every test below that lets window?.close() run
//  for real therefore swaps NSApp.delegate for a
//  ConfirmQuitMockAppDelegate-derived mock whose removeWindowController
//  override never reaches the real, NSApp.terminate-calling
//  implementation — the exact same, already-established pattern
//  CalyxWindowControllerCloseArmsTests uses to safely exercise a real
//  window?.close() call from this exact test host (see that file's own
//  "Mocks" section header comment for the identical rationale).
//
//  NOT tested here (see this cycle's final report for the full
//  reasoning): target-list snapshotting surviving mutation during
//  iteration, and the exact interleaving of the two `for wc in targets`
//  loops (isClosingForShutdown set for every target before ANY window
//  closes, rather than interleaved one-at-a-time). Observing either
//  safely would require windowControllers to be mutated by a REAL,
//  unstubbed removeWindowController — which reintroduces the exact
//  NSApp.terminate risk this file exists to avoid. Left to manual
//  verification once the real implementation lands.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateCloseAllWindowsTests: XCTestCase {

    // MARK: - Mock

    /// Layers call recording on top of `ConfirmQuitMockAppDelegate`'s
    /// established safety overrides (`closingWouldTerminate` -> true,
    /// `removeWindowController` -> no real NSApp.terminate cascade — see
    /// that base class's own doc comment) — mirrors
    /// `CalyxWindowControllerCloseArmsTests.ConfirmingAppDelegate`'s
    /// identical "subclass the shared mock, add just what this suite
    /// needs" shape.
    private final class RecordingAppDelegate: ConfirmQuitMockAppDelegate {
        var confirmQuitIfNeededReturnValue = true
        private(set) var confirmQuitIfNeededCallCount = 0
        private(set) var removedControllers: [ObjectIdentifier] = []

        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool {
            confirmQuitIfNeededCallCount += 1
            return confirmQuitIfNeededReturnValue
        }

        override func removeWindowController(_ controller: CalyxWindowController) {
            removedControllers.append(ObjectIdentifier(controller))
            super.removeWindowController(controller)
        }
    }

    // MARK: - Fixture

    private struct SingleTabFixture {
        let controller: CalyxWindowController
    }

    /// Mirrors `CalyxWindowControllerCloseArmsTests.makeSingleTabFixture`
    /// exactly: a plain, leaf-less `Tab(title:)` (no `SurfaceRegistry`
    /// surfaces, so the real `windowWillClose` teardown loop this
    /// fixture's real `.close()` call triggers is a harmless no-op) is
    /// enough — `closeAllWindows` only needs `windowControllers`/
    /// `window?.close()`, never a live ghostty surface.
    private func makeSingleTabFixture() -> SingleTabFixture {
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

    // MARK: - Tests

    /// With no managed windows at all, closeAllWindows must be a
    /// complete no-op — in particular it must not even consult
    /// confirmQuitIfNeeded (there is nothing to confirm quitting over).
    func test_closeAllWindows_withNoWindowControllers_doesNotCallConfirmQuitIfNeeded() {
        let mock = RecordingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertEqual(mock.confirmQuitIfNeededCallCount, 0,
                       "closeAllWindows must not consult confirmQuitIfNeeded when there are no managed windows")
    }

    /// When confirmQuitIfNeeded declines (user cancelled the prompt),
    /// closeAllWindows must leave every window controller completely
    /// untouched: no window closed, no isClosingForShutdown flag set, no
    /// isTerminationConfirmed change.
    func test_closeAllWindows_withConfirmQuitIfNeededFalse_leavesWindowsUntouched() {
        let mock = RecordingAppDelegate()
        mock.confirmQuitIfNeededReturnValue = false
        let fixture = makeSingleTabFixture()
        mock._testInsertWindowController(fixture.controller)

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertEqual(mock.confirmQuitIfNeededCallCount, 1,
                       "closeAllWindows must consult confirmQuitIfNeeded exactly once when a window exists")
        XCTAssertEqual(mock.allWindowControllers.count, 1,
                       "Declining the confirm-quit prompt must not remove any window controller")
        XCTAssertTrue(mock.allWindowControllers.first === fixture.controller,
                     "The untouched controller must still be the same fixture instance")
        XCTAssertFalse(fixture.controller.isClosingForShutdown,
                       "isClosingForShutdown must stay false when confirmQuitIfNeeded declined")
        XCTAssertFalse(mock.isTerminationConfirmed,
                       "isTerminationConfirmed must stay false when confirmQuitIfNeeded declined")
        XCTAssertTrue(mock.removedControllers.isEmpty,
                      "No window may be closed (and thus no removeWindowController callback) when confirmQuitIfNeeded declined")
    }

    /// Happy path: confirmQuitIfNeeded accepts, so closeAllWindows must
    /// mark the controller as closing-for-shutdown and actually close its
    /// window — proven by the resulting REAL windowWillClose ->
    /// removeWindowController callback, not just an internal flag.
    /// Because RecordingAppDelegate's removeWindowController never
    /// empties the real (private) windowControllers array
    /// (ConfirmQuitMockAppDelegate's own no-op, called via super), the
    /// controller "survives" from closeAllWindows' own point of view, so
    /// isTerminationConfirmed must end up back at false by the time this
    /// call returns — pendingTerminationSnapshot, however, must already
    /// have been captured by the transient false -> true transition
    /// (its own didSet deliberately leaves an already-captured snapshot
    /// in place even once isTerminationConfirmed itself is reset, see
    /// that property's own doc comment in AppDelegate.swift), proving the
    /// flag really was raised before teardown, not merely left unset the
    /// whole time.
    func test_closeAllWindows_withConfirmQuitIfNeededTrue_closesWindowAndRestoresTerminationConfirmedFlag() {
        let mock = RecordingAppDelegate()
        mock.confirmQuitIfNeededReturnValue = true
        let fixture = makeSingleTabFixture()
        mock._testInsertWindowController(fixture.controller)
        XCTAssertNil(mock.pendingTerminationSnapshot,
                    "Precondition: a fresh AppDelegate must not already carry a pending termination snapshot")

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                     "closeAllWindows must set isClosingForShutdown before closing the window")
        XCTAssertEqual(mock.removedControllers, [ObjectIdentifier(fixture.controller)],
                       "The window must actually be closed for real (window?.close() -> windowWillClose -> removeWindowController)")
        XCTAssertNotNil(mock.pendingTerminationSnapshot,
                        "isTerminationConfirmed must have transitioned false -> true at some point, capturing a snapshot")
        XCTAssertFalse(mock.isTerminationConfirmed,
                       "isTerminationConfirmed must be restored to false once the controller is found to have survived")
    }
}
