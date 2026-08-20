//
//  ConfirmQuitMockAppDelegate.swift
//  CalyxTests
//
//  Shared base for the four near-identical `AppDelegate` test doubles in
//  `SessionCommandPaletteTests` (MockConfirmQuitAppDelegate,
//  ClosingTabIDsSpyAppDelegate) and `CalyxWindowControllerCloseArmsTests`
//  (ConfirmingAppDelegate, ClosingTabIDsWindowCloseSpyAppDelegate), all
//  of which drive a close path under test through to its
//  `.windowShouldClose` arm without a real, blocking `NSAlert.runModal()`.
//  No production change: purely test-infrastructure consolidation.
//

import AppKit
@testable import Calyx

@MainActor
class ConfirmQuitMockAppDelegate: AppDelegate {
    /// A no-op purely as test-process safety: a confirmed teardown
    /// empties the fixture's window for real, calling `window?.close()`
    /// -> `windowWillClose` -> `AppDelegate.removeWindowController`,
    /// whose real implementation calls `saveImmediately()` once its
    /// (private) `windowControllers` list is empty.
    override func removeWindowController(_ controller: CalyxWindowController) {}
}
