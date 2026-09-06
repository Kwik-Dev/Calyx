//
//  AppDelegateCurrentWindowTests.swift
//  CalyxTests
//
//  Covers `AppDelegate.currentWindowController` (the window the user is
//  working in: the key `CalyxWindowController`, else the last one that
//  was key, else the first open window, nil with zero open windows --
//  resolved via `currentWindowTracker`, see `CurrentWindowTrackerTests
//  .swift`'s own header for the full resolution contract), the app-wide
//  approval panel wiring that hangs off it, `windowController(owningSurface:)`,
//  and `restoreTerminalFocusAfterApproval(targetSurfaceID:)`.
//  `approvalBannerModel`/`approvalPanelController` are singletons owned
//  by `AppDelegate` itself (one page-style panel for the whole app, not
//  one per window), `refreshApprovalPanel()` re-renders that single
//  panel (a no-op while `isApplicationTerminating`), and
//  `windowControllerDidBecomeKey(_:)`/`windowControllerGeometryChanged(_:)`
//  are what `CalyxWindowController` calls on key/geometry changes
//  instead of refreshing its own, per-window banner.
//
//  Mirrors `AppDelegateSpawnRemoteSessionTabWindowLookupTests`'s
//  established convention: a bare `AppDelegate()`, controllers
//  registered via the DEBUG-only `_testInsertWindowController` seam
//  (no live window/surface creation, no `NSApp.delegate` swap needed --
//  none of these tests drive a real close/termination path).
//  `approvalPanelController._orderHookForTesting` is set on every bare
//  `AppDelegate()` before any request is submitted, so no test here
//  ever calls the real `orderFrontRegardless()`/`orderOut(_:)` (mirrors
//  `ApprovalPanelControllerTests`'s own established discipline).
//  `ApprovalInboxStore.shared` is used deliberately, not a fresh
//  instance -- `AppDelegate.approvalBannerModel`'s production wiring is
//  hardcoded to `store: .shared` -- so every submitted request is
//  `decide()`d again via `defer` before the test ends, to leave the
//  shared store empty for the next test.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateCurrentWindowTests: XCTestCase {

    /// `removeWindowController` reaches `saveImmediately()`/
    /// `requestSave()`, both of which hit the real
    /// `SessionPersistenceActor.shared` (and, transitively, the real
    /// `~/.calyx` on disk) -- mirrors
    /// `AppDelegateLastWindowClosedDoesNotTerminateTests.RemoveWindowControllerTerminationSpyAppDelegate`'s
    /// identical safety rationale, overriding both as pure spies so
    /// every test in this file can drive the real `removeWindowController`
    /// without ever touching the developer's actual on-disk session.
    private final class SaveSpyAppDelegate: AppDelegate {
        override func saveImmediately() {}
        override func requestSave() {}
    }

    private func makeController(title: String) -> CalyxWindowController {
        let tab = Tab(title: title)
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

    /// A `CalyxWindowController` whose single tab owns exactly one
    /// split-tree leaf, `surfaceID` -- built inline (a fresh
    /// `SurfaceRegistry` + `_testInsert(view:id:)`, mirroring
    /// `TwoPaneSessionFixture.swift`'s own construction) rather than
    /// reusing that shared fixture, since this file needs no
    /// `SessionSurfaceMap.shared` registration (no session-attach flow
    /// exercised here) and therefore owes no such cleanup.
    private func makeControllerOwningSurface(_ surfaceID: UUID, title: String) -> CalyxWindowController {
        let registry = SurfaceRegistry()
        registry._testInsert(view: SurfaceView(frame: .zero), id: surfaceID)
        let tab = Tab(
            title: title,
            splitTree: SplitTree(root: .leaf(id: surfaceID), focusedLeafID: surfaceID),
            registry: registry
        )
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

    private func makeRequest(targetSurfaceID: UUID? = UUID()) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: targetSurfaceID, payload: "ls -la", createdAt: Date())
    }

    // MARK: - currentWindowController

    func test_currentWindowController_withNoControllers_isNil() {
        let appDelegate = AppDelegate()

        XCTAssertNil(appDelegate.currentWindowController, "with zero open windows there is no current window at all")
    }

    func test_currentWindowController_withTwoControllers_defaultsToFirst() {
        let appDelegate = AppDelegate()
        let first = makeController(title: "First")
        let second = makeController(title: "Second")
        appDelegate._testInsertWindowController(first)
        appDelegate._testInsertWindowController(second)

        XCTAssertTrue(appDelegate.currentWindowController === first,
                      "with no window ever having become key yet, currentWindowController must fall back to the FIRST inserted controller")
    }

    func test_currentWindowTracker_didBecomeKey_secondController_changesCurrentWindowController() {
        let appDelegate = AppDelegate()
        let first = makeController(title: "First")
        let second = makeController(title: "Second")
        appDelegate._testInsertWindowController(first)
        appDelegate._testInsertWindowController(second)

        _ = appDelegate.currentWindowTracker.didBecomeKey(second)

        XCTAssertTrue(appDelegate.currentWindowController === second,
                      "once a different controller becomes key, currentWindowController must resolve to it")
    }

    func test_removeWindowController_removingCurrentWindow_fallsBackToFirstRemaining() {
        let appDelegate = SaveSpyAppDelegate()
        let first = makeController(title: "First")
        let second = makeController(title: "Second")
        appDelegate._testInsertWindowController(first)
        appDelegate._testInsertWindowController(second)
        _ = appDelegate.currentWindowTracker.didBecomeKey(second)
        XCTAssertTrue(appDelegate.currentWindowController === second, "precondition: second is the current window")

        appDelegate.removeWindowController(second)

        XCTAssertTrue(appDelegate.currentWindowController === first,
                      "once the current window's controller is removed, currentWindowController must fall back to the remaining first controller")
    }

    // MARK: - windowController(owningSurface:)

    func test_windowControllerOwningSurface_returnsControllerOwningThatSurface() {
        let appDelegate = SaveSpyAppDelegate()
        let surfaceID = UUID()
        let first = makeController(title: "First")
        let second = makeControllerOwningSurface(surfaceID, title: "Second")
        appDelegate._testInsertWindowController(first)
        appDelegate._testInsertWindowController(second)

        XCTAssertTrue(appDelegate.windowController(owningSurface: surfaceID) === second,
                      "windowController(owningSurface:) must resolve to the controller whose split tree actually owns that surface")
        XCTAssertNil(appDelegate.windowController(owningSurface: UUID()),
                    "an unknown surface id must resolve to nil, never fall back to any open controller")
    }

    // MARK: - App-wide approval panel: refreshApprovalPanel()

    func test_refreshApprovalPanel_pendingRequest_createsPanel_secondRequestSharesItWithPositionInfo() {
        let appDelegate = AppDelegate()
        var intents: [ApprovalPanelController.OrderIntent] = []
        appDelegate.approvalPanelController._orderHookForTesting = { intents.append($0) }

        let first = makeRequest()
        ApprovalInboxStore.shared.submit(first)
        defer { ApprovalInboxStore.shared.decide(id: first.id, .denied(.userRejected)) }

        appDelegate.refreshApprovalPanel()

        XCTAssertNotNil(appDelegate.approvalPanelController.panel,
                        "refreshApprovalPanel() must drive approvalPanelController.render(), lazily creating the app-wide floating panel once a request is pending")
        guard case .orderFront = intents.last else {
            XCTFail("expected the last recorded intent to be .orderFront, got \(intents)")
            return
        }
        let firstPanel = appDelegate.approvalPanelController.panel

        let second = makeRequest()
        ApprovalInboxStore.shared.submit(second)
        defer { ApprovalInboxStore.shared.decide(id: second.id, .denied(.userRejected)) }

        appDelegate.refreshApprovalPanel()

        XCTAssertTrue(appDelegate.approvalPanelController.panel === firstPanel,
                      "a second pending request must reuse the SAME app-wide panel instance -- there is only ever one, page-style")
        XCTAssertEqual(appDelegate.approvalBannerModel.positionInfo?.count, 2,
                       "with two requests pending, the app-wide model's own queue must report a count of 2")
    }

    /// With zero open windows, `currentWindowController` is nil, but a
    /// window-agnostic (nil `targetSurfaceID`) request must still show
    /// the app-wide panel -- it falls back to `NSScreen.main`'s own
    /// top-right corner rather than waiting for a window to exist. This
    /// test only pins that an order intent is still recorded, never the
    /// specific frame/screen (see this suite's header: a bare
    /// `AppDelegate()` has zero `windowControllers` by construction, so
    /// `currentWindowController` is guaranteed nil here without
    /// inserting and then removing anything).
    func test_refreshApprovalPanel_nilTargetRequest_zeroOpenWindows_stillOrdersFront() {
        let appDelegate = AppDelegate()
        XCTAssertNil(appDelegate.currentWindowController, "precondition: a fresh AppDelegate() has zero open windows")
        var intents: [ApprovalPanelController.OrderIntent] = []
        appDelegate.approvalPanelController._orderHookForTesting = { intents.append($0) }

        let request = makeRequest(targetSurfaceID: nil)
        ApprovalInboxStore.shared.submit(request)
        defer { ApprovalInboxStore.shared.decide(id: request.id, .denied(.userRejected)) }

        appDelegate.refreshApprovalPanel()

        guard case .orderFront = intents.last else {
            XCTFail("a window-agnostic request must still show the app-wide panel with zero open windows -- got \(intents)")
            return
        }
    }

    func test_refreshApprovalPanel_whileApplicationTerminating_isNoOp() {
        let appDelegate = AppDelegate()
        var intents: [ApprovalPanelController.OrderIntent] = []
        appDelegate.approvalPanelController._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        ApprovalInboxStore.shared.submit(request)
        defer { ApprovalInboxStore.shared.decide(id: request.id, .denied(.userRejected)) }
        appDelegate._setApplicationTerminatingForTesting(true)

        appDelegate.refreshApprovalPanel()

        XCTAssertTrue(intents.isEmpty, "refreshApprovalPanel() must be a complete no-op while isApplicationTerminating")
    }

    // MARK: - windowControllerDidBecomeKey(_:)

    func test_windowControllerDidBecomeKey_changesCurrentWindow_andRefreshesPanel() {
        let appDelegate = AppDelegate()
        let first = makeController(title: "First")
        let second = makeController(title: "Second")
        appDelegate._testInsertWindowController(first)
        appDelegate._testInsertWindowController(second)
        var intents: [ApprovalPanelController.OrderIntent] = []
        appDelegate.approvalPanelController._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        ApprovalInboxStore.shared.submit(request)
        defer { ApprovalInboxStore.shared.decide(id: request.id, .denied(.userRejected)) }

        appDelegate.windowControllerDidBecomeKey(second)

        XCTAssertTrue(appDelegate.currentWindowController === second,
                      "windowControllerDidBecomeKey must update currentWindowController once it actually changes")
        guard case .orderFront = intents.last else {
            XCTFail("a current-window change must re-render the app-wide panel, got \(intents)")
            return
        }
    }

    func test_windowControllerDidBecomeKey_sameControllerAgain_doesNotReRefresh() {
        let appDelegate = AppDelegate()
        let only = makeController(title: "Only")
        appDelegate._testInsertWindowController(only)
        appDelegate.windowControllerDidBecomeKey(only) // first designation, already == ordered.first
        var intents: [ApprovalPanelController.OrderIntent] = []
        appDelegate.approvalPanelController._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        ApprovalInboxStore.shared.submit(request)
        defer { ApprovalInboxStore.shared.decide(id: request.id, .denied(.userRejected)) }

        appDelegate.windowControllerDidBecomeKey(only)

        XCTAssertTrue(intents.isEmpty,
                      "re-designating the SAME already-current window must not re-render the panel")
    }

    // MARK: - windowControllerGeometryChanged(_:)

    func test_windowControllerGeometryChanged_onlyCurrentWindowTriggersRender() {
        let appDelegate = AppDelegate()
        let current = makeController(title: "Current")
        let other = makeController(title: "Other")
        appDelegate._testInsertWindowController(current)
        appDelegate._testInsertWindowController(other)
        XCTAssertTrue(appDelegate.currentWindowController === current, "precondition: with neither controller ever key, currentWindowController falls back to the first inserted")
        var intents: [ApprovalPanelController.OrderIntent] = []
        appDelegate.approvalPanelController._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        ApprovalInboxStore.shared.submit(request)
        defer { ApprovalInboxStore.shared.decide(id: request.id, .denied(.userRejected)) }

        appDelegate.windowControllerGeometryChanged(other)

        XCTAssertTrue(intents.isEmpty, "a geometry change on a window that is NOT the current one must not re-render the panel")

        appDelegate.windowControllerGeometryChanged(current)

        guard case .orderFront = intents.last else {
            XCTFail("a geometry change on the current window must re-render (re-measure) the panel, got \(intents)")
            return
        }
    }

    // MARK: - restoreTerminalFocusAfterApproval(targetSurfaceID:)

    /// With two inserted controllers where the SECOND owns a surface: a
    /// surface-targeted call must reach only the controller that owns
    /// that surface (`windowController(owningSurface:)`), and a nil
    /// call must reach only `currentWindowController` (here, the
    /// first inserted controller, since neither has ever become key) --
    /// never both, and never the other one.
    func test_restoreTerminalFocusAfterApproval_surfaceTargeted_reachesOwningController_nilReachesCurrentWindow() {
        let appDelegate = SaveSpyAppDelegate()
        let surfaceID = UUID()
        let first = makeController(title: "First")
        let second = makeControllerOwningSurface(surfaceID, title: "Second")
        appDelegate._testInsertWindowController(first)
        appDelegate._testInsertWindowController(second)
        XCTAssertTrue(appDelegate.currentWindowController === first, "precondition: with neither controller ever key, currentWindowController falls back to the first inserted")
        XCTAssertTrue(appDelegate.windowController(owningSurface: surfaceID) === second, "precondition: second owns the surface")

        var firstCallCount = 0
        var secondCallCount = 0
        first._restoreTerminalFocusAfterApprovalHookForTesting = { firstCallCount += 1 }
        second._restoreTerminalFocusAfterApprovalHookForTesting = { secondCallCount += 1 }

        appDelegate.restoreTerminalFocusAfterApproval(targetSurfaceID: surfaceID)

        XCTAssertEqual(secondCallCount, 1, "a surface-targeted call must reach the controller owning that surface")
        XCTAssertEqual(firstCallCount, 0, "a surface-targeted call must never reach any other controller")

        appDelegate.restoreTerminalFocusAfterApproval(targetSurfaceID: nil)

        XCTAssertEqual(firstCallCount, 1, "a nil-targeted call must reach currentWindowController")
        XCTAssertEqual(secondCallCount, 1, "a nil-targeted call must never reach the surface-owning controller when it isn't the current window")
    }
}
