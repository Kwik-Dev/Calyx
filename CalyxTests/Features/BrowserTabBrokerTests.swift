//
//  BrowserTabBrokerTests.swift
//  CalyxTests
//
//  Tests for BrowserTabBroker: app-level resolver for browser tabs across windows.
//
//  Coverage:
//  - resolveTab returns nil when appDelegate is nil
//  - resolveTab(nil) returns nil when no key window exists
//  - resolveTab with unknown UUID returns nil
//  - listTabs returns empty when appDelegate is nil
//  - listTabs returns empty when no browser tabs exist
//  - createTab returns nil when appDelegate is nil
//  - resolveTab(nil) resolves through `AppDelegate.currentWindowController`,
//    not a live `isKeyWindow` lookup, once `CurrentWindowTracker`
//    designates a window as current, so no window has to be key
//    -- proven with a controller that is inserted via
//    `_testInsertWindowController` and NEVER shown (no real
//    `orderFront`/`makeKeyAndOrderFront` call anywhere in this file),
//    so `window?.isKeyWindow` is false for it the whole time; only
//    `currentWindowTracker.didBecomeKey(_:)` designates it.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class BrowserTabBrokerTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT() -> BrowserTabBroker {
        BrowserTabBroker()
    }

    /// A `CalyxWindowController` whose active tab is a `.browser` tab
    /// (so `activeBrowserControllerForExternal` resolves to something),
    /// built the same throwaway-window/`restoring: true` way
    /// `GroupControllerFixture.swift`'s own fixtures are (no live
    /// ghostty surface needed for a browser tab).
    private func makeBrowserController(title: String = "Browser") -> CalyxWindowController {
        let tab = Tab(title: title, content: .browser(url: URL(string: "https://example.com")!))
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    // ==================== resolveTab ====================

    func test_should_return_nil_when_resolveTab_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()
        XCTAssertNil(sut.appDelegate, "Precondition: appDelegate should be nil")

        // When: resolveTab with a specific UUID
        let result = sut.resolveTab(UUID())

        // Then: returns nil because there are no windows to search
        XCTAssertNil(result, "resolveTab should return nil when appDelegate is nil")
    }

    func test_should_return_nil_when_resolveTab_nil_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()

        // When: resolveTab(nil) — requesting active browser tab in key window
        let result = sut.resolveTab(nil)

        // Then: returns nil because there is no key window
        XCTAssertNil(result, "resolveTab(nil) should return nil when appDelegate is nil")
    }

    func test_should_return_nil_when_resolveTab_with_unknown_uuid() {
        // Given: broker with no appDelegate
        let sut = makeSUT()
        let unknownID = UUID()

        // When: resolveTab with an ID that doesn't match any tab
        let result = sut.resolveTab(unknownID)

        // Then: returns nil
        XCTAssertNil(result, "resolveTab should return nil for unknown tab ID")
    }

    // ==================== listTabs ====================

    func test_should_return_empty_when_listTabs_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()

        // When: listing all browser tabs
        let result = sut.listTabs()

        // Then: returns empty array because there are no windows
        XCTAssertTrue(result.isEmpty, "listTabs should return empty when appDelegate is nil")
    }

    // ==================== createTab ====================

    func test_should_return_nil_when_createTab_with_nil_appDelegate() {
        // Given: broker with no appDelegate set
        let sut = makeSUT()
        let url = URL(string: "https://example.com")!

        // When: attempting to create a browser tab
        let result = sut.createTab(url: url)

        // Then: returns nil because there is no key window to create it in
        XCTAssertNil(result, "createTab should return nil when appDelegate is nil")
    }

    // ==================== resolveTab(nil) via current window ====================

    func test_resolveTab_nil_withNoKeyWindow_resolvesThroughCurrentWindowController() {
        let appDelegate = AppDelegate()
        let host = makeBrowserController(title: "Host")
        appDelegate._testInsertWindowController(host)
        _ = appDelegate.currentWindowTracker.didBecomeKey(host)
        XCTAssertTrue(appDelegate.currentWindowController === host, "precondition: host is the current window")
        XCTAssertFalse(host.window?.isKeyWindow ?? false, "precondition: this controller's window is never shown, so it is never the real key window")

        let sut = makeSUT()
        sut.appDelegate = appDelegate

        let result = sut.resolveTab(nil)

        XCTAssertNotNil(result,
                        "resolveTab(nil) must resolve through AppDelegate.currentWindowController rather than a live isKeyWindow lookup, so a nil-target request can still route to a window even though nothing is actually key")
    }

    // ==================== Initial State ====================

    func test_should_have_nil_appDelegate_after_init() {
        // Given & When: fresh broker
        let sut = makeSUT()

        // Then: appDelegate is nil by default (weak reference, not set)
        XCTAssertNil(sut.appDelegate,
                     "BrowserTabBroker should have nil appDelegate after initialization")
    }
}
