// SplitContainerView.swift
// Calyx
//
// NSView that recursively renders a SplitTree using SurfaceRegistry lookups.

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SplitContainerView")

@MainActor
class SplitContainerView: NSView {

    /// Composite cache key that uniquely identifies a single split node in
    /// the current tree. Built from the leftmost leaves of BOTH children
    /// plus direction, because in a binary tree two distinct splits cannot
    /// share both children's leftmost leaves AND direction. This avoids the
    /// Bug A collision in trees like `V(H(A, C), B)` where the outer V and
    /// the inner H would otherwise both compute `firstLeafID(first) == A`
    /// and clobber each other in a UUID-only cache.
    private struct DividerKey: Hashable {
        let firstChildFirstLeafID: UUID
        let secondChildFirstLeafID: UUID
        let direction: SplitDirection
    }

    private var registry: SurfaceRegistry
    private var currentTree: SplitTree = SplitTree()
    private var scrollWrappers: [UUID: SurfaceScrollView] = [:]
    private var activeLeafID: UUID?
    // Keep divider NSView instances alive across layout passes; AppKit's
    // mouse-capture session is bound to the original instance, so tearing
    // them down mid-drag kills subsequent mouseDragged events.
    private var dividerCache: [DividerKey: SplitDividerView] = [:]
    private var dividersUsedThisPass: Set<DividerKey> = []
    /// Fired on every divider drag tick. Carries both the leftmost leaf IDs
    /// of the split's children (required to disambiguate nested
    /// same-direction splits — Bug B) and the split's containing rect in
    /// the container's coordinate space (required so the controller can
    /// pass the LOCAL size to `setRatio` — Bug C).
    var onTargetRatioChange: ((
        _ firstChildFirstLeafID: UUID,
        _ secondChildFirstLeafID: UUID,
        _ targetRatio: Double,
        _ direction: SplitDirection,
        _ splitRect: CGRect
    ) -> Void)?
    var onDeferredLayoutComplete: (() -> Void)?
    var onActiveLeafChange: ((UUID) -> Void)?

    private static let minPaneSize: CGFloat = 50

    init(registry: SurfaceRegistry) {
        self.registry = registry
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    // MARK: - Update

    func updateRegistry(_ registry: SurfaceRegistry) {
        guard self.registry !== registry else { return }
        self.registry = registry
        currentTree = SplitTree()
        scrollWrappers.removeAll()
        dividerCache.removeAll()
        dividersUsedThisPass.removeAll()
        subviews.forEach { $0.removeFromSuperview() }
        activeLeafID = nil
        needsLayout = true
    }

    func updateLayout(tree: SplitTree) {
        let oldTree = currentTree
        currentTree = tree

        guard oldTree != tree else { return }

        // Don't move surface views into a zero-bounds container —
        // setFrameSize(zero) kills Metal drawable and ghostty stops rendering.
        // resizeSubviews/layout will handle it when we get proper bounds.
        guard bounds.width > 0 && bounds.height > 0 else { return }

        guard tree.root != nil else {
            dividersUsedThisPass.removeAll()
            subviews.forEach { $0.removeFromSuperview() }
            scrollWrappers.removeAll()
            dividerCache.removeAll()
            activeLeafID = nil
            applyActiveDimming()
            return
        }

        applyLayout()

        if activeLeafID == nil || scrollWrappers[activeLeafID!] == nil {
            activeLeafID = tree.focusedLeafID
            // A brand new container's (or brand new tab's, after
            // updateRegistry(_:) resets activeLeafID) first-ever active
            // leaf pick — mirrors surfaceDidBecomeActive's own call so the
            // production requestSave() wiring fires for a window/tab's
            // first surface with no later focus/split/tab action required.
            if let id = activeLeafID {
                onActiveLeafChange?(id)
            }
        }
        // Must run AFTER the reseed above, not folded into applyLayout():
        // a brand-new container's first-ever updateLayout(tree:) call
        // reaches this method with activeLeafID still nil, and dimming a
        // multi-pane split against a nil active leaf would flatten every
        // pane to alpha 1.0 instead of the tree's actual focused/dimmed
        // split (see testTwoPaneSplitDimsInactivePane).
        applyActiveDimming()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard currentTree.root != nil else { return }
        applyLayout()
        applyActiveDimming()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard currentTree.root != nil else { return }

        // Deferred layout: surface views haven't been added yet
        if subviews.isEmpty || subviews.allSatisfy({ !($0 is SplitDividerView) }) {
            applyLayout()
            applyActiveDimming()
            let callback = onDeferredLayoutComplete
            onDeferredLayoutComplete = nil
            callback?()
        }
    }

    /// Shared layout body for all three AppKit entry points above
    /// (`updateLayout(tree:)` — when `tree.root != nil`, `resizeSubviews
    /// (withOldSize:)`, and `layout()`'s deferred-layout branch): lay out
    /// `currentTree` into `bounds`, drop orphaned surfaces, and reap
    /// unused dividers. Centralizing this is not just DRY — it is the fix
    /// for a real, reproducible regression class: before this method
    /// existed, the zoom branch below would need to be duplicated in all
    /// three call sites, and forgetting it in exactly one (`resizeSubviews`,
    /// historically the easiest one to miss) means zoom visibly un-zooms
    /// the instant the window is resized, even though `currentTree
    /// .zoomedLeafID` never actually changed.
    ///
    /// Deliberately does NOT call `applyActiveDimming()` itself, unlike
    /// every other per-pass step here — each of the three call sites
    /// above calls it independently, right after `applyLayout()` returns,
    /// because `updateLayout(tree:)` needs to run its own `activeLeafID`
    /// reseed IN BETWEEN the two (see that call site's own comment);
    /// folding dimming into this method would run it before that reseed
    /// on every first-ever layout pass.
    private func applyLayout() {
        guard let root = currentTree.root else { return }

        dividersUsedThisPass.removeAll()
        if let zoomID = currentTree.effectiveZoomedLeafID {
            // Zoomed: lay out ONLY the zoomed leaf, at the container's
            // full bounds, and hide every other wrapper. Hiding the
            // `SurfaceScrollView` WRAPPER (not the `SurfaceView` inside
            // it) matters: wrappers are recreated whenever a leaf is
            // freshly laid out (see the `.leaf` case in `layoutNode`
            // below), so a stale `isHidden` can never leak across a
            // registry swap the way it could if this toggled the
            // long-lived, registry-owned `SurfaceView` instead.
            //
            // Deliberately does NOT zero any non-zoomed wrapper's frame —
            // `updateLayout(tree:)`'s own comment above documents why
            // `setFrameSize(zero)` kills a live Metal drawable; a hidden
            // pane simply keeps whatever frame its last visible layout
            // pass gave it, which is harmless since it isn't drawn.
            //
            // `placeDivider` is never called on this path, so
            // `dividersUsedThisPass` stays empty and `reapUnusedDividers()`
            // below removes every cached divider — they reappear
            // automatically the moment zoom clears and the `else` branch
            // walks the full tree again.
            layoutNode(.leaf(id: zoomID), in: bounds)
            for (id, wrapper) in scrollWrappers {
                wrapper.isHidden = (id != zoomID)
            }
        } else {
            layoutNode(root, in: bounds)
            for (_, wrapper) in scrollWrappers {
                wrapper.isHidden = false
            }
        }
        removeOrphanedSurfaces()
        reapUnusedDividers()
    }

    // MARK: - Active Pane Dimming

    private func applyActiveDimming() {
        let inactiveAlpha: CGFloat = 0.75
        let count = scrollWrappers.count

        if count <= 1 {
            for (_, wrapper) in scrollWrappers where wrapper.surfaceView.alphaValue != 1.0 {
                wrapper.surfaceView.alphaValue = 1.0
            }
            return
        }

        // While zoomed, the zoomed leaf is the effective active pane for
        // dimming purposes, regardless of `activeLeafID` — `activeLeafID`
        // only updates on an explicit focus transition (surfaceDidBecomeActive
        // / updateLayout's reseed), so it can lag behind a just-applied
        // zoom (e.g. zooming a pane that isn't the currently-focused one).
        // Without this, that pane would be visible (per applyLayout's
        // isHidden branch above) but dimmed to 0.75 — a single, fully
        // visible pane that looks wrong.
        let effectiveActive = currentTree.effectiveZoomedLeafID ?? activeLeafID

        guard let active = effectiveActive, scrollWrappers[active] != nil else {
            for (_, wrapper) in scrollWrappers where wrapper.surfaceView.alphaValue != 1.0 {
                wrapper.surfaceView.alphaValue = 1.0
            }
            return
        }

        for (id, wrapper) in scrollWrappers {
            let desired: CGFloat = (id == active) ? 1.0 : inactiveAlpha
            if wrapper.surfaceView.alphaValue != desired {
                wrapper.surfaceView.alphaValue = desired
            }
        }
    }

    // MARK: - Recursive Layout

    private func layoutNode(_ node: SplitNode, in rect: CGRect) {
        switch node {
        case .leaf(let id):
            if let surfaceView = registry.view(for: id) {
                let wrapper: SurfaceScrollView
                if let existing = scrollWrappers[id] {
                    wrapper = existing
                } else {
                    wrapper = SurfaceScrollView(surfaceView: surfaceView)
                    scrollWrappers[id] = wrapper
                }
                surfaceView.focusHost = self
                wrapper.frame = rect
                wrapper.autoresizingMask = []
                if wrapper.superview !== self {
                    addSubview(wrapper)
                }
            }

        case .split(let data):
            let dividerThickness: CGFloat = 1

            switch data.direction {
            case .horizontal:
                let splitX = rect.minX + rect.width * data.ratio
                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: max(splitX - rect.minX - dividerThickness / 2, Self.minPaneSize),
                    height: rect.height
                )
                let dividerRect = CGRect(
                    x: firstRect.maxX,
                    y: rect.minY,
                    width: dividerThickness,
                    height: rect.height
                )
                let secondRect = CGRect(
                    x: dividerRect.maxX,
                    y: rect.minY,
                    width: max(rect.maxX - dividerRect.maxX, Self.minPaneSize),
                    height: rect.height
                )

                layoutNode(data.first, in: firstRect)
                placeDivider(direction: .horizontal, frame: dividerRect, splitData: data, splitRect: rect)
                layoutNode(data.second, in: secondRect)

            case .vertical:
                let splitY = rect.minY + rect.height * data.ratio
                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: max(splitY - rect.minY - dividerThickness / 2, Self.minPaneSize)
                )
                let dividerRect = CGRect(
                    x: rect.minX,
                    y: firstRect.maxY,
                    width: rect.width,
                    height: dividerThickness
                )
                let secondRect = CGRect(
                    x: rect.minX,
                    y: dividerRect.maxY,
                    width: rect.width,
                    height: max(rect.maxY - dividerRect.maxY, Self.minPaneSize)
                )

                layoutNode(data.first, in: firstRect)
                placeDivider(direction: .vertical, frame: dividerRect, splitData: data, splitRect: rect)
                layoutNode(data.second, in: secondRect)
            }
        }
    }

    private func placeDivider(
        direction: SplitDirection,
        frame: CGRect,
        splitData: SplitData,
        splitRect: CGRect
    ) {
        // Expand hit area around the visible divider
        let hitExpansion: CGFloat = 3
        let hitFrame: CGRect
        switch direction {
        case .horizontal:
            hitFrame = CGRect(
                x: frame.minX - hitExpansion,
                y: frame.minY,
                width: frame.width + hitExpansion * 2,
                height: frame.height
            )
        case .vertical:
            hitFrame = CGRect(
                x: frame.minX,
                y: frame.minY - hitExpansion,
                width: frame.width,
                height: frame.height + hitExpansion * 2
            )
        }

        guard let firstChildID = SplitTree.firstLeafID(of: splitData.first),
              let secondChildID = SplitTree.firstLeafID(of: splitData.second) else { return }

        let key = DividerKey(
            firstChildFirstLeafID: firstChildID,
            secondChildFirstLeafID: secondChildID,
            direction: direction
        )

        let divider: SplitDividerView
        if let existing = dividerCache[key] {
            // Direction is already part of the key, so a cache hit always
            // means the directions match — no need to recheck.
            divider = existing
            divider.frame = hitFrame
            if divider.superview !== self {
                addSubview(divider)
            }
        } else {
            divider = SplitDividerView(direction: direction)
            divider.frame = hitFrame
            dividerCache[key] = divider
            addSubview(divider)
        }

        // Keep the divider in sync with the sub-rect it lives in so drag
        // math is computed relative to that rect, not the whole container
        // (Bug C).
        divider.containingRect = splitRect

        // Rebind the callback every pass so it captures the latest splitData
        // shape (ratio/children may have changed even if the cache key didn't)
        // AND the latest splitRect (resizing the container moves nested splits).
        divider.onTargetRatioChange = { [weak self] targetRatio in
            guard let self else { return }
            self.onTargetRatioChange?(firstChildID, secondChildID, targetRatio, direction, splitRect)
        }

        dividersUsedThisPass.insert(key)
    }

    private func reapUnusedDividers() {
        for key in Array(dividerCache.keys) where !dividersUsedThisPass.contains(key) {
            dividerCache[key]?.removeFromSuperview()
            dividerCache.removeValue(forKey: key)
        }
        dividersUsedThisPass.removeAll()
    }

    /// Remove orphaned subviews not present in the current tree.
    /// Handles both SurfaceScrollView wrappers and legacy bare SurfaceView subviews.
    private func removeOrphanedSurfaces() {
        let treeIDs = Set(currentTree.allLeafIDs())
        for subview in subviews {
            if let wrapper = subview as? SurfaceScrollView {
                let id = registry.id(for: wrapper.surfaceView)
                if id == nil || !treeIDs.contains(id!) {
                    subview.removeFromSuperview()
                    if let id { scrollWrappers.removeValue(forKey: id) }
                }
            } else if let surface = subview as? SurfaceView {
                // Legacy: shouldn't happen, but clean up
                let id = registry.id(for: surface)
                if id == nil || !treeIDs.contains(id!) {
                    subview.removeFromSuperview()
                }
            }
        }
        // Also clean wrapper dictionary of IDs no longer in tree
        for id in scrollWrappers.keys where !treeIDs.contains(id) {
            scrollWrappers[id]?.removeFromSuperview()
            scrollWrappers.removeValue(forKey: id)
        }
    }
}

// MARK: - SurfaceFocusHost

extension SplitContainerView: SurfaceFocusHost {
    func surfaceDidBecomeActive(_ surfaceView: SurfaceView) {
        guard let id = registry.id(for: surfaceView) else { return }
        guard activeLeafID != id else { return }
        activeLeafID = id
        applyActiveDimming()
        onActiveLeafChange?(id)
    }
}
