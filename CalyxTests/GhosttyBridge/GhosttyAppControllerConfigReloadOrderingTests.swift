//
//  GhosttyAppControllerConfigReloadOrderingTests.swift
//  CalyxTests
//
//  Missing-observer investigation:
//  `GhosttyAppController.reloadConfig(soft:)` and its
//  `ReloadDepsAdapter.loadConfigFromDisk()` twin used to call
//  `GhosttyFFI.appUpdateConfig(app, config:)` BEFORE reassigning
//  `self.configManager`/`controller.configManager` to the freshly loaded
//  instance. `appUpdateConfig` synchronously triggers
//  GHOSTTY_ACTION_CONFIG_CHANGE (App.zig -> apprt.performAction ->
//  ghosttyActionCallback, no queue/async dispatch), which
//  `NotificationCenter` delivers to every `.ghosttyConfigChange` observer
//  SYNCHRONOUSLY, still inside that call — so any observer that reads
//  `GhosttyAppController.shared.configManager` (`GhosttyThemeProvider`,
//  `SurfaceScrollView`, `AppDelegate.refreshBellFeaturesCache`) used to
//  see the STALE, pre-reload manager for the entire reload that was
//  supposed to deliver the new value.
//
//  This pins the FIX directly against the real, production
//  `GhosttyAppController.shared` singleton and its real `reloadConfig`
//  method (not a mock): confirmed safe to touch from this test host --
//  `GhosttyAppController.shared` is already exercised by more than a
//  dozen existing test files, and its own "GhosttyAppController
//  initialized successfully" log line is observed during a normal
//  CalyxTests run. Scoped to the config layer only: no window, no
//  ghostty SURFACE is ever created here (that specific operation is
//  documented as unsafe in this test host, see SurfaceLocator.swift's
//  header comment; `reloadConfig` itself never creates one). `soft: true`
//  throughout, to avoid `reloadConfig`'s `applyCurrentGhosttyConfigToAllWindows()`
//  branch -- irrelevant to the ordering bug under test here, since both
//  `soft` values share the identical configManager-swap-then-
//  appUpdateConfig sequence this test cares about, ahead of that branch.
//
//  `ReloadDepsAdapter.loadConfigFromDisk()` (the second of the two fixed
//  call sites, reached only through `GhosttyAppController`'s private
//  `reloadCoordinator`/`ConfigReloadCoordinator`'s debounce) is not
//  independently exercised here: it has no public seam to drive directly
//  without adding new test-only surface area, and it is fixed with the
//  exact same shape/reasoning as `reloadConfig(soft:)` below (see that
//  method's own comment in GhosttyApp.swift).
//

import XCTest
@testable import Calyx

@MainActor
final class GhosttyAppControllerConfigReloadOrderingTests: XCTestCase {

    /// The regression this test would have caught: before the fix, this
    /// assertion failed, because the `.ghosttyConfigChange` observer below
    /// fired WHILE `GhosttyAppController.shared.configManager` was still
    /// `beforeReload` -- `appUpdateConfig` (inside `reloadConfig`) used to
    /// post the notification before the swap to the new instance ran.
    func test_reloadConfig_configChangeObserver_seesFreshConfigManagerNotStaleOne() {
        let controller = GhosttyAppController.shared
        let beforeReload = ObjectIdentifier(controller.configManager)

        var configManagerSeenByObserver: ObjectIdentifier?
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                configManagerSeenByObserver = ObjectIdentifier(controller.configManager)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.reloadConfig(soft: true)

        XCTAssertNotNil(
            configManagerSeenByObserver,
            "Precondition: reloadConfig must actually deliver .ghosttyConfigChange synchronously for this test to " +
            "mean anything (requires GhosttyAppController.shared.app to be non-nil in this test host)"
        )
        XCTAssertNotEqual(
            configManagerSeenByObserver,
            beforeReload,
            ".ghosttyConfigChange observers must already see the FRESH configManager, not the stale pre-reload " +
            "one, while the notification is being delivered mid-reload"
        )
    }

    /// Sanity companion: after `reloadConfig` returns, `configManager` is
    /// (obviously) the fresh instance too. Not itself proof of the fix
    /// (this already held true before it, since the swap always happened
    /// eventually) -- documents the end state the test above additionally
    /// checks mid-flight, not just eventually.
    func test_reloadConfig_afterReturning_configManagerIsFreshInstance() {
        let controller = GhosttyAppController.shared
        let beforeReload = ObjectIdentifier(controller.configManager)

        controller.reloadConfig(soft: true)

        XCTAssertNotEqual(
            ObjectIdentifier(controller.configManager),
            beforeReload,
            "reloadConfig must swap configManager to a freshly loaded instance"
        )
    }
}
