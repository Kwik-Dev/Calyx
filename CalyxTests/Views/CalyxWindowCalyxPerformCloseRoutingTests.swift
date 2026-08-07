//
//  CalyxWindowCalyxPerformCloseRoutingTests.swift
//  CalyxTests
//
//  TDD Red phase, GitHub issue #45. Full root-cause writeup:
//  `NSWindow+CalyxClose.swift`'s header comment.
//
//  Exercises `CalyxWindow.calyxPerformClose(_:)` itself (not the pure
//  `CalyxWindowController.closeFocusedTarget` decision function, see
//  `CalyxWindowControllerCloseFocusedTargetTests` for that exhaustive
//  matrix) — proves the WIRING from "Cmd+W landed on this window" all
//  the way to "the right `CloseFocusedTarget` was resolved", via
//  `CalyxWindowController._closeFocusedTargetHookForTesting`, mirroring
//  `CalyxWindowControllerCloseWindowTests`'s identical
//  hook-instead-of-the-real-unsafe-close pattern (a real close is never
//  driven here, so there is no test-host-crash risk — see that file's
//  own header for the danger this avoids).
//
//  Against the CURRENT code, `CalyxWindow.calyxPerformClose(_:)` is an
//  empty override and `CalyxWindowController.performCloseFocusedTarget(_:)`
//  is an empty stub that never touches the hook at all, so BOTH tests
//  below are RED-proving: the hook is never invoked, and `observed`
//  stays `nil`.
//
//  Fixtures mirror `CalyxWindowControllerCloseWindowTests
//  .makeSurfaceOwningFixture()` (terminal case) and
//  `AppDelegateCloseAllWindowsTests.makeSingleTabFixture()` (browser
//  case, no live ghostty surface needed for a browser tab).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowCalyxPerformCloseRoutingTests: XCTestCase {

    // MARK: - Fixtures

    private struct TerminalTabFixture {
        let controller: CalyxWindowController
        let tabID: UUID
        let leafID: UUID
    }

    /// Single-pane/single-tab/single-group terminal window.
    /// `SplitTree(leafID:)` auto-assigns `focusedLeafID = leafID` (see
    /// that initializer's own doc comment), so this tab's focused leaf
    /// is unambiguous.
    private func makeTerminalTabFixture() -> TerminalTabFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return TerminalTabFixture(controller: controller, tabID: tab.id, leafID: leafID)
    }

    private struct BrowserTabFixture {
        let controller: CalyxWindowController
        let tabID: UUID
    }

    /// Single browser tab: no `SurfaceRegistry` surface needed at all
    /// (mirrors `AppDelegateCloseAllWindowsTests.makeSingleTabFixture()`'s
    /// identical "no live ghostty surface" reasoning).
    private func makeBrowserTabFixture() -> BrowserTabFixture {
        let tab = Tab(content: .browser(url: URL(string: "https://example.com")!))
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return BrowserTabFixture(controller: controller, tabID: tab.id)
    }

    // MARK: - Tests

    /// RED-proving: see file header.
    func test_calyxPerformClose_terminalTabWithFocusedLeaf_routesToSurfaceTarget() {
        let fixture = makeTerminalTabFixture()
        var observed: CloseFocusedTarget?
        fixture.controller._closeFocusedTargetHookForTesting = { observed = $0 }

        fixture.controller.window?.calyxPerformClose(nil)

        XCTAssertEqual(
            observed, .surface(tabID: fixture.tabID, surfaceID: fixture.leafID),
            "calyxPerformClose(_:) on this window must resolve to .surface for its focused terminal pane"
        )
    }

    /// RED-proving: see file header.
    func test_calyxPerformClose_browserTab_routesToTabTarget() {
        let fixture = makeBrowserTabFixture()
        var observed: CloseFocusedTarget?
        fixture.controller._closeFocusedTargetHookForTesting = { observed = $0 }

        fixture.controller.window?.calyxPerformClose(nil)

        XCTAssertEqual(
            observed, .tab(fixture.tabID),
            "calyxPerformClose(_:) on a browser-tab window must resolve to .tab, never .surface"
        )
    }
}
