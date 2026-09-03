// ClickContainerNSViewContextMenuTests.swift
// CalyxTests
//
// Covers `ClickContainerNSView.contextMenuProvider` and its overridden
// `menu(for:)` (Calyx/Views/TabBar/TabClickRecognizer.swift). AppKit
// calls `menu(for:)` to resolve the context menu
// for a right-click/Ctrl+click; this only asserts that override's
// return value directly (constructing an `NSEvent` and calling it), NOT
// the actual right-click popup -- `NSMenu.popUpContextMenu` runs a
// modal tracking loop that must never be exercised in a unit test.
//
// `isEnabled == false` (the existing property, used elsewhere to
// suppress single/double-click handling while an inline rename text
// field is showing) does NOT gate the context menu: `menu(for:)` returns
// the provider's menu regardless of `isEnabled`. `InlineTextField` installs
// its own click monitor 0.3s after the editor opens; once that monitor
// exists, it commits the in-progress rename before a right-click event
// ever reaches this view, so gating on `isEnabled` here would only ever
// have suppressed the menu on that one click.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class ClickContainerNSViewContextMenuTests: XCTestCase {

    private func makeRightClickEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    /// With a provider set and `isEnabled == true`, `menu(for:)` must
    /// return exactly the menu the provider produced (identity, not a
    /// copy).
    func test_menuForEvent_withProviderSet_andEnabled_returnsProvidersMenu() throws {
        let view = ClickContainerNSView()
        let providedMenu = NSMenu()
        view.contextMenuProvider = { providedMenu }
        view.isEnabled = true
        let event = try makeRightClickEvent()

        let resolved = view.menu(for: event)

        XCTAssertTrue(resolved === providedMenu, "menu(for:) must return exactly the menu the provider produced")
    }

    /// With no provider set at all, `menu(for:)` must return nil.
    func test_menuForEvent_withNoProvider_returnsNil() throws {
        let view = ClickContainerNSView()
        view.isEnabled = true
        let event = try makeRightClickEvent()

        XCTAssertNil(view.menu(for: event), "menu(for:) must return nil when no contextMenuProvider is set")
    }

    /// With a provider set but `isEnabled == false` (inline rename in
    /// progress), `menu(for:)` must still return exactly the provider's
    /// menu: `isEnabled` never gates the context menu.
    func test_menuForEvent_withProviderSet_whileDisabled_stillReturnsProvidersMenu() throws {
        let view = ClickContainerNSView()
        let providedMenu = NSMenu()
        view.contextMenuProvider = { providedMenu }
        view.isEnabled = false
        let event = try makeRightClickEvent()

        let resolved = view.menu(for: event)

        XCTAssertTrue(resolved === providedMenu, "menu(for:) must return the provider's menu regardless of isEnabled")
    }
}
