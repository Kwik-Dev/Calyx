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
//  - windowFrame(sheetSize:visibleFrame:margin:): the WINDOW's own frame
//    for a glass sheet of a given size -- 2*gutter points wider and
//    taller than the sheet (gutter on every side), its right and top
//    edges each pushed gutter further past the sheet's own right/top
//    edges.
//  - panelWidth(for:visibleFrame:margin:): the notification-style panel
//    is one of exactly two fixed widths, never content-dependent -- nil
//    or a non-wide request reads fixedWidth (344pt), a request whose
//    prompt wants inline option rows reads wideWidth (640pt), and either
//    way min(desiredWidth, visibleFrame.width - 2*margin) so a narrow
//    screen still clamps down to the available cap.
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

    // MARK: - windowFrame

    /// For a 400x300 sheet against the same non-origin visibleFrame:
    /// window width = 400 + 24 = 424, height = 300 + 24 = 324;
    /// maxX = 1540 - 12 + 12 = 1540 (margin cancels gutter, both 12 here);
    /// maxY = 900 - 12 + 12 = 900 (same cancellation).
    func test_windowFrame_isSheetSizePlusGutter_topRightAnchored() {
        let sheetSize = CGSize(width: 400, height: 300)

        let rect = ApprovalPanelArranger.windowFrame(sheetSize: sheetSize, visibleFrame: visibleFrame)

        XCTAssertEqual(rect.width, 424, accuracy: 0.001, "window width must be sheetSize.width + 2*gutter")
        XCTAssertEqual(rect.height, 324, accuracy: 0.001, "window height must be sheetSize.height + 2*gutter")
        XCTAssertEqual(rect.maxX, visibleFrame.maxX - ApprovalPanelArranger.margin + ApprovalPanelArranger.gutter,
                       accuracy: 0.001, "window maxX must be visibleFrame.maxX - margin + gutter")
        XCTAssertEqual(rect.maxY, visibleFrame.maxY - ApprovalPanelArranger.margin + ApprovalPanelArranger.gutter,
                       accuracy: 0.001, "window maxY must be visibleFrame.maxY - margin + gutter")
    }

    /// The SHEET's own top-right corner (window.maxX - gutter,
    /// window.maxY - gutter) must land exactly where
    /// `anchor(size:visibleFrame:)` would have placed a same-sized rect
    /// -- the gutter must never move the sheet itself, only enlarge the
    /// window around it, uniformly on every side.
    func test_windowFrame_sheetTopRightCorner_matchesAnchor() {
        let sheetSize = CGSize(width: 400, height: 300)

        let windowRect = ApprovalPanelArranger.windowFrame(sheetSize: sheetSize, visibleFrame: visibleFrame)
        let anchoredRect = ApprovalPanelArranger.anchor(size: sheetSize, visibleFrame: visibleFrame)

        XCTAssertEqual(windowRect.maxX - ApprovalPanelArranger.gutter, anchoredRect.maxX, accuracy: 0.001)
        XCTAssertEqual(windowRect.maxY - ApprovalPanelArranger.gutter, anchoredRect.maxY, accuracy: 0.001)
    }

    // MARK: - panelWidth

    /// A wide-preferring request, for exercising the `wideWidth` branch.
    private func makeWideRequest() -> ApprovalRequest {
        let prompt = AgentQuestionPrompt(
            questions: [
                AgentQuestionPrompt.Question(
                    text: "Which?", header: nil,
                    options: [AgentQuestionPrompt.Option(label: "a", description: nil, preview: "preview")],
                    multiSelect: false
                ),
            ],
            originalToolInputJSON: Data()
        )
        return ApprovalRequest(
            id: UUID(), source: .agentQuestion(kind: AgentEntry.claudeCodeKind, prompt: prompt),
            targetSurfaceID: nil, payload: "", createdAt: Date()
        )
    }

    /// On a normal-sized screen a `nil` request (nothing pending) reads
    /// exactly `fixedWidth` (344pt) -- never content-dependent, and never
    /// clamped down, since the available cap (1440 - 24 = 1416) is far
    /// above it.
    func test_panelWidth_nilRequest_normalScreen_isFixedWidth() {
        let width = ApprovalPanelArranger.panelWidth(for: nil, visibleFrame: visibleFrame)

        XCTAssertEqual(width, 344, accuracy: 0.001,
                       "panelWidth for a nil request must be the fixed 344pt width on a screen wide enough to fit it")
        XCTAssertEqual(width, ApprovalPanelArranger.fixedWidth, accuracy: 0.001)
    }

    /// A non-wide request (e.g. `.mcpTool`) reads the same `fixedWidth`
    /// as a `nil` request.
    func test_panelWidth_nonWideRequest_normalScreen_isFixedWidth() {
        let request = ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: nil, payload: "ls", createdAt: Date())

        let width = ApprovalPanelArranger.panelWidth(for: request, visibleFrame: visibleFrame)

        XCTAssertEqual(width, ApprovalPanelArranger.fixedWidth, accuracy: 0.001)
    }

    /// A request whose prompt wants inline option rows
    /// (`ApprovalRequest.prefersWideApprovalPanel`) reads `wideWidth`
    /// (640pt) instead.
    func test_panelWidth_wideRequest_normalScreen_isWideWidth() {
        let width = ApprovalPanelArranger.panelWidth(for: makeWideRequest(), visibleFrame: visibleFrame)

        XCTAssertEqual(width, 640, accuracy: 0.001,
                       "panelWidth for a request wanting inline option rows must be the 640pt wideWidth")
        XCTAssertEqual(width, ApprovalPanelArranger.wideWidth, accuracy: 0.001)
    }

    /// A narrow "screen" whose own cap (width - 2*margin) falls BELOW
    /// `fixedWidth`: the cap must win for a `nil`/non-wide request, so
    /// the panel can never be wider than the available space no matter
    /// how small that space is.
    func test_panelWidth_nilRequest_narrowScreen_clampsToAvailableCap() {
        let narrowVisibleFrame = NSRect(x: 0, y: 0, width: 300, height: 850)

        let width = ApprovalPanelArranger.panelWidth(for: nil, visibleFrame: narrowVisibleFrame)

        // cap = 300 - 24 = 276, which is below fixedWidth (344)
        XCTAssertEqual(width, 276, accuracy: 0.001,
                       "when the available cap itself falls below fixedWidth, the cap must win")
    }

    /// The same cap-wins behavior for a wide request: the cap
    /// (visibleFrame.width - 2*margin) falls below `wideWidth` (640) too,
    /// and must win over it the same way.
    func test_panelWidth_wideRequest_narrowScreen_clampsToAvailableCap() {
        let narrowVisibleFrame = NSRect(x: 0, y: 0, width: 300, height: 850)

        let width = ApprovalPanelArranger.panelWidth(for: makeWideRequest(), visibleFrame: narrowVisibleFrame)

        // cap = 300 - 24 = 276, which is below wideWidth (640)
        XCTAssertEqual(width, 276, accuracy: 0.001,
                       "when the available cap itself falls below wideWidth, the cap must win")
    }

    func test_panelWidth_customMargin_isRespected() {
        let width = ApprovalPanelArranger.panelWidth(for: nil, visibleFrame: visibleFrame, margin: 600)

        // cap = 1440 - 1200 = 240, below fixedWidth (344)
        XCTAssertEqual(width, 240, accuracy: 0.001)
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
        XCTAssertEqual(ApprovalPanelArranger.fixedWidth, 344, accuracy: 0.001)
        XCTAssertEqual(ApprovalPanelArranger.wideWidth, 640, accuracy: 0.001)
        XCTAssertEqual(ApprovalPanelArranger.gutter, 12, accuracy: 0.001)
        XCTAssertEqual(ApprovalPanelArranger.gutter, ApprovalPanelArranger.margin, accuracy: 0.001,
                       "gutter is defined as margin, so the window's own top and right edges land exactly on visibleFrame's own top and right edges")
    }
}
