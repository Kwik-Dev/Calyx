//
//  SplitTreeTests.swift
//  CalyxTests
//
//  Tests for the SplitTree model — a pure value type representing
//  the split layout of terminal panes.
//
//  Coverage:
//  - Insert leaf (single → split with 2 leaves)
//  - Remove leaf (collapse parent, verify focus target)
//  - Focus navigation (next/previous with wrap-around)
//  - Equalize (all ratios become 0.5)
//  - Codable roundtrip
//  - Edge: remove last leaf → nil root, nil focus
//  - Ratio clamping to [0.1, 0.9]
//  - Nested splits (insert into already-split tree)
//  - allLeafIDs returns all leaf IDs in order
//

import XCTest
@testable import Calyx

final class SplitTreeTests: XCTestCase {

    // MARK: - Helpers

    /// Build a tree with a single leaf.
    private func makeSingleLeafTree() -> (SplitTree, UUID) {
        let id = UUID()
        let tree = SplitTree(root: .leaf(id: id), focusedLeafID: id)
        return (tree, id)
    }

    // ==================== 1. Insert Leaf ====================

    func test_should_create_split_with_two_leaves_when_inserting_into_single_leaf() {
        // Arrange
        let (tree, originalID) = makeSingleLeafTree()

        // Act
        let (newTree, newLeafID) = tree.insert(at: originalID, direction: .horizontal)

        // Assert — root must now be a split, not a leaf
        guard case .split(let data) = newTree.root else {
            XCTFail("Expected root to be a split after insert, got leaf or nil")
            return
        }

        XCTAssertEqual(data.direction, .horizontal)
        XCTAssertEqual(data.ratio, 0.5, "Default split ratio should be 0.5")

        // The original leaf and the new leaf should appear as children
        guard case .leaf(let firstID) = data.first,
              case .leaf(let secondID) = data.second else {
            XCTFail("Expected both children to be leaves")
            return
        }

        XCTAssertEqual(firstID, originalID, "First child should be the original leaf")
        XCTAssertEqual(secondID, newLeafID, "Second child should be the newly created leaf")
        XCTAssertNotEqual(originalID, newLeafID, "New leaf must have a distinct UUID")
    }

    func test_should_split_vertically_when_vertical_direction_specified() {
        let (tree, leafID) = makeSingleLeafTree()

        let (newTree, _) = tree.insert(at: leafID, direction: .vertical)

        guard case .split(let data) = newTree.root else {
            XCTFail("Expected root to be a split after vertical insert")
            return
        }
        XCTAssertEqual(data.direction, .vertical)
    }

    // ==================== 2. Remove Leaf ====================

    func test_should_collapse_parent_split_when_removing_one_of_two_leaves() {
        // Arrange — start with a single leaf, split it, then remove the new leaf
        let (tree, originalID) = makeSingleLeafTree()
        let (splitTree, newLeafID) = tree.insert(at: originalID, direction: .horizontal)

        // Act — remove the new leaf; the parent split should collapse
        let (result, focusTarget) = splitTree.remove(newLeafID)

        // Assert — root should revert to the original single leaf
        guard case .leaf(let remainingID) = result.root else {
            XCTFail("Expected root to collapse back to a single leaf")
            return
        }
        XCTAssertEqual(remainingID, originalID)
        XCTAssertEqual(focusTarget, originalID, "Focus should move to the remaining leaf")
    }

    func test_should_return_sibling_as_focus_target_when_removing_first_child() {
        let (tree, originalID) = makeSingleLeafTree()
        let (splitTree, newLeafID) = tree.insert(at: originalID, direction: .horizontal)

        // Remove the original (first) leaf
        let (result, focusTarget) = splitTree.remove(originalID)

        guard case .leaf(let remainingID) = result.root else {
            XCTFail("Expected root to collapse back to a single leaf")
            return
        }
        XCTAssertEqual(remainingID, newLeafID)
        XCTAssertEqual(focusTarget, newLeafID, "Focus should move to the remaining sibling")
    }

    // ==================== 3. Focus Navigation ====================

    func test_should_navigate_to_next_leaf_in_order() {
        // Arrange — create a tree with 3 leaves: A | B | C
        let (tree, idA) = makeSingleLeafTree()
        let (tree2, idB) = tree.insert(at: idA, direction: .horizontal)
        let (tree3, idC) = tree2.insert(at: idB, direction: .horizontal)

        let allIDs = tree3.allLeafIDs()
        XCTAssertEqual(allIDs.count, 3, "Should have 3 leaves")

        // Act — from the first leaf, navigate next
        let nextFromA = tree3.focusTarget(for: .next, from: idA)
        XCTAssertEqual(nextFromA, idB, "Next from first leaf should be second leaf")
    }

    func test_should_navigate_to_previous_leaf_in_order() {
        let (tree, idA) = makeSingleLeafTree()
        let (tree2, idB) = tree.insert(at: idA, direction: .horizontal)
        let (tree3, _) = tree2.insert(at: idB, direction: .horizontal)

        let prevFromB = tree3.focusTarget(for: .previous, from: idB)
        XCTAssertEqual(prevFromB, idA, "Previous from second leaf should be first leaf")
    }

    func test_should_wrap_around_when_navigating_next_from_last_leaf() {
        let (tree, idA) = makeSingleLeafTree()
        let (tree2, idB) = tree.insert(at: idA, direction: .horizontal)

        // idB is the last leaf; next should wrap to idA
        let wrapped = tree2.focusTarget(for: .next, from: idB)
        XCTAssertEqual(wrapped, idA, "Next from last leaf should wrap to the first leaf")
    }

    func test_should_wrap_around_when_navigating_previous_from_first_leaf() {
        let (tree, idA) = makeSingleLeafTree()
        let (tree2, idB) = tree.insert(at: idA, direction: .horizontal)

        let wrapped = tree2.focusTarget(for: .previous, from: idA)
        XCTAssertEqual(wrapped, idB, "Previous from first leaf should wrap to the last leaf")
    }

    // ==================== 4. Equalize ====================

    func test_should_set_all_ratios_to_half_when_equalized() {
        // Arrange — build a tree with unequal ratios via nested splits
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        let innerSplit = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.3,
            first: .leaf(id: idB),
            second: .leaf(id: idC)
        ))
        let root = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.7,
            first: .leaf(id: idA),
            second: innerSplit
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act
        let equalized = tree.equalize()

        // Assert — recursively verify all ratios are 0.5
        func verifyRatios(_ node: SplitNode) {
            switch node {
            case .leaf:
                break
            case .split(let data):
                XCTAssertEqual(data.ratio, 0.5, accuracy: 0.001,
                               "All ratios should be 0.5 after equalize")
                verifyRatios(data.first)
                verifyRatios(data.second)
            }
        }

        if let root = equalized.root {
            verifyRatios(root)
        } else {
            XCTFail("Root should not be nil after equalize")
        }
    }

    func test_should_preserve_directions_when_equalized() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        let innerSplit = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.3,
            first: .leaf(id: idB),
            second: .leaf(id: idC)
        ))
        let root = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.7,
            first: .leaf(id: idA),
            second: innerSplit
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        let equalized = tree.equalize()

        guard case .split(let outerData) = equalized.root else {
            XCTFail("Root should be a split")
            return
        }
        XCTAssertEqual(outerData.direction, .vertical, "Outer direction preserved")

        guard case .split(let innerData) = outerData.second else {
            XCTFail("Second child should be a split")
            return
        }
        XCTAssertEqual(innerData.direction, .horizontal, "Inner direction preserved")
    }

    // ==================== 5. Codable Roundtrip ====================

    func test_should_survive_codable_roundtrip_for_single_leaf() throws {
        let (tree, _) = makeSingleLeafTree()

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)

        XCTAssertEqual(decoded, tree, "Decoded tree should equal original")
    }

    func test_should_survive_codable_roundtrip_for_nested_split() throws {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        let innerSplit = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.4,
            first: .leaf(id: idB),
            second: .leaf(id: idC)
        ))
        let root = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.6,
            first: .leaf(id: idA),
            second: innerSplit
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)

        XCTAssertEqual(decoded, tree, "Complex tree should survive Codable roundtrip")
    }

    func test_should_survive_codable_roundtrip_for_nil_root() throws {
        let tree = SplitTree(root: nil, focusedLeafID: nil)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)

        XCTAssertEqual(decoded, tree, "Empty tree should survive Codable roundtrip")
    }

    // ==================== 6. Edge: Remove Last Leaf ====================

    func test_should_return_nil_root_when_removing_the_only_leaf() {
        let (tree, onlyID) = makeSingleLeafTree()

        let (result, focusTarget) = tree.remove(onlyID)

        XCTAssertNil(result.root, "Root should be nil after removing the only leaf")
        XCTAssertNil(focusTarget, "Focus target should be nil when no leaves remain")
    }

    func test_should_return_nil_focused_leaf_when_removing_last_leaf() {
        let (tree, onlyID) = makeSingleLeafTree()

        let (result, _) = tree.remove(onlyID)

        XCTAssertNil(result.focusedLeafID, "focusedLeafID should be nil when tree is empty")
    }

    // ==================== 7. Ratio Clamping ====================

    func test_should_clamp_ratio_to_minimum_when_below_threshold() {
        let idA = UUID()
        let idB = UUID()

        let data = SplitData(
            direction: .horizontal,
            ratio: 0.0,  // below minimum of 0.1
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        )

        XCTAssertGreaterThanOrEqual(data.ratio, 0.1,
                                     "Ratio should be clamped to at least 0.1")
    }

    func test_should_clamp_ratio_to_maximum_when_above_threshold() {
        let idA = UUID()
        let idB = UUID()

        let data = SplitData(
            direction: .horizontal,
            ratio: 1.0,  // above maximum of 0.9
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        )

        XCTAssertLessThanOrEqual(data.ratio, 0.9,
                                  "Ratio should be clamped to at most 0.9")
    }

    func test_should_accept_ratio_within_valid_range() {
        let idA = UUID()
        let idB = UUID()

        let data = SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        )

        XCTAssertEqual(data.ratio, 0.5, accuracy: 0.001,
                       "Ratio within range should be unchanged")
    }

    func test_should_clamp_ratio_at_boundary_values() {
        let idA = UUID()
        let idB = UUID()

        let dataMin = SplitData(
            direction: .horizontal,
            ratio: 0.1,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        )
        XCTAssertEqual(dataMin.ratio, 0.1, accuracy: 0.001,
                       "Ratio of exactly 0.1 should be accepted")

        let dataMax = SplitData(
            direction: .horizontal,
            ratio: 0.9,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        )
        XCTAssertEqual(dataMax.ratio, 0.9, accuracy: 0.001,
                       "Ratio of exactly 0.9 should be accepted")
    }

    // ==================== 8. Nested Splits ====================

    func test_should_insert_into_already_split_tree() {
        // Arrange — start with A | B, then split B into B | C
        let (tree, idA) = makeSingleLeafTree()
        let (tree2, idB) = tree.insert(at: idA, direction: .horizontal)

        // Act — insert at idB (which is inside a split)
        let (tree3, idC) = tree2.insert(at: idB, direction: .vertical)

        // Assert — should have 3 leaves total
        let allIDs = tree3.allLeafIDs()
        XCTAssertEqual(allIDs.count, 3, "Tree should have 3 leaves after nested insert")
        XCTAssertTrue(allIDs.contains(idA), "Original leaf A should still exist")
        XCTAssertTrue(allIDs.contains(idB), "Leaf B should still exist")
        XCTAssertTrue(allIDs.contains(idC), "New leaf C should exist")
    }

    func test_should_create_correct_nesting_structure_when_inserting_into_split() {
        let (tree, idA) = makeSingleLeafTree()
        let (tree2, idB) = tree.insert(at: idA, direction: .horizontal)
        let (tree3, idC) = tree2.insert(at: idB, direction: .vertical)

        // Root should be a horizontal split: A | (B / C)
        guard case .split(let outerData) = tree3.root else {
            XCTFail("Root should be a split")
            return
        }
        XCTAssertEqual(outerData.direction, .horizontal)

        // First child should be leaf A
        guard case .leaf(let firstID) = outerData.first else {
            XCTFail("First child should be a leaf")
            return
        }
        XCTAssertEqual(firstID, idA)

        // Second child should be a vertical split of B and C
        guard case .split(let innerData) = outerData.second else {
            XCTFail("Second child should be a nested split")
            return
        }
        XCTAssertEqual(innerData.direction, .vertical)

        guard case .leaf(let innerFirstID) = innerData.first,
              case .leaf(let innerSecondID) = innerData.second else {
            XCTFail("Inner split children should both be leaves")
            return
        }
        XCTAssertEqual(innerFirstID, idB, "Inner first child should be the original leaf B")
        XCTAssertEqual(innerSecondID, idC, "Inner second child should be the new leaf C")
    }

    func test_should_remove_leaf_from_deeply_nested_tree() {
        // Build: A | (B / C), then remove C, should collapse inner split
        let (tree, idA) = makeSingleLeafTree()
        let (tree2, idB) = tree.insert(at: idA, direction: .horizontal)
        let (tree3, idC) = tree2.insert(at: idB, direction: .vertical)

        // Act — remove C from the nested split
        let (result, focusTarget) = tree3.remove(idC)

        // Assert — inner split should collapse; tree becomes A | B
        let allIDs = result.allLeafIDs()
        XCTAssertEqual(allIDs.count, 2, "Should have 2 leaves after removing from nested split")
        XCTAssertTrue(allIDs.contains(idA))
        XCTAssertTrue(allIDs.contains(idB))
        XCTAssertFalse(allIDs.contains(idC), "Removed leaf should no longer appear")
        XCTAssertEqual(focusTarget, idB, "Focus should move to sibling B")
    }

    // ==================== 9. allLeafIDs ====================

    func test_should_return_single_id_for_single_leaf_tree() {
        let (tree, id) = makeSingleLeafTree()

        let ids = tree.allLeafIDs()

        XCTAssertEqual(ids, [id], "Single leaf tree should return one ID")
    }

    func test_should_return_all_ids_in_left_to_right_order() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        let innerSplit = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idB),
            second: .leaf(id: idC)
        ))
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: innerSplit
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        let ids = tree.allLeafIDs()

        XCTAssertEqual(ids, [idA, idB, idC],
                       "allLeafIDs should return IDs in left-to-right (depth-first) order")
    }

    func test_should_return_empty_array_when_root_is_nil() {
        let tree = SplitTree(root: nil, focusedLeafID: nil)

        let ids = tree.allLeafIDs()

        XCTAssertTrue(ids.isEmpty, "allLeafIDs should return empty array for nil root")
    }

    // ==================== findParentSplit ====================

    func test_should_find_parent_split_of_nested_leaf() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        let innerSplit = SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idB),
            second: .leaf(id: idC)
        )
        let root = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .split(innerSplit)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        let parent = tree.findParentSplit(of: idB)

        XCTAssertEqual(parent, innerSplit,
                       "Parent of idB should be the inner horizontal split")
    }

    func test_should_return_nil_parent_for_root_leaf() {
        let (tree, rootID) = makeSingleLeafTree()

        let parent = tree.findParentSplit(of: rootID)

        XCTAssertNil(parent, "Root leaf has no parent split")
    }

    // ==================== Resize ====================

    func test_should_adjust_ratio_when_resizing() {
        let (tree, idA) = makeSingleLeafTree()
        let (splitTree, _) = tree.insert(at: idA, direction: .horizontal)

        let resized = splitTree.resize(
            node: idA,
            by: 50.0,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 100.0
        )

        guard case .split(let data) = resized.root else {
            XCTFail("Root should remain a split after resize")
            return
        }

        // Ratio should have changed from the default 0.5
        XCTAssertNotEqual(data.ratio, 0.5, "Ratio should change after resize")
        XCTAssertGreaterThanOrEqual(data.ratio, 0.1, "Ratio must stay within bounds")
        XCTAssertLessThanOrEqual(data.ratio, 0.9, "Ratio must stay within bounds")
    }

    func test_should_not_resize_below_min_size() {
        let (tree, idA) = makeSingleLeafTree()
        let (splitTree, _) = tree.insert(at: idA, direction: .horizontal)

        // Try to resize by an extreme amount that would violate minSize
        let resized = splitTree.resize(
            node: idA,
            by: -10000.0,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 100.0
        )

        guard case .split(let data) = resized.root else {
            XCTFail("Root should remain a split after resize")
            return
        }

        // The ratio should be clamped so that neither pane is below minSize
        XCTAssertGreaterThanOrEqual(data.ratio, 0.1,
                                     "Ratio must be clamped to keep panes above min size")
    }

    // ==================== Set Ratio ====================
    //
    // The new `SplitTree.setRatio(node:to:direction:bounds:minSize:)` API pins
    // an *absolute* ratio (in [0, 1]) on the direction-matching split that
    // owns the given leaf. It exists alongside the existing `resize(by:)`
    // pixel-delta API (which keyboard `ghostty_resize_split` still depends on)
    // and replaces the delta-accumulation drag flow that suffered from the
    // double pixel→ratio conversion bug described in the fix plan.
    //
    // Contract:
    //   • If the target leaf is in `data.first` → newRatio = targetRatio.
    //   • If the target leaf is in `data.second` → newRatio = 1 - targetRatio
    //     (because dragging the leaf's leading edge to absolute position p in
    //     the splitting axis places the split boundary at p).
    //   • Clamp to `[minSize/totalSize, 1 - minSize/totalSize]` (geometric).
    //   • Final pass through `SplitData.clampRatio` (global [0.1, 0.9]).
    //   • For mismatched-direction parents, recurse without touching ratios.
    //   • Unknown leaf → returns `self` unchanged.
    //   • Empty tree → returns `self` unchanged (root stays nil).
    //
    // Red-phase expectation: these tests FAIL TO COMPILE because
    // `SplitTree.setRatio(...)` does not exist yet.

    func test_setRatio_should_set_horizontal_split_to_target_when_leaf_in_first() {
        // Arrange — build a 2-leaf horizontal split with idA in first, idB in second.
        let idA = UUID()
        let idB = UUID()
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act
        let result = tree.setRatio(
            node: idA,
            to: 0.7,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 50.0
        )

        // Assert
        guard case .split(let data) = result.root else {
            XCTFail("Root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(data.ratio, 0.7, accuracy: 0.0001,
                       "Setting target leaf in `first` slot must place the split ratio at the target value")
    }

    func test_setRatio_should_set_horizontal_split_to_complement_when_leaf_in_second() {
        // Arrange — same setup, but call setRatio with idB (the leaf in `second`).
        let idA = UUID()
        let idB = UUID()
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idB)

        // Act — dragging leaf B's leading (left) edge to absolute 0.7 should
        // place the split boundary at 0.7, meaning data.ratio == 1 - 0.7 = 0.3
        // is the WRONG sign convention. Re-reading the spec: when the target
        // leaf lives in `second`, the user is dragging its leading edge, which
        // is the split boundary itself. Setting absolute ratio = 0.7 means the
        // boundary lives at 0.7, and `first` occupies [0, 0.7] → ratio = 0.7.
        //
        // But the plan / spec explicitly says: "target leaf in `data.second`
        // → newRatio = 1 - targetRatio". This pins the divider-coordinate
        // semantics where `targetRatio` is the cursor's position projected as
        // a fraction of `bounds` along the splitting axis, but interpreted
        // RELATIVE to the leaf's local first→second axis. The test exists to
        // pin that contract verbatim.
        let result = tree.setRatio(
            node: idB,
            to: 0.7,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 50.0
        )

        // Assert
        guard case .split(let data) = result.root else {
            XCTFail("Root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(data.ratio, 0.3, accuracy: 0.0001,
                       "When target leaf lives in `second`, newRatio must equal 1 - targetRatio (0.3 here)")
    }

    func test_setRatio_should_clamp_to_minRatio_when_target_too_small() {
        // Arrange — minRatio = 100 / 800 = 0.125. Asking for 0.01 must clamp up.
        let idA = UUID()
        let idB = UUID()
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act
        let result = tree.setRatio(
            node: idA,
            to: 0.01,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 100.0
        )

        // Assert
        guard case .split(let data) = result.root else {
            XCTFail("Root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(data.ratio, 0.125, accuracy: 0.0001,
                       "Sub-min target ratio must clamp up to minRatio = minSize / totalSize")
    }

    func test_setRatio_should_clamp_to_one_minus_minRatio_when_target_too_large() {
        // Arrange — minRatio = 100 / 800 = 0.125. Max allowable ratio = 0.875.
        let idA = UUID()
        let idB = UUID()
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act
        let result = tree.setRatio(
            node: idA,
            to: 0.99,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 100.0
        )

        // Assert
        guard case .split(let data) = result.root else {
            XCTFail("Root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(data.ratio, 0.875, accuracy: 0.0001,
                       "Above-max target ratio must clamp down to 1 - minRatio")
    }

    func test_setRatio_should_apply_splitdata_global_clamp_to_0_9() {
        // Arrange — choose a tiny minSize so the geometric clamp window is
        // wider than [0.1, 0.9]; the binding limit is then SplitData.clampRatio.
        // minRatio = 1 / 800 = 0.00125, so the geometric window is
        // [0.00125, 0.99875]. Asking for 1.5 must end up at 0.9 (global cap).
        let idA = UUID()
        let idB = UUID()
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act
        let result = tree.setRatio(
            node: idA,
            to: 1.5,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 1.0
        )

        // Assert
        guard case .split(let data) = result.root else {
            XCTFail("Root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(data.ratio, 0.9, accuracy: 0.0001,
                       "Out-of-range high targets must end up at the SplitData global cap (0.9)")
    }

    func test_setRatio_should_apply_splitdata_global_clamp_to_0_1() {
        // Arrange — mirror of the previous test. Geometric window wider than
        // [0.1, 0.9]; asking for -1.0 must end up at 0.1 (global floor).
        let idA = UUID()
        let idB = UUID()
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act
        let result = tree.setRatio(
            node: idA,
            to: -1.0,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 1.0
        )

        // Assert
        guard case .split(let data) = result.root else {
            XCTFail("Root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(data.ratio, 0.1, accuracy: 0.0001,
                       "Out-of-range low targets must end up at the SplitData global floor (0.1)")
    }

    func test_setRatio_should_recurse_through_mismatched_direction_split() {
        // Arrange — nested tree:
        //   outer = vertical split with ratio 0.5:
        //     first = horizontal split with ratio 0.5 of (idA, idB)
        //     second = .leaf(idC)
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let innerSplit = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let root = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.5,
            first: innerSplit,
            second: .leaf(id: idC)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act — setRatio with horizontal direction targets the inner split
        // only; the outer vertical split must be untouched.
        let result = tree.setRatio(
            node: idA,
            to: 0.75,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 50.0
        )

        // Assert — outer ratio unchanged.
        guard case .split(let outerData) = result.root else {
            XCTFail("Outer root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(outerData.direction, .vertical,
                       "Outer split direction must be preserved")
        XCTAssertEqual(outerData.ratio, 0.5, accuracy: 0.0001,
                       "Mismatched-direction outer split's ratio must be untouched")

        // Assert — inner horizontal split's ratio is now 0.75.
        guard case .split(let innerData) = outerData.first else {
            XCTFail("Inner first child must remain a split after recursive setRatio")
            return
        }
        XCTAssertEqual(innerData.direction, .horizontal,
                       "Inner split direction must be preserved")
        XCTAssertEqual(innerData.ratio, 0.75, accuracy: 0.0001,
                       "Recursive setRatio must update only the direction-matching descendant split")
    }

    func test_setRatio_should_return_unchanged_tree_when_leaf_not_found() {
        // Arrange — 2-leaf horizontal split.
        let idA = UUID()
        let idB = UUID()
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA)

        // Act — pass a random UUID that does not exist in the tree.
        let unknownID = UUID()
        XCTAssertNotEqual(unknownID, idA)
        XCTAssertNotEqual(unknownID, idB)
        let result = tree.setRatio(
            node: unknownID,
            to: 0.7,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 50.0
        )

        // Assert — tree returned unchanged.
        XCTAssertEqual(result.root, tree.root,
                       "Unknown leaf IDs must leave the tree's root unchanged")
    }

    func test_setRatio_should_be_noop_when_root_is_nil() {
        // Arrange — empty tree.
        let tree = SplitTree(root: nil, focusedLeafID: nil)

        // Act
        let result = tree.setRatio(
            node: UUID(),
            to: 0.5,
            direction: .horizontal,
            bounds: CGSize(width: 800, height: 600),
            minSize: 50.0
        )

        // Assert — root stays nil.
        XCTAssertNil(result.root,
                     "setRatio on an empty tree must leave root nil")
    }

    // ==================== Set Ratio (specific-split overload) ====================
    //
    // Bug B regression coverage. The leaf-only `setRatio(node:to:...)` API
    // walks the tree top-down and updates the FIRST direction-matching
    // ancestor that contains the target leaf. For nested SAME-direction
    // splits — e.g. `V(A, V(B, C))` — this means dragging the inner B|C
    // divider would always pin the OUTER vertical ratio, leaving the inner
    // ratio untouched.
    //
    // The fix introduces a more specific overload that identifies a split
    // by BOTH of its children's leftmost leaves (which, together with the
    // direction, uniquely identify a split in the binary tree):
    //
    //     func setRatio(
    //         firstChildFirstLeafID: UUID,
    //         secondChildFirstLeafID: UUID,
    //         direction: SplitDirection,
    //         to targetRatio: Double,
    //         bounds: CGSize,
    //         minSize: CGFloat
    //     ) -> SplitTree
    //
    // The pre-existing `setRatio(node:to:direction:...)` is preserved as a
    // convenience for tests / callers that don't need the disambiguation.
    //
    // Red-phase expectation: this test FAILS TO COMPILE against the pre-fix
    // codebase because the new overload doesn't exist yet.

    /// Given: a tree V(A, V(B, C)) — outer vertical, inner vertical.
    /// When:  `setRatio` is called targeting specifically the INNER split
    ///        (firstChildFirstLeafID: B, secondChildFirstLeafID: C) with
    ///        ratio 0.7.
    /// Then:  the INNER split's ratio becomes 0.7 and the OUTER split's
    ///        ratio remains at 0.5 (unchanged).
    func test_setRatio_with_specific_split_id_pins_inner_not_outer_for_same_direction_nest() {
        // Arrange — V(A, V(B, C))
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let innerVertical = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(id: idB),
            second: .leaf(id: idC)
        ))
        let outerVertical = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: innerVertical
        ))
        let tree = SplitTree(root: outerVertical, focusedLeafID: idB)

        // Act — target the inner split specifically.
        let result = tree.setRatio(
            firstChildFirstLeafID: idB,
            secondChildFirstLeafID: idC,
            direction: .vertical,
            to: 0.7,
            bounds: CGSize(width: 800, height: 600),
            minSize: 50.0
        )

        // Assert — outer ratio unchanged.
        guard case .split(let outerData) = result.root else {
            XCTFail("Outer root must remain a split after setRatio")
            return
        }
        XCTAssertEqual(outerData.direction, .vertical,
                       "Outer split direction must be preserved")
        XCTAssertEqual(outerData.ratio, 0.5, accuracy: 0.0001,
                       "Bug B regression: outer vertical split's ratio must be untouched when targeting the inner split")

        // Assert — inner ratio becomes 0.7.
        guard case .split(let innerData) = outerData.second else {
            XCTFail("Outer split's second child must remain a vertical split")
            return
        }
        XCTAssertEqual(innerData.direction, .vertical,
                       "Inner split direction must be preserved")
        XCTAssertEqual(innerData.ratio, 0.7, accuracy: 0.0001,
                       "Bug B regression: inner vertical split's ratio must be pinned to the target value")
    }

    // ==================== Split Zoom (GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM) ====================
    //
    // `SplitTree.zoomedLeafID` + `effectiveZoomedLeafID` /
    // `togglingZoom(at:)` / `clearingZoom()` / `settingFocus(_:)` are
    // Calyx's port of upstream ghostty's `SplitTree.zoomed` +
    // `BaseTerminalController.ghosttyDidToggleSplitZoom`
    // (macos/Sources/Features/Splits/SplitTree.swift,
    // macos/Sources/Features/Terminal/BaseTerminalController.swift,
    // v1.3.1). Calyx previously had no zoom concept at all.
    //
    // GREEN PHASE: `togglingZoom(at:)`/`clearingZoom()`/`settingFocus(_:)`/
    // `effectiveZoomedLeafID` now carry their real implementations, and
    // `insert`/`remove`/`equalize`/`resize`/`setRatio`×2/`remapLeafIDs`
    // each explicitly thread `zoomedLeafID` through their own
    // `SplitTree(root:focusedLeafID:zoomedLeafID:)` call per the table in
    // `SplitTree.swift`'s own "MARK: - Zoom" section. The per-test
    // "REGRESSION GUARD" / "REAL RED FAILURE" labels below are kept as
    // historical context from the TDD red phase (they still correctly
    // describe why each test exists and what it guards against) even
    // though every test in this section now exercises real logic rather
    // than a stub.

    // MARK: Zoom Helpers

    private func makeHorizontalSplit(_ first: UUID, _ second: UUID, zoomedLeafID: UUID? = nil) -> SplitTree {
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: first),
            second: .leaf(id: second)
        ))
        return SplitTree(root: root, focusedLeafID: first, zoomedLeafID: zoomedLeafID)
    }

    // MARK: togglingZoom(at:)

    func test_should_zoom_leaf_when_toggling_zoom_on_an_unzoomed_split() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB)

        let result = tree.togglingZoom(at: idA)

        XCTAssertEqual(result.zoomedLeafID, idA,
                       "Toggling zoom on an unzoomed split tree must zoom the target leaf")
    }

    func test_should_unzoom_when_toggling_the_already_zoomed_leaf_again() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB)

        let zoomed = tree.togglingZoom(at: idA)
        XCTAssertEqual(zoomed.zoomedLeafID, idA,
                       "The first toggle must zoom idA, as a precondition for this test")

        let unzoomed = zoomed.togglingZoom(at: idA)
        XCTAssertNil(unzoomed.zoomedLeafID,
                    "Toggling the SAME already-zoomed leaf again must clear zoom")
    }

    func test_should_switch_zoom_to_new_target_when_different_leaf_toggled_while_zoomed() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let result = tree.togglingZoom(at: idB)

        XCTAssertEqual(result.zoomedLeafID, idB,
                       "Toggling a DIFFERENT leaf while zoomed must switch zoom to the new target, not clear it")
    }

    /// REGRESSION GUARD: passes today because `togglingZoom` is still the
    /// identity stub — a single-leaf tree already starts at
    /// `zoomedLeafID == nil`, so "stays nil" trivially holds regardless.
    /// Pins upstream ghostty's own `guard surfaceTree.isSplit else {
    /// return }` (BaseTerminalController.swift): the real implementation
    /// must never let an un-split tab report as zoomed.
    func test_should_not_zoom_when_tree_has_only_a_single_leaf() {
        let (tree, onlyID) = makeSingleLeafTree()
        XCTAssertFalse(tree.isSplit, "Precondition: a single-leaf tree must not be split")

        let result = tree.togglingZoom(at: onlyID)

        XCTAssertNil(result.zoomedLeafID,
                    "A single-leaf (non-split) tree must never enter a zoomed state")
    }

    /// REGRESSION GUARD: `togglingZoom`'s stub is the identity function,
    /// so "the tree comes back completely unchanged" trivially holds for
    /// ANY input today, not just an absent leaf ID specifically.
    func test_should_noop_when_toggling_zoom_at_a_leaf_id_not_in_the_tree() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)
        let unknownID = UUID()
        XCTAssertNotEqual(unknownID, idA)
        XCTAssertNotEqual(unknownID, idB)

        let result = tree.togglingZoom(at: unknownID)

        XCTAssertEqual(result, tree,
                       "Toggling zoom at a leaf ID absent from the tree must be a complete no-op")
    }

    // MARK: insert / remove / equalize clear zoom

    /// REGRESSION GUARD (see this section's header): `insert` itself is
    /// untouched by this stub pass; its existing call sites don't pass
    /// `zoomedLeafID` explicitly, so the new parameter's `nil` default
    /// already clears zoom on every insert today, which happens to be
    /// the correct final behavior too (a newly created split pane would
    /// otherwise be invisible behind a still-zoomed sibling).
    func test_should_clear_zoom_when_inserting_a_new_split() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let (result, _) = tree.insert(at: idA, direction: .vertical)

        XCTAssertNil(result.zoomedLeafID,
                    "Inserting a new split must clear zoom")
    }

    /// REGRESSION GUARD: same reasoning as the insert test above —
    /// `remove` removing the ZOOMED leaf itself already defaults to
    /// clearing zoom today.
    func test_should_clear_zoom_when_removing_the_zoomed_leaf_itself() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let (result, _) = tree.remove(idA)

        XCTAssertNil(result.zoomedLeafID,
                    "Removing the zoomed leaf itself must clear zoom")
    }

    /// REAL RED FAILURE (contrast the two REGRESSION GUARDs above):
    /// removing a leaf UNRELATED to the zoomed one, while the tree is
    /// STILL split afterward, must PRESERVE zoom. `remove`'s current,
    /// unmodified body doesn't thread `zoomedLeafID` through at all, so
    /// today this always comes back `nil` instead of `idA`.
    func test_should_preserve_zoom_when_removing_an_unrelated_leaf_from_a_three_leaf_tree() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let innerSplit = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.5,
            first: .leaf(id: idB),
            second: .leaf(id: idC)
        ))
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: innerSplit
        ))
        let tree = SplitTree(root: root, focusedLeafID: idA, zoomedLeafID: idA)

        let (result, _) = tree.remove(idC)

        XCTAssertEqual(result.zoomedLeafID, idA,
                       "Removing a leaf unrelated to the zoomed one, when the tree is still split " +
                       "afterward, must preserve zoom")
    }

    /// REGRESSION GUARD: unlike the "unrelated leaf, still split" case
    /// directly above (a real red failure today), removing the zoomed
    /// leaf's ONLY sibling collapses the tree to a single leaf — Calyx's
    /// own extra invariant, beyond upstream ghostty's `zoomed == target ?
    /// nil : zoomed` (which only clears zoom when the REMOVED node IS the
    /// zoomed one): a tree that is no longer split must never carry a
    /// truthy zoom, so `effectiveZoomedLeafID`'s `isSplit` guard is never
    /// the ONLY thing standing between a stale `zoomedLeafID` and a
    /// wrongly-zoomed single pane. Passes today because `remove`'s
    /// current body already defaults to `nil` regardless of the reason.
    func test_should_clear_zoom_when_removal_collapses_the_tree_to_a_single_leaf() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let (result, _) = tree.remove(idB)

        XCTAssertFalse(result.isSplit,
                       "Precondition: removing B from a 2-leaf tree must collapse it to a single leaf")
        XCTAssertNil(result.zoomedLeafID,
                    "Zoom must be cleared once the tree is no longer split, even though the " +
                    "REMOVED leaf (B) was never the zoomed one (A)")
    }

    /// CORRECTED SPEC (post-review): the original design table had this
    /// backwards. Upstream ghostty's own `SplitTree.equalized()`
    /// (macos/Sources/Features/Splits/SplitTree.swift:236-240) is
    /// `.init(root: newRoot, zoomed: zoomed)` — the ONE mutating
    /// transform there that PRESERVES `zoomed`, unlike every other one
    /// (insert/remove/etc.), which all reset it to nil. `equalize()`
    /// only touches split ratios; which pane is temporarily zoomed to
    /// fill the tab is an orthogonal, unrelated axis of state — exactly
    /// like `resize`/`setRatio` (both already preserve zoom), not like
    /// `insert` (which clears it because a new pane would otherwise be
    /// invisible behind a still-zoomed sibling). Calyx follows upstream
    /// here rather than deviating from it.
    func test_should_preserve_zoom_when_equalizing_splits() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let result = tree.equalize()

        XCTAssertEqual(result.zoomedLeafID, idA,
                       "Equalizing splits must preserve zoom — ratio changes are orthogonal to zoom state, " +
                       "matching upstream ghostty's own SplitTree.equalized() and this type's resize/setRatio")
    }

    // MARK: resize / setRatio preserve zoom (REAL RED FAILUREs)

    func test_should_preserve_zoom_when_resizing_a_split() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let result = tree.resize(
            node: idA, by: 50.0, direction: .horizontal,
            bounds: CGSize(width: 800, height: 600), minSize: 50.0
        )

        XCTAssertEqual(result.zoomedLeafID, idA,
                       "Resizing a split (a pure ratio/geometry change) must not disturb zoom")
    }

    func test_should_preserve_zoom_when_setting_ratio_by_leaf() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let result = tree.setRatio(
            node: idA, to: 0.7, direction: .horizontal,
            bounds: CGSize(width: 800, height: 600), minSize: 50.0
        )

        XCTAssertEqual(result.zoomedLeafID, idA,
                       "setRatio(node:to:direction:bounds:minSize:) must not disturb zoom")
    }

    func test_should_preserve_zoom_when_setting_ratio_for_a_specific_split() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let result = tree.setRatio(
            firstChildFirstLeafID: idA,
            secondChildFirstLeafID: idB,
            direction: .horizontal,
            to: 0.7,
            bounds: CGSize(width: 800, height: 600),
            minSize: 50.0
        )

        XCTAssertEqual(result.zoomedLeafID, idA,
                       "setRatio(firstChildFirstLeafID:secondChildFirstLeafID:direction:to:bounds:minSize:) must not disturb zoom")
    }

    // MARK: remapLeafIDs re-keys zoom (REAL RED FAILURE)

    func test_should_remap_zoomedLeafID_when_its_leaf_is_remapped() {
        let idA = UUID()
        let idB = UUID()
        let newA = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let result = tree.remapLeafIDs([idA: newA])

        XCTAssertEqual(result.zoomedLeafID, newA,
                       "remapLeafIDs must re-key zoomedLeafID exactly like it already re-keys " +
                       "focusedLeafID, so a session restore's remap doesn't silently orphan a persisted zoom")
    }

    // MARK: settingFocus(_:) clears zoom (REAL RED FAILURE)

    func test_should_clear_zoom_when_focus_moves_to_a_different_leaf() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let result = tree.settingFocus(idB)

        XCTAssertEqual(result.focusedLeafID, idB,
                       "settingFocus must move focus to the requested leaf")
        XCTAssertNil(result.zoomedLeafID,
                    "settingFocus must clear zoom — Calyx doesn't implement ghostty's " +
                    "split-preserve-zoom config, whose default (navigation: false) means " +
                    "goto_split always clears zoom")
    }

    // MARK: effectiveZoomedLeafID

    /// REAL RED FAILURE: `effectiveZoomedLeafID` is still the `{ nil }`
    /// stub, so a legitimately zoomed, currently-split tree's own zoom is
    /// not yet reported.
    func test_effectiveZoomedLeafID_should_return_zoomedLeafID_when_it_names_a_real_leaf_of_a_split_tree() {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        XCTAssertEqual(tree.effectiveZoomedLeafID, idA,
                       "A zoomedLeafID naming a real leaf of a currently-split tree must be reported as the effective zoom")
    }

    /// REGRESSION GUARD: `effectiveZoomedLeafID` unconditionally returns
    /// `nil` today, so a stale/absent leaf ID trivially reports `nil`
    /// regardless of whether the double-guard is actually implemented.
    func test_effectiveZoomedLeafID_should_return_nil_when_zoomedLeafID_is_not_a_leaf_of_the_tree() {
        let idA = UUID()
        let idB = UUID()
        let staleID = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: staleID)

        XCTAssertNil(tree.effectiveZoomedLeafID,
                    "A zoomedLeafID naming a leaf that no longer exists in the tree (e.g. a stale " +
                    "value surviving a bug elsewhere) must never be reported as the effective zoom")
    }

    /// REGRESSION GUARD: same reasoning — the unconditional `{ nil }`
    /// stub already satisfies this.
    func test_effectiveZoomedLeafID_should_return_nil_when_tree_is_not_split_even_if_zoomedLeafID_is_set() {
        let onlyID = UUID()
        let tree = SplitTree(root: .leaf(id: onlyID), focusedLeafID: onlyID, zoomedLeafID: onlyID)
        XCTAssertFalse(tree.isSplit, "Precondition: a single-leaf tree must not be split")

        XCTAssertNil(tree.effectiveZoomedLeafID,
                    "A non-split tree must never report an effective zoom, even if zoomedLeafID " +
                    "somehow carries a value (e.g. restored from a JSON snapshot written by a buggy build)")
    }

    // MARK: Codable

    /// Mechanical: `zoomedLeafID` is a plain stored `UUID?` with fully
    /// synthesized Codable, so this already passes today — there is no
    /// "logic" for a stub to fake here. Still a real regression guard: it
    /// would catch a future change that gives `SplitTree` a hand-written
    /// `Codable` conformance which forgets this field.
    func test_should_preserve_zoomedLeafID_through_codable_roundtrip() throws {
        let idA = UUID()
        let idB = UUID()
        let tree = makeHorizontalSplit(idA, idB, zoomedLeafID: idA)

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)

        XCTAssertEqual(decoded.zoomedLeafID, idA,
                       "zoomedLeafID must survive an encode-decode roundtrip like every other SplitTree field")
        XCTAssertEqual(decoded, tree, "The full tree must be equal after a roundtrip")
    }

    /// Backward compatibility: a `SplitTree` JSON blob with no
    /// `zoomedLeafID` key at all (every blob written before this feature
    /// existed) must decode with `zoomedLeafID == nil`, not throw.
    /// Mechanical (see the roundtrip test's own note) — passes today
    /// because `zoomedLeafID` is a plain Optional stored property, and
    /// synthesized `Decodable` already uses `decodeIfPresent` for
    /// Optional properties. The `{"leaf": {"id": ...}}` shape for `root`
    /// is confirmed against `SessionSnapshotV6Tests.v5JSONFixture`'s own
    /// embedded `splitTree` object, not guessed.
    func test_should_decode_zoomedLeafID_as_nil_when_json_key_is_absent() throws {
        let leafID = UUID()
        let legacyJSON = """
        {
            "focusedLeafID": "\(leafID.uuidString)",
            "root": {"leaf": {"id": "\(leafID.uuidString)"}}
        }
        """
        let data = Data(legacyJSON.utf8)

        let decoded = try JSONDecoder().decode(SplitTree.self, from: data)

        XCTAssertEqual(decoded.allLeafIDs(), [leafID],
                       "Precondition: the legacy tree's own leaf must still decode correctly")
        XCTAssertNil(decoded.zoomedLeafID,
                    "A SplitTree JSON blob with no zoomedLeafID key at all must decode with zoomedLeafID == nil")
    }
}
