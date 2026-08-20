//
//  AppDelegateAgentRegistryObserverTests.swift
//  CalyxTests
//
//  `.ghosttyCommandFinished` and `.calyxSurfaceDestroyed` both name a
//  surface and mutate the app-wide `AgentRegistry` singleton, so their
//  observers belong on `AppDelegate`, which lives for the app's lifetime,
//  not on `CalyxWindowController`. A window-scoped observer drops both
//  signals whenever every main window is closed and only the QuickTerminal
//  is open -- an ordinary state on macOS, where closing the last window
//  does not terminate the app -- and neither signal repeats, so a drop is
//  permanent.
//
//  Each test below runs in two phases, and the first phase is what keeps
//  this file honest: it posts the notification BEFORE registering this
//  delegate's observers and asserts nothing happened. That phase fails if
//  any other live object in the test process still relays the notification
//  into `AgentRegistry.shared` -- which is exactly what moving these
//  observers back into `CalyxWindowController` would reintroduce, since
//  around sixty fixtures across `CalyxTests` build real controllers whose
//  `init` registers observers on `NotificationCenter.default`.
//
//  How far the `.ghosttyCommandFinished` test can reach: its handler
//  resolves the surface ID through `surfaceView.surfaceController?.id`,
//  and `GhosttySurfaceController` has exactly one initializer, which
//  requires a live `ghostty_app_t` -- the same wall
//  `GhosttyActionCommandFinishedTests`' own header documents on the
//  posting side of this notification. No unit test can hand the handler a
//  non-nil `surfaceController`, so the final
//  `AgentRegistry.handleGhosttyCommandFinished` call is NOT pinned here.
//  What IS pinned is everything ahead of it: that the post reaches an
//  app-scoped observer with no window controller in existence, and gets as
//  far as resolving the surface. `ReadCountingSurfaceView` below counts
//  that resolution. The `.calyxSurfaceDestroyed` handler needs no surface
//  controller (its payload is a bare `UUID`), so that one is pinned all
//  the way into `AgentRegistry`.
//

import XCTest
@testable import Calyx

/// `SurfaceView` whose `surfaceController` getter counts its own reads and
/// always answers `nil`. Reaching that read is the deepest point of
/// `AppDelegate.handleGhosttyCommandFinishedNotification` a unit test can
/// observe (see this file's header). Overriding the stored property is
/// possible because `@testable import` makes `Calyx`'s internal classes and
/// members overridable from the test module.
private final class ReadCountingSurfaceView: SurfaceView {

    private(set) var surfaceControllerReads = 0

    override var surfaceController: GhosttySurfaceController? {
        get {
            surfaceControllerReads += 1
            return nil
        }
        set { _ = newValue }
    }
}

@MainActor
final class AppDelegateAgentRegistryObserverTests: XCTestCase {

    private var appDelegate: AppDelegate!

    /// Every surface ID this test case seeded into `AgentRegistry.shared`,
    /// retired in `tearDown`. The registry is a process-wide singleton, so
    /// a row left behind would outlive this test case and be visible to
    /// every later one.
    private var seededSurfaceIDs: [UUID] = []

    // `async throws` rather than the plain synchronous overloads:
    // `AppDelegate` and `AgentRegistry` are both `@MainActor`, and the
    // synchronous overloads are nonisolated even in a `@MainActor` test
    // class. Same precedent as `CalyxWindowControllerHerdrAutoCloseTests`.
    override func setUp() async throws {
        try await super.setUp()
        appDelegate = AppDelegate()
    }

    /// `_testRegisterNotificationObservers` registers `appDelegate` with
    /// `NotificationCenter.default` for real, exactly as
    /// `applicationDidFinishLaunching` does in production. Without this
    /// removal the registration would outlive the test case and keep
    /// relaying every later test's posts.
    override func tearDown() async throws {
        if let appDelegate {
            NotificationCenter.default.removeObserver(appDelegate)
        }
        for surfaceID in seededSurfaceIDs {
            AgentRegistry.shared.handleSurfaceDestroyed(surfaceID: surfaceID)
        }
        seededSurfaceIDs = []
        appDelegate = nil
        try await super.tearDown()
    }

    /// Seeds one `.mcpConnection` row into `AgentRegistry.shared` and
    /// returns its surface ID. `handleMCPConnection` needs no running IPC
    /// server, so it registers a row from a bare singleton.
    private func seedRegistryRow() -> UUID {
        let surfaceID = UUID()
        AgentRegistry.shared.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)
        seededSurfaceIDs.append(surfaceID)
        return surfaceID
    }

    // MARK: - .calyxSurfaceDestroyed

    func test_surfaceDestroyed_prunesRegistryRowWithNoWindowControllerAlive() {
        XCTAssertTrue(appDelegate.allWindowControllers.isEmpty,
                      "precondition: this test must run with no window controller of its own, so the only " +
                      "possible relay into AgentRegistry is the app-scoped observer registered below")

        let unobservedID = seedRegistryRow()
        XCTAssertNotNil(AgentRegistry.shared.entries[unobservedID], "precondition: the seeded row exists")

        NotificationCenter.default.post(
            name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": unobservedID]
        )

        XCTAssertNotNil(AgentRegistry.shared.entries[unobservedID],
                        "with this delegate's observers not yet registered, nothing else in the app may relay " +
                        ".calyxSurfaceDestroyed into AgentRegistry -- a window controller doing so is the very " +
                        "wiring this test exists to keep out")

        appDelegate._testRegisterNotificationObservers()
        let observedID = seedRegistryRow()

        NotificationCenter.default.post(
            name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": observedID]
        )

        XCTAssertNil(AgentRegistry.shared.entries[observedID],
                     "AppDelegate's .calyxSurfaceDestroyed observer must retire the destroyed pane's row " +
                     "with no window controller in existence -- the state Calyx is in whenever every main " +
                     "window is closed and only the QuickTerminal is open")
    }

    // MARK: - .ghosttyCommandFinished

    func test_ghosttyCommandFinished_reachesAppScopedHandlerWithNoWindowControllerAlive() {
        XCTAssertTrue(appDelegate.allWindowControllers.isEmpty,
                      "precondition: this test must run with no window controller of its own, so the only " +
                      "possible receiver is the app-scoped observer registered below")

        let unobservedView = ReadCountingSurfaceView(frame: .zero)
        NotificationCenter.default.post(
            name: .ghosttyCommandFinished, object: unobservedView, userInfo: ["exit_code": Int32(0)]
        )
        let baselineReads = unobservedView.surfaceControllerReads

        appDelegate._testRegisterNotificationObservers()

        let observedView = ReadCountingSurfaceView(frame: .zero)
        NotificationCenter.default.post(
            name: .ghosttyCommandFinished, object: observedView, userInfo: ["exit_code": Int32(0)]
        )

        XCTAssertEqual(observedView.surfaceControllerReads, baselineReads + 1,
                       "registering AppDelegate's observers must add exactly one .ghosttyCommandFinished " +
                       "receiver that resolves the posting surface, with no window controller in existence")
    }

    /// The handler reads `userInfo["exit_code"]` directly rather than
    /// through a `guard let`: ghostty reports "no exit code" as an absent
    /// or non-`Int32` value, which is a legitimate reading, not a malformed
    /// notification. A post carrying no `userInfo` at all must therefore
    /// still reach the surface resolution.
    func test_ghosttyCommandFinished_withNoExitCodeStillReachesSurfaceResolution() {
        appDelegate._testRegisterNotificationObservers()

        let view = ReadCountingSurfaceView(frame: .zero)
        NotificationCenter.default.post(name: .ghosttyCommandFinished, object: view)

        XCTAssertEqual(view.surfaceControllerReads, 1,
                       "a missing exit_code is a legitimate 'no exit code reported' reading, so the handler " +
                       "must still resolve the surface instead of bailing out on the absent key")
    }
}
