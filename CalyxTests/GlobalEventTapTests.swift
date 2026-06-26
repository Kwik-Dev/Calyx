//
//  GlobalEventTapTests.swift
//  CalyxTests
//
//  Regression tests for the global CGEvent tap's interaction with Calyx's
//  main menu key equivalents. The tap sits at the head of the session event
//  stream, so it can otherwise consume app-level ghostty keybindings (such as
//  Ctrl+Cmd+F for Toggle Full Screen) before AppKit routes them through the
//  menu.
//

import XCTest
@testable import Calyx
@preconcurrency import AppKit

@MainActor
final class GlobalEventTapTests: XCTestCase {

    // MARK: - Helpers

    /// A trivial object that records whether its sole action was invoked.
    private final class DummyTarget: NSObject {
        private(set) var actionInvoked = false

        @objc func menuAction(_ sender: Any?) {
            actionInvoked = true
        }
    }

    /// Create a synthetic key-down NSEvent for use in tests.
    private func makeKeyEvent(
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    /// Build a menu containing a single item bound to Ctrl+Cmd+F.
    private func makeFullScreenMenu(target: DummyTarget) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(DummyTarget.menuAction(_:)),
            keyEquivalent: "f"
        )
        item.target = target
        item.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(item)
        return menu
    }

    // MARK: - Tests

    /// Regression: Ctrl+Cmd+F must match the Window > Toggle Full Screen menu
    /// item so the shortcut is not swallowed by ghostty's app-level binding.
    func test_shouldPassEventToMainMenu_cmdCtrlF_routesToMenuAction() throws {
        let target = DummyTarget()
        let menu = makeFullScreenMenu(target: target)

        guard let event = makeKeyEvent(
            modifiers: [.command, .control],
            keyCode: 3,
            characters: "f",
            charactersIgnoringModifiers: "f"
        ) else {
            XCTFail("Failed to create synthetic Ctrl+Cmd+F event")
            return
        }

        let matched = shouldPassEventToMainMenu(event, isActive: true, menu: menu)

        XCTAssertTrue(
            matched,
            "Ctrl+Cmd+F should match the main menu Toggle Full Screen item"
        )
        XCTAssertTrue(
            target.actionInvoked,
            "performKeyEquivalent should fire the menu action"
        )
    }

    /// Sanity check: an unrelated key event with the same modifiers should not
    /// be scooped up by the menu-item matcher.
    func test_shouldPassEventToMainMenu_unrelatedKey_doesNotMatch() {
        let target = DummyTarget()
        let menu = makeFullScreenMenu(target: target)

        guard let event = makeKeyEvent(
            modifiers: [.command, .control],
            keyCode: 14, // "e"
            characters: "e",
            charactersIgnoringModifiers: "e"
        ) else {
            XCTFail("Failed to create synthetic Ctrl+Cmd+E event")
            return
        }

        let matched = shouldPassEventToMainMenu(event, isActive: true, menu: menu)

        XCTAssertFalse(
            matched,
            "Ctrl+Cmd+E should not match the Toggle Full Screen menu item"
        )
        XCTAssertFalse(
            target.actionInvoked,
            "No action should fire for a non-matching key"
        )
    }

    /// Global keybindings for other apps must remain intact; do not treat menu
    /// key equivalents as matching when Calyx is not the active app.
    func test_shouldPassEventToMainMenu_inactiveApp_doesNotMatch() {
        let target = DummyTarget()
        let menu = makeFullScreenMenu(target: target)

        guard let event = makeKeyEvent(
            modifiers: [.command, .control],
            keyCode: 3,
            characters: "f",
            charactersIgnoringModifiers: "f"
        ) else {
            XCTFail("Failed to create synthetic Ctrl+Cmd+F event")
            return
        }

        let matched = shouldPassEventToMainMenu(event, isActive: false, menu: menu)

        XCTAssertFalse(
            matched,
            "The event should not be routed to the main menu when Calyx is inactive"
        )
        XCTAssertFalse(
            target.actionInvoked,
            "The menu action must not fire for an inactive app"
        )
    }

    func test_shouldPassEventToMainMenu_nilMenu_returnsFalse() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .control],
            keyCode: 3,
            characters: "f",
            charactersIgnoringModifiers: "f"
        ) else {
            XCTFail("Failed to create synthetic Ctrl+Cmd+F event")
            return
        }

        let matched = shouldPassEventToMainMenu(event, isActive: true, menu: nil)

        XCTAssertFalse(matched, "A nil menu must not produce a match")
    }
}
