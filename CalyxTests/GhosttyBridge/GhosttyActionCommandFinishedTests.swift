// GhosttyActionCommandFinishedTests.swift
// CalyxTests
//
// GHOSTTY_ACTION_COMMAND_FINISHED (apprt.action.CommandFinished, ghostty.h)
// is surface-scoped (apprt.Target.Key) and OSC-133-triggered, not a
// keybind action, so it does not belong in GhosttyActionNoOpActionsTests'
// consumed/not-consumed rationale (see that file's own header comment).
// Its handler follows the guard-let pattern already established by
// handleProgressReport and every other surface-required handler in
// GhosttyAction.swift: a target that cannot resolve to a SurfaceView
// returns false rather than true. There is no keybind here whose raw key
// sequence would otherwise wrongly fall through to the shell, so the
// return-true-to-mark-consumed rationale the no-op group relies on does
// not apply.
//
// Two target shapes reach handleAction without ever calling libghostty's
// FFI (GhosttyAppController.surfaceView(from:) dereferences a live
// ghostty_surface_t and traps for a fake one, per the "Second
// Missing-Observer Investigation" comment block in GhosttyAction.swift):
// GHOSTTY_TARGET_APP, and GHOSTTY_TARGET_SURFACE with its union's
// surface pointer left zero-initialized. GhosttyActionRouter
// .surfaceView(from:) returns nil for both without ever touching a
// surface pointee in the second case: its `guard let surface =
// target.target.surface else { return nil }` check fails on the null
// pointer itself, before GhosttyAppController.surfaceView(from:) is ever
// called. Both shapes are therefore safely testable "cannot resolve"
// cases with the same expected result, false.
//
// A surface target that DOES resolve, so the notification the handler
// posts can be inspected end to end, needs a live ghostty_surface_t,
// which needs a running libghostty app, not available to a unit test
// (the same wall GhosttyAction.swift's own "Second Missing-Observer
// Investigation" comment block documents for its own six handlers).
//
// The handler's exit-code payload conversion is pinned independently of
// that wall below, against GhosttyActionRouter.commandFinishedExitCode(_:),
// the seam handleCommandFinished calls to build its notification payload.
// Its contract: take the raw Int16 ghostty_action_command_finished_s
// .exit_code payload, return Int32? for
// AgentRegistry.handleGhosttyCommandFinished's exitCode parameter,
// mapping ghostty's own -1 ("no exit code was reported") sentinel to
// nil and passing every other value through unchanged. A small pure
// mapper with no target/surface dependency at all, so it is reachable
// without the FFI trap risk above.

import Foundation
import Testing
import GhosttyKit
@testable import Calyx

@MainActor
@Suite("GhosttyAction Command Finished Tests")
struct GhosttyActionCommandFinishedTests {

    /// Mirrors GhosttyActionNoOpActionsTests.dummyApp: never dereferenced
    /// on either "cannot resolve a surface" path below.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    private func makeAppTarget() -> ghostty_target_s {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        return target
    }

    /// `ghostty_target_s()` zero-initializes `target.target.surface` to a
    /// null pointer. Tagging it GHOSTTY_TARGET_SURFACE without setting
    /// that pointer reaches `surfaceView(from:)`'s null-pointer branch,
    /// which returns before ever calling
    /// `GhosttyAppController.surfaceView(from:)`, the one call that would
    /// dereference a real `ghostty_surface_t` and trap for a fake
    /// pointer. See this file's own header comment for why that makes
    /// this shape safe to construct.
    private func makeUnresolvableSurfaceTarget() -> ghostty_target_s {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        return target
    }

    private func makeCommandFinishedAction(exitCode: Int16 = 0, durationNs: UInt64 = 0) -> ghostty_action_s {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_COMMAND_FINISHED
        action.action.command_finished = ghostty_action_command_finished_s(
            exit_code: exitCode, duration: durationNs
        )
        return action
    }

    // MARK: - handleAction: unresolvable target

    @Test("APP target is not consumed")
    func appTargetReturnsFalse() {
        let handled = GhosttyActionRouter.handleAction(
            app: dummyApp, target: makeAppTarget(), action: makeCommandFinishedAction()
        )

        #expect(handled == false)
    }

    @Test("SURFACE target with no resolvable surface is not consumed")
    func unresolvableSurfaceTargetReturnsFalse() {
        let handled = GhosttyActionRouter.handleAction(
            app: dummyApp, target: makeUnresolvableSurfaceTarget(), action: makeCommandFinishedAction()
        )

        #expect(handled == false)
    }

    // MARK: - Payload conversion (GhosttyActionRouter.commandFinishedExitCode)

    // ghostty_action_command_finished_s.exit_code (ghostty.h) is an
    // Int16 with -1 as its own sentinel for "no exit code was reported."
    // AgentRegistry.handleGhosttyCommandFinished takes Int32? like its
    // handlePaneCommandFinished sibling, so this GhosttyKit-specific
    // sentinel must be translated to nil before crossing into the
    // notification this handler posts -- AgentRegistry itself stays free
    // of any GhosttyKit dependency, matching the rest of this router's
    // role of translating libghostty's C payloads into Swift-native
    // shapes before they leave GhosttyAction.swift. Stop-signal exit
    // codes (146 and friends) are deliberately NOT filtered here: that
    // exclusion is AgentRegistry.handleGhosttyCommandFinished's own job
    // (see AgentRegistryTests' handleGhosttyCommandFinished coverage), so
    // this mapper passes one through unchanged to confirm it does not
    // duplicate that decision.
    //
    // This helper has no target/surface parameter at all, so it is
    // reachable without GhosttyAppController.surfaceView(from:) and its
    // FFI trap risk for a fake pointer -- unlike the handler itself, its
    // payload-to-notification conversion is fully unit-testable.

    @Test("commandFinishedExitCode maps ghostty's -1 sentinel to nil")
    func commandFinishedExitCodeMapsSentinelToNil() {
        #expect(GhosttyActionRouter.commandFinishedExitCode(-1) == nil)
    }

    @Test("commandFinishedExitCode passes a clean exit through unchanged")
    func commandFinishedExitCodePassesZeroThrough() {
        #expect(GhosttyActionRouter.commandFinishedExitCode(0) == 0)
    }

    @Test("commandFinishedExitCode passes an ordinary failure code through unchanged")
    func commandFinishedExitCodePassesOrdinaryCodeThrough() {
        #expect(GhosttyActionRouter.commandFinishedExitCode(1) == 1)
    }

    @Test("commandFinishedExitCode passes a stop-signal code through unchanged")
    func commandFinishedExitCodePassesStopSignalCodeThrough() {
        // 146 = 128 + SIGTSTP: this mapper must not itself apply the
        // stop-signal exclusion, only AgentRegistry does.
        #expect(GhosttyActionRouter.commandFinishedExitCode(146) == 146)
    }

    // MARK: - Notification name

    @Test("ghosttyCommandFinished notification name is defined")
    func commandFinishedNotificationNameDefined() {
        #expect(Notification.Name.ghosttyCommandFinished.rawValue == "com.calyx.ghostty.commandFinished")
    }
}
