//
//  CalyxWindowControllerCopyTitleToClipboardTests.swift
//  CalyxTests
//
//  TDD RED phase, second missing-observer investigation: ghostty's
//  copy_title_to_clipboard keybind (`GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD`)
//  is not routed anywhere in `GhosttyActionRouter.handleAction` at all
//  (falls to `default:`) -- pressing it does nothing.
//  `CalyxWindowController.processCopyTitleToClipboard(tab:)` is the
//  intended receiver once a `.ghosttyCopyTitleToClipboard` case/observer
//  exists; today it is an intentional no-op stub (see its own doc comment
//  in CalyxWindowController.swift), so every test below that expects a
//  clipboard write fails.
//
//  `controller.clipboardWriter` is swapped for
//  `SelectionEditHandlerTests.FakeClipboardWriter` (already `internal` in
//  that file, reused here rather than duplicated) so these tests never
//  touch the real system pasteboard.
//
//  `processCopyTitleToClipboard` is called directly, not via a posted
//  notification -- see CalyxWindowControllerSetTabTitleTests's header for
//  why (mirrors CalyxWindowControllerCloseTabTests's established split).
//
//  Coverage-gap follow-up: see CalyxWindowControllerSetTabTitleTests's own
//  identically-worded follow-up note -- `registerNotificationObservers()`
//  never registered an observer for `.ghosttyCopyTitleToClipboard` either,
//  so copy_title_to_clipboard stayed silently inert despite `process*`
//  having a real body. The "Notification post (Tactic A)" section below
//  closes the gap and covers the fix.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCopyTitleToClipboardTests: XCTestCase {

    private struct Fixture {
        let controller: CalyxWindowController
        let clipboard: FakeClipboardWriter
    }

    private func makeFixture() -> Fixture {
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        let clipboard = FakeClipboardWriter()
        controller.clipboardWriter = clipboard
        return Fixture(controller: controller, clipboard: clipboard)
    }

    /// A tab with a `titleOverride` set must copy the OVERRIDE, not the
    /// underlying `title`.
    func test_processCopyTitleToClipboard_withTitleOverride_copiesOverride() {
        let fixture = makeFixture()
        let tab = Tab(title: "Terminal", titleOverride: "Custom Name")

        fixture.controller.processCopyTitleToClipboard(tab: tab)

        XCTAssertEqual(
            fixture.clipboard.copiedText,
            "Custom Name",
            "processCopyTitleToClipboard must copy titleOverride when one is set"
        )
    }

    /// With no override, the plain `tab.title` must be copied instead.
    func test_processCopyTitleToClipboard_noTitleOverride_copiesTabTitle() {
        let fixture = makeFixture()
        let tab = Tab(title: "My Shell")

        fixture.controller.processCopyTitleToClipboard(tab: tab)

        XCTAssertEqual(
            fixture.clipboard.copiedText,
            "My Shell",
            "processCopyTitleToClipboard must fall back to tab.title when titleOverride is nil"
        )
    }

    /// An empty resolved title (no override, and `title` itself is `""`)
    /// must write nothing to the clipboard at all.
    func test_processCopyTitleToClipboard_emptyResolvedTitle_writesNothing() {
        let fixture = makeFixture()
        let tab = Tab(title: "")

        fixture.controller.processCopyTitleToClipboard(tab: tab)

        XCTAssertNil(
            fixture.clipboard.copiedText,
            "processCopyTitleToClipboard must not write anything when the resolved title is empty"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Unlike `Fixture` above, `findTab(for:)` needs a real
    /// `SurfaceRegistry` entry -- mirrors `CalyxWindowControllerCloseWindowTests
    /// .SurfaceOwningFixture`.
    private struct SurfaceOwningFixture {
        let controller: CalyxWindowController
        let clipboard: FakeClipboardWriter
        let surfaceView: SurfaceView
    }

    private func makeSurfaceOwningFixture(tabTitle: String) -> SurfaceOwningFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(title: tabTitle, splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        let clipboard = FakeClipboardWriter()
        controller.clipboardWriter = clipboard
        return SurfaceOwningFixture(controller: controller, clipboard: clipboard, surfaceView: surfaceView)
    }

    /// Posting the real `.ghosttyCopyTitleToClipboard` notification for a
    /// surface THIS window owns must copy that surface's owning tab's
    /// title -- exercises `handleCopyTitleToClipboardNotification`'s
    /// `findTab(for:)` routing end to end, not just
    /// `processCopyTitleToClipboard` called directly.
    func test_ghosttyCopyTitleToClipboard_postedForOwnSurface_copiesTabTitle() {
        let fixture = makeSurfaceOwningFixture(tabTitle: "My Shell")

        NotificationCenter.default.post(name: .ghosttyCopyTitleToClipboard, object: fixture.surfaceView)

        XCTAssertEqual(
            fixture.clipboard.copiedText,
            "My Shell",
            "Posting .ghosttyCopyTitleToClipboard for a surface this window owns must copy that surface's owning tab's title"
        )
    }

    /// Regression guard: posting `.ghosttyCopyTitleToClipboard` for a
    /// surface NO controller's `windowSession` owns must write nothing to
    /// the clipboard -- depends on
    /// `handleCopyTitleToClipboardNotification`'s own `guard let
    /// (owningTab, _) = findTab(for:)` actually gating the dispatch.
    func test_ghosttyCopyTitleToClipboard_postedForSurfaceNoWindowOwns_writesNothing() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if findTab(for:)'s ownership
        // check were removed entirely.
        let fixture = makeSurfaceOwningFixture(tabTitle: "My Shell")
        let orphanSurfaceView = SurfaceView(frame: .zero)

        NotificationCenter.default.post(name: .ghosttyCopyTitleToClipboard, object: orphanSurfaceView)

        XCTAssertNil(
            fixture.clipboard.copiedText,
            "Posting .ghosttyCopyTitleToClipboard for a surface no window owns must not write to the clipboard"
        )
    }
}
