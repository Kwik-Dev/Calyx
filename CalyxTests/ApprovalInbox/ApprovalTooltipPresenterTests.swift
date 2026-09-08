//
//  ApprovalTooltipPresenterTests.swift
//  CalyxTests
//
//  Covers `ApprovalTooltipPresenter.frame(for:pointer:visibleFrame:)`,
//  the pure placement function `show(text:at:)` itself relies on: the
//  box's top-left corner sits at `pointer + (0, -18)` in AppKit's own
//  bottom-up screen coordinates (directly below the cursor, left-aligned
//  with it), clamped fully inside `visibleFrame`.
//
//  Also covers `scheduleShow(text:)`/`hide()`'s own pending-show
//  lifecycle, using the `#if DEBUG` `_delayMillisecondsForTesting`/
//  `_showHookForTesting` seams (mirrors
//  `ApprovalPanelController._orderHookForTesting`'s established
//  convention) -- no test here ever shows a real window: every case
//  either never reaches `show(text:at:)` at all, or reaches it only
//  through `_showHookForTesting`, which replaces that call entirely.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class ApprovalTooltipPresenterTests: XCTestCase {

    private let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 850)

    // MARK: - Unclamped placement

    func test_frame_unclamped_topLeftSitsAtPointerXAndPointerYMinus18MinusHeight() {
        let contentSize = NSSize(width: 132, height: 19)
        let pointer = NSPoint(x: 400, y: 400)

        let frame = ApprovalTooltipPresenter.frame(for: contentSize, pointer: pointer, visibleFrame: visibleFrame)

        XCTAssertEqual(frame.origin.x, pointer.x, accuracy: 0.01,
                       "the box's left edge must be left-aligned with the pointer")
        XCTAssertEqual(frame.origin.y, pointer.y - 18 - contentSize.height, accuracy: 0.01,
                       "the box's top edge (origin.y + height, in AppKit's bottom-up space) must sit 18pt below the pointer")
        XCTAssertEqual(frame.size, contentSize)
    }

    // MARK: - Clamping

    func test_frame_pointerNearRightEdge_clampsInsideVisibleFrame() {
        let contentSize = NSSize(width: 132, height: 19)
        let pointer = NSPoint(x: visibleFrame.maxX - 5, y: 400)

        let frame = ApprovalTooltipPresenter.frame(for: contentSize, pointer: pointer, visibleFrame: visibleFrame)

        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX, "the box must never extend past the visible frame's right edge")
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
    }

    func test_frame_pointerNearLeftEdge_clampsInsideVisibleFrame() {
        let contentSize = NSSize(width: 132, height: 19)
        let pointer = NSPoint(x: visibleFrame.minX - 50, y: 400)

        let frame = ApprovalTooltipPresenter.frame(for: contentSize, pointer: pointer, visibleFrame: visibleFrame)

        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX, "the box must never extend past the visible frame's left edge")
    }

    func test_frame_pointerNearTopEdge_clampsInsideVisibleFrame() {
        let contentSize = NSSize(width: 132, height: 19)
        let pointer = NSPoint(x: 400, y: visibleFrame.maxY - 2)

        let frame = ApprovalTooltipPresenter.frame(for: contentSize, pointer: pointer, visibleFrame: visibleFrame)

        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY, "the box must never extend past the visible frame's top edge")
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
    }

    func test_frame_pointerNearBottomEdge_clampsInsideVisibleFrame() {
        let contentSize = NSSize(width: 132, height: 19)
        let pointer = NSPoint(x: 400, y: visibleFrame.minY + 2)

        let frame = ApprovalTooltipPresenter.frame(for: contentSize, pointer: pointer, visibleFrame: visibleFrame)

        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY, "the box must never extend past the visible frame's bottom edge")
    }

    func test_frame_pointerAtOrigin_boxStaysFullyInsideVisibleFrame() {
        let contentSize = NSSize(width: 200, height: 40)
        let pointer = NSPoint(x: visibleFrame.minX, y: visibleFrame.minY)

        let frame = ApprovalTooltipPresenter.frame(for: contentSize, pointer: pointer, visibleFrame: visibleFrame)

        XCTAssertTrue(visibleFrame.contains(frame.origin))
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
    }

    /// A content size at the tooltip's own `maxHeight` cap (an
    /// oversized/truncated text) must still land fully inside the
    /// visible frame, the same as any other content size.
    func test_frame_maxHeightCappedContentSize_staysFullyInsideVisibleFrame() {
        let contentSize = NSSize(width: 413, height: visibleFrame.height - 36)
        let pointer = NSPoint(x: 400, y: 400)

        let frame = ApprovalTooltipPresenter.frame(for: contentSize, pointer: pointer, visibleFrame: visibleFrame)

        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    // MARK: - scheduleShow(text:) / hide() lifecycle

    func test_scheduleShow_afterDelayElapses_invokesShowHookExactlyOnce() async {
        let presenter = ApprovalTooltipPresenter()
        presenter._delayMillisecondsForTesting = 10
        var calls: [String] = []
        presenter._showHookForTesting = { text, _ in calls.append(text) }

        presenter.scheduleShow(text: "echo HOVER_MARKER")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(calls, ["echo HOVER_MARKER"], "the delayed show must fire exactly once, with the scheduled text")
    }

    func test_hide_beforeDelayElapses_cancelsPendingShow_hookNeverInvoked() async {
        let presenter = ApprovalTooltipPresenter()
        presenter._delayMillisecondsForTesting = 10
        var calls: [String] = []
        presenter._showHookForTesting = { text, _ in calls.append(text) }

        presenter.scheduleShow(text: "echo HOVER_MARKER")
        presenter.hide()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(calls.isEmpty, "hide() called before the delay elapses must cancel the pending show -- it must never fire for content the caller has already moved past")
    }

    func test_scheduleShow_calledAgainBeforeDelayElapses_cancelsTheFirst_onlyTheSecondFires() async {
        let presenter = ApprovalTooltipPresenter()
        presenter._delayMillisecondsForTesting = 30
        var calls: [String] = []
        presenter._showHookForTesting = { text, _ in calls.append(text) }

        presenter.scheduleShow(text: "first")
        presenter.scheduleShow(text: "second")
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(calls, ["second"], "a second scheduleShow(text:) before the first's own delay elapses must cancel the first entirely, not queue both")
    }

    func test_tearDown_beforeDelayElapses_cancelsPendingShow_hookNeverInvoked() async {
        let presenter = ApprovalTooltipPresenter()
        presenter._delayMillisecondsForTesting = 10
        var calls: [String] = []
        presenter._showHookForTesting = { text, _ in calls.append(text) }

        presenter.scheduleShow(text: "echo HOVER_MARKER")
        presenter.tearDown()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(calls.isEmpty, "tearDown() must cancel a pending show the same way hide() does")
    }

    // MARK: - show(text:at:): end-to-end measurement + placement

    /// Pins `show(text:at:)`'s own frame math end to end (content
    /// measurement, then `frame(for:pointer:visibleFrame:)`) through
    /// `_setFrameHookForTesting`, which intercepts BEFORE any real
    /// window is created/resized/ordered front -- this test never shows
    /// a real window. The frame passed to `NSWindow.setFrame(_:display:)`
    /// must reflect the content's own fitting size (19pt tall for "echo
    /// HOVER_MARKER"), not some unrelated/stale size from a previous
    /// call's own hosting controller state.
    func test_show_capturesFrame_heightMatchesContent_topEdgeAtPointerYMinus18() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen available in this test environment")
        }
        let presenter = ApprovalTooltipPresenter()
        var capturedFrame: NSRect?
        presenter._setFrameHookForTesting = { capturedFrame = $0 }
        let pointer = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)

        presenter.show(text: "echo HOVER_MARKER", at: pointer)

        let frame = try XCTUnwrap(capturedFrame, "show(text:at:) must invoke _setFrameHookForTesting with the computed frame")
        XCTAssertEqual(frame.width, 132, accuracy: 1)
        XCTAssertEqual(frame.height, 19, accuracy: 1,
                       "the window's own height must match the content's fitting height, not some unrelated/stale size")
        XCTAssertEqual(frame.origin.y + frame.height, pointer.y - 18, accuracy: 1,
                       "the box's top edge (origin.y + height, in AppKit's bottom-up space) must sit 18pt below the pointer")
    }

    /// A 3000-scalar text's natural height vastly exceeds any real
    /// screen's own visible height -- `show(text:at:)` must cap the
    /// frame it computes at `visibleFrame.height - 36`, and that frame
    /// must still land fully inside `visibleFrame` (never partly off
    /// screen).
    func test_show_veryLongText_capsHeight_frameStaysInsideVisibleFrame() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("no screen available in this test environment")
        }
        let presenter = ApprovalTooltipPresenter()
        var capturedFrame: NSRect?
        presenter._setFrameHookForTesting = { capturedFrame = $0 }
        let pointer = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let longText = String(repeating: "a", count: 3000)

        presenter.show(text: longText, at: pointer)

        let frame = try XCTUnwrap(capturedFrame, "show(text:at:) must invoke _setFrameHookForTesting with the computed frame")
        let expectedMaxHeight = screen.visibleFrame.height - 36
        XCTAssertLessThanOrEqual(frame.height, expectedMaxHeight,
                                 "a 3000-scalar text must measure at most visibleFrame.height - 36, not its own much taller natural height")
        XCTAssertGreaterThanOrEqual(frame.minX, screen.visibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, screen.visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.visibleFrame.maxY)
    }
}
