//
//  AppDelegateFileMenuCloseItemsTests.swift
//  CalyxTests
//
//  GitHub issue #45 (see `NSWindow+CalyxClose.swift`'s header comment
//  for the full root-cause writeup): the File menu used to carry a
//  single nil-target "Close Tab" item on Cmd+W, which is what let
//  `-[NSApplication targetForAction:]` fall through to the MAIN
//  window's `CalyxWindowController` whenever a non-`CalyxWindow` panel
//  (About/Settings/Session Browser) was key. `setupMainMenu()` now
//  builds four distinct, adjacent File-menu items instead — this file
//  pins their exact titles, order, shortcuts, actions, and (nil)
//  targets, mirroring `AppDelegateSessionBrowserMenuItemTests`'s own
//  "un-privated `setupMainMenu()`, construct a bare `AppDelegate()`,
//  call it directly" testability precedent (safe here for the same
//  reason: no ghostty surface, no window, no async work).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateFileMenuCloseItemsTests: XCTestCase {

    private func fileMenu() throws -> NSMenu {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()

        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let fileMenuItem = try XCTUnwrap(
            mainMenu.items.first(where: { $0.submenu?.title == "File" }),
            "setupMainMenu must build a \"File\" menu"
        )
        return try XCTUnwrap(fileMenuItem.submenu, "The File menu item must have a submenu")
    }

    /// The four close-scope items must be the LAST four items in the
    /// File menu, in this exact order — `setupMainMenu()` appends
    /// nothing to the File menu after them.
    func test_fileMenu_lastFourItems_areCloseCloseTabCloseWindowCloseAllWindows_inOrder() throws {
        let menu = try fileMenu()
        let titles = menu.items.suffix(4).map(\.title)

        XCTAssertEqual(
            titles, ["Close", "Close Tab", "Close Window", "Close All Windows"],
            "The File menu's last four items must be exactly these titles, in this order"
        )
    }

    /// Data-driven: (title, keyEquivalent, modifierMask, expected action
    /// selector name). Every one of these four items must keep
    /// `target == nil` — a nil target is what lets AppKit's own
    /// `targetForAction:` resolve `calyxPerformClose:` against the KEY
    /// window's own responder chain first; setting `target = self`
    /// (like `selectTabByNumber`'s items do) would defeat that entirely.
    private struct ExpectedItem {
        let title: String
        let keyEquivalent: String
        let modifierMask: NSEvent.ModifierFlags
        let actionName: String
    }

    private static let expectedItems: [ExpectedItem] = [
        ExpectedItem(title: "Close", keyEquivalent: "w", modifierMask: [.command], actionName: "calyxPerformClose:"),
        ExpectedItem(title: "Close Tab", keyEquivalent: "w", modifierMask: [.command, .option], actionName: "closeTab:"),
        ExpectedItem(title: "Close Window", keyEquivalent: "w", modifierMask: [.command, .shift], actionName: "performClose:"),
        ExpectedItem(
            title: "Close All Windows", keyEquivalent: "w", modifierMask: [.command, .shift, .option],
            actionName: "closeAllWindows:"
        ),
    ]

    func test_fileMenu_closeItems_haveExpectedShortcutActionAndNilTarget() throws {
        let menu = try fileMenu()

        for expected in Self.expectedItems {
            let item = try XCTUnwrap(
                menu.items.first(where: { $0.title == expected.title }),
                "File menu must contain an item titled \"\(expected.title)\""
            )

            XCTAssertEqual(
                item.keyEquivalent, expected.keyEquivalent,
                "\"\(expected.title)\"'s key equivalent must be \"\(expected.keyEquivalent)\""
            )
            XCTAssertEqual(
                item.keyEquivalentModifierMask, expected.modifierMask,
                "\"\(expected.title)\"'s shortcut modifiers must be \(expected.modifierMask)"
            )
            XCTAssertEqual(
                item.action.map(NSStringFromSelector), expected.actionName,
                "\"\(expected.title)\" must be wired to the \(expected.actionName) selector"
            )
            XCTAssertNil(
                item.target,
                "\"\(expected.title)\" must keep a nil target so AppKit's targetForAction: resolves it " +
                "against the key window's own responder chain"
            )
        }
    }
}
