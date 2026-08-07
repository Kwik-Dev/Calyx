//
//  QuickTerminalControllerRequestHideTests.swift
//  CalyxTests
//
//  TDD Red phase, GitHub issue #45. Full root-cause writeup:
//  `NSWindow+CalyxClose.swift`'s header comment.
//
//  `QuickTerminalController.requestHide()` is
//  `QuickTerminalWindow.calyxPerformClose(_:)`'s intended receiver: Cmd+W
//  on the quick terminal must HIDE it (mirroring the existing
//  `windowDidResignKey`/`autoHide` -> `animateOut()` path), never close/
//  destroy the window for real — a persistent-session surface behind it
//  must survive a Cmd+W exactly like it survives an autoHide.
//
//  `QuickTerminalController()` is safe to construct directly: its
//  `init` only registers notification observers (`.ghosttyConfigChange`
//  and `.ghosttyCloseSurface`), and neither creates a window nor a
//  ghostty surface (both deferred to `animateIn()`/`ensureSurface()`,
//  never called here) — see
//  `AppDelegate._setQuickTerminalControllerForTesting`'s own doc
//  comment (AppDelegate.swift) for this exact guarantee. The
//  `visible == true` case below uses the `_setVisibleForTesting`/
//  `_requestHideHookForTesting` seams instead of a real `animateIn()`/
//  `animateOut()` call, both of which need a real `NSScreen` and drive a
//  real window animation — unsafe in this test host.
//
//  RED ledger (ran 2026-08-07):
//   - `test_requestHide_whenVisible_invokesHideHook` was RED-proving:
//     `requestHide()`'s body was an empty stub then, so the hook was
//     never invoked. It is implemented now and this test passes.
//   - `test_requestHide_whenNotVisible_isNoOp` is NOT RED-proving
//     (regression guard only): "no-op when not visible" is behaviorally
//     identical to "does nothing at all", which the empty stub already
//     satisfied. Kept because it is the literal behavior the task brief
//     requires, and it still has real teeth against a future
//     implementation that calls the hook (or otherwise acts)
//     unconditionally, forgetting its own `visible` guard.
//

import XCTest
@testable import Calyx

@MainActor
final class QuickTerminalControllerRequestHideTests: XCTestCase {

    // MARK: - Not visible: no-op (regression guard)

    func test_requestHide_whenNotVisible_isNoOp() {
        let controller = QuickTerminalController()
        XCTAssertFalse(controller.visible, "Precondition: a freshly constructed controller starts hidden")
        var hookCalled = false
        controller._requestHideHookForTesting = { hookCalled = true }

        controller.requestHide()

        XCTAssertFalse(hookCalled, "requestHide() must not attempt to hide anything when already not visible")
        XCTAssertFalse(controller.visible, "requestHide() must not flip visible when it was already false")
    }

    // MARK: - Visible: hides (RED-proving)

    func test_requestHide_whenVisible_invokesHideHook() {
        let controller = QuickTerminalController()
        controller._setVisibleForTesting(true)
        var hookCalled = false
        controller._requestHideHookForTesting = { hookCalled = true }

        controller.requestHide()

        XCTAssertTrue(hookCalled, "requestHide() must attempt to hide (animateOut() in production) when visible")
    }
}
