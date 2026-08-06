//
//  AppDelegateCloseAllWindowsTests.swift
//  CalyxTests
//
//  TDD Red phase: GHOSTTY_ACTION_CLOSE_ALL_WINDOWS keybind wiring
//  (app-scoped action wiring, phase 1). `AppDelegate.closeAllWindows()`
//  is currently an empty do-nothing stub — `GhosttyActionRouter
//  .handleAction` has no case for `GHOSTTY_ACTION_CLOSE_ALL_WINDOWS` yet.
//
//  Real behavior under test (current implementation, post code-review
//  CRITICAL-1 fix — see that fix's own doc comment on
//  AppDelegate.closeAllWindows() for the full "why"):
//
//      let targets = windowControllers
//      guard !targets.isEmpty else { return }
//      guard confirmQuitIfNeeded() else { return }
//      let willTerminate = quickTerminalController == nil
//      if willTerminate {
//          isTerminationConfirmed = true
//      }
//      for wc in targets { wc.isClosingForShutdown = true }
//      for wc in targets { wc.window?.close() }
//      if willTerminate, !windowControllers.isEmpty {
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
//  CODE REVIEW fix (CRITICAL 1): the quick-terminal-open interaction
//  this section used to call "left to manual verification" is now
//  covered directly below
//  (test_closeAllWindows_withQuickTerminalOpen_neverRaisesIsTerminationConfirmed),
//  via the new `_setQuickTerminalControllerForTesting` seam
//  (AppDelegate.swift) — a bare `QuickTerminalController()` is safe to
//  construct in-process (see that seam's own doc comment: its `init`
//  neither opens a window nor creates a ghostty surface). RecordingAppDelegate
//  below now also overrides `saveImmediately()` as a pure call-count spy,
//  mirroring CalyxWindowControllerLastWindowCloseSaveTests'
//  SaveOnCloseSpyAppDelegate exactly, so exercising the (now legitimately
//  reachable, quick-terminal-open) synchronous-save path never hits the
//  real SessionPersistenceActor.shared and writes to the developer's
//  actual ~/.calyx.
//
//  NOT tested here (see this cycle's final report for the full
//  reasoning): target-list snapshotting surviving mutation during
//  iteration, and the exact interleaving of the two `for wc in targets`
//  loops (isClosingForShutdown set for every target before ANY window
//  closes, rather than interleaved one-at-a-time). Observing either
//  safely would require windowControllers to be mutated by a REAL,
//  unstubbed removeWindowController — which reintroduces the exact
//  NSApp.terminate risk this file exists to avoid. Left to manual
//  verification.
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
        /// CODE REVIEW addition (CRITICAL 1): spies on `saveImmediately()`
        /// WITHOUT calling through to the real implementation, which would
        /// hit `SessionPersistenceActor.shared` and write to the
        /// developer's actual `~/.calyx` — mirrors
        /// `CalyxWindowControllerLastWindowCloseSaveTests.SaveOnCloseSpyAppDelegate`'s
        /// identical override, now exercisable here too since the fixed
        /// `closeAllWindows()` can legitimately reach this call (when a
        /// quick terminal is open, see the new
        /// `test_closeAllWindows_withQuickTerminalOpen_...` test below).
        private(set) var saveImmediatelyCallCount = 0

        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool {
            confirmQuitIfNeededCallCount += 1
            return confirmQuitIfNeededReturnValue
        }

        override func removeWindowController(_ controller: CalyxWindowController) {
            removedControllers.append(ObjectIdentifier(controller))
            super.removeWindowController(controller)
        }

        override func saveImmediately() {
            saveImmediatelyCallCount += 1
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
        XCTAssertEqual(mock.saveImmediatelyCallCount, 0,
                       "With no quick terminal open, this close genuinely terminates the app, so " +
                       "windowWillClose's own isAppActuallyTerminating gate must already read true by " +
                       "the time it runs and skip saveImmediately() entirely -- the only legitimate " +
                       "termination-time save is applicationWillTerminate's saveForTermination()")
    }

    /// CRITICAL 1 regression (code review): with a Quick Terminal open,
    /// closing every managed window does NOT terminate the app (the quick
    /// terminal keeps it alive) -- closeAllWindows must therefore NEVER
    /// raise isTerminationConfirmed, exactly like every other close path
    /// in this file already gates on `quickTerminalController == nil`
    /// (see closingWouldTerminate's own doc comment).
    ///
    /// Before the fix, closeAllWindows raised isTerminationConfirmed
    /// unconditionally, which (1) made windowWillClose's destroy loop
    /// treat every persistent session in every closed window as
    /// "preserve for restart" instead of "kill" -- SessionCloseKillPolicy
    /// .shouldTearDown requires `!isTerminating`, so those sessions would
    /// leak as headless orphans instead of being killed, contradicting
    /// this codebase's own "close=kill / quit=detach" contract -- and (2)
    /// skipped the last window's pre-teardown saveImmediately(), leaving
    /// the on-disk snapshot stale, since the app never actually
    /// terminates and applicationWillTerminate/saveForTermination()
    /// therefore never runs either to save it some other way.
    ///
    /// Asserted via `pendingTerminationSnapshot` staying `nil` throughout
    /// (its own didSet only fires -- and captures -- on a false -> true
    /// transition, and NEVER clears once captured, see that property's
    /// own doc comment), which is exactly what makes it able to catch a
    /// transient true-then-false raise, not just an end-state read of
    /// `isTerminationConfirmed`: the OLD buggy code's own trailing guard
    /// already restored `isTerminationConfirmed` back to `false` whenever
    /// `quickTerminalController != nil`, so asserting only the flag's
    /// final value would pass even against the bug (this is precisely
    /// what `test_closeAllWindows_withConfirmQuitIfNeededTrue_...` above
    /// uses `pendingTerminationSnapshot` to prove happened in the
    /// terminating case). `saveImmediatelyCallCount == 1` proves the
    /// second symptom's fix directly: the last window's synchronous save
    /// now correctly fires, exactly as it would for closing that same
    /// window individually while other windows/a quick terminal stay
    /// open.
    func test_closeAllWindows_withQuickTerminalOpen_neverRaisesIsTerminationConfirmed() {
        let mock = RecordingAppDelegate()
        mock.confirmQuitIfNeededReturnValue = true
        let fixture = makeSingleTabFixture()
        mock._testInsertWindowController(fixture.controller)
        mock._setQuickTerminalControllerForTesting(QuickTerminalController())
        XCTAssertNil(mock.pendingTerminationSnapshot,
                    "Precondition: a fresh AppDelegate must not already carry a pending termination snapshot")

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                     "closeAllWindows must still mark every target as closing-for-shutdown even when " +
                     "a quick terminal is open -- this flag means \"this window's own teardown is " +
                     "underway\", not \"the app is terminating\"")
        XCTAssertEqual(mock.removedControllers, [ObjectIdentifier(fixture.controller)],
                       "The window must still actually be closed for real even when a quick terminal is open")
        XCTAssertNil(mock.pendingTerminationSnapshot,
                     "isTerminationConfirmed must NEVER transition to true while a quick terminal keeps " +
                     "the app alive -- raising it even transiently would make every closed window's " +
                     "windowWillClose wrongly treat itself as an app-terminating close (preserving " +
                     "instead of killing persistent sessions, and skipping the pre-teardown save)")
        XCTAssertFalse(mock.isTerminationConfirmed,
                       "isTerminationConfirmed must stay false throughout when a quick terminal is open")
        XCTAssertEqual(mock.saveImmediatelyCallCount, 1,
                       "The last window's pre-teardown synchronous save must still fire when the app " +
                       "does not actually terminate (a quick terminal keeps it alive), exactly as " +
                       "closing that same window individually would -- otherwise the on-disk snapshot " +
                       "is left stale with no other save ever reaching disk")
    }
}
