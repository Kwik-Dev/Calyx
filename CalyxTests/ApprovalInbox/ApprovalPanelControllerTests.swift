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
//    panel, records exactly one `.orderFront(frame)`, and that frame's
//    top-right corner sits `margin` inside the injected visibleFrame,
//    with a width in [minimumWidth, cap].
//  - A second render() with the SAME still-pending request is
//    idempotent: records another `.orderFront` with an identical frame,
//    but creates no second panel instance.
//  - Deciding the displayed request then calling render() records
//    `.orderOut`.
//  - tearDown() then render() records nothing further, `isTornDown`
//    becomes true, and the panel is no longer visible.
//  - Width clamping is exercised end-to-end through render(): an
//    extremely long payload clamps the frame's width up to the cap; a
//    short one stays within [minimumWidth, cap); a visible frame
//    narrower than the minimum makes the cap win over the minimum.
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
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class ApprovalPanelControllerTests: XCTestCase {

    private let fixedVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 850)

    private func makeRequest(payload: String = "ls -la /tmp") -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: nil, payload: payload, createdAt: Date())
    }

    private func makeController(store: ApprovalInboxStore) -> ApprovalPanelController {
        makeControllerAndModel(store: store).controller
    }

    private func makeControllerAndModel(store: ApprovalInboxStore) -> (controller: ApprovalPanelController, model: ApprovalBannerModel) {
        let model = ApprovalBannerModel(store: store)
        let controller = ApprovalPanelController(
            model: model,
            hostWindow: { nil },
            hostWindowTitle: { "Terminal" },
            visibleFrame: { [weak self] in self?.fixedVisibleFrame ?? .zero }
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
                       "the panel's right edge must sit `margin` (12pt) inside the visible frame's right edge")
        XCTAssertEqual(frame.maxY, fixedVisibleFrame.maxY - 12, accuracy: 0.5,
                       "the panel's top edge must sit `margin` (12pt) inside the visible frame's top edge")
        XCTAssertGreaterThanOrEqual(frame.width, 360, "the panel's width must never fall below the 360pt minimum")
        XCTAssertLessThanOrEqual(frame.width, fixedVisibleFrame.width - 24, "the panel's width must never exceed the available cap (visibleFrame.width - 2*margin)")
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

    // MARK: - Width clamping end-to-end

    func test_render_veryLongPayload_clampsWidthUpToCap() {
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
        XCTAssertEqual(frame.width, fixedVisibleFrame.width - 24, accuracy: 0.5,
                       "a payload far wider than the available screen must clamp the panel's width up to the cap (visibleFrame.width - 2*margin)")

        store.decide(id: request.id, .denied(.userRejected))
    }

    /// A short `.mcpTool` payload's own natural content width (its
    /// header row, e.g. "pane_run", plus the fixed chrome around a
    /// `.mcpTool` banner) is roughly 404pt -- ABOVE the 360pt minimum --
    /// so this can only pin the width into `[minimumWidth, cap)`, never
    /// an exact value: asserting exactly 360 here would pass for a
    /// wrong implementation that happened to also clamp everything down
    /// to the floor. `test_render_visibleFrameNarrowerThanMinimum_capWinsOverMinimum`
    /// below is what actually exercises the minimum-vs-cap boundary.
    func test_render_veryShortPayload_widthWithinBounds_belowCap() {
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
        let cap = fixedVisibleFrame.width - 24
        XCTAssertGreaterThanOrEqual(frame.width, ApprovalPanelArranger.minimumWidth,
                                    "a tiny payload's natural content width must never clamp below the 360pt minimum")
        XCTAssertLessThan(frame.width, cap,
                          "a tiny payload's natural content width, well under the available cap, must not clamp UP to the cap either")

        store.decide(id: request.id, .denied(.userRejected))
    }

    /// The available cap itself (visibleFrame.width - 2*margin = 300 -
    /// 24 = 276) falls BELOW the 360pt minimum here -- proves the cap
    /// wins over the minimum end-to-end through `render()`, mirroring
    /// `ApprovalPanelArrangerTests.test_clampWidth_capBelowMinimum_capWins`'s
    /// own pure-geometry pin.
    func test_render_visibleFrameNarrowerThanMinimum_capWinsOverMinimum() {
        let store = ApprovalInboxStore()
        let model = ApprovalBannerModel(store: store)
        let narrowVisibleFrame = NSRect(x: 0, y: 0, width: 300, height: 850)
        let controller = ApprovalPanelController(
            model: model,
            hostWindow: { nil },
            hostWindowTitle: { "Terminal" },
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
        XCTAssertEqual(frame.width, 276, accuracy: 0.5,
                       "with a 300pt-wide visible frame, the cap (300 - 2*12 = 276) must win over the 360pt minimum")

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
            hostWindowTitle: { "Terminal" },
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
        XCTAssertEqual(frame.maxY, newVisibleFrame.maxY - 12, accuracy: 0.5,
                       "reanchor() must anchor to the NEW visible frame's top edge")
        let newHeightCap = ApprovalPanelArranger.heightCap(visibleFrame: newVisibleFrame)
        XCTAssertLessThanOrEqual(frame.height, newHeightCap,
                                 "reanchor() must respect the NEW visible frame's own height cap")

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
}
