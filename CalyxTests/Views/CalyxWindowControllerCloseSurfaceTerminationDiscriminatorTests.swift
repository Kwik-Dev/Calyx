//
//  CalyxWindowControllerCloseSurfaceTerminationDiscriminatorTests.swift
//  CalyxTests
//
//  TDD Red phase, window-lifetime redesign: `closeSurfaceAndCleanUp`'s
//  kill decision (CalyxWindowController.swift ~:2305) still calls
//  `killSessionIfPersistent(tab:surfaceID:isTerminating: isClosingForShutdown)`
//  -- reading the per-WINDOW `isClosingForShutdown` flag as its "is this
//  actually a quit" signal. That is exactly the discriminator-mismatch
//  class `CalyxWindowControllerNonLastWindowCloseTests`'s R8-C fix
//  already closed for `windowWillClose`'s OWN teardown loop (which
//  correctly reads `isAppActuallyTerminating` instead -- see that file's
//  header comment and its
//  `test_windowWillClose_isClosingForShutdownTrueButAppNotTerminating_stillKillsPersistentSession`)
//  -- but never for THIS call site, reached via
//  `handleCloseSurfaceNotification`/`processCloseSurface`, not
//  `windowWillClose`.
//
//  Under the window-lifetime redesign, closing one of several open
//  windows sets `isClosingForShutdown = true` for THAT window (via
//  `closeLastWindow`/`windowShouldClose`) even though the app itself
//  stays alive (closing a window no longer terminates Calyx at all, see
//  `AppDelegateLastWindowClosedDoesNotTerminateTests`). If a pane's
//  process exits (ghostty's `close_surface` callback,
//  `handleCloseSurfaceNotification`) WHILE that window happens to be
//  mid-close, the session backing it must still be genuinely KILLED,
//  exactly like an ordinary `closeTab` does -- not silently left running
//  because `isClosingForShutdown` happened to be `true` for an unrelated
//  reason.
//
//  Against the CURRENT code: `killSessionIfPersistent` is called with
//  `isTerminating: true` (this window's own `isClosingForShutdown`, set
//  directly by this test), and
//  `SessionCloseKillPolicy.shouldKill(hasSession: true, isTerminating:
//  true, isReconnectSwap: false)` is `false` ("must detach, not kill",
//  see `SessionCloseKillPolicyTests`'s truth table) -- so the session is
//  left registered, not killed. RED.
//
//  Drives `handleCloseSurfaceNotification` via the real
//  `NotificationCenter` post it's wired to (mirrors
//  `SessionReconnectGiveUpTests
//  .test_handleCloseSurfaceNotification_deferredWhileConfirmingQuit_thenReplayedAfterGateClears`'s
//  own posting pattern), against `TwoPaneSessionFixture` (this codebase's
//  shared two-pane fixture, see its own header comment): removing the
//  tracked leaf leaves the untracked sibling leaf in place, so this only
//  exercises `closeSurfaceAndCleanUp`'s "tab still has leaves" branch,
//  never reaching `window?.close()` / `AppDelegate.removeWindowController`
//  at all. `isClosingForShutdown` is set directly by this test, not
//  produced by a real close cascade, and `killSessionIfPersistent`'s real
//  (fire-and-forget) `SessionDaemonClient.shared.kill(id:)` call for this
//  fake session ID is the same already-accepted pattern
//  `CalyxWindowControllerRemoteKillRoutingTests` already exercises via
//  the identical `_killSessionIfPersistentRouteObserverForTesting` seam.
//
//  `NSApp.delegate` IS still swapped for `RequestSaveSpyAppDelegate`
//  below, despite never reaching `window?.close()`: the "tab still has
//  leaves" branch this test exercises ends with its own `requestSave()`
//  call, which -- against the REAL, ambient `AppDelegate` this test host
//  installs -- reaches `SessionPersistenceActor.shared` and risks writing
//  to the developer's actual `~/.calyx` (confirmed by observation, see
//  that mock's own doc comment).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseSurfaceTerminationDiscriminatorTests: XCTestCase {

    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    private func makeFixture() -> TwoPaneSessionFixture {
        let fixture = makeTwoPaneSessionFixture()
        registeredSessionIDs.append(fixture.sessionID)
        return fixture
    }

    /// Neutral `AppDelegate` stand-in swapped into `NSApp.delegate` for
    /// this file's test: not terminating, not confirming quit (defaults
    /// unchanged), so `deferOrRun`'s `isConfirmingQuit` check lets the
    /// notification run synchronously exactly like production. Exists
    /// purely so `requestSave()` never reaches the REAL
    /// `AppDelegate.requestSave()` -> `SessionPersistenceActor.shared` --
    /// `closeSurfaceAndCleanUp`'s tab-still-has-leaves branch (reached
    /// here, since the sibling leaf survives) calls `requestSave()` on
    /// its way out regardless of this bug's fix state. Confirmed by
    /// observation: running this test against the ambient, real
    /// `NSApp.delegate` left a real (if empty) write behind in the
    /// developer's actual `~/.calyx/sessions.json`.
    /// `applicationShouldTerminate`/`removeWindowController` are
    /// belt-and-suspenders: this test's fixture never reaches
    /// `window?.close()` (the sibling leaf keeps the tab non-empty), but
    /// overriding them costs nothing and matches this codebase's general
    /// safety convention for any `NSApp.delegate` swap.
    private final class RequestSaveSpyAppDelegate: AppDelegate {
        override func requestSave() {}

        override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            .terminateCancel
        }

        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    func test_handleCloseSurfaceNotification_isClosingForShutdownTrueButAppNotTerminating_stillKillsSession() throws {
        let fixture = makeFixture()
        fixture.controller.isClosingForShutdown = true

        var observedKillCalls: [(sessionID: String, host: String?)] = []
        fixture.controller._killSessionIfPersistentRouteObserverForTesting = { sessionID, host in
            observedKillCalls.append((sessionID, host))
        }

        let trackedSurfaceView = try XCTUnwrap(
            fixture.tab.registry.view(for: fixture.trackedLeafID),
            "makeFixture's _testInsert must make the tracked leaf's SurfaceView resolvable"
        )

        let mock = RequestSaveSpyAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        XCTAssertFalse(mock.isApplicationTerminating, "Precondition: the app is not terminating in this scenario")

        withExtendedLifetime(mock) {
            NotificationCenter.default.post(
                name: .ghosttyCloseSurface, object: trackedSurfaceView, userInfo: ["process_alive": false]
            )
        }

        XCTAssertNil(
            SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
            "A pane whose process exits while its OWN window is mid-close (isClosingForShutdown true) " +
            "must still be genuinely killed when the app itself is not terminating -- isClosingForShutdown " +
            "alone must not be misread as 'the app is quitting'"
        )
        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "...and must clear tab.sessionRefs too, matching an ordinary closeTab's kill semantics")
        XCTAssertEqual(observedKillCalls.count, 1,
                      "killSessionIfPersistent's real kill route must actually fire exactly once")
        XCTAssertEqual(observedKillCalls.first?.sessionID, fixture.sessionID)
        XCTAssertNil(observedKillCalls.first?.host, "This fixture's SessionRef is local (no host)")

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "The untracked sibling pane must remain untouched")
    }
}
