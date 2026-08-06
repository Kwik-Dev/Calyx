//
//  CalyxWindowControllerCloseArmsTests.swift
//  CalyxTests
//
//  TDD Red phase for round-4 fixes F7/F8 (r4-fix-spec.md; full evidence
//  in r4-verdicts.md V07/V08), plus the window-lifetime redesign's own
//  "closing the last tab/group must not confirm quit" coverage below.
//
//  - F7/T7 (the three arms NOT already covered by
//    `SessionCommandPaletteTests`'s `closeSurfaceAndCleanUp` coverage):
//    `closeTab`, `closeActiveGroup` (via the public `closeGroup(_:)`),
//    and `closeAllTabsInGroup` must set `isClosingForShutdown = true`
//    immediately before `window?.close()`, currently dead code for
//    `windowDidExitFullScreen`'s stale-snapshot guard on these three
//    paths (V07's "bonus lead").
//
//  Window-lifetime redesign: this file used to also cover F3/T3
//  (`windowShouldClose` pre-populating `closingTabIDs` before consulting
//  `confirmQuitIfNeeded`, and removing them again on cancel) -- deleted
//  along with `windowShouldClose` itself and the close-path confirm-quit
//  prompt it drove, see `AppDelegateLastWindowClosedDoesNotTerminateTests`.
//
//  Fixtures below use plain, leaf-less `Tab(title:)` tabs (no
//  `SurfaceRegistry` surfaces): `closeTab`/`closeActiveGroup`/
//  `closeAllTabsInGroup` all operate on `WindowSession`'s tab/group model
//  and `tab.registry.allIDs` (empty here, so the kill/destroy loop is a
//  harmless no-op), no live ghostty surface is needed to exercise the
//  flag-timing contracts under test.
//
//  `closeAllTabsInGroup(id:)` is not `private` (P4 round-4 fix RED
//  phase, see its own doc comment) so this file can drive it directly,
//  matching this codebase's `handleSessionReconnectDecision` precedent.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseArmsTests: XCTestCase {

    // MARK: - Fixtures

    private struct SingleTabFixture {
        let controller: CalyxWindowController
        let tabID: UUID
        let groupID: UUID
    }

    /// Single-tab/single-group window: the "last tab in the last
    /// group" case every arm under test gates its confirm-quit prompt
    /// on.
    private func makeSingleTabFixture() -> SingleTabFixture {
        let tab = Tab(title: "Only")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SingleTabFixture(controller: controller, tabID: tab.id, groupID: group.id)
    }

    // MARK: - Mocks

    /// `AppDelegate` subclass confirming quit unconditionally, driving
    /// every close path under test through to its `.windowShouldClose`
    /// arm without a real, blocking `NSAlert.runModal()`.
    /// `removeWindowController` comes from `ConfirmQuitMockAppDelegate`
    /// (R6-J, r6-fix-spec.md): confirmed teardown here empties the
    /// window for real, calling `window?.close()` -> `windowWillClose`
    /// -> `AppDelegate.removeWindowController`, see that base class's
    /// own doc comment for why the override is a no-op.
    private final class ConfirmingAppDelegate: ConfirmQuitMockAppDelegate {
        override func confirmQuitIfNeeded() -> Bool { true }
    }

    // MARK: - F7/T7: isClosingForShutdown timing

    /// Against the CURRENT code, `closeTab`'s `.windowShouldClose` case
    /// never sets `isClosingForShutdown`, so it remains `false` after
    /// this call.
    func test_closeTab_setsIsClosingForShutdown_beforeWindowCloses() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeTab(nil)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                      "closeTab's .windowShouldClose arm must set isClosingForShutdown before " +
                      "window?.close(), matching windowShouldClose's own eager set")
    }

    /// Same contract for `closeActiveGroup` (driven via the public
    /// `closeGroup(_:)` action).
    func test_closeGroup_setsIsClosingForShutdown_beforeWindowCloses() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeGroup(nil)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                      "closeActiveGroup's .windowShouldClose arm must set isClosingForShutdown before " +
                      "window?.close(), matching windowShouldClose's own eager set")
    }

    /// Same contract for `closeAllTabsInGroup(id:)`.
    func test_closeAllTabsInGroup_setsIsClosingForShutdown_beforeWindowCloses() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeAllTabsInGroup(id: fixture.groupID)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                      "closeAllTabsInGroup's .windowShouldClose arm must set isClosingForShutdown before " +
                      "window?.close(), matching windowShouldClose's own eager set")
    }

    // MARK: - Window-lifetime redesign: closing the last tab/group must not confirm quit

    /// Closing the last window no longer terminates Calyx at all (see
    /// `AppDelegateLastWindowClosedDoesNotTerminateTests`), so the "Quit
    /// Calyx?" confirmation these three arms show via
    /// `confirmQuitBeforeCloseIfWouldTerminate` ->
    /// `AppDelegate.confirmQuitIfNeeded` must be removed from every close
    /// path entirely (Cmd+Q / the Quit menu item keep their own,
    /// unrelated confirmation). Counts calls the same way
    /// `SessionCommandPaletteTests.MockConfirmQuitAppDelegate` and
    /// `SessionReconnectGiveUpTests.LastPaneGiveUpMockAppDelegate` do;
    /// still returns `true` (rather than never being consulted at all
    /// under the CURRENT code) so a not-yet-fixed close path proceeds
    /// through to its real `.windowShouldClose` arm exactly as
    /// `ConfirmingAppDelegate` above already does, keeping
    /// `removeWindowController`'s no-op override load-bearing for
    /// test-process safety. `requestSave` is also overridden to a no-op:
    /// with the confirm-quit gate satisfied, `closeTab`/`closeActiveGroup`/
    /// `closeAllTabsInGroup` all reach their own `requestSave()` call on
    /// the way out, which -- left unmocked -- would reach the REAL
    /// `AppDelegate.requestSave()` and, via its async, actor-hopping
    /// `SessionPersistenceActor.shared.save(...)`, risk writing to the
    /// developer's actual `~/.calyx` (confirmed by observation: running
    /// this suite without this override left a real, if empty, write
    /// behind).
    private final class ConfirmQuitCallCountAppDelegate: ConfirmQuitMockAppDelegate {
        private(set) var confirmQuitCallCount = 0

        override func confirmQuitIfNeeded() -> Bool {
            confirmQuitCallCount += 1
            return true
        }

        override func requestSave() {}
    }

    /// Against the CURRENT code, `closeTab`'s `.windowShouldClose` branch
    /// still calls `confirmQuitBeforeCloseIfWouldTerminate` ->
    /// `AppDelegate.confirmQuitIfNeeded` before tearing anything down, so
    /// this count is 1, not 0.
    func test_closeTab_lastTab_neverConsultsConfirmQuitGate() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmQuitCallCountAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeTab(nil)
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 0,
                      "Closing the last tab must no longer show any quit confirmation -- closing the last " +
                      "window must not terminate the app any more, so there is nothing left to confirm")
    }

    /// Same contract for `closeActiveGroup` (driven via the public
    /// `closeGroup(_:)` action). Against the CURRENT code this count is
    /// 1, not 0, for the same reason as `closeTab` above.
    func test_closeGroup_lastGroup_neverConsultsConfirmQuitGate() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmQuitCallCountAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeGroup(nil)
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 0,
                      "Closing the last group must no longer show any quit confirmation")
    }

    /// Same contract for `closeAllTabsInGroup(id:)`. Against the CURRENT
    /// code this count is 1, not 0, for the same reason as `closeTab`
    /// above.
    func test_closeAllTabsInGroup_lastGroup_neverConsultsConfirmQuitGate() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmQuitCallCountAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeAllTabsInGroup(id: fixture.groupID)
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 0,
                      "Closing the last group via closeAllTabsInGroup must no longer show any quit " +
                      "confirmation")
    }
}
