//
//  AppDelegateCloseAllWindowsTests.swift
//  CalyxTests
//
//  GHOSTTY_ACTION_CLOSE_ALL_WINDOWS keybind wiring (app-scoped action
//  wiring, phase 1).
//
//  Window-lifetime redesign (merged from main's "Keep Calyx running
//  after the last window closes"): this file originally pinned a
//  `closeAllWindows()` implementation that confirmed quit once up front
//  and manually raised/restored `AppDelegate.isTerminationConfirmed`
//  around the close loop. Both `isTerminationConfirmed` and
//  `closingWouldTerminate(_:)` (the helper it was computed from) were
//  deleted wholesale by the redesign, along with EVERY other close-path
//  confirm-quit prompt in this codebase -- closing a window, batched or
//  not, never terminates the app any more (see
//  `AppDelegateLastWindowClosedDoesNotTerminateTests`), so there is
//  nothing left to confirm. The current implementation (see its own doc
//  comment in `AppDelegate.swift`) is now just:
//
//      let targets = windowControllers
//      guard !targets.isEmpty else { return }
//      for wc in targets { wc.isClosingForShutdown = true }
//      for wc in targets { wc.window?.close() }
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
//  Quick Terminal invariant (previously a CRITICAL code-review finding
//  against the pre-merge implementation -- see this branch's own
//  history): with a Quick Terminal open, closing every managed window
//  must still correctly KILL (never leak/detach) every persistent
//  session behind them, honoring this codebase's "close=kill / quit=
//  detach" contract (`SessionCloseKillPolicy.swift`). Under the OLD
//  implementation this depended on a manually maintained `willTerminate`
//  flag derived from `quickTerminalController`; the CURRENT
//  implementation has no such branch left at all -- it cannot
//  special-case app-termination semantics because it never touches
//  `AppDelegate.isApplicationTerminating` in the first place any more
//  (only `applicationShouldTerminate`/`applicationWillTerminate` do).
//  `test_closeAllWindows_withQuickTerminalOpen_behavesIdenticallyToWithoutIt`
//  below proves this directly: `isApplicationTerminating` -- the ONE
//  discriminator `CalyxWindowController.windowWillClose`'s destroy loop
//  and `killSessionIfPersistent` both consult (see each's own doc
//  comment) to decide kill vs. preserve -- stays `false` throughout
//  regardless of whether a quick terminal is open, so every closed
//  window's persistent sessions are genuinely killed either way.
//
//  NOT tested here (mirrors this file's own pre-merge scope limit):
//  target-list snapshotting surviving mutation during
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
    /// established safety override (`removeWindowController` -> no real
    /// save/terminate cascade -- see that base class's own doc comment)
    /// -- mirrors `CalyxWindowControllerCloseArmsTests.ConfirmingAppDelegate`'s
    /// identical "subclass the shared mock, add just what this suite
    /// needs" shape. `confirmQuitIfNeeded` is still overridden (never
    /// left to reach the real implementation) purely as a safety net: if
    /// a future regression reintroduces a call to it from
    /// `closeAllWindows`, this override records it instead of blocking
    /// the test host on a real `NSAlert.runModal()`.
    private final class RecordingAppDelegate: ConfirmQuitMockAppDelegate {
        private(set) var confirmQuitIfNeededCallCount = 0
        private(set) var removedControllers: [ObjectIdentifier] = []

        override func confirmQuitIfNeeded() -> Bool {
            confirmQuitIfNeededCallCount += 1
            return true
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
    /// complete no-op.
    func test_closeAllWindows_withNoWindowControllers_doesNothing() {
        let mock = RecordingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertTrue(mock.removedControllers.isEmpty,
                      "closeAllWindows must not close anything when there are no managed windows")
        XCTAssertEqual(mock.confirmQuitIfNeededCallCount, 0,
                       "closeAllWindows must not consult confirmQuitIfNeeded when there is nothing to close")
    }

    /// Window-lifetime redesign: no close path confirms quit any more --
    /// closeAllWindows must never consult confirmQuitIfNeeded at all,
    /// replacing this file's pre-merge "confirm once up front" contract
    /// entirely.
    func test_closeAllWindows_neverConsultsConfirmQuitIfNeeded() {
        let mock = RecordingAppDelegate()
        let fixture = makeSingleTabFixture()
        mock._testInsertWindowController(fixture.controller)

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertEqual(mock.confirmQuitIfNeededCallCount, 0,
                       "closeAllWindows must not show any quit confirmation any more -- closing windows, " +
                       "one or all of them, never terminates the app, and confirmQuitIfNeeded's own doc " +
                       "comment documents applicationShouldTerminate (Cmd+Q) as its one legitimate caller")
    }

    /// Happy path: closeAllWindows must mark the controller as
    /// closing-for-shutdown BEFORE actually closing its window -- proven
    /// by the resulting REAL windowWillClose -> removeWindowController
    /// callback, not just an internal flag.
    func test_closeAllWindows_setsIsClosingForShutdownAndClosesWindowForReal() {
        let mock = RecordingAppDelegate()
        let fixture = makeSingleTabFixture()
        mock._testInsertWindowController(fixture.controller)
        XCTAssertFalse(fixture.controller.isClosingForShutdown, "Precondition: a fresh fixture is not closing")

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                     "closeAllWindows must set isClosingForShutdown before closing the window")
        XCTAssertEqual(mock.removedControllers, [ObjectIdentifier(fixture.controller)],
                       "The window must actually be closed for real (window?.close() -> windowWillClose -> " +
                       "removeWindowController)")
    }

    /// Batch variant of the happy path above: every target in a
    /// multi-window batch must be marked and closed, not just the first
    /// -- exercises both `for wc in targets` loops across more than one
    /// controller.
    func test_closeAllWindows_withMultipleWindows_closesEveryOne() {
        let mock = RecordingAppDelegate()
        let first = makeSingleTabFixture()
        let second = makeSingleTabFixture()
        mock._testInsertWindowController(first.controller)
        mock._testInsertWindowController(second.controller)

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertTrue(first.controller.isClosingForShutdown, "The first window must be marked closing")
        XCTAssertTrue(second.controller.isClosingForShutdown, "The second window must be marked closing too")
        XCTAssertEqual(Set(mock.removedControllers),
                       Set([ObjectIdentifier(first.controller), ObjectIdentifier(second.controller)]),
                       "Both windows must actually be closed for real")
    }

    /// CRITICAL 1 regression (pre-merge code review; see this branch's
    /// own history): with a Quick Terminal open, closing every managed
    /// window must behave IDENTICALLY to closing them with no quick
    /// terminal open at all, proving there is no special-casing left
    /// that could preserve/leak a persistent session instead of killing
    /// it.
    func test_closeAllWindows_withQuickTerminalOpen_behavesIdenticallyToWithoutIt() {
        let mock = RecordingAppDelegate()
        let fixture = makeSingleTabFixture()
        mock._testInsertWindowController(fixture.controller)
        mock._setQuickTerminalControllerForTesting(QuickTerminalController())

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            mock.closeAllWindows()
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                     "closeAllWindows must still mark every target as closing-for-shutdown even when a " +
                     "quick terminal is open -- this flag means \"this window's own teardown is underway\", " +
                     "not \"the app is terminating\"")
        XCTAssertEqual(mock.removedControllers, [ObjectIdentifier(fixture.controller)],
                       "The window must still actually be closed for real even when a quick terminal is open")
        XCTAssertEqual(mock.confirmQuitIfNeededCallCount, 0,
                       "...and still without ever consulting confirmQuitIfNeeded")
        XCTAssertFalse(mock.isApplicationTerminating,
                       "isApplicationTerminating must stay false throughout -- with no branch left in " +
                       "closeAllWindows that could set it, every closed window's windowWillClose sees " +
                       "isAppActuallyTerminating == false and genuinely kills (never preserves/leaks) its " +
                       "own persistent sessions, exactly as an ordinary individual close would, quick " +
                       "terminal open or not")
    }
}
