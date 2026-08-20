//
//  SessionReconnectEstablishGraceSeamTests.swift
//  CalyxTests
//
//  Covers the fix for
//  the HIGH-SPEED RECONNECT FLASHING bug covered directly by
//  SessionReconnectAttemptResetTimingTests (see that file's header
//  comment for the bug itself): `CalyxWindowController.performReconnect`
//  must reset sessionID's attempt count (via
//  `sessionReconnectCoordinator.markEstablished(sessionID:)`) only once
//  the replacement surface has survived a GRACE PERIOD without its own
//  child exiting, not immediately upon creation.
//
//  Asserting the real production grace period directly would need a
//  multi-second wall-clock test. This codebase's established
//  convention (see `SessionDaemonClientBoundTimeoutOverrides`,
//  exercised by `SessionDaemonClientSessionStateBoundTimeoutSeamTests`)
//  is to add a narrow, DEBUG-only override hook instead, so the
//  grace-period wait can be shrunk to a few milliseconds for the test.
//  This file proposes that same shape for the reconnect grace period:
//
//    #if DEBUG
//    enum CalyxWindowControllerReconnectGraceOverrides {
//        nonisolated(unsafe) static var reconnectEstablishGraceMilliseconds: UInt64?
//    }
//    #endif
//
//  -- `nil` (the default) means "use the production value" (proposed:
//  2000ms). `CalyxWindowController`'s own
//  `reconnectEstablishGraceMilliseconds` computed property would
//  consult this override first under `#if DEBUG`, mirroring
//  `SessionDaemonClientProtocol.daemonQueryBoundTimeoutSeconds`'s
//  identical shape. `performReconnect` would then schedule the
//  `markEstablished(sessionID:)` call on a `Task` that sleeps out this
//  bound before firing, rather than calling it synchronously and
//  immediately as it does today -- and should re-check, once that wait
//  elapses, that `newSurfaceID` is still the session's current surface
//  (e.g. via `SessionSurfaceMap.shared.surfaceID(for: sessionID) ==
//  newSurfaceID`) before marking it established, so a replacement that
//  was ITSELF already swapped out again by a second reconnect within
//  the grace window doesn't wrongly reset an unrelated, still-in-
//  progress attempt count.
//
//  Under test: the override enum and the grace-period wait itself.
//  Before them, `performReconnect` called
//  `markEstablished(sessionID:)` unconditionally and immediately --
//  see `SessionReconnectAttemptResetTimingTests` for that bug's own
//  direct coverage.
//
//  Reuses the exact fixture/seam approach
//  SessionReconnectAttemptResetTimingTests already establishes
//  (`_performReconnectSurfaceCreationHookForTesting`,
//  `_sessionReconnectCoordinatorForTesting`,
//  `SessionReconnectCoordinator._testSeedAttemptCount(sessionID:count:)`,
//  the CALYX_SESSION_BIN env override, the inactive-second-tab fixture
//  shape) -- see that file's own header comment for why each of those
//  is necessary/safe. `pumpRunLoop`/`ReconnectFixture`/
//  `makeReconnectFixture` themselves live in the shared
//  `CalyxTests/ReconnectFixture.swift`.
//
//  Coverage:
//  - A replacement surface that survives past the (overridden, tiny)
//    grace period DOES get its sessionID's attempt count reset --
//    regression coverage for markEstablished's legitimate purpose
//    (a later, unrelated disconnect starts backing off from attempt 1
//    again) against the fix that delays WHEN it fires.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class SessionReconnectEstablishGraceSeamTests: XCTestCase {

    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = nil
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// Pins the grace-period wait, its override seam
    /// (`CalyxWindowControllerReconnectGraceOverrides`), and the delayed
    /// `markEstablished` call described above.
    ///
    /// Overrides the grace period to a tiny value,
    /// seeds attemptCounts[sessionID] = 2 (simulating two prior
    /// consecutive reconnect failures already recorded), drives a real
    /// `.reconnect(attempt: 1)` decision through the real, unmodified
    /// `performReconnect`, then pumps the run loop past the overridden
    /// grace period and asserts the attempt count HAS been reset by
    /// then -- proving `markEstablished`'s legitimate purpose still
    /// works once the replacement genuinely survives, now that the fix
    /// delays when it fires.
    func test_performReconnect_replacementSurvivesGracePeriod_attemptCountEventuallyResets() {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = 30

        let fixture = makeReconnectFixture()
        registeredSessionIDs.append(fixture.sessionID)
        fixture.controller._sessionReconnectCoordinatorForTesting._testSeedAttemptCount(
            sessionID: fixture.sessionID, count: 2
        )

        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

        let newSurfaceID = UUID()
        fixture.tab.registry._testInsert(view: SurfaceView(frame: .zero), id: newSurfaceID)
        fixture.controller._performReconnectSurfaceCreationHookForTesting = { newSurfaceID }
        // Establishment also requires
        // `reconnectGraceProbe(sessionID:)` to report `.established`. This
        // test drives a real `performReconnect` against `/usr/bin/true`
        // and never registers `sessionID` with any real or fake daemon
        // ledger, so the real, un-hooked probe fallback would find no
        // matching session and report `.notEstablished` under fail-closed
        // semantics, breaking this test's expectation that the count
        // eventually resets. Stub the probe to isolate this test's actual
        // subject (the grace-period wait/surface-identity check) from G6's
        // separate probe contract, which `SessionReconnectGracePositiveSignalSeamTests`
        // covers directly.
        fixture.controller._reconnectGraceProbeForTesting = { .established }

        fixture.controller.handleSessionReconnectDecision(
            surfaceID: fixture.trackedLeafID,
            decision: .reconnect(sessionID: fixture.sessionID, attempt: 1)
        )

        pumpRunLoop(timeout: 1.0) {
            fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID)
        }
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID),
                      "Precondition: performReconnect must have swapped in the replacement surface")

        // The replacement is left alone from here on (never re-driven
        // through another childExited/decision), simulating "it
        // survived" -- wait past the overridden grace period.
        pumpRunLoop(timeout: 1.0) {
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID] == nil
        }

        XCTAssertNil(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID],
            "Once the replacement survives past the grace period without its own child exiting, " +
            "performReconnect must still eventually call markEstablished(sessionID:), resetting the " +
            "attempt count so a later, unrelated disconnect starts backing off from attempt 1 again"
        )
    }
}
