// GhosttyActionNoOpActionsTests.swift
// CalyxTests
//
// Second missing-observer investigation, no-op batch (not a RED-phase
// suite — these four are already fully implemented in GhosttyActionRouter
// .handleAction, GhosttyBridge/GhosttyAction.swift, so every test below is
// expected to PASS).
//
// GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW / SHOW_GTK_INSPECTOR /
// SHOW_ON_SCREEN_KEYBOARD / COMMAND_FINISHED moved out of the "Known but
// unimplemented" (`return false`) group into their own "Intentional
// No-Ops" group (`return true`) — see each case's own comment in
// GhosttyAction.swift for the full per-action rationale (GTK/iOS-only
// capabilities Calyx has nothing to route to, or, for COMMAND_FINISHED,
// a signal Calyx already replaced with its own shell-integration hook).
// `return false` told libghostty the triggering keybind was NOT consumed,
// so the raw key sequence fell through to the shell; `return true` fixes
// that by marking it consumed instead.
//
// Only `GHOSTTY_TARGET_APP` is exercised here, with a fake, never-
// dereferenced `ghostty_app_t` (`void*` per ghostty.h) — sound only
// because none of these four handlers ever calls `surfaceView(from:)` or
// otherwise dereferences `app`/`target`; each returns `true`
// unconditionally, regardless of target. Do not add other actions to this
// suite: e.g. `GHOSTTY_ACTION_CHECK_FOR_UPDATES` would construct
// `UpdateController.shared`, whose `init` starts Sparkle.

import Testing
import GhosttyKit
@testable import Calyx

@MainActor
@Suite("GhosttyAction No-Op Actions Tests")
struct GhosttyActionNoOpActionsTests {

    /// `ghostty_app_t` is `void*` (ghostty.h) and is never dereferenced by
    /// any of these four handlers, so a non-null, otherwise-meaningless
    /// pointer is safe to pass — mirrors the same `UnsafeMutableRawPointer
    /// (bitPattern: 1)!` pattern already established by
    /// `AppDelegateRestoreRemoteSessionTests`/`CockpitAppAccessSeamTests`/etc.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    /// `ghostty_target_s()`/`ghostty_action_s()` zero-initialize every
    /// field (imported C structs get a memberwise-zero `init()` in
    /// addition to the field-by-field one); only `.tag` is set here. The
    /// unused `target.target.surface` union member staying zero/nil is
    /// fine — these four handlers never read it.
    private func makeAppTarget() -> ghostty_target_s {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        return target
    }

    @Test("TOGGLE_TAB_OVERVIEW is treated as consumed")
    func toggleTabOverviewReturnsTrue() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW

        #expect(GhosttyActionRouter.handleAction(app: dummyApp, target: makeAppTarget(), action: action))
    }

    @Test("SHOW_GTK_INSPECTOR is treated as consumed")
    func showGTKInspectorReturnsTrue() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SHOW_GTK_INSPECTOR

        #expect(GhosttyActionRouter.handleAction(app: dummyApp, target: makeAppTarget(), action: action))
    }

    @Test("SHOW_ON_SCREEN_KEYBOARD is treated as consumed")
    func showOnScreenKeyboardReturnsTrue() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD

        #expect(GhosttyActionRouter.handleAction(app: dummyApp, target: makeAppTarget(), action: action))
    }

    @Test("COMMAND_FINISHED is treated as consumed")
    func commandFinishedReturnsTrue() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_COMMAND_FINISHED

        #expect(GhosttyActionRouter.handleAction(app: dummyApp, target: makeAppTarget(), action: action))
    }
}
