// SplitTree.swift
// Calyx
//
// Immutable value type representing a binary tree of terminal panes with ratio-based layout.

import Foundation

// MARK: - Direction Types

enum SplitDirection: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

enum SpatialDirection: Sendable {
    case left, right, up, down
}

enum FocusDirection: Sendable {
    case previous
    case next
    case spatial(SpatialDirection)
}

// MARK: - SplitNode

indirect enum SplitNode: Codable, Equatable, Sendable {
    case leaf(id: UUID)
    case split(SplitData)

    var leafID: UUID? {
        if case .leaf(let id) = self { return id }
        return nil
    }
}

// MARK: - SplitData

struct SplitData: Codable, Equatable, Sendable {
    let direction: SplitDirection
    let ratio: Double
    let first: SplitNode
    let second: SplitNode

    init(direction: SplitDirection, ratio: Double, first: SplitNode, second: SplitNode) {
        self.direction = direction
        self.ratio = Self.clampRatio(ratio)
        self.first = first
        self.second = second
    }

    static func clampRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0.1), 0.9)
    }
}

// MARK: - SplitTree

struct SplitTree: Codable, Equatable, Sendable {
    var root: SplitNode?
    var focusedLeafID: UUID?
    /// The leaf currently zoomed (temporarily expanded to fill the whole
    /// tab), or `nil` if nothing is zoomed. `private(set)`: every write
    /// path goes through `togglingZoom(at:)`/`clearingZoom()`/
    /// `settingFocus(_:)` (or one of this type's own mutating transforms
    /// below, each of which decides for itself whether to preserve,
    /// clear, or remap it) — never a direct assignment from outside this
    /// file, the same discipline `root`'s own privacy would get if it
    /// weren't for `SplitContainerView`'s direct-mutation needs elsewhere.
    /// View/Controller code must read `effectiveZoomedLeafID`, never this
    /// property directly — see that computed property's own doc comment.
    /// Defaults to `nil` deliberately: every one of this type's mutating
    /// transforms constructs a NEW `SplitTree` via the initializer below,
    /// and any call site that forgets to explicitly thread this value
    /// through therefore fails safe (zoom silently clears) rather than
    /// unsafe (a stale zoom silently persists somewhere it shouldn't).
    private(set) var zoomedLeafID: UUID?

    init(root: SplitNode? = nil, focusedLeafID: UUID? = nil, zoomedLeafID: UUID? = nil) {
        self.root = root
        self.focusedLeafID = focusedLeafID
        self.zoomedLeafID = zoomedLeafID
    }

    init(leafID: UUID) {
        self.root = .leaf(id: leafID)
        self.focusedLeafID = leafID
        self.zoomedLeafID = nil
    }

    var isEmpty: Bool { root == nil }

    var isSplit: Bool {
        if case .split = root { return true }
        return false
    }

    // MARK: - Insert

    func insert(at leafID: UUID, direction: SplitDirection, newID: UUID = UUID()) -> (tree: SplitTree, newLeafID: UUID) {
        let newID = newID
        guard let root else {
            // zoomedLeafID: nil — a brand new single-leaf tree has nothing
            // to zoom relative to (mirrors init(leafID:)).
            let tree = SplitTree(root: .leaf(id: newID), focusedLeafID: newID, zoomedLeafID: nil)
            return (tree, newID)
        }

        let newRoot = Self.insertNode(in: root, at: leafID, newID: newID, direction: direction)
        // zoomedLeafID: nil — creating a new split pane while another pane
        // is zoomed would otherwise make the new pane invisible behind its
        // still-zoomed sibling.
        let tree = SplitTree(root: newRoot, focusedLeafID: newID, zoomedLeafID: nil)
        return (tree, newID)
    }

    private static func insertNode(in node: SplitNode, at targetID: UUID, newID: UUID, direction: SplitDirection) -> SplitNode {
        switch node {
        case .leaf(let id):
            if id == targetID {
                let existing = SplitNode.leaf(id: id)
                let new = SplitNode.leaf(id: newID)
                switch direction {
                case .horizontal:
                    return .split(SplitData(direction: .horizontal, ratio: 0.5, first: existing, second: new))
                case .vertical:
                    return .split(SplitData(direction: .vertical, ratio: 0.5, first: existing, second: new))
                }
            }
            return node

        case .split(let data):
            let newFirst = insertNode(in: data.first, at: targetID, newID: newID, direction: direction)
            let newSecond = insertNode(in: data.second, at: targetID, newID: newID, direction: direction)
            return .split(SplitData(direction: data.direction, ratio: data.ratio, first: newFirst, second: newSecond))
        }
    }

    // MARK: - Remove

    func remove(_ leafID: UUID) -> (tree: SplitTree, focusTarget: UUID?) {
        guard let root else { return (self, nil) }

        // Single leaf removal
        if case .leaf(let id) = root, id == leafID {
            return (SplitTree(), nil)
        }

        // Find the sibling in the tree (the node that shares a parent split with the leaf)
        let focusTarget = Self.findSiblingLeaf(in: root, of: leafID)

        let newRoot = Self.removeNode(from: root, leafID: leafID)
        let newFocused = focusTarget ?? focusedLeafID

        // zoomedLeafID: cleared if the removed leaf WAS the zoomed one, or
        // if the removal collapsed the tree so it's no longer split (a
        // non-split tree must never carry a truthy zoom — see
        // effectiveZoomedLeafID's own doc comment). This is a Calyx-only
        // normalization on top of upstream's simpler `zoomed == target ?
        // nil : zoomed`: preserved otherwise (an unrelated leaf removed
        // from a tree that's still split afterward).
        let stillSplitAfterRemoval: Bool
        if case .split = newRoot {
            stillSplitAfterRemoval = true
        } else {
            stillSplitAfterRemoval = false
        }
        let newZoomed: UUID? = (leafID == zoomedLeafID || !stillSplitAfterRemoval) ? nil : zoomedLeafID

        return (
            SplitTree(root: newRoot, focusedLeafID: newRoot == nil ? nil : newFocused, zoomedLeafID: newZoomed),
            focusTarget
        )
    }

    /// Find the leftmost/first leaf in the sibling subtree of the given leaf.
    private static func findSiblingLeaf(in node: SplitNode, of leafID: UUID) -> UUID? {
        guard case .split(let data) = node else { return nil }

        let firstContains = containsLeaf(data.first, id: leafID)
        let secondContains = containsLeaf(data.second, id: leafID)

        if firstContains && !secondContains {
            // Leaf is in first child — sibling is the first leaf of second child
            if case .leaf(let id) = data.first, id == leafID {
                return firstLeafID(of: data.second)
            }
            return findSiblingLeaf(in: data.first, of: leafID)
        }

        if secondContains && !firstContains {
            // Leaf is in second child — sibling is the first leaf of first child
            if case .leaf(let id) = data.second, id == leafID {
                return firstLeafID(of: data.first)
            }
            return findSiblingLeaf(in: data.second, of: leafID)
        }

        return nil
    }

    static func firstLeafID(of node: SplitNode) -> UUID? {
        switch node {
        case .leaf(let id):
            return id
        case .split(let data):
            return firstLeafID(of: data.first)
        }
    }

    private static func removeNode(from node: SplitNode, leafID: UUID) -> SplitNode? {
        switch node {
        case .leaf(let id):
            return id == leafID ? nil : node

        case .split(let data):
            let newFirst = removeNode(from: data.first, leafID: leafID)
            let newSecond = removeNode(from: data.second, leafID: leafID)

            switch (newFirst, newSecond) {
            case (nil, nil):
                return nil
            case (nil, let remaining?):
                return remaining
            case (let remaining?, nil):
                return remaining
            case (let f?, let s?):
                return .split(SplitData(direction: data.direction, ratio: data.ratio, first: f, second: s))
            }
        }
    }

    // MARK: - Focus Navigation

    func focusTarget(for direction: FocusDirection, from leafID: UUID) -> UUID? {
        let leaves = allLeafIDs()
        guard leaves.count > 1 else { return nil }
        guard let currentIndex = leaves.firstIndex(of: leafID) else { return nil }

        switch direction {
        case .previous:
            let idx = (currentIndex - 1 + leaves.count) % leaves.count
            return leaves[idx]

        case .next:
            let idx = (currentIndex + 1) % leaves.count
            return leaves[idx]

        case .spatial(let spatialDir):
            return spatialFocusTarget(from: leafID, direction: spatialDir)
        }
    }

    private func spatialFocusTarget(from leafID: UUID, direction: SpatialDirection) -> UUID? {
        guard let root else { return nil }
        let slots = Self.buildSpatialSlots(node: root, bounds: CGRect(x: 0, y: 0, width: 1, height: 1))

        guard let currentSlot = slots.first(where: { $0.id == leafID }) else { return nil }

        let candidates = slots.filter { slot in
            guard slot.id != leafID else { return false }
            switch direction {
            case .left:  return slot.bounds.midX < currentSlot.bounds.minX
            case .right: return slot.bounds.midX > currentSlot.bounds.maxX
            case .up:    return slot.bounds.midY < currentSlot.bounds.minY
            case .down:  return slot.bounds.midY > currentSlot.bounds.maxY
            }
        }

        let currentCenter = CGPoint(x: currentSlot.bounds.midX, y: currentSlot.bounds.midY)
        return candidates.min(by: {
            distance(from: currentCenter, to: CGPoint(x: $0.bounds.midX, y: $0.bounds.midY))
                < distance(from: currentCenter, to: CGPoint(x: $1.bounds.midX, y: $1.bounds.midY))
        })?.id
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    struct SpatialSlot {
        let id: UUID
        let bounds: CGRect
    }

    private static func buildSpatialSlots(node: SplitNode, bounds: CGRect) -> [SpatialSlot] {
        switch node {
        case .leaf(let id):
            return [SpatialSlot(id: id, bounds: bounds)]

        case .split(let data):
            let (firstBounds, secondBounds) = splitBounds(bounds, direction: data.direction, ratio: data.ratio)
            return buildSpatialSlots(node: data.first, bounds: firstBounds)
                + buildSpatialSlots(node: data.second, bounds: secondBounds)
        }
    }

    private static func splitBounds(_ bounds: CGRect, direction: SplitDirection, ratio: Double) -> (CGRect, CGRect) {
        switch direction {
        case .horizontal:
            let splitX = bounds.minX + bounds.width * ratio
            let first = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * ratio, height: bounds.height)
            let second = CGRect(x: splitX, y: bounds.minY, width: bounds.width * (1 - ratio), height: bounds.height)
            return (first, second)

        case .vertical:
            let splitY = bounds.minY + bounds.height * ratio
            let first = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * ratio)
            let second = CGRect(x: bounds.minX, y: splitY, width: bounds.width, height: bounds.height * (1 - ratio))
            return (first, second)
        }
    }

    // MARK: - Equalize

    func equalize() -> SplitTree {
        guard let root else { return self }
        let newRoot = Self.equalizeNode(root)
        // zoomedLeafID: preserved. Matches upstream ghostty's own
        // `SplitTree.equalized()` (macos/Sources/Features/Splits/
        // SplitTree.swift), which is the one mutating transform there
        // that keeps `zoomed` instead of resetting it — equalize only
        // touches ratios, an orthogonal concern from zoom's "which pane
        // temporarily fills the tab" state.
        return SplitTree(root: newRoot, focusedLeafID: focusedLeafID, zoomedLeafID: zoomedLeafID)
    }

    private static func equalizeNode(_ node: SplitNode) -> SplitNode {
        switch node {
        case .leaf:
            return node
        case .split(let data):
            let newFirst = equalizeNode(data.first)
            let newSecond = equalizeNode(data.second)
            return .split(SplitData(direction: data.direction, ratio: 0.5, first: newFirst, second: newSecond))
        }
    }

    // MARK: - Resize

    func resize(node leafID: UUID, by amount: Double, direction: SplitDirection, bounds: CGSize, minSize: CGFloat) -> SplitTree {
        guard let root else { return self }

        let targetDirection = direction
        guard let newRoot = Self.resizeInNode(
            root,
            targetLeafID: leafID,
            amount: amount,
            targetDirection: targetDirection,
            totalSize: targetDirection == .horizontal ? bounds.width : bounds.height,
            minSize: minSize
        ) else {
            return self
        }

        // zoomedLeafID: preserved — a pure ratio/geometry change, orthogonal to zoom.
        return SplitTree(root: newRoot, focusedLeafID: focusedLeafID, zoomedLeafID: zoomedLeafID)
    }

    private static func resizeInNode(
        _ node: SplitNode,
        targetLeafID: UUID,
        amount: Double,
        targetDirection: SplitDirection,
        totalSize: CGFloat,
        minSize: CGFloat
    ) -> SplitNode? {
        guard case .split(let data) = node else { return nil }

        let firstContains = containsLeaf(data.first, id: targetLeafID)
        let secondContains = containsLeaf(data.second, id: targetLeafID)

        guard firstContains || secondContains else { return nil }

        if data.direction == targetDirection {
            // This split matches the resize direction — adjust ratio
            let pixelAmount = amount
            let ratioChange = pixelAmount / Double(totalSize)
            let newRatio: Double
            if firstContains {
                newRatio = data.ratio + ratioChange
            } else {
                newRatio = data.ratio - ratioChange
            }

            let minRatio = Double(minSize) / Double(totalSize)
            let clampedRatio = SplitData.clampRatio(max(minRatio, min(1 - minRatio, newRatio)))

            return .split(SplitData(direction: data.direction, ratio: clampedRatio, first: data.first, second: data.second))
        }

        // Direction doesn't match — recurse into the child that contains the target
        if firstContains {
            if let newFirst = resizeInNode(data.first, targetLeafID: targetLeafID, amount: amount, targetDirection: targetDirection, totalSize: totalSize, minSize: minSize) {
                return .split(SplitData(direction: data.direction, ratio: data.ratio, first: newFirst, second: data.second))
            }
        }
        if secondContains {
            if let newSecond = resizeInNode(data.second, targetLeafID: targetLeafID, amount: amount, targetDirection: targetDirection, totalSize: totalSize, minSize: minSize) {
                return .split(SplitData(direction: data.direction, ratio: data.ratio, first: data.first, second: newSecond))
            }
        }

        return nil
    }

    // MARK: - Set Ratio

    /// Pin the direction-matching split that owns `leafID` to an absolute
    /// `targetRatio` in [0, 1]. Used by callers that only have a leaf in hand
    /// (e.g. tests, future programmatic resize APIs). Clamping happens here
    /// so callers never have to know about `minSize` or the `SplitData`
    /// global cap.
    ///
    /// NOTE: This walks top-down and stops at the FIRST direction-matching
    /// ancestor split that contains `leafID`. For nested SAME-direction
    /// splits — e.g. `V(A, V(B, C))` — this is ambiguous: targeting B will
    /// pin the OUTER vertical split, not the inner one. The divider-drag
    /// path must use `setRatio(firstChildFirstLeafID:secondChildFirstLeafID:direction:to:bounds:minSize:)`
    /// instead, which identifies a split unambiguously by both of its
    /// children's leftmost leaf IDs.
    func setRatio(
        node leafID: UUID,
        to targetRatio: Double,
        direction: SplitDirection,
        bounds: CGSize,
        minSize: CGFloat
    ) -> SplitTree {
        guard let root else { return self }

        guard let newRoot = Self.setRatioInNode(
            root,
            targetLeafID: leafID,
            targetRatio: targetRatio,
            targetDirection: direction,
            totalSize: direction == .horizontal ? bounds.width : bounds.height,
            minSize: minSize
        ) else {
            return self
        }

        // zoomedLeafID: preserved — a pure ratio/geometry change, orthogonal to zoom.
        return SplitTree(root: newRoot, focusedLeafID: focusedLeafID, zoomedLeafID: zoomedLeafID)
    }

    /// Pin a SPECIFIC split — identified unambiguously by the leftmost leaf
    /// IDs of both its children plus its direction — to an absolute
    /// `targetRatio` in [0, 1]. This is the divider-drag entry point: in a
    /// binary tree, two distinct splits cannot share BOTH children's
    /// leftmost leaves AND direction, so this triple uniquely names exactly
    /// one split, which avoids the Bug B ambiguity that
    /// `setRatio(node:to:...)` suffers for nested same-direction nests
    /// like `V(A, V(B, C))`.
    func setRatio(
        firstChildFirstLeafID: UUID,
        secondChildFirstLeafID: UUID,
        direction: SplitDirection,
        to targetRatio: Double,
        bounds: CGSize,
        minSize: CGFloat
    ) -> SplitTree {
        guard let root else { return self }

        guard let newRoot = Self.setRatioForSpecificSplit(
            root,
            firstChildFirstLeafID: firstChildFirstLeafID,
            secondChildFirstLeafID: secondChildFirstLeafID,
            targetDirection: direction,
            targetRatio: targetRatio,
            totalSize: direction == .horizontal ? bounds.width : bounds.height,
            minSize: minSize
        ) else {
            return self
        }

        // zoomedLeafID: preserved — a pure ratio/geometry change, orthogonal to zoom.
        return SplitTree(root: newRoot, focusedLeafID: focusedLeafID, zoomedLeafID: zoomedLeafID)
    }

    private static func setRatioInNode(
        _ node: SplitNode,
        targetLeafID: UUID,
        targetRatio: Double,
        targetDirection: SplitDirection,
        totalSize: CGFloat,
        minSize: CGFloat
    ) -> SplitNode? {
        guard case .split(let data) = node else { return nil }

        let firstContains = containsLeaf(data.first, id: targetLeafID)
        let secondContains = containsLeaf(data.second, id: targetLeafID)

        guard firstContains || secondContains else { return nil }

        if data.direction == targetDirection {
            let newRatio: Double = firstContains ? targetRatio : 1 - targetRatio
            let minRatio = totalSize > 0 ? Double(minSize) / Double(totalSize) : 0
            let geometryClamped = max(minRatio, min(1 - minRatio, newRatio))
            let clampedRatio = SplitData.clampRatio(geometryClamped)

            return .split(SplitData(direction: data.direction, ratio: clampedRatio, first: data.first, second: data.second))
        }

        // Direction doesn't match — recurse into the child that contains the target
        if firstContains {
            if let newFirst = setRatioInNode(data.first, targetLeafID: targetLeafID, targetRatio: targetRatio, targetDirection: targetDirection, totalSize: totalSize, minSize: minSize) {
                return .split(SplitData(direction: data.direction, ratio: data.ratio, first: newFirst, second: data.second))
            }
        }
        if secondContains {
            if let newSecond = setRatioInNode(data.second, targetLeafID: targetLeafID, targetRatio: targetRatio, targetDirection: targetDirection, totalSize: totalSize, minSize: minSize) {
                return .split(SplitData(direction: data.direction, ratio: data.ratio, first: data.first, second: newSecond))
            }
        }

        return nil
    }

    /// Walk the tree and pin exactly the split whose `(firstLeafID(first),
    /// firstLeafID(second), direction)` triple matches the request. Returns
    /// `nil` if no such split exists (e.g. caller passed IDs for a split
    /// that's already been collapsed away).
    private static func setRatioForSpecificSplit(
        _ node: SplitNode,
        firstChildFirstLeafID: UUID,
        secondChildFirstLeafID: UUID,
        targetDirection: SplitDirection,
        targetRatio: Double,
        totalSize: CGFloat,
        minSize: CGFloat
    ) -> SplitNode? {
        guard case .split(let data) = node else { return nil }

        if data.direction == targetDirection,
           firstLeafID(of: data.first) == firstChildFirstLeafID,
           firstLeafID(of: data.second) == secondChildFirstLeafID {
            // Exact match — clamp and pin the ratio here.
            let minRatio = totalSize > 0 ? Double(minSize) / Double(totalSize) : 0
            let geometryClamped = max(minRatio, min(1 - minRatio, targetRatio))
            let clampedRatio = SplitData.clampRatio(geometryClamped)
            return .split(SplitData(
                direction: data.direction,
                ratio: clampedRatio,
                first: data.first,
                second: data.second
            ))
        }

        // Not this split — recurse into either child that might contain it.
        if let newFirst = setRatioForSpecificSplit(
            data.first,
            firstChildFirstLeafID: firstChildFirstLeafID,
            secondChildFirstLeafID: secondChildFirstLeafID,
            targetDirection: targetDirection,
            targetRatio: targetRatio,
            totalSize: totalSize,
            minSize: minSize
        ) {
            return .split(SplitData(
                direction: data.direction,
                ratio: data.ratio,
                first: newFirst,
                second: data.second
            ))
        }
        if let newSecond = setRatioForSpecificSplit(
            data.second,
            firstChildFirstLeafID: firstChildFirstLeafID,
            secondChildFirstLeafID: secondChildFirstLeafID,
            targetDirection: targetDirection,
            targetRatio: targetRatio,
            totalSize: totalSize,
            minSize: minSize
        ) {
            return .split(SplitData(
                direction: data.direction,
                ratio: data.ratio,
                first: data.first,
                second: newSecond
            ))
        }

        return nil
    }

    // MARK: - Queries

    func allLeafIDs() -> [UUID] {
        guard let root else { return [] }
        return Self.collectLeaves(root)
    }

    private static func collectLeaves(_ node: SplitNode) -> [UUID] {
        switch node {
        case .leaf(let id):
            return [id]
        case .split(let data):
            return collectLeaves(data.first) + collectLeaves(data.second)
        }
    }

    func findParentSplit(of leafID: UUID) -> SplitData? {
        guard let root else { return nil }
        return Self.findParent(in: root, of: leafID)
    }

    private static func findParent(in node: SplitNode, of leafID: UUID) -> SplitData? {
        guard case .split(let data) = node else { return nil }

        if data.first.leafID == leafID || data.second.leafID == leafID {
            return data
        }

        return findParent(in: data.first, of: leafID) ?? findParent(in: data.second, of: leafID)
    }

    static func containsLeaf(_ node: SplitNode, id: UUID) -> Bool {
        switch node {
        case .leaf(let leafID):
            return leafID == id
        case .split(let data):
            return containsLeaf(data.first, id: id) || containsLeaf(data.second, id: id)
        }
    }

    // MARK: - Remap

    /// Replace leaf UUIDs according to the given mapping.
    /// Leaf IDs not present in the mapping remain unchanged.
    /// focusedLeafID is also updated if it appears in the mapping.
    func remapLeafIDs(_ mapping: [UUID: UUID]) -> SplitTree {
        guard let root else { return self }
        let newRoot = Self.remapNode(root, mapping: mapping)
        let newFocused = focusedLeafID.flatMap { mapping[$0] ?? $0 }
        // zoomedLeafID: re-keyed through the same mapping as focusedLeafID,
        // so a session restore's leaf-ID remap doesn't silently orphan a
        // persisted zoom.
        let newZoomed = zoomedLeafID.flatMap { mapping[$0] ?? $0 }
        return SplitTree(root: newRoot, focusedLeafID: newFocused, zoomedLeafID: newZoomed)
    }

    private static func remapNode(_ node: SplitNode, mapping: [UUID: UUID]) -> SplitNode {
        switch node {
        case .leaf(let id):
            return .leaf(id: mapping[id] ?? id)
        case .split(let data):
            let newFirst = remapNode(data.first, mapping: mapping)
            let newSecond = remapNode(data.second, mapping: mapping)
            return .split(SplitData(direction: data.direction, ratio: data.ratio, first: newFirst, second: newSecond))
        }
    }

    // MARK: - Zoom (GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM)
    //
    // Ported from upstream ghostty's `SplitTree.zoomed` +
    // `BaseTerminalController.ghosttyDidToggleSplitZoom`
    // (macos/Sources/Features/Splits/SplitTree.swift,
    // macos/Sources/Features/Terminal/BaseTerminalController.swift).
    //
    // Every mutating transform above (`insert`/`remove`/`equalize`/
    // `resize`/`setRatio`×2/`remapLeafIDs`) threads `zoomedLeafID` through
    // its own `SplitTree(root:focusedLeafID:zoomedLeafID:)` call
    // explicitly, rather than relying on the initializer's `nil` default,
    // so a reviewer can see what each transform intends for zoom right at
    // its own call site instead of cross-referencing this section. Summary
    // (see SplitTreeTests.swift's own "Split Zoom" section for the
    // test-level contract):
    //
    //   insert          -> nil (a new split pane would otherwise be
    //                       invisible behind a still-zoomed sibling)
    //   remove          -> nil if the removed leaf WAS the zoomed one, or
    //                       if the removal collapsed the tree so it's no
    //                       longer split (Calyx-only normalization beyond
    //                       upstream — see effectiveZoomedLeafID's own
    //                       doc comment); preserved otherwise
    //   equalize        -> preserved (matches upstream's own
    //                       `SplitTree.equalized()`, the one mutating
    //                       transform there that also keeps `zoomed` —
    //                       ratio changes are orthogonal to zoom)
    //   resize/setRatio -> preserved (pure ratio/geometry changes)
    //   remapLeafIDs    -> re-keyed through the same `mapping` dictionary
    //                       `focusedLeafID` already goes through

    /// Returns `zoomedLeafID` only when it names a leaf that actually
    /// exists in `root` AND the tree `isSplit`. View/Controller code
    /// reads ONLY this, never `zoomedLeafID` directly — double defense so
    /// a corrupt/stale `zoomedLeafID` (restored from JSON written by a
    /// build with a bug, or surviving some future transform that fails
    /// to clear it on collapse) can never present a single-pane tab as
    /// zoomed, or point at a leaf that no longer exists.
    var effectiveZoomedLeafID: UUID? {
        guard isSplit, let zoomedLeafID, let root, Self.containsLeaf(root, id: zoomedLeafID) else {
            return nil
        }
        return zoomedLeafID
    }

    /// Toggle zoom on `leafID`: zoom it if it isn't already the zoomed
    /// leaf, clear zoom if it is. A no-op (zoom stays whatever it already
    /// was) when the tree isn't split, mirroring upstream ghostty's
    /// `guard surfaceTree.isSplit else { return }` — a single pane can
    /// never be "zoomed" (there is nothing to expand it relative to) —
    /// and likewise a no-op when `leafID` doesn't actually name a leaf of
    /// this tree, so a stale/unknown id can never fabricate a zoom.
    func togglingZoom(at leafID: UUID) -> SplitTree {
        guard isSplit, let root, Self.containsLeaf(root, id: leafID) else { return self }
        let newZoomed: UUID? = (zoomedLeafID == leafID) ? nil : leafID
        return SplitTree(root: root, focusedLeafID: focusedLeafID, zoomedLeafID: newZoomed)
    }

    /// Unconditionally clears zoom.
    func clearingZoom() -> SplitTree {
        SplitTree(root: root, focusedLeafID: focusedLeafID, zoomedLeafID: nil)
    }

    /// Move focus to `leafID`, clearing zoom. Calyx does not implement
    /// ghostty's `split-preserve-zoom` config (`src/config/Config.zig`);
    /// its default (`navigation: false`) means `goto_split` always clears
    /// zoom, so that's the only behavior this type needs to encode.
    func settingFocus(_ leafID: UUID) -> SplitTree {
        SplitTree(root: root, focusedLeafID: leafID, zoomedLeafID: nil)
    }
}
