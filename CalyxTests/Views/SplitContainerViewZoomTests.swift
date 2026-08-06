//
//  SplitContainerViewZoomTests.swift
//  CalyxTests
//
//  View-layer coverage for GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM
//  (`SplitContainerView.applyLayout()`'s zoom branch, and
//  `applyActiveDimming()`'s zoom-aware effective-active leaf).
//  Mirrors `SplitContainerViewDimmingTests.swift`'s fixture shape
//  (`Fixture` / `makeFixture()` / `registerLeaf(_:in:)` /
//  `installedWrappers(in:)` / `wrapper(hosting:in:)`) rather than sharing
//  code cross-file, matching this codebase's established per-file fixture
//  duplication convention (see `SplitContainerViewDividerReuseTests.swift`,
//  which duplicates the same shapes rather than factoring them out).
//
//  Coverage:
//    1. Zoomed layout shows ONLY the zoomed wrapper, at the container's
//       full bounds.
//    2. Unzooming restores both wrappers visible, with split-proportioned
//       (not full-bounds) frames.
//    3. Zooming removes any SplitDividerView that existed while unzoomed.
//    4. Resizing the container WHILE zoomed keeps the zoom layout intact
//       — the regression guard for `resizeSubviews(withOldSize:)`
//       forgetting the zoom branch (SplitContainerView.swift's own
//       `applyLayout()` doc comment explains why this is the single most
//       likely omission).
//    5. An invalid/stale `zoomedLeafID` (not a real leaf of the tree)
//       falls back to the normal full-tree layout, both panes visible.
//    6. The zoomed pane is alpha 1.0 even when it differs from
//       `activeLeafID` (`applyActiveDimming`'s `effectiveActive` branch).
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class SplitContainerViewZoomTests: XCTestCase {

    // MARK: - Constants

    private static let standardBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: - Fixtures / Helpers

    private struct Fixture {
        let registry: SurfaceRegistry
        let container: SplitContainerView
    }

    private func makeFixture() -> Fixture {
        let registry = SurfaceRegistry()
        let container = SplitContainerView(registry: registry)
        container.frame = Self.standardBounds
        container.layoutSubtreeIfNeeded()
        return Fixture(registry: registry, container: container)
    }

    @discardableResult
    private func registerLeaf(_ id: UUID, in registry: SurfaceRegistry) -> SurfaceView {
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)
        return view
    }

    private func installedWrappers(in container: SplitContainerView) -> [SurfaceScrollView] {
        container.subviews.compactMap { $0 as? SurfaceScrollView }
    }

    private func installedDividers(in container: SplitContainerView) -> [SplitDividerView] {
        container.subviews.compactMap { $0 as? SplitDividerView }
    }

    private func wrapper(hosting surface: SurfaceView, in container: SplitContainerView) -> SurfaceScrollView? {
        installedWrappers(in: container).first { $0.surfaceView === surface }
    }

    private func makeTwoLeafHorizontalTree(
        firstLeafID: UUID,
        secondLeafID: UUID,
        focusedLeafID: UUID,
        zoomedLeafID: UUID?
    ) -> SplitTree {
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        return SplitTree(root: root, focusedLeafID: focusedLeafID, zoomedLeafID: zoomedLeafID)
    }

    // MARK: - 1. Zoomed layout shows only the zoomed wrapper, at full bounds

    /// Given: a 2-leaf horizontal split tree laid out for the FIRST time
    ///        with `zoomedLeafID == firstLeafID` already set.
    /// When:  `updateLayout(tree:)` is invoked.
    /// Then:  exactly one `SurfaceScrollView` wrapper is installed (the
    ///        zoomed one), it is not hidden, and its frame fills the
    ///        container's entire bounds.
    func testZoomedLayout_showsOnlyZoomedWrapper_atContainerFullBounds() {
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let tree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: firstLeafID
        )

        fixture.container.updateLayout(tree: tree)

        let wrappers = installedWrappers(in: fixture.container)
        XCTAssertEqual(wrappers.count, 1,
                       "Only the zoomed leaf's wrapper may be installed while zoomed")
        guard let zoomWrapper = wrappers.first else {
            XCTFail("The zoomed leaf's wrapper must be installed")
            return
        }
        XCTAssertFalse(zoomWrapper.isHidden, "The zoomed wrapper must be visible")
        XCTAssertEqual(zoomWrapper.frame, fixture.container.bounds,
                       "The zoomed wrapper's frame must fill the container's full bounds")
    }

    // MARK: - 2. Unzooming restores both wrappers, split-proportioned frames

    /// Given: a container zoomed on the first leaf (only one wrapper
    ///        materialized, per test 1 above).
    /// When:  `updateLayout(tree:)` is invoked again with the SAME tree
    ///        shape but `zoomedLeafID == nil`.
    /// Then:  both wrappers are installed and visible, neither fills the
    ///        full container bounds (each reflects its half of the
    ///        split), and the normal divider is present again.
    func testUnzoomingRestoresBothWrappersVisible_withSplitProportionedFrames() {
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let zoomedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: firstLeafID
        )
        fixture.container.updateLayout(tree: zoomedTree)
        XCTAssertEqual(installedWrappers(in: fixture.container).count, 1,
                       "Precondition: only the zoomed wrapper is installed before unzooming")

        let unzoomedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: nil
        )
        fixture.container.updateLayout(tree: unzoomedTree)

        let wrappers = installedWrappers(in: fixture.container)
        XCTAssertEqual(wrappers.count, 2, "Both wrappers must be installed after unzooming")
        for w in wrappers {
            XCTAssertFalse(w.isHidden, "Every wrapper must be visible after unzooming")
        }

        guard let firstWrapper = fixture.registry.view(for: firstLeafID).flatMap({ wrapper(hosting: $0, in: fixture.container) }),
              let secondWrapper = fixture.registry.view(for: secondLeafID).flatMap({ wrapper(hosting: $0, in: fixture.container) })
        else {
            XCTFail("Both wrappers must resolve after unzooming")
            return
        }
        XCTAssertNotEqual(firstWrapper.frame, fixture.container.bounds,
                          "After unzooming, the first pane must no longer fill the full container bounds")
        XCTAssertEqual(firstWrapper.frame.width, fixture.container.bounds.width * 0.5, accuracy: 5.0,
                       "After unzooming, the first pane's width must reflect its half of the 0.5 split")
        XCTAssertEqual(secondWrapper.frame.width, fixture.container.bounds.width * 0.5, accuracy: 5.0,
                       "After unzooming, the second pane's width must reflect its half of the 0.5 split")
        XCTAssertEqual(installedDividers(in: fixture.container).count, 1,
                       "The normal split divider must reappear once zoom clears")
    }

    // MARK: - 3. Zooming removes any existing SplitDividerView

    /// Given: a 2-leaf horizontal split laid out unzoomed (one divider
    ///        installed).
    /// When:  `updateLayout(tree:)` is invoked again with the same shape
    ///        but zoomed.
    /// Then:  no `SplitDividerView` remains — the zoom layout pass never
    ///        calls `placeDivider`, so `reapUnusedDividers()` removes it.
    func testZoomingRemovesExistingSplitDividerViews() {
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let unzoomedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: nil
        )
        fixture.container.updateLayout(tree: unzoomedTree)
        XCTAssertEqual(installedDividers(in: fixture.container).count, 1,
                       "Precondition: an unzoomed 2-pane split must install exactly one divider")

        let zoomedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: firstLeafID
        )
        fixture.container.updateLayout(tree: zoomedTree)

        XCTAssertTrue(installedDividers(in: fixture.container).isEmpty,
                      "Zooming must remove every SplitDividerView")
    }

    // MARK: - 4. Resizing while zoomed keeps the zoom layout intact
    //
    // CRITICAL regression guard: `SplitContainerView.applyLayout()`'s own
    // doc comment explains why `resizeSubviews(withOldSize:)` forgetting
    // the zoom branch is the single most likely way to reintroduce this
    // bug — this test is the automated tripwire for exactly that.

    /// Given: a container zoomed on the first leaf at 800×600.
    /// When:  the container is resized to 1000×700 via `setFrameSize` +
    ///        `layoutSubtreeIfNeeded()` (which drives `resizeSubviews
    ///        (withOldSize:)`, mirroring `SplitContainerViewDividerReuseTests
    ///        .testDividerNSViewIdentityPreservedAcrossResizeSubviews`).
    /// Then:  still exactly one wrapper installed (the zoomed one), still
    ///        visible, its frame now fills the NEW bounds, and still no
    ///        dividers.
    func testResizingWhileZoomed_keepsZoomLayoutIntact() {
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let zoomedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: firstLeafID
        )
        fixture.container.updateLayout(tree: zoomedTree)

        fixture.container.setFrameSize(NSSize(width: 1000, height: 700))
        fixture.container.layoutSubtreeIfNeeded()

        let wrappers = installedWrappers(in: fixture.container)
        XCTAssertEqual(wrappers.count, 1,
                       "Resizing while zoomed must not reveal the non-zoomed pane's wrapper")
        guard let zoomWrapper = wrappers.first else {
            XCTFail("The zoomed wrapper must still be installed after resizing")
            return
        }
        XCTAssertFalse(zoomWrapper.isHidden, "The zoomed wrapper must remain visible across a resize")
        XCTAssertEqual(zoomWrapper.frame, fixture.container.bounds,
                       "The zoomed wrapper's frame must track the container's NEW bounds after " +
                       "resizeSubviews(withOldSize:) — the regression guard for that call site " +
                       "forgetting the zoom branch")
        XCTAssertTrue(installedDividers(in: fixture.container).isEmpty,
                      "No divider may reappear from a resize pass while zoomed")
    }

    // MARK: - 5. Invalid zoomedLeafID falls back to normal layout

    /// Given: a 2-leaf horizontal split tree whose `zoomedLeafID` names a
    ///        UUID that is NOT a leaf of the tree.
    /// When:  `updateLayout(tree:)` is invoked.
    /// Then:  the container falls back to the ordinary full-tree layout —
    ///        both wrappers installed and visible, the normal divider
    ///        present — exactly as `effectiveZoomedLeafID` (SplitTree.swift)
    ///        promises for a stale/corrupt zoom value.
    func testInvalidZoomedLeafID_fallsBackToNormalLayout_bothPanesVisible() {
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        let staleZoomID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let tree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: staleZoomID
        )

        fixture.container.updateLayout(tree: tree)

        let wrappers = installedWrappers(in: fixture.container)
        XCTAssertEqual(wrappers.count, 2,
                       "A zoomedLeafID that names no real leaf must fall back to laying out the full tree")
        for w in wrappers {
            XCTAssertFalse(w.isHidden, "Every wrapper must be visible when zoom falls back to invalid")
        }
        XCTAssertEqual(installedDividers(in: fixture.container).count, 1,
                       "The normal split divider must be present when zoom falls back to invalid")
    }

    // MARK: - 6. Zoomed pane is alpha 1.0 even when it isn't activeLeafID

    /// Given: a 2-leaf split laid out UNZOOMED first (so both wrappers
    ///        materialize and `activeLeafID` reseeds to `firstLeafID`,
    ///        the tree's `focusedLeafID`), then re-laid-out zoomed onto
    ///        the SECOND leaf — a leaf other than `activeLeafID`. (Zooming
    ///        alone never touches `activeLeafID`/`focusedLeafID`, and the
    ///        `updateLayout` reseed guard does not fire here because
    ///        `firstLeafID`'s wrapper still exists, merely hidden.)
    /// When:  reading each surface's `alphaValue` after the zoomed pass.
    /// Then:  the zoomed (second) pane is alpha 1.0 despite not being
    ///        `activeLeafID`, and the nominally-"active" (first) pane is
    ///        dimmed to 0.75 — proving `applyActiveDimming()`'s
    ///        `effectiveActive` branch, not the `scrollWrappers.count <= 1`
    ///        shortcut, decided this (both wrappers exist here).
    func testZoomedPane_isFullyOpaque_evenWhenItDiffersFromActiveLeafID() {
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)

        let unzoomedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: nil
        )
        fixture.container.updateLayout(tree: unzoomedTree)

        let zoomedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID, secondLeafID: secondLeafID,
            focusedLeafID: firstLeafID, zoomedLeafID: secondLeafID
        )
        fixture.container.updateLayout(tree: zoomedTree)

        guard let firstSurface = fixture.registry.view(for: firstLeafID),
              let secondSurface = fixture.registry.view(for: secondLeafID) else {
            XCTFail("Registry must provide SurfaceView instances for both leaves")
            return
        }
        XCTAssertEqual(secondSurface.alphaValue, 1.0, accuracy: 0.0001,
                       "The zoomed pane must be alpha 1.0 even though activeLeafID is the OTHER leaf (firstLeafID)")
        XCTAssertEqual(firstSurface.alphaValue, 0.75, accuracy: 0.0001,
                       "The non-zoomed pane must still be dimmed — proving zoom, not activeLeafID, decided " +
                       "the effective active pane while both wrappers exist")
    }
}
