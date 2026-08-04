//
//  CalyxWindowControllerCloseWindowTests.swift
//  CalyxTests
//
//  TDD RED phase, missing-observer investigation: `GhosttyActionRouter
//  .handleCloseWindow` (GhosttyAction.swift) posts `.ghosttyCloseWindow`
//  for every `GHOSTTY_ACTION_CLOSE_WINDOW` action, but no observer has
//  ever been registered for it — ghostty's default close_window keybind
//  (Cmd+Shift+W) is silently inert. `CalyxWindowController
//  .processCloseWindow()` is the intended receiver once that observer
//  exists; today it is an intentional no-op stub, and closing a real
//  window from a test is dangerous, so a `#if DEBUG` hook
//  (`_processCloseWindowHookForTesting`) observes the call instead
//  (mirrors `AppDelegate._focusWindowForExistingSessionShowHookForTesting`,
//  AppDelegate.swift:716-727 — "a hook right before the
//  actually-unsafe-to-test call").
//
//  Two kinds of test below:
//   - RED-proving (`test_processCloseWindow_...` and
//     `test_ghosttyCloseWindow_postedForOwnSurface_...`): these assert
//     the hook WAS called and currently fail, because the stub body is
//     empty and no observer is registered.
//   - Regression guards (`..._doesNotInvoke...`): these assert the hook
//     was NOT called for a scenario that should never trigger a close.
//     Since NOTHING is wired up yet, "nothing happens" is trivially true
//     for these today — they pass now and will keep passing once the
//     real observer exists, only failing if a future implementation
//     starts routing too broadly (e.g. skips the `findTab(for:)`
//     ownership check). This mirrors this codebase's own established
//     precedent for a non-RED-proving-but-still-valuable regression
//     guard: see `CalyxWindowControllerNonLastWindowCloseTests
//     .test_windowWillClose_terminatingClose_preservesSessionRefsIntoSnapshot`'s
//     doc comment ("NOT a RED-proving test... passes against BOTH the
//     current code... and the intended fix").
//
//  Fixture mirrors `CalyxWindowControllerChildExitedTasksTests
//  .makeOrdinaryPaneFixture()`: `SurfaceRegistry()` -> `SurfaceView(frame:
//  .zero)` -> `registry._testInsert(view:id:)` -> `Tab(splitTree:
//  registry:)` -> `TabGroup` -> `WindowSession` -> `CalyxWindow` ->
//  `CalyxWindowController(restoring: true)` — a real ghostty surface
//  would hang the XCTest process (SurfaceLocator.swift's header comment).

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseWindowTests: XCTestCase {

    // MARK: - Fixture

    private struct SurfaceOwningFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
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
        return SurfaceOwningFixture(controller: controller, surfaceView: surfaceView)
    }

    // MARK: - Direct call (unit-level RED)

    /// `processCloseWindow()` itself, called directly, must invoke the
    /// close hook. Against the current empty stub body, the hook is
    /// never invoked.
    func test_processCloseWindow_invokesCloseHook() {
        let fixture = makeSurfaceOwningFixture()
        var hookCalled = false
        fixture.controller._processCloseWindowHookForTesting = { hookCalled = true }

        fixture.controller.processCloseWindow()

        XCTAssertTrue(
            hookCalled,
            "processCloseWindow() must invoke the close hook (window?.performClose(nil) in production)"
        )
    }

    // MARK: - Notification post (integration-level, "Tactic A")

    /// Posting `.ghosttyCloseWindow` for a surface THIS window owns must
    /// eventually invoke the close hook. Currently fails because no
    /// observer is registered at all — the exact production bug this
    /// suite exists to catch (close_window's keybind is silently inert).
    func test_ghosttyCloseWindow_postedForOwnSurface_invokesCloseHook() {
        let fixture = makeSurfaceOwningFixture()
        var hookCalled = false
        fixture.controller._processCloseWindowHookForTesting = { hookCalled = true }

        NotificationCenter.default.post(name: .ghosttyCloseWindow, object: fixture.surfaceView)

        XCTAssertTrue(
            hookCalled,
            "Posting .ghosttyCloseWindow for a surface this window owns must invoke the close hook"
        )
    }

    /// Regression guard (NOT RED-proving — see file header): posting
    /// `.ghosttyCloseWindow` for a surface owned by a DIFFERENT window
    /// must never invoke THIS window's close hook.
    func test_ghosttyCloseWindow_postedForOtherWindowsSurface_doesNotInvokeCloseHook() {
        let ownFixture = makeSurfaceOwningFixture()
        let otherFixture = makeSurfaceOwningFixture()
        var hookCalled = false
        ownFixture.controller._processCloseWindowHookForTesting = { hookCalled = true }
        // otherFixture.controller legitimately OWNS otherFixture.surfaceView
        // (findTab(for:) succeeds for it), so it correctly reacts to the
        // notification below too -- give it a no-op hook so that reaction
        // doesn't fall through to the real `window?.performClose(nil)`.
        // Without this, that real close cascades into `windowWillClose` ->
        // `AppDelegate.removeWindowController`, whose real implementation
        // calls `NSApp.terminate(nil)` once its `windowControllers` list is
        // empty -- which it always is here, since this ad-hoc fixture
        // controller was never added to it -- silently exiting the whole
        // test process. This is the exact hazard `ConfirmQuitMockAppDelegate`
        // (CalyxTests/ConfirmQuitMockAppDelegate.swift) documents for other
        // close paths; irrelevant to what this test actually asserts (only
        // ownFixture's hook).
        otherFixture.controller._processCloseWindowHookForTesting = {}

        NotificationCenter.default.post(name: .ghosttyCloseWindow, object: otherFixture.surfaceView)

        XCTAssertFalse(
            hookCalled,
            "Posting .ghosttyCloseWindow for a surface owned by a DIFFERENT window must not invoke this " +
            "window's close hook"
        )
    }

    /// Regression guard (NOT RED-proving — see file header): an
    /// app-targeted broadcast (`object: nil`, mirroring
    /// `GhosttyActionRouter.handleCloseWindow`'s `GHOSTTY_TARGET_APP`
    /// branch, where `surfaceView(from:)` returns nil) must only affect
    /// the key window. This fixture's window is constructed but never
    /// shown/activated, so it is not key.
    func test_ghosttyCloseWindow_postedWithNilObjectWhileNotKeyWindow_doesNotInvokeCloseHook() {
        let fixture = makeSurfaceOwningFixture()
        var hookCalled = false
        fixture.controller._processCloseWindowHookForTesting = { hookCalled = true }
        XCTAssertFalse(
            fixture.controller.window?.isKeyWindow ?? true,
            "Precondition: a freshly constructed, never-shown window must not be key"
        )

        NotificationCenter.default.post(name: .ghosttyCloseWindow, object: nil)

        XCTAssertFalse(
            hookCalled,
            "An app-targeted .ghosttyCloseWindow broadcast must not invoke a non-key window's close hook"
        )
    }
}
