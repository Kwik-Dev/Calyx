//
//  ApprovalPanelControllerTests.swift
//  CalyxTests
//
//  Covers `ApprovalPanelController`'s `render()` lifecycle: lazily
//  creating the floating `ApprovalPanelWindow` on first non-nil
//  `model.current`, sizing/positioning it via `ApprovalPanelArranger`,
//  and ordering it front/out -- WITHOUT ever calling the real AppKit
//  `orderFrontRegardless()`/`orderOut(_:)`, using the `#if DEBUG`
//  `_orderHookForTesting` seam instead (mirrors
//  `QuickTerminalController._requestHideHookForTesting`'s established
//  convention). No test in this file ever shows a real window.
//
//  Coverage:
//  - render() with nothing pending creates no panel and records no
//    order intent, so `app.windows.count` stays untouched in a real
//    run.
//  - Submitting a request then calling render() lazily creates the
//    panel, records exactly one `.orderFront(frame)`, and that WINDOW
//    frame's own right edge sits `margin` inside the injected
//    visibleFrame's right edge, with a width equal to fixedWidth +
//    dismissGutter (344 + 12 = 356pt) on a screen wide enough -- the
//    window is `ApprovalPanelArranger.dismissGutter` points larger than
//    the glass sheet on its top and left, so the sheet's own top-right
//    corner (not the window's) is the one that sits exactly `margin`
//    inside both edges.
//  - A second render() with the SAME still-pending request is
//    idempotent: records another `.orderFront` with an identical frame,
//    but creates no second panel instance.
//  - Deciding the displayed request then calling render() records
//    `.orderOut`.
//  - tearDown() then render() records nothing further, `isTornDown`
//    becomes true, and the panel is no longer visible.
//  - Width is exercised end-to-end through render(): the WINDOW's own
//    width is ALWAYS exactly `ApprovalPanelArranger.fixedWidth +
//    dismissGutter` (344 + 12 = 356pt), regardless of payload length --
//    a single-pass measurement at a fixed sheet width, never
//    content-dependent; a visible frame narrower than fixedWidth clamps
//    the SHEET down to the available cap instead, still `+ dismissGutter`
//    for the window.
//  - reanchor() re-measures (the same path render() itself takes) and
//    reports a fresh order intent anchored to whatever the injected
//    `visibleFrame` closure currently reports, not whatever it reported
//    the last time render() ran.
//  - After render(), the content view's own measured-size echo
//    (onContentSizeChange -> applyContentHeight(_:)) causes no further
//    render -- a brief run-loop pump records no additional order
//    intent. After navigating to a different pending request
//    (selectNext()) and pumping again, exactly one new order intent is
//    recorded for the navigation itself, and no more after that.
//  - A payload that hits `heightCap(visibleFrame:)` (a very short visible
//    frame) yields a WINDOW height of exactly `heightCap + dismissGutter`
//    -- pins `measureFrame(hostingController:)`'s own gutter arithmetic,
//    ruling out both an un-inflated `heightCap` and a double-counted
//    `heightCap + 2*dismissGutter`.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class ApprovalPanelControllerTests: XCTestCase {

    private let fixedVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 850)

    private func makeRequest(payload: String = "ls -la /tmp", targetSurfaceID: UUID? = nil) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: targetSurfaceID, payload: payload, createdAt: Date())
    }

    private func makeController(store: ApprovalInboxStore) -> ApprovalPanelController {
        makeControllerAndModel(store: store).controller
    }

    private func makeControllerAndModel(store: ApprovalInboxStore) -> (controller: ApprovalPanelController, model: ApprovalBannerModel) {
        let model = ApprovalBannerModel(store: store)
        let controller = ApprovalPanelController(
            model: model,
            hostWindow: { nil },
            visibleFrame: { [weak self] in self?.fixedVisibleFrame ?? .zero }
        )
        return (controller, model)
    }

    /// Same as `makeControllerAndModel(store:)`, but also wires
    /// `handOffKey` to a recording closure -- used by the
    /// `handOffKey`/`_panelIsKeyForTesting` coverage below.
    private func makeControllerAndModel(
        store: ApprovalInboxStore, handOffKey: @escaping (UUID?) -> Void
    ) -> (controller: ApprovalPanelController, model: ApprovalBannerModel) {
        let model = ApprovalBannerModel(store: store)
        let controller = ApprovalPanelController(
            model: model,
            hostWindow: { nil },
            visibleFrame: { [weak self] in self?.fixedVisibleFrame ?? .zero },
            handOffKey: handOffKey
        )
        return (controller, model)
    }

    // MARK: - render(): nothing pending

    func test_render_withNothingPending_createsNoPanel() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }

        controller.render()

        XCTAssertNil(controller.panel, "render() with nothing pending must never create a panel")
        XCTAssertTrue(intents.isEmpty, "render() with nothing pending must record no order intent at all")
    }

    // MARK: - render(): a pending request

    func test_render_withPendingRequest_createsPanelAndOrdersFrontAtTopRightCorner() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        store.submit(request)

        controller.render()

        XCTAssertNotNil(controller.panel, "render() with a visible pending request must lazily create the panel")
        XCTAssertEqual(intents.count, 1, "exactly one order intent must be recorded")
        guard case .orderFront(let frame) = intents[0] else {
            XCTFail("the recorded intent must be .orderFront, got \(intents[0])")
            return
        }
        XCTAssertEqual(frame.maxX, fixedVisibleFrame.maxX - 12, accuracy: 0.5,
                       "the window's right edge must sit `margin` (12pt) inside the visible frame's right edge (the dismiss gutter never sits on the right)")
        XCTAssertEqual(frame.maxY,
                       fixedVisibleFrame.maxY - ApprovalPanelArranger.margin + ApprovalPanelArranger.dismissGutter,
                       accuracy: 0.5,
                       "the window's top edge must sit at visibleFrame.maxY - margin + dismissGutter: `margin` (12pt) inside the visible frame's top edge for the sheet, plus the 12pt dismissGutter above that")
        XCTAssertEqual(frame.width, 356, accuracy: 0.5, "the window's width must always be the fixed 344pt sheet width plus the 12pt dismissGutter")
        XCTAssertGreaterThan(frame.height, 0, "the panel must always have a positive height")

        // Clean up so this store doesn't leak a pending request.
        store.decide(id: request.id, .denied(.userRejected))
    }

    func test_render_calledAgainWithSameRequest_isIdempotent_reusesSamePanelInstance() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        store.submit(request)

        controller.render()
        let firstPanel = controller.panel
        XCTAssertNotNil(firstPanel)

        controller.render()

        XCTAssertTrue(controller.panel === firstPanel, "a second render() with the same still-pending request must reuse the SAME panel instance, never create a second one")
        XCTAssertEqual(intents.count, 2, "each render() call while a request is showing records its own .orderFront intent")
        guard case .orderFront(let firstFrame) = intents[0], case .orderFront(let secondFrame) = intents[1] else {
            XCTFail("both recorded intents must be .orderFront")
            return
        }
        XCTAssertEqual(firstFrame, secondFrame, "re-rendering the same request must compute an identical frame")

        store.decide(id: request.id, .denied(.userRejected))
    }

    // MARK: - render(): request decided

    func test_render_afterRequestDecided_ordersOut() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        store.submit(request)
        controller.render()
        intents.removeAll()

        store.decide(id: request.id, .allowed)
        controller.render()

        XCTAssertEqual(intents.count, 1, "render() once the displayed request has been decided must record exactly one more intent")
        guard case .orderOut = intents[0] else {
            XCTFail("the recorded intent must be .orderOut, got \(intents[0])")
            return
        }
    }

    // MARK: - tearDown()

    func test_tearDown_thenRender_recordsNothingFurther_andPanelNotVisible() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        store.submit(request)
        controller.render()
        XCTAssertNotNil(controller.panel, "precondition: the panel exists before tearDown")
        intents.removeAll()

        controller.tearDown()

        XCTAssertTrue(controller.isTornDown, "tearDown() must set isTornDown")
        XCTAssertEqual(controller.panel?.isVisible, false, "tearDown() must leave the panel not visible")

        controller.render()

        XCTAssertTrue(intents.isEmpty, "render() after tearDown() must be a complete no-op, recording nothing")

        store.decide(id: request.id, .denied(.userRejected))
    }

    // MARK: - Width is fixed, end-to-end

    /// A payload far too long to fit at 344pt must NOT grow the panel --
    /// the notification-style panel is a fixed width, and a long payload
    /// scrolls/wraps within it instead.
    func test_render_veryLongPayload_widthStaysFixed() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest(payload: String(repeating: "a", count: 2000))
        store.submit(request)

        controller.render()

        guard case .orderFront(let frame) = intents.last else {
            XCTFail("expected an .orderFront intent")
            return
        }
        XCTAssertEqual(frame.width, 356, accuracy: 0.5,
                       "a very long payload must never grow the window past its fixed 344pt sheet width plus the 12pt dismissGutter")

        store.decide(id: request.id, .denied(.userRejected))
    }

    /// A short payload's own natural content width is irrelevant now --
    /// the panel is always exactly `fixedWidth` (344pt), never
    /// content-dependent.
    func test_render_veryShortPayload_widthStaysFixed() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest(payload: "abcdefghij")
        store.submit(request)

        controller.render()

        guard case .orderFront(let frame) = intents.last else {
            XCTFail("expected an .orderFront intent")
            return
        }
        XCTAssertEqual(frame.width, 356, accuracy: 0.5,
                       "a tiny payload must still render at the fixed 344pt sheet width plus the 12pt dismissGutter, never shrunk to its own content")

        store.decide(id: request.id, .denied(.userRejected))
    }

    /// The available cap itself (visibleFrame.width - 2*margin = 300 -
    /// 24 = 276) falls BELOW `fixedWidth` (344) here -- proves the cap
    /// wins over the fixed width end-to-end through `render()`,
    /// mirroring `ApprovalPanelArrangerTests.test_panelWidth_nilRequest_narrowScreen_clampsToAvailableCap`'s
    /// own pure-geometry pin.
    func test_render_visibleFrameNarrowerThanFixedWidth_capWinsOverFixedWidth() {
        let store = ApprovalInboxStore()
        let model = ApprovalBannerModel(store: store)
        let narrowVisibleFrame = NSRect(x: 0, y: 0, width: 300, height: 850)
        let controller = ApprovalPanelController(
            model: model,
            hostWindow: { nil },
            visibleFrame: { narrowVisibleFrame }
        )
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest(payload: "abcdefghij")
        store.submit(request)

        controller.render()

        guard case .orderFront(let frame) = intents.last else {
            XCTFail("expected an .orderFront intent")
            return
        }
        XCTAssertEqual(frame.width, 288, accuracy: 0.5,
                       "with a 300pt-wide visible frame, the sheet cap (300 - 2*12 = 276) must win over the 344pt fixedWidth, plus the 12pt dismissGutter (276 + 12 = 288) for the window")

        store.decide(id: request.id, .denied(.userRejected))
    }

    /// A payload short enough to stay within `ExpandableBodyText`'s own
    /// 2-line collapsed clip, on a visible frame short enough (44pt tall)
    /// that `heightCap(visibleFrame:)` (44 - 24 = 20pt) falls well below
    /// even the shortest banner's own minimum content height -- the
    /// content is guaranteed to hit the `.frame(maxHeight: layout.heightCap)`
    /// cap regardless of payload length. Pins `measureFrame(hostingController:)`'s
    /// own gutter arithmetic: the WINDOW's own frame for a cap-hitting
    /// payload must be exactly `heightCap + dismissGutter`, never
    /// `heightCap` alone (the sheet's own capped height) and never
    /// `heightCap + 2*dismissGutter` (double-counting the gutter).
    func test_render_capHittingVisibleFrame_windowHeightIsHeightCapPlusDismissGutter() {
        let store = ApprovalInboxStore()
        let model = ApprovalBannerModel(store: store)
        let shortVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 44)
        let controller = ApprovalPanelController(
            model: model,
            hostWindow: { nil },
            visibleFrame: { shortVisibleFrame }
        )
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest(payload: "ls -la")
        store.submit(request)

        controller.render()

        guard case .orderFront(let frame) = intents.last else {
            XCTFail("expected an .orderFront intent")
            return
        }
        let expectedHeightCap = ApprovalPanelArranger.heightCap(visibleFrame: shortVisibleFrame)
        XCTAssertEqual(frame.height, expectedHeightCap + ApprovalPanelArranger.dismissGutter, accuracy: 0.5,
                       "a cap-hitting payload's window height must be heightCap(visibleFrame:) + dismissGutter, never heightCap alone")

        store.decide(id: request.id, .denied(.userRejected))
    }

    // MARK: - reanchor()

    /// `reanchor()` re-measures through the SAME path `render()` does;
    /// there is no cheap "just move the existing frame" path, because
    /// the single app-wide panel's `reanchor()` must pick up a NEW
    /// screen's own width cap/height cap too, not just its origin
    /// -- so after the injected `visibleFrame` closure starts reporting
    /// a different screen, `reanchor()` must report a fresh
    /// `.orderFront` anchored to that NEW frame, whose height never
    /// exceeds the NEW frame's own height cap.
    func test_reanchor_afterVisibleFrameChanges_reportsOrderFrontAnchoredToNewFrame() {
        let store = ApprovalInboxStore()
        let model = ApprovalBannerModel(store: store)
        var currentVisibleFrame = fixedVisibleFrame
        let controller = ApprovalPanelController(
            model: model,
            hostWindow: { nil },
            visibleFrame: { currentVisibleFrame }
        )
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        store.submit(request)
        controller.render()
        intents.removeAll()

        let newVisibleFrame = NSRect(x: 200, y: 100, width: 1000, height: 700)
        currentVisibleFrame = newVisibleFrame

        controller.reanchor()

        guard case .orderFront(let frame) = intents.last else {
            XCTFail("expected reanchor() to report a fresh .orderFront intent, got \(intents)")
            return
        }
        XCTAssertEqual(frame.maxX, newVisibleFrame.maxX - 12, accuracy: 0.5,
                       "reanchor() must anchor to the NEW visible frame's right edge, not the one render() originally measured against")
        XCTAssertEqual(frame.maxY,
                       newVisibleFrame.maxY - ApprovalPanelArranger.margin + ApprovalPanelArranger.dismissGutter,
                       accuracy: 0.5,
                       "reanchor() must anchor the window's top edge to the NEW visible frame's own top edge: visibleFrame.maxY - margin + dismissGutter (margin inside for the sheet, plus dismissGutter above that)")
        let newHeightCap = ApprovalPanelArranger.heightCap(visibleFrame: newVisibleFrame)
        XCTAssertLessThanOrEqual(frame.height, newHeightCap + ApprovalPanelArranger.dismissGutter,
                                 "reanchor() must respect the NEW visible frame's own height cap, plus the window's dismissGutter")

        store.decide(id: request.id, .denied(.userRejected))
    }

    // MARK: - Geometry-echo does not loop

    /// `render()`'s own measurement passes report `layout.width`/
    /// `layout.heightCap` into `ApprovalPanelContentView`, which echoes
    /// its measured size back out through `onContentSizeChange` ->
    /// `applyContentHeight(_:)`. Once that echo reports the SAME size
    /// `render()` already settled on, `applyContentHeight(_:)` must not
    /// call `render()` again -- pumping the run loop briefly after a
    /// single `render()` call must record no further order intent. The
    /// fixed pump interval only weakens this check on a slow machine (a
    /// spurious intent has less time to appear before the assertion
    /// runs); it never produces a false failure.
    func test_render_thenPumpRunLoop_recordsNoFurtherOrderIntent() {
        let store = ApprovalInboxStore()
        let controller = makeController(store: store)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }
        let request = makeRequest()
        store.submit(request)

        controller.render()
        intents.removeAll()

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(intents.isEmpty,
                      "once render()'s own measurement settles, the content view's size-change echo must never trigger a further order intent on its own")

        store.decide(id: request.id, .denied(.userRejected))
    }

    /// The same settle-then-pump discipline as the test above, but after
    /// an actual navigation (`selectNext()`) to a second request:
    /// `handleRequestChange()` resets the layout and re-renders exactly
    /// once for the navigation itself, and the subsequent pump must
    /// record no ADDITIONAL intent beyond that one.
    func test_render_afterSelectNext_thenPumpRunLoop_recordsExactlyOneNewOrderIntent() {
        let store = ApprovalInboxStore()
        let (controller, model) = makeControllerAndModel(store: store)
        let first = makeRequest(payload: "first")
        let second = makeRequest(payload: "second")
        store.submit(first)
        store.submit(second)
        var intents: [ApprovalPanelController.OrderIntent] = []
        controller._orderHookForTesting = { intents.append($0) }

        controller.render()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        intents.removeAll()

        let orderIntentRecorded = expectation(description: "order intent recorded after selectNext")
        orderIntentRecorded.expectedFulfillmentCount = 1
        orderIntentRecorded.assertForOverFulfill = true
        controller._orderHookForTesting = { intent in
            intents.append(intent)
            orderIntentRecorded.fulfill()
        }

        model.selectNext()
        wait(for: [orderIntentRecorded], timeout: 5)

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(intents.count, 1,
                       "navigating to a different request must record exactly one new .orderFront intent, with the run-loop pump afterward settling and recording nothing further")
        guard case .orderFront = intents.first else {
            XCTFail("the recorded intent must be .orderFront, got \(intents)")
            return
        }

        store.decide(id: first.id, .denied(.userRejected))
        store.decide(id: second.id, .denied(.userRejected))
    }

    // MARK: - handOffKey(_:), via _panelIsKeyForTesting

    /// `render()`'s own displayed-request-change branch: while the panel
    /// holds key (simulated via `_panelIsKeyForTesting = true`, since an
    /// XCTest host cannot reliably make a real window key -- see
    /// `_orderHookForTesting`'s own doc comment for the identical
    /// constraint), navigating to a different pending request must
    /// invoke `handOffKey(_:)` exactly once, with the DISPLAYED (about to
    /// be replaced) request's own `targetSurfaceID`.
    func test_handOffKey_invokedOnceWithDisplayedTargetSurfaceID_whenDisplayedRequestChanges_andPanelIsKey() {
        let store = ApprovalInboxStore()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        var handOffTargets: [UUID?] = []
        let (controller, model) = makeControllerAndModel(store: store, handOffKey: { handOffTargets.append($0) })
        controller._orderHookForTesting = { _ in }
        let first = makeRequest(payload: "first", targetSurfaceID: firstSurfaceID)
        let second = makeRequest(payload: "second", targetSurfaceID: secondSurfaceID)
        store.submit(first)
        store.submit(second)
        controller.render()
        // Only marked key AFTER the panel's very first render, which
        // hands off nothing of its own (nothing was previously
        // displayed) -- isolates the assertion below to the navigation.
        controller._panelIsKeyForTesting = true

        model.selectNext()
        controller.render()

        XCTAssertEqual(handOffTargets, [firstSurfaceID],
                       "navigating to a different displayed request while the panel is key must invoke handOffKey exactly once, with the request that WAS displayed")

        store.decide(id: first.id, .denied(.userRejected))
        store.decide(id: second.id, .denied(.userRejected))
    }

    /// `render()`'s own order-out branch: deciding the only pending
    /// (displayed) request while the panel holds key must invoke
    /// `handOffKey(_:)` exactly once, with that request's own
    /// `targetSurfaceID`.
    func test_handOffKey_invokedOnceWithDisplayedTargetSurfaceID_onOrderOut_whenPanelIsKey() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        var handOffTargets: [UUID?] = []
        let (controller, _) = makeControllerAndModel(store: store, handOffKey: { handOffTargets.append($0) })
        controller._orderHookForTesting = { _ in }
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        controller.render()
        controller._panelIsKeyForTesting = true

        store.decide(id: request.id, .allowed)
        controller.render()

        XCTAssertEqual(handOffTargets, [surfaceID],
                       "ordering the panel out while it is key must invoke handOffKey exactly once, with the just-decided request's own targetSurfaceID")
    }

    /// While the panel does NOT hold key, neither a displayed-request
    /// change nor an order-out may ever invoke `handOffKey(_:)` --
    /// `handOffKeyIfNeeded()`'s own guard.
    func test_handOffKey_neverInvoked_whenPanelIsNotKey() {
        let store = ApprovalInboxStore()
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        var handOffTargets: [UUID?] = []
        let (controller, model) = makeControllerAndModel(store: store, handOffKey: { handOffTargets.append($0) })
        controller._orderHookForTesting = { _ in }
        controller._panelIsKeyForTesting = false
        let first = makeRequest(payload: "first", targetSurfaceID: firstSurfaceID)
        let second = makeRequest(payload: "second", targetSurfaceID: secondSurfaceID)
        store.submit(first)
        store.submit(second)
        controller.render()

        model.selectNext()
        controller.render()
        store.decide(id: first.id, .denied(.userRejected))
        store.decide(id: second.id, .denied(.userRejected))
        controller.render()

        XCTAssertTrue(handOffTargets.isEmpty,
                      "handOffKey must never be invoked while the panel does not hold key, for any render() cause")
    }
}
