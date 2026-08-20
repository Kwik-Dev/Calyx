//
//  CommandPaletteStateTests.swift
//  CalyxTests
//
//  Tests that WindowSession exposes a `showCommandPalette` property
//  for toggling the command palette overlay.
//
//  Coverage:
//  - showCommandPalette defaults to false
//  - showCommandPalette toggles correctly
//
//  `showCommandPalette` is a WindowSession property.
//

import XCTest
@testable import Calyx

@MainActor
final class CommandPaletteStateTests: XCTestCase {

    // ==================== 1. Default Value ====================

    func test_showCommandPalette_should_default_to_false() {
        // Arrange
        let session = WindowSession()

        // Assert
        XCTAssertFalse(session.showCommandPalette,
                       "showCommandPalette should default to false on a new WindowSession")
    }

    // ==================== 2. Toggle ====================

    func test_showCommandPalette_should_toggle_correctly() {
        // Arrange
        let session = WindowSession()

        // Act — set to true
        session.showCommandPalette = true

        // Assert
        XCTAssertTrue(session.showCommandPalette,
                      "showCommandPalette should be true after setting to true")

        // Act — set back to false
        session.showCommandPalette = false

        // Assert
        XCTAssertFalse(session.showCommandPalette,
                       "showCommandPalette should be false after setting back to false")
    }
}
