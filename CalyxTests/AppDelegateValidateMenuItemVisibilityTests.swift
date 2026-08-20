//
//  AppDelegateValidateMenuItemVisibilityTests.swift
//  CalyxTests
//
//  The defect this file pins: `AppDelegate.validateMenuItem(_:)`
//  (AppDelegate.swift:3227) has no `@objc`, and `AppDelegate`
//  (AppDelegate.swift:11) does not conform to `NSMenuItemValidation`
//  (confirmed by grep: no `extension AppDelegate` anywhere in `Calyx/`,
//  and no reference to `NSMenuItemValidation` anywhere in `Calyx/`
//  either). Swift therefore never emits `validateMenuItem:` into the
//  ObjC method table, so AppKit -- which validates menu items via
//  ObjC-runtime dispatch, not a Swift protocol witness table -- never
//  calls it. The "Secure Keyboard Entry" item's checkmark then never
//  updates, even though the click itself lands and really flips
//  `SecureInput.shared.global` (measured on a real running build:
//  `AXMenuItemMarkChar` stays "missing value" forever).
//
//  Coverage:
//  - `AppDelegate.instancesRespond(to: "validateMenuItem:")`
//    (pins the fix): the actual defect, checked at the class level via
//    `NSObject.instancesRespond(to:)` -- pure ObjC-runtime introspection,
//    no instance needed.
//  - `validateMenuItem(_:)`'s state-mapping logic: a direct Swift-level
//    call against a real `AppDelegate()` instance. Swift-to-Swift
//    dispatch does not need `@objc` at all -- only AppKit's
//    ObjC-runtime-mediated validation call does, which is exactly bug 1
//    -- so this exercises the method's actual logic independently of the
//    visibility defect above. Bare `AppDelegate()` construction is safe
//    per this codebase's established pattern (see e.g.
//    `AppDelegateApplyGhosttyResourcesDirEnvironmentTests`'s header
//    comment, "bare AppDelegate(), bypassing applicationDidFinishLaunching"):
//    `AppDelegate.init` is the plain inherited `NSObject.init()`, and
//    `applicationDidFinishLaunching` only runs if AppKit itself calls it
//    on a delegate it owns, which never happens for a locally-constructed
//    instance that is never installed as `NSApp.delegate`.
//
//  HAZARD analysis (`SecureInput.swift`, read in full first): the real
//  system-wide side effect lives ENTIRELY in `SecureInput.global`'s
//  `didSet { apply() }` -- `apply()` calls `EnableSecureEventInput()`,
//  and only when `NSApp.isActive` AND the desired state actually
//  changes. `validateMenuItem(_:)` itself only READS
//  `SecureInput.shared.global` (`menuItem.state = SecureInput.shared
//  .global ? .on : .off`); it never writes to it, so exercising
//  `validateMenuItem(_:)` cannot itself trigger `EnableSecureEventInput()`
//  no matter what `.global` currently holds. This file goes further and
//  never WRITES `.global` either (the one way to flip it,
//  `toggleSecureInput(_:)`, is never called here), so the hazard is
//  fully avoided while still covering the state-mapping branch that
//  reads it. Confirmed nothing else can have set `.global` to `true`
//  before this test runs: grepped the whole `Calyx/` tree for every read
//  of the `"SecureInput"` UserDefaults key (none -- it is only ever
//  written, never restored at launch) and every write site to
//  `SecureInput.shared.global` (`toggleSecureInput(_:)`, requires a real
//  menu click; `GhosttyAction.handleSecureInput`, requires a real
//  ghostty app action dispatch -- neither fires in this headless
//  unit-test host), and grepped `CalyxTests/` for any existing reference
//  to `SecureInput` (none). The `.on` branch (`global == true`) is
//  deliberately NOT exercised here, since the only way to produce it is
//  to WRITE `.global` and trigger the real side effect -- out of scope
//  for this file: dropping coverage is preferable to risking the side
//  effect.
//
//  What each test pins:
//   - `test_appDelegateClass_instancesRespondToValidateMenuItemSelector`
//     pins the fix: AppDelegate must expose validateMenuItem:
//     to the ObjC runtime (via @objc or NSMenuItemValidation
//     conformance), or AppKit's menu validation pass never calls it at
//     all, and the Secure Keyboard Entry item's checkmark never
//     updates. `AppDelegate.instancesRespond(to:
//     NSSelectorFromString("validateMenuItem:"))` returning `false` was
//     the whole defect.
//   - `test_validateMenuItem_reflectsSecureInputGlobalFalseAsOffState` is
//     a regression guard: `validateMenuItem(_:)`'s body already
//     performed the state-mapping assignment correctly (only its
//     ObjC visibility was broken, covered above).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateValidateMenuItemVisibilityTests: XCTestCase {

    // MARK: - ObjC runtime visibility

    func test_appDelegateClass_instancesRespondToValidateMenuItemSelector() {
        XCTAssertTrue(
            AppDelegate.instancesRespond(to: NSSelectorFromString("validateMenuItem:")),
            "AppDelegate must expose validateMenuItem: to the ObjC runtime (via @objc or " +
            "NSMenuItemValidation conformance), or AppKit's menu validation pass never calls it at all, " +
            "and the Secure Keyboard Entry item's checkmark never updates"
        )
    }

    // MARK: - State-mapping logic (read-only; see header comment)

    func test_validateMenuItem_reflectsSecureInputGlobalFalseAsOffState() {
        XCTAssertFalse(
            SecureInput.shared.global,
            "Precondition: SecureInput.shared.global must still be its untouched default (false) -- see " +
            "this file's header comment for why nothing in this test host can have set it before now"
        )

        let appDelegate = AppDelegate()
        let menuItem = NSMenuItem(title: "Secure Keyboard Entry", action: nil, keyEquivalent: "")
        menuItem.action = NSSelectorFromString("toggleSecureInput:")
        // .mixed is neither .on nor .off, so a passing assertion below
        // proves validateMenuItem actively WROTE .off, not merely that
        // it left a coincidentally-already-off state untouched.
        menuItem.state = .mixed

        let result = appDelegate.validateMenuItem(menuItem)

        XCTAssertTrue(result, "validateMenuItem must return true for the Secure Keyboard Entry item")
        XCTAssertEqual(
            menuItem.state, .off,
            "validateMenuItem must set state to .off when SecureInput.shared.global is false"
        )
    }
}
