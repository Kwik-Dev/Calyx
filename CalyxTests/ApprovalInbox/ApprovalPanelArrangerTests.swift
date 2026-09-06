//
//  ApprovalPanelArrangerTests.swift
//  CalyxTests
//
//  Covers `ApprovalPanelArranger`: pure geometry for the floating
//  approval panel (`ApprovalPanelWindow`) -- one app-wide, page-style
//  panel, so this only ever anchors a single rect to the screen's
//  top-right corner and clamps its width/height; there is no stacking
//  to cover any more (see `ApprovalPanelArranger.swift`'s own header).
//  `nonisolated`, no AppKit window state -- every case below is exact
//  arithmetic against a hand-picked, non-origin `visibleFrame`, never a
//  re-simulation of whatever the implementation happens to compute.
//
//  Coverage:
//  - anchor(size:visibleFrame:margin:): top-right corner, margin pt
//    inset from BOTH edges, against a visibleFrame whose origin is NOT
//    (0, 0) -- proves the arithmetic is expressed in terms of
//    visibleFrame.maxX/maxY, never hardcoded against a screen at the
//    origin.
//  - clampWidth(ideal:minimum:visibleFrame:margin:): below the minimum
//    clamps up to the minimum; above the available cap clamps down to
//    the cap; and when the cap itself falls below the minimum (a
//    narrow screen), the cap wins over the minimum.
//  - heightCap(visibleFrame:margin:): the visible height minus 2*margin.
//

import XCTest
import AppKit
@testable import Calyx

final class ApprovalPanelArrangerTests: XCTestCase {

    /// A non-origin, "real monitor" visible frame: x 100, y 50 (menu bar
    /// + Dock already excluded), 1440x850.
    private let visibleFrame = NSRect(x: 100, y: 50, width: 1440, height: 850)

    // MARK: - anchor

    func test_anchor_topRightCorner_insetByMargin() {
        let size = CGSize(width: 400, height: 300)

        let rect = ApprovalPanelArranger.anchor(size: size, visibleFrame: visibleFrame)

        // maxX = 100 + 1440 = 1540; x = 1540 - 12 - 400 = 1128
        // maxY = 50 + 850 = 900;   y = 900 - 12 - 300 = 588
        XCTAssertEqual(rect.origin.x, 1128, accuracy: 0.001, "anchor's x must be visibleFrame.maxX - margin - width")
        XCTAssertEqual(rect.origin.y, 588, accuracy: 0.001, "anchor's y must be visibleFrame.maxY - margin - height")
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.height, 300, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, visibleFrame.maxX - ApprovalPanelArranger.margin, accuracy: 0.001,
                       "the anchored rect's right edge must sit exactly `margin` inside visibleFrame's right edge")
        XCTAssertEqual(rect.maxY, visibleFrame.maxY - ApprovalPanelArranger.margin, accuracy: 0.001,
                       "the anchored rect's top edge must sit exactly `margin` inside visibleFrame's top edge")
    }

    func test_anchor_customMargin_isRespected() {
        let size = CGSize(width: 200, height: 100)

        let rect = ApprovalPanelArranger.anchor(size: size, visibleFrame: visibleFrame, margin: 20)

        XCTAssertEqual(rect.maxX, visibleFrame.maxX - 20, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, visibleFrame.maxY - 20, accuracy: 0.001)
    }

    // MARK: - clampWidth

    func test_clampWidth_belowMinimum_clampsUpToMinimum() {
        let width = ApprovalPanelArranger.clampWidth(ideal: 200, visibleFrame: visibleFrame)

        XCTAssertEqual(width, ApprovalPanelArranger.minimumWidth, accuracy: 0.001,
                       "an ideal width narrower than the minimum must clamp up to the minimum")
    }

    func test_clampWidth_aboveCap_clampsDownToCap() {
        let width = ApprovalPanelArranger.clampWidth(ideal: 5000, visibleFrame: visibleFrame)

        // cap = visibleFrame.width - 2*margin = 1440 - 24 = 1416
        XCTAssertEqual(width, 1416, accuracy: 0.001,
                       "an ideal width wider than the available cap must clamp down to visibleFrame.width - 2*margin")
    }

    func test_clampWidth_withinBounds_isUnchanged() {
        let width = ApprovalPanelArranger.clampWidth(ideal: 500, visibleFrame: visibleFrame)

        XCTAssertEqual(width, 500, accuracy: 0.001, "an ideal width already within [minimum, cap] must pass through unchanged")
    }

    /// A narrow "screen" whose own cap (width - 2*margin) is itself
    /// BELOW the 360pt minimum: the cap must win over the minimum, so a
    /// panel can never be wider than the available space no matter how
    /// small that space is.
    func test_clampWidth_capBelowMinimum_capWins() {
        let narrowVisibleFrame = NSRect(x: 0, y: 0, width: 300, height: 850)

        let width = ApprovalPanelArranger.clampWidth(ideal: 200, visibleFrame: narrowVisibleFrame)

        // cap = 300 - 24 = 276, which is below minimumWidth (360)
        XCTAssertEqual(width, 276, accuracy: 0.001,
                       "when the available cap itself falls below the minimum width, the cap must win")
    }

    func test_clampWidth_customMinimumAndMargin_areRespected() {
        let width = ApprovalPanelArranger.clampWidth(ideal: 100, minimum: 250, visibleFrame: visibleFrame, margin: 12)

        XCTAssertEqual(width, 250, accuracy: 0.001)
    }

    // MARK: - heightCap

    func test_heightCap_isVisibleHeightMinusTwoMargins() {
        let cap = ApprovalPanelArranger.heightCap(visibleFrame: visibleFrame)

        XCTAssertEqual(cap, 826, accuracy: 0.001, "heightCap must be visibleFrame.height - 2*margin (850 - 24)")
    }

    func test_heightCap_customMargin_isRespected() {
        let cap = ApprovalPanelArranger.heightCap(visibleFrame: visibleFrame, margin: 50)

        XCTAssertEqual(cap, 750, accuracy: 0.001)
    }

    // MARK: - Constants

    func test_constants_matchSpec() {
        XCTAssertEqual(ApprovalPanelArranger.margin, 12, accuracy: 0.001)
        XCTAssertEqual(ApprovalPanelArranger.minimumWidth, 360, accuracy: 0.001)
    }
}
