//
//  GlassOpacityCellsSettingsToggleWiringTests.swift
//  CalyxTests
//
//  Covers the new Appearance-pane "Glass Opacity Cells" toggle, which lets
//  the user opt into ghostty's background-opacity-cells so cell-level
//  background colors (used for e.g. selection or app-drawn backgrounds)
//  also respect the glass transparency, instead of the default fully
//  opaque behavior Calyx has always written. Default OFF preserves the
//  existing behavior. Same two-part split as
//  CommandTrackingSettingsToggleWiringTests (see that file's own header
//  for the full rationale of each part's reachability) -- this file adds
//  no third (C) part, since the change handler's only side effect is
//  GhosttyAppController.shared.reloadConfig() via
//  applyOpacityToRunningSurfaces(), which is not safe to invoke from a
//  unit test and has no dedicated seam the way ShellIntegrationInstaller
//  does for commandTrackingDidChange(:).
//
//  (A) TARGET/ACTION WIRING -- against the REAL SettingsWindowController
//  .shared singleton's Appearance pane view tree, located by its OWN
//  accessibility identifier (not positional index), so this file is
//  independent of where the row sits relative to the other Appearance
//  rows.
//
//  (B) INITIAL-STATE SEEDING -- against
//  SettingsWindowController.sessionToggleInitialState(for:), the same
//  singleton-independent pure seam CommandTrackingSettingsToggleWiringTests
//  exercises, extended with a new .glassOpacityCells case. Unlike
//  commandTracking (backed by CommandTrackingSettings, with its own
//  _testUseSuite seam), this row reads UserDefaults.standard directly
//  under the key "terminalGlassOpacityCells" -- there is no dedicated
//  settings type to swap a suite into, so this file saves and restores
//  UserDefaults.standard's existing value for that key around each test.
//
//  Also pins SettingsRow.glassOpacityCells.pane == .appearance and its
//  declared position in SettingsRow.allCases -- immediately after
//  .glassOpacity and immediately before .smoothScrolling -- since
//  SettingsWindowController's pane-stack builder renders rows in
//  declaration order and a row with no SectionHeading of its own
//  inherits whichever section heading precedes it (see
//  SettingsWindowController.paneStack(for:)); a row in the wrong slot
//  would silently land outside the Glass section. This does not
//  duplicate SettingsPaneTests.test_everyPreShuffleSettingRow_..., which
//  pins the pre-existing row set and does not know about this new row.
//
//  Under test: SettingsRow.glassOpacityCells,
//  AccessibilityID.Settings.glassOpacityCellsSwitch, and the
//  #selector(glassOpacityCellsDidChange:) target.
//
//  Proposed API:
//
//    SettingsRow.swift: add `case glassOpacityCells` between `.glassOpacity`
//    and `.smoothScrolling`, routed to `.pane == .appearance`.
//
//    AccessibilityID.swift, enum Settings: add
//    `static let glassOpacityCellsSwitch = "calyx.settings.appearance.glassOpacityCellsSwitch"`
//
//    SettingsWindowController.swift:
//    - sectionHeading(for: .glassOpacityCells) returns nil (continues the
//      existing Glass section heading, unchanged).
//    - contentView(for: .glassOpacityCells) returns a new
//      glassOpacityCellsRow(): local NSSwitch, identifier
//      AccessibilityID.Settings.glassOpacityCellsSwitch, state seeded from
//      Self.sessionToggleInitialState(for: .glassOpacityCells), target
//      self, action #selector(glassOpacityCellsDidChange:).
//    - sessionToggleInitialState(for:) gets a new
//      `case .glassOpacityCells: return UserDefaults.standard.bool(forKey: "terminalGlassOpacityCells")`
//      arm (default false when unset).
//    - a new `@objc private func glassOpacityCellsDidChange(_ sender: NSSwitch)`
//      sets UserDefaults.standard's "terminalGlassOpacityCells" and calls
//      applyOpacityToRunningSurfaces().
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class GlassOpacityCellsSettingsToggleWiringTests: XCTestCase {

    // MARK: - (A) target/action wiring, via the real singleton's built view tree

    private func appearancePaneView() throws -> NSView {
        let tabViewController = try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
            "SettingsWindowController's window must host an NSTabViewController as its content"
        )
        let appearanceIndex = try XCTUnwrap(
            SettingsPane.allCases.firstIndex(of: .appearance),
            "SettingsPane must have a .appearance case"
        )
        let tabItem = tabViewController.tabViewItems[appearanceIndex]
        return try XCTUnwrap(tabItem.viewController?.view, "The Appearance tab item must host a real view controller")
    }

    /// Depth-first walk collecting every NSSwitch in `view`'s subview
    /// tree whose accessibility identifier matches `identifier` --
    /// located by identifier rather than position, since this file must
    /// not assume where the row sits relative to the other Appearance
    /// rows.
    private func findSwitch(identifier: String, in view: NSView) -> NSSwitch? {
        for subview in view.subviews {
            if let toggleSwitch = subview as? NSSwitch, toggleSwitch.accessibilityIdentifier() == identifier {
                return toggleSwitch
            }
            if let found = findSwitch(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    func test_glassOpacityCellsSwitch_existsWithTargetAndActionWired() throws {
        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.glassOpacityCellsSwitch, in: try appearancePaneView()),
            "the Appearance pane must contain exactly one switch with the glassOpacityCellsSwitch accessibility identifier"
        )

        XCTAssertTrue(
            toggleSwitch.target === SettingsWindowController.shared,
            "the glass opacity cells switch must have SettingsWindowController.shared as its .target"
        )
        XCTAssertEqual(
            toggleSwitch.action, Selector(("glassOpacityCellsDidChange:")),
            "the glass opacity cells switch's .action must be #selector(glassOpacityCellsDidChange:)"
        )
    }

    // MARK: - (B) initial-state seeding, via the existing singleton-independent seam

    private let userDefaultsKey = "terminalGlassOpacityCells"
    private var originalValue: Any?
    private var hadOriginalValue = false

    override func setUp() {
        super.setUp()
        originalValue = UserDefaults.standard.object(forKey: userDefaultsKey)
        hadOriginalValue = originalValue != nil
    }

    override func tearDown() {
        if hadOriginalValue {
            UserDefaults.standard.set(originalValue, forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
        super.tearDown()
    }

    func test_sessionToggleInitialState_glassOpacityCells_readsUserDefaults_true() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
        XCTAssertTrue(
            SettingsWindowController.sessionToggleInitialState(for: .glassOpacityCells),
            "the initial state must read UserDefaults.standard's terminalGlassOpacityCells key LIVE"
        )
    }

    func test_sessionToggleInitialState_glassOpacityCells_readsUserDefaults_false() {
        UserDefaults.standard.set(false, forKey: userDefaultsKey)
        XCTAssertFalse(
            SettingsWindowController.sessionToggleInitialState(for: .glassOpacityCells),
            "the initial state must reflect an explicit false in UserDefaults"
        )
    }

    func test_sessionToggleInitialState_glassOpacityCells_defaultsToFalseWhenUnset() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        XCTAssertFalse(
            SettingsWindowController.sessionToggleInitialState(for: .glassOpacityCells),
            "the initial state must default to false (preserving today's always-opaque-cells behavior) " +
            "when terminalGlassOpacityCells has never been set"
        )
    }

    // MARK: - Row declaration: pane and position

    func test_glassOpacityCellsRow_belongsToAppearancePane() {
        XCTAssertEqual(
            SettingsRow.glassOpacityCells.pane, .appearance,
            "glassOpacityCells must belong to the Appearance pane, alongside the other Glass-section rows"
        )
    }

    func test_glassOpacityCellsRow_isDeclaredImmediatelyAfterGlassOpacityAndBeforeSmoothScrolling() throws {
        let allCases = SettingsRow.allCases
        let glassOpacityIndex = try XCTUnwrap(allCases.firstIndex(of: .glassOpacity))
        let glassOpacityCellsIndex = try XCTUnwrap(allCases.firstIndex(of: .glassOpacityCells))
        let smoothScrollingIndex = try XCTUnwrap(allCases.firstIndex(of: .smoothScrolling))

        XCTAssertEqual(
            glassOpacityCellsIndex, glassOpacityIndex + 1,
            "glassOpacityCells must be declared immediately after glassOpacity, so it renders inside the " +
            "same Glass section (rows with no own SectionHeading inherit the preceding one)"
        )
        XCTAssertEqual(
            smoothScrollingIndex, glassOpacityCellsIndex + 1,
            "smoothScrolling must be declared immediately after glassOpacityCells, so glassOpacityCells stays " +
            "inside the Glass section and does not leak into the Scrolling section"
        )
    }
}
