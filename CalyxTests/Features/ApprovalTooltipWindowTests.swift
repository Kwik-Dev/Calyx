//
//  ApprovalTooltipWindowTests.swift
//  CalyxTests
//
//  Covers `ApprovalTooltipWindow`'s fixed configuration -- a
//  non-activating, click-through, always-above-the-approval-panel
//  window that never becomes key or main. Every window built below is
//  NEVER shown (no `orderFront`/`makeKeyAndOrderFront` call anywhere in
//  this file) -- mirrors `ApprovalPanelWindowTests`'s own established
//  safety discipline for a bare, unshown panel fixture in this test
//  host.
//

import XCTest
import AppKit
import SwiftUI
@testable import Calyx

@MainActor
final class ApprovalTooltipWindowTests: XCTestCase {

    private func makeWindow() -> ApprovalTooltipWindow {
        let window = ApprovalTooltipWindow()
        window.isReleasedWhenClosed = false
        return window
    }

    func test_styleMask_isBorderlessNonactivatingPanel() {
        let window = makeWindow()

        XCTAssertEqual(window.styleMask, [.borderless, .nonactivatingPanel])
    }

    func test_isOpaque_isFalse() {
        XCTAssertFalse(makeWindow().isOpaque)
    }

    func test_backgroundColor_isClear() {
        XCTAssertEqual(makeWindow().backgroundColor, .clear)
    }

    func test_hasShadow_isFalse() {
        XCTAssertFalse(makeWindow().hasShadow)
    }

    func test_ignoresMouseEvents_isTrue() {
        XCTAssertTrue(makeWindow().ignoresMouseEvents, "a tooltip must never intercept a click meant for whatever is beneath it")
    }

    func test_level_isOnePastFloating() {
        let expected = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        XCTAssertEqual(makeWindow().level, expected, "the tooltip must draw above the floating approval panel it annotates")
    }

    func test_collectionBehavior_containsAllRequiredFlags() {
        let window = makeWindow()

        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))
    }

    func test_isReleasedWhenClosed_isFalse() {
        // Constructed fresh (not through makeWindow(), which forces this
        // to false defensively) -- pins the PRODUCTION default itself.
        let window = ApprovalTooltipWindow()

        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    func test_canBecomeKey_isFalse() {
        XCTAssertFalse(makeWindow().canBecomeKey, "a tooltip must never take key status")
    }

    func test_canBecomeMain_isFalse() {
        XCTAssertFalse(makeWindow().canBecomeMain, "a tooltip must never take main status")
    }

    func test_identifier_isComCalyxApprovalTooltip() {
        XCTAssertEqual(makeWindow().identifier?.rawValue, "com.calyx.approvalTooltip")
    }

    func test_hidesOnDeactivate_isFalse() {
        // NSPanel defaults this to true -- the approval panel this
        // tooltip serves must keep working while Calyx is not the
        // active app, so a tooltip left at the default would hide the
        // instant Calyx deactivates, even while still shown.
        XCTAssertFalse(makeWindow().hidesOnDeactivate)
    }

    func test_isRestorable_isFalse() {
        XCTAssertFalse(makeWindow().isRestorable, "the tooltip is derived, transient state -- it must never be saved into / restored from macOS window state")
    }

    // MARK: - ApprovalTooltipContent measurement

    /// Pins the spec's own measured pixel dump: for "echo HOVER_MARKER"
    /// (118.7pt wide text), the box must measure 132x19pt -- built the
    /// same way `ApprovalTooltipPresenter.measureContentSize(text:)`
    /// does, a throwaway `NSHostingController` (never shown) measured
    /// via `sizeThatFits(in:)` at the same 400pt-plus-chrome width
    /// proposal.
    func test_tooltipContent_measuresSpecSizeForHoverMarkerText() {
        let hostingController = NSHostingController(rootView: ApprovalTooltipContent(text: "echo HOVER_MARKER"))
        hostingController.safeAreaRegions = []

        let size = hostingController.sizeThatFits(
            in: CGSize(
                width: ApprovalTooltipContent.maxTextWidth + ApprovalTooltipContent.chromeWidth,
                height: .greatestFiniteMagnitude
            )
        )

        XCTAssertEqual(size.width, 132, accuracy: 1)
        // Tight accuracy, not the earlier 1pt tolerance: that wider
        // tolerance silently passed at 20pt too, hiding the top-inset
        // defect.
        XCTAssertEqual(size.height, 19, accuracy: 0.5)
    }
}
