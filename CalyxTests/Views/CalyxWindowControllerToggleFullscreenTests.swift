//
//  CalyxWindowControllerToggleFullscreenTests.swift
//  CalyxTests
//
//  Missing observer: `GhosttyActionRouter
//  .handleToggleFullscreen` (GhosttyAction.swift) posts
//  `.ghosttyToggleFullscreen` for every `GHOSTTY_ACTION_TOGGLE_FULLSCREEN`
//  action, but no observer has ever been registered for it — ghostty's
//  default toggle_fullscreen keybinds (Ctrl+Cmd+F and Cmd+Enter) are
//  silently inert. `CalyxWindowController.processToggleFullscreen(mode:)`
//  is the intended receiver once that observer exists; today it is an
//  intentional no-op stub. `window.toggleFullScreen(nil)` requires a real
//  `NSScreen` and is asynchronous (see
//  `CalyxWindowControllerFullScreenTests.swift`'s header comment), so a
//  `#if DEBUG` hook (`_processToggleFullscreenHookForTesting`) observes
//  the call instead, mirroring `CalyxWindowControllerCloseWindowTests`'s
//  `_processCloseWindowHookForTesting`.
//
//  As in `CalyxWindowControllerCloseWindowTests` (see that file's header
//  for the full reasoning), the "own surface" tests below are
//  the ones that pin the fix (without it no observer exists), and the "other window"
//  test is a regression guard (passes vacuously today, guards a future
//  over-broad implementation). `shouldUseNativeFullscreen(for:)`'s tests
//  fully pin the fix: the pre-fix stub unconditionally returned
//  `false`, so every case (expecting `true`) failed for a real reason.
//
//  Fixture mirrors `CalyxWindowControllerCloseWindowTests
//  .makeSurfaceOwningFixture()` (itself mirroring
//  `CalyxWindowControllerChildExitedTasksTests.makeOrdinaryPaneFixture()`).

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerToggleFullscreenTests: XCTestCase {

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

    // MARK: - Direct call (unit level)

    /// `processToggleFullscreen(mode:)`, called directly, must invoke the
    /// fullscreen hook. Against the current empty stub body, the hook is
    /// never invoked.
    func test_processToggleFullscreen_invokesFullscreenHook() {
        let fixture = makeSurfaceOwningFixture()
        var hookCalled = false
        fixture.controller._processToggleFullscreenHookForTesting = { hookCalled = true }

        fixture.controller.processToggleFullscreen(mode: GHOSTTY_FULLSCREEN_NATIVE)

        XCTAssertTrue(
            hookCalled,
            "processToggleFullscreen(mode:) must invoke the fullscreen hook (window.toggleFullScreen(nil) " +
            "in production)"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Posting `.ghosttyToggleFullscreen` for a surface THIS window owns
    /// must eventually invoke the fullscreen hook. Currently fails
    /// because no observer is registered at all.
    func test_ghosttyToggleFullscreen_postedForOwnSurface_invokesFullscreenHook() {
        let fixture = makeSurfaceOwningFixture()
        var hookCalled = false
        fixture.controller._processToggleFullscreenHookForTesting = { hookCalled = true }

        NotificationCenter.default.post(
            name: .ghosttyToggleFullscreen,
            object: fixture.surfaceView,
            userInfo: ["mode": GHOSTTY_FULLSCREEN_NATIVE]
        )

        XCTAssertTrue(
            hookCalled,
            "Posting .ghosttyToggleFullscreen for a surface this window owns must invoke the fullscreen hook"
        )
    }

    /// Regression guard (see file header): posting
    /// `.ghosttyToggleFullscreen` for a surface owned by a DIFFERENT
    /// window must never invoke THIS window's fullscreen hook.
    func test_ghosttyToggleFullscreen_postedForOtherWindowsSurface_doesNotInvokeFullscreenHook() {
        let ownFixture = makeSurfaceOwningFixture()
        let otherFixture = makeSurfaceOwningFixture()
        var hookCalled = false
        ownFixture.controller._processToggleFullscreenHookForTesting = { hookCalled = true }
        // otherFixture.controller legitimately OWNS otherFixture.surfaceView
        // (findTab(for:) succeeds for it), so it correctly reacts to the
        // notification below too -- give it a no-op hook so that reaction
        // doesn't fall through to the real `toggleFullScreen(nil)`, which
        // requires a real NSScreen and is asynchronous (see this file's own
        // header and CalyxWindowControllerFullScreenTests.swift's). Mirrors
        // CalyxWindowControllerCloseWindowTests' identical fixture fix for
        // the identical hazard.
        otherFixture.controller._processToggleFullscreenHookForTesting = {}

        NotificationCenter.default.post(
            name: .ghosttyToggleFullscreen,
            object: otherFixture.surfaceView,
            userInfo: ["mode": GHOSTTY_FULLSCREEN_NATIVE]
        )

        XCTAssertFalse(
            hookCalled,
            "Posting .ghosttyToggleFullscreen for a surface owned by a DIFFERENT window must not invoke " +
            "this window's fullscreen hook"
        )
    }

    // MARK: - shouldUseNativeFullscreen(for:) — pure function

    /// Native mode must resolve to native (the trivial case).
    func test_shouldUseNativeFullscreen_true_forNativeMode() {
        XCTAssertTrue(CalyxWindowController.shouldUseNativeFullscreen(for: GHOSTTY_FULLSCREEN_NATIVE))
    }

    /// Non-native mode must STILL fall back to native — Calyx has no
    /// non-native fullscreen presentation of its own.
    func test_shouldUseNativeFullscreen_true_forNonNativeMode() {
        XCTAssertTrue(CalyxWindowController.shouldUseNativeFullscreen(for: GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE))
    }

    /// Non-native "visible menu" mode must also fall back to native.
    func test_shouldUseNativeFullscreen_true_forNonNativeVisibleMenuMode() {
        XCTAssertTrue(
            CalyxWindowController.shouldUseNativeFullscreen(for: GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU)
        )
    }

    /// Non-native "padded notch" mode must also fall back to native.
    func test_shouldUseNativeFullscreen_true_forNonNativePaddedNotchMode() {
        XCTAssertTrue(
            CalyxWindowController.shouldUseNativeFullscreen(for: GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH)
        )
    }

    /// A `nil` mode (the notification handler found no `"mode"` key at
    /// all) must ALSO fall back to native, not silently no-op.
    func test_shouldUseNativeFullscreen_true_forNilMode() {
        XCTAssertTrue(CalyxWindowController.shouldUseNativeFullscreen(for: nil))
    }
}
