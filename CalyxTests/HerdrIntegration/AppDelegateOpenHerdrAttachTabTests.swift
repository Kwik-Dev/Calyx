//
//  AppDelegateOpenHerdrAttachTabTests.swift
//  CalyxTests
//
//  Coverage for `AppDelegate.openHerdrAttachTab(command:title:)`: opens
//  an already-synthesized herdr attach command
//  (`HerdrAttachCommandSynthesizer`'s job, out of this file's scope) as
//  a new tab -- mirroring `attachSessionAsNewTab`
//  (AppDelegateAttachSessionAsTabTests.swift's own precedent) but with
//  every calyx-session identity concern stripped: no `SessionRef`, no
//  `SessionSurfaceMap` registration (herdr session identity must never
//  enter either -- `SessionReconnectCoordinator.childExited`'s
//  surfaceMap-registration guard is what keeps herdr panes structurally
//  unreachable from calyx-session's own reconnect/kill/restore paths),
//  plus a new registration into `HerdrHostedSurfaces` (foundation for a
//  later de-duplication stage).
//
//  SAFETY: reuses `AppDelegateAttachSessionAsTabTests`' established
//  fixture shapes and test seams (`_testInsertWindowController`, the
//  placeholder-tab-observer + creation-hook pair) for the identical
//  reason that file gives: driving a real window/ghostty surface from
//  this test host hangs the XCTest process indefinitely. Every test
//  below inserts an unrelated, already-open window controller via
//  `_testInsertWindowController`, since the real implementation needs
//  `windowControllers.first(...)` to resolve to something (mirrors
//  `attachSessionAsNewTab`'s own `target` parameter).
//
//  Coverage:
//  - openHerdrAttachTab(command:title:) builds and fires
//    `_openHerdrAttachTabPlaceholderTabObserverForTesting` with a
//    placeholder Tab whose sessionRefs is EMPTY -- a permanent
//    structural invariant
//  - ...never registers the surface it would create in
//    SessionSurfaceMap -- same invariant, checked via the reverse
//    lookup (`SessionSurfaceMap.sessionID(for:)`) against a test-unique
//    UUID handed through `_openHerdrAttachTabSurfaceCreationHookForTesting`
//  - ...passes the EXACT command string through to
//    `_openHerdrAttachTabSurfaceCreationHookForTesting`, unchanged
//  - ...registers the surface ID
//    `_openHerdrAttachTabSurfaceCreationHookForTesting` returns with
//    `HerdrHostedSurfaces`
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateOpenHerdrAttachTabTests: XCTestCase {

    // `async throws` (not the plain synchronous overload): `setUp()`/
    // `tearDown()` override XCTestCase's own nonisolated signatures, so
    // only the `async` overload lets this @MainActor class's body
    // actually run isolated -- required to call
    // `HerdrHostedSurfaces.shared._testReset()` (itself @MainActor)
    // without a compile error (verified: the plain sync overload does
    // not compile here). Mirrors `AgentHookPipelineIntegrationTests`'
    // identical `setUp() async throws` precedent.
    override func setUp() async throws {
        try await super.setUp()
        HerdrHostedSurfaces.shared._testReset()
    }

    override func tearDown() async throws {
        HerdrHostedSurfaces.shared._testReset()
        try await super.tearDown()
    }

    /// An `AppDelegate` with one ordinary, unrelated main window already
    /// open -- mirrors `AppDelegateAttachSessionAsTabTests`' Row 3
    /// fixture (`Tab(title: "Unrelated")` + `TabGroup`/`WindowSession`/
    /// `CalyxWindow`/`CalyxWindowController`), reused identically by
    /// every test in this file since none of them need anything more
    /// specific about the window itself.
    private func makeAppDelegateWithAvailableWindow() -> AppDelegate {
        let appDelegate = AppDelegate()
        let tab = Tab(title: "Unrelated")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        appDelegate._testInsertWindowController(controller)
        return appDelegate
    }

    // MARK: - Placeholder tab: sessionRefs must be empty

    func test_openHerdrAttachTab_buildsPlaceholderTabWithEmptySessionRefs() throws {
        let appDelegate = makeAppDelegateWithAvailableWindow()
        var observedTab: Tab?
        appDelegate._openHerdrAttachTabPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._openHerdrAttachTabSurfaceCreationHookForTesting = { _ in UUID() }

        appDelegate.openHerdrAttachTab(command: "herdr-binary-fixture", title: "herdr: work")

        let tab = try XCTUnwrap(observedTab, "openHerdrAttachTab must build and observe a placeholder Tab")
        XCTAssertTrue(
            tab.sessionRefs.isEmpty,
            "The placeholder tab's sessionRefs must be empty -- herdr session identity must never enter " +
            "Tab.sessionRefs, a permanent structural invariant independent of how surface creation itself " +
            "is implemented"
        )
    }

    // MARK: - SessionSurfaceMap: must never gain an entry for herdr's surface

    func test_openHerdrAttachTab_neverRegistersItsSurfaceInSessionSurfaceMap() {
        let appDelegate = makeAppDelegateWithAvailableWindow()
        let fakeSurfaceID = UUID()
        appDelegate._openHerdrAttachTabSurfaceCreationHookForTesting = { _ in fakeSurfaceID }

        appDelegate.openHerdrAttachTab(command: "herdr-binary-fixture", title: "herdr: work")

        XCTAssertNil(
            SessionSurfaceMap.shared.sessionID(for: fakeSurfaceID),
            "openHerdrAttachTab must never register its surface in SessionSurfaceMap -- " +
            "SessionReconnectCoordinator.childExited's registration guard is what keeps herdr panes " +
            "structurally unreachable from calyx-session's reconnect/kill/restore paths"
        )
    }

    // MARK: - The exact command reaches surface creation, unchanged

    func test_openHerdrAttachTab_passesTheExactCommandToSurfaceCreation() {
        let appDelegate = makeAppDelegateWithAvailableWindow()
        var capturedCommand: String?
        appDelegate._openHerdrAttachTabSurfaceCreationHookForTesting = { command in
            capturedCommand = command
            return UUID()
        }

        let expectedCommand = "herdr-binary-fixture --session work"
        appDelegate.openHerdrAttachTab(command: expectedCommand, title: "herdr: work")

        XCTAssertEqual(
            capturedCommand, expectedCommand,
            "openHerdrAttachTab must pass the exact command string through to surface creation, unchanged"
        )
    }

    // MARK: - The created surface is registered with HerdrHostedSurfaces

    func test_openHerdrAttachTab_registersTheCreatedSurfaceInHerdrHostedSurfaces() {
        let appDelegate = makeAppDelegateWithAvailableWindow()
        let fakeSurfaceID = UUID()
        appDelegate._openHerdrAttachTabSurfaceCreationHookForTesting = { _ in fakeSurfaceID }

        appDelegate.openHerdrAttachTab(command: "herdr-binary-fixture", title: "herdr: work")

        XCTAssertTrue(
            HerdrHostedSurfaces.shared.contains(fakeSurfaceID),
            "openHerdrAttachTab must register the surface it creates with HerdrHostedSurfaces, so Stage " +
            "2/3's de-duplication can recognize it as herdr-hosted"
        )
    }
}
