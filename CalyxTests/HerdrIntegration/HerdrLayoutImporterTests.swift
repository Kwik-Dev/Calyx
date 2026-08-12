//
//  HerdrLayoutImporterTests.swift
//  CalyxTests
//
//  TDD Red Phase for HerdrLayoutImporter: a pure function converting an
//  already-decoded `layout.export` result (HerdrLayoutExportResult, the
//  schema-derived wire shape below) into Calyx's own BSP tree
//  (SplitTree.swift's SplitNode/SplitData), plus a flat list of
//  HerdrPaneDescriptor correlating each leaf's freshly assigned UUID
//  back to the herdr pane id it represents. HerdrLayoutImporter does
//  NOT talk to the socket itself -- that is HerdrConnection.swift's job;
//  every fixture below is fed directly to JSONDecoder, exactly the
//  value shape a caller would already hold after decoding a real
//  `layout.export` response's own "result" key.
//
//  SCHEMA SHAPE (herdr `api schema --json`, protocol 19, schema_version
//  1, matching a live herdr 0.8.0 server; success_response.$defs):
//    ResponseResult (type: "layout_export") -> "layout": LayoutDescription
//    LayoutDescription: workspace_id, tab_id, zoomed, focused_pane_id,
//      root ALL REQUIRED (no optional fields at this level at all).
//    LayoutNode (oneOf, discriminated on "type"):
//      "pane": ONLY "type" required. cwd/command/env/label/pane_id are
//        ALL optional -- pane_id is `["string","null"]`. A REAL
//        layout.export always sends pane_id (confirmed live below), but
//        the schema itself permits omitting it (see the minimal-payload
//        test below, which pins exactly this).
//      "split": type, direction, ratio, first, second ALL required --
//        so "a split with fewer than 2 children" is NOT expressible
//        against a schema-conforming payload; the "unknown node type
//        string" form is used instead, and a truly missing
//        "first"/"second" would be a JSONDecoder throw at decode time,
//        not something HerdrLayoutImporter.convert(_:) ever sees.
//    SplitDirection: enum ["right", "down"] -- NOT "horizontal"/
//      "vertical". Live sample confirming the "pane" branch's shape
//      (read-only `layout.export` against wB, a real single-pane
//      workspace, ~/.config/herdr/herdr.sock):
//        {"id":"1","result":{"type":"layout_export","layout":
//          {"workspace_id":"wB","tab_id":"wB:t1","zoomed":false,
//           "focused_pane_id":"wB:p1",
//           "root":{"type":"pane","pane_id":"wB:p1","cwd":"..."}}}}
//      No live split sample was captured -- creating one would mutate a
//      real running session's layout (`pane.split` is a write). The
//      right/down -> horizontal/vertical mapping below is instead
//      derived from the schema's own naming alone, corroborated two
//      ways:
//        1. SplitTree.swift's own spatialFocusTarget/buildSpatialSlots
//           logic makes first->second movement literally "right" for a
//           `.horizontal` split (first occupies the smaller-x share of
//           bounds.width) and literally "down" for a `.vertical` split
//           (first occupies the smaller-y share of bounds.height) --
//           word-for-word herdr's own two enum values.
//        2. herdr's request-side PaneDirection enum (pane.neighbor /
//           pane.focus_direction) is ["left","right","up","down"], the
//           same spatial vocabulary family, reinforcing that "right"/
//           "down" name actual spatial directions on this wire, not two
//           arbitrary opaque labels.
//
//  FIXTURE FIELD SELECTION: every fixture below carries the full set of
//  LayoutDescription's five REQUIRED fields (nothing to omit there --
//  all five are required), and for every "pane" node, pane_id (needed
//  to assert which descriptor correlates to which leaf -- the whole
//  reason this importer exists) but never cwd/command/env/label
//  (schema-legal but irrelevant to tree reconstruction, and never read
//  by convert(_:)).
//
//  UUIDs ARE NEVER HARDCODED: HerdrLayoutImporter assigns a FRESH leaf
//  UUID per pane (mirroring SplitTree.insert(at:direction:newID:)'s own
//  `newID: UUID = UUID()` convention) -- every assertion below reads the
//  UUID actually assigned out of the returned tuple/descriptors and
//  checks structural placement, distinctness, and count, never a
//  literal UUID string.
//

import XCTest
@testable import Calyx

final class HerdrLayoutImporterTests: XCTestCase {

    // MARK: - Fixture builders

    private func paneNodeJSON(paneID: String?) -> String {
        if let paneID {
            return "{\"type\":\"pane\",\"pane_id\":\"\(paneID)\"}"
        }
        return "{\"type\":\"pane\"}"
    }

    private func splitNodeJSON(direction: String, ratio: Double, first: String, second: String) -> String {
        "{\"type\":\"split\",\"direction\":\"\(direction)\",\"ratio\":\(ratio),\"first\":\(first),\"second\":\(second)}"
    }

    private func layoutExportResultJSON(
        workspaceID: String, tabID: String, zoomed: Bool, focusedPaneID: String, root: String
    ) -> String {
        "{\"workspace_id\":\"\(workspaceID)\",\"tab_id\":\"\(tabID)\",\"zoomed\":\(zoomed),\"focused_pane_id\":\"\(focusedPaneID)\",\"root\":\(root)}"
    }

    private func decode(_ json: String) throws -> HerdrLayoutExportResult {
        try JSONDecoder().decode(HerdrLayoutExportResult.self, from: Data(json.utf8))
    }

    // MARK: - Single-pane layout

    func test_convert_singlePaneLayout_producesLeafRootAndOneDescriptor() throws {
        let decoded = try decode(layoutExportResultJSON(
            workspaceID: "wB", tabID: "wB:t1", zoomed: false, focusedPaneID: "wB:p1",
            root: paneNodeJSON(paneID: "wB:p1")
        ))

        guard let (root, panes) = HerdrLayoutImporter.convert(decoded) else {
            XCTFail("expected a successful conversion for a single-pane layout")
            return
        }

        guard case .leaf(let leafID) = root else {
            XCTFail("expected root to be a .leaf node for a single-pane layout, got \(root)")
            return
        }
        XCTAssertEqual(panes, [HerdrPaneDescriptor(paneID: "wB:p1", leafID: leafID)])
    }

    // MARK: - One horizontal split, ratio 0.5

    func test_convert_oneHorizontalSplit_ratioOneHalf_producesCorrectSplitDataAndDescriptors() throws {
        let decoded = try decode(layoutExportResultJSON(
            workspaceID: "wB", tabID: "wB:t1", zoomed: false, focusedPaneID: "wB:p1",
            root: splitNodeJSON(
                direction: "right", ratio: 0.5,
                first: paneNodeJSON(paneID: "wB:p1"), second: paneNodeJSON(paneID: "wB:p2")
            )
        ))

        guard let (root, panes) = HerdrLayoutImporter.convert(decoded) else {
            XCTFail("expected a successful conversion for a well-formed single-level split")
            return
        }

        guard case .split(let data) = root else {
            XCTFail("expected root to be a .split node, got \(root)")
            return
        }
        XCTAssertEqual(data.direction, .horizontal, "herdr's \"right\" split direction must map to Calyx's .horizontal (side-by-side) direction")
        XCTAssertEqual(data.ratio, 0.5, accuracy: 0.0001)

        XCTAssertEqual(panes.count, 2)
        guard let firstLeafID = data.first.leafID, let secondLeafID = data.second.leafID else {
            XCTFail("expected both children to be leaves")
            return
        }
        XCTAssertNotEqual(firstLeafID, secondLeafID, "the two panes must be assigned distinct leaf UUIDs")

        // Positional correlation, not just "two distinct UUIDs exist":
        // this catches an implementation that swaps which descriptor
        // maps to which side of the split.
        guard let firstDescriptor = panes.first(where: { $0.paneID == "wB:p1" }) else {
            XCTFail("expected a descriptor for wB:p1")
            return
        }
        guard let secondDescriptor = panes.first(where: { $0.paneID == "wB:p2" }) else {
            XCTFail("expected a descriptor for wB:p2")
            return
        }
        XCTAssertEqual(firstDescriptor.leafID, firstLeafID, "wB:p1 (the split's FIRST child in the wire data) must correlate to root.first's own leaf id, not root.second's")
        XCTAssertEqual(secondDescriptor.leafID, secondLeafID, "wB:p2 (the split's SECOND child) must correlate to root.second's own leaf id, not root.first's")
    }

    // MARK: - Nested split (depth 2)

    func test_convert_nestedSplit_depthTwo_preservesStructureAndBothDirections() throws {
        let decoded = try decode(layoutExportResultJSON(
            workspaceID: "wB", tabID: "wB:t1", zoomed: false, focusedPaneID: "wB:p1",
            root: splitNodeJSON(
                direction: "right", ratio: 0.5,
                first: paneNodeJSON(paneID: "wB:p1"),
                second: splitNodeJSON(
                    direction: "down", ratio: 0.3,
                    first: paneNodeJSON(paneID: "wB:p2"), second: paneNodeJSON(paneID: "wB:p3")
                )
            )
        ))

        guard let (root, panes) = HerdrLayoutImporter.convert(decoded) else {
            XCTFail("expected a successful conversion for a well-formed depth-2 nested split")
            return
        }

        guard case .split(let outer) = root else {
            XCTFail("expected root to be a .split node")
            return
        }
        XCTAssertEqual(outer.direction, .horizontal, "outer split: herdr \"right\" -> Calyx .horizontal")
        XCTAssertEqual(outer.ratio, 0.5, accuracy: 0.0001)

        guard let p1LeafID = outer.first.leafID else {
            XCTFail("expected outer.first to be a leaf (wB:p1)")
            return
        }
        guard case .split(let inner) = outer.second else {
            XCTFail("expected outer.second to be a nested .split node, got \(outer.second)")
            return
        }
        XCTAssertEqual(inner.direction, .vertical, "inner split: herdr \"down\" -> Calyx .vertical")
        XCTAssertEqual(inner.ratio, 0.3, accuracy: 0.0001)

        guard let p2LeafID = inner.first.leafID, let p3LeafID = inner.second.leafID else {
            XCTFail("expected both inner children to be leaves")
            return
        }

        XCTAssertEqual(Set([p1LeafID, p2LeafID, p3LeafID]).count, 3, "all three panes must be assigned distinct leaf UUIDs")

        XCTAssertEqual(panes.count, 3)
        XCTAssertEqual(panes.first(where: { $0.paneID == "wB:p1" })?.leafID, p1LeafID)
        XCTAssertEqual(panes.first(where: { $0.paneID == "wB:p2" })?.leafID, p2LeafID)
        XCTAssertEqual(panes.first(where: { $0.paneID == "wB:p3" })?.leafID, p3LeafID)
    }

    // MARK: - Ratio clamping (both bounds of SplitData.clampRatio's [0.1, 0.9])

    func test_convert_ratioAboveZeroPointNine_isClampedToZeroPointNine_andWireValueUnmodified() throws {
        let decoded = try decode(layoutExportResultJSON(
            workspaceID: "wB", tabID: "wB:t1", zoomed: false, focusedPaneID: "wB:p1",
            root: splitNodeJSON(
                direction: "right", ratio: 0.97,
                first: paneNodeJSON(paneID: "wB:p1"), second: paneNodeJSON(paneID: "wB:p2")
            )
        ))

        guard let (root, _) = HerdrLayoutImporter.convert(decoded) else {
            XCTFail("expected a successful conversion")
            return
        }
        guard case .split(let splitData) = root else {
            XCTFail("expected root to be a .split node")
            return
        }
        XCTAssertEqual(splitData.ratio, 0.9, accuracy: 0.0001, "SplitData.clampRatio(0.97) == 0.9 -- the imported tree must carry Calyx's own clamped ratio, not herdr's raw 0.97")

        // Non-mutation: the DECODED WIRE value's own root must still show
        // herdr's raw, un-clamped 0.97 after conversion.
        guard case .split(let wireSplit) = decoded.root else {
            XCTFail("expected the decoded wire value's own root to still be a .split node")
            return
        }
        XCTAssertEqual(wireSplit.ratio, 0.97, accuracy: 0.0001, "convert(_:) must not mutate its input -- the wire value's own raw ratio must still read herdr's un-clamped 0.97 after conversion")
    }

    func test_convert_ratioBelowZeroPointOne_isClampedToZeroPointOne_andWireValueUnmodified() throws {
        let decoded = try decode(layoutExportResultJSON(
            workspaceID: "wB", tabID: "wB:t1", zoomed: false, focusedPaneID: "wB:p1",
            root: splitNodeJSON(
                direction: "down", ratio: 0.03,
                first: paneNodeJSON(paneID: "wB:p1"), second: paneNodeJSON(paneID: "wB:p2")
            )
        ))

        guard let (root, _) = HerdrLayoutImporter.convert(decoded) else {
            XCTFail("expected a successful conversion")
            return
        }
        guard case .split(let splitData) = root else {
            XCTFail("expected root to be a .split node")
            return
        }
        XCTAssertEqual(splitData.ratio, 0.1, accuracy: 0.0001, "SplitData.clampRatio(0.03) == 0.1 -- the imported tree must carry Calyx's own clamped ratio, not herdr's raw 0.03")

        guard case .split(let wireSplit) = decoded.root else {
            XCTFail("expected the decoded wire value's own root to still be a .split node")
            return
        }
        XCTAssertEqual(wireSplit.ratio, 0.03, accuracy: 0.0001, "convert(_:) must not mutate its input -- the wire value's own raw ratio must still read herdr's un-clamped 0.03 after conversion")
    }

    // MARK: - Malformed node: unrecognized "type" string

    func test_decode_unrecognizedNodeType_toleratesAndConvertReturnsNil() throws {
        let decoded = try decode(layoutExportResultJSON(
            workspaceID: "wB", tabID: "wB:t1", zoomed: false, focusedPaneID: "wB:p1",
            root: splitNodeJSON(
                direction: "right", ratio: 0.5,
                first: paneNodeJSON(paneID: "wB:p1"), second: "{\"type\":\"carousel\"}"
            )
        ))

        // Tolerant decode: an unrecognized "type" string nested inside an
        // otherwise well-formed split must not fail JSON decoding of the
        // line it lives inside -- mirrors HerdrEvent.swift's own
        // `.unknown(eventType:)` precedent (see this file's header).
        guard case .split(let splitData) = decoded.root else {
            XCTFail("expected decode to succeed with root still a .split node")
            return
        }
        guard case .unrecognized(let type) = splitData.second else {
            XCTFail("expected the second child to tolerantly decode as .unrecognized, got \(splitData.second)")
            return
        }
        XCTAssertEqual(type, "carousel")

        XCTAssertNil(
            HerdrLayoutImporter.convert(decoded),
            "an unrecognized node anywhere in the tree must fail the WHOLE import -- never trap, never silently drop the bad node"
        )
    }

    // MARK: - Minimal payload: a pane node with no pane_id at all

    func test_decode_paneNodeWithoutPaneID_decodesToNilPaneID_andConvertReturnsNil() throws {
        // Minimal, schema-required-fields-only payload: pane_id is the
        // LayoutNode "pane" branch's only OPTIONAL field of interest
        // here (schema: only "type" is required). A real herdr
        // layout.export always sends pane_id (confirmed live, see this
        // file's header), but the schema permits omitting it, so this
        // pins that a schema-legal, minimal "pane" node still decodes
        // without throwing.
        let decoded = try decode(layoutExportResultJSON(
            workspaceID: "wB", tabID: "wB:t1", zoomed: false, focusedPaneID: "wB:p1",
            root: "{\"type\":\"pane\"}"
        ))

        guard case .pane(let paneID) = decoded.root else {
            XCTFail("expected root to decode as .pane, got \(decoded.root)")
            return
        }
        XCTAssertNil(paneID, "a pane node's own pane_id is schema-OPTIONAL -- an absent key must decode to nil, never an empty string or a substituted placeholder")

        XCTAssertNil(
            HerdrLayoutImporter.convert(decoded),
            "a pane leaf with no pane_id cannot produce a HerdrPaneDescriptor (which must carry a real paneID) -- the whole import must fail rather than silently drop or fabricate a leaf"
        )
    }
}
