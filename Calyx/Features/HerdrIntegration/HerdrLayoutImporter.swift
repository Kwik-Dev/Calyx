// HerdrLayoutImporter.swift
// Calyx
//
// Pure function converting an already-decoded `layout.export` result
// (HerdrLayoutExportResult) into Calyx's own BSP tree (SplitTree.swift's
// SplitNode/SplitData), plus a flat list of HerdrPaneDescriptor
// correlating each leaf's freshly assigned UUID back to the herdr pane
// id it represents. Does NOT talk to the socket -- HerdrConnection.swift
// owns that; every input here is already-decoded JSON.
//
// SCHEMA (herdr `api schema --json`, protocol 19, schema_version 1):
//   LayoutDescription: workspace_id, tab_id, zoomed, focused_pane_id,
//     root ALL REQUIRED.
//   LayoutNode (oneOf, discriminated on "type"):
//     "pane": only "type" required; pane_id is optional AND nullable.
//     "split": type, direction, ratio, first, second ALL required.
//   SplitDirection: enum ["right", "down"] -- not "horizontal"/
//     "vertical".
//
// DIRECTION MAPPING: "right" maps to SplitTree's .horizontal with
// `first` as the left/first child; "down" maps to .vertical with
// `first` as the top/first child. MEASURED live via `pane.edges`
// (first pane touches the LEFT wall for "right"; nested exports
// preserve structure), not re-derived here -- corroborated by
// SplitTree.swift's own spatialFocusTarget/buildSpatialSlots logic
// (first occupies the smaller-x share of bounds for .horizontal, the
// smaller-y share for .vertical) and by herdr's own PaneDirection enum
// using the same "right"/"down" vocabulary for pane.neighbor/
// pane.focus_direction.
//
// RATIO: the wire ratio is passed straight into SplitData's own
// initializer, which clamps to [0.1, 0.9] itself (SplitTree.swift) --
// convert(_:) never clamps separately and never mutates its input.
//
// TOLERANT DECODE, STRICT CONVERT: an unrecognized "type" string decodes
// to `.unrecognized(type:)` rather than throwing (mirrors
// HerdrEvent.unknown(eventType:)), but convert(_:) then fails the WHOLE
// tree (nil) if any node anywhere is `.unrecognized`, or any pane has a
// nil paneID -- all-or-nothing, never a partially-imported tree.
//
// Every leaf gets a FRESH `UUID()` (mirrors
// SplitTree.insert(at:direction:newID:)'s own `newID: UUID = UUID()`
// convention) -- never derived from wire data.

import Foundation

// MARK: - Wire shapes

enum HerdrLayoutSplitDirection: String, Sendable, Equatable, Decodable {
    case right
    case down
}

struct HerdrLayoutSplitNode: Sendable, Equatable, Decodable {
    let direction: HerdrLayoutSplitDirection
    let ratio: Double
    let first: HerdrLayoutNode
    let second: HerdrLayoutNode
}

indirect enum HerdrLayoutNode: Sendable, Equatable {
    case pane(paneID: String?)
    case split(HerdrLayoutSplitNode)
    /// Tolerant landing spot for any "type" string this file does not
    /// recognize -- mirrors HerdrEvent.unknown(eventType:). Decoding
    /// never throws for this; convert(_:) is what turns it into a hard
    /// failure for the whole tree.
    case unrecognized(type: String)
}

extension HerdrLayoutNode: Decodable {
    private enum TypeCodingKeys: String, CodingKey {
        case type
    }

    private enum PaneCodingKeys: String, CodingKey {
        case paneID = "pane_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TypeCodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            let paneContainer = try decoder.container(keyedBy: PaneCodingKeys.self)
            let paneID = try paneContainer.decodeIfPresent(String.self, forKey: .paneID)
            self = .pane(paneID: paneID)
        case "split":
            self = .split(try HerdrLayoutSplitNode(from: decoder))
        default:
            self = .unrecognized(type: type)
        }
    }
}

struct HerdrLayoutExportResult: Sendable, Equatable, Decodable {
    let workspaceID: String
    let tabID: String
    let zoomed: Bool
    let focusedPaneID: String
    let root: HerdrLayoutNode

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case zoomed
        case focusedPaneID = "focused_pane_id"
        case root
    }
}

// MARK: - Import result

/// One pane correlated to the leaf UUID HerdrLayoutImporter.convert(_:)
/// freshly assigned it.
struct HerdrPaneDescriptor: Sendable, Equatable {
    let paneID: String
    let leafID: UUID
}

// MARK: - HerdrLayoutImporter

enum HerdrLayoutImporter {
    /// Converts a decoded `layout.export` result into a Calyx SplitNode
    /// tree plus its flat pane descriptor list. `nil` if any node in the
    /// tree is `.unrecognized`, or any pane leaf has no paneID -- see
    /// this file's header.
    static func convert(_ result: HerdrLayoutExportResult) -> (root: SplitNode, panes: [HerdrPaneDescriptor])? {
        var panes: [HerdrPaneDescriptor] = []
        guard let root = convertNode(result.root, panes: &panes) else { return nil }
        return (root, panes)
    }

    private static func convertNode(_ node: HerdrLayoutNode, panes: inout [HerdrPaneDescriptor]) -> SplitNode? {
        switch node {
        case .pane(let paneID):
            guard let paneID else { return nil }
            let leafID = UUID()
            panes.append(HerdrPaneDescriptor(paneID: paneID, leafID: leafID))
            return .leaf(id: leafID)

        case .split(let splitNode):
            guard let first = convertNode(splitNode.first, panes: &panes) else { return nil }
            guard let second = convertNode(splitNode.second, panes: &panes) else { return nil }
            let direction: SplitDirection
            switch splitNode.direction {
            case .right: direction = .horizontal
            case .down: direction = .vertical
            }
            return .split(SplitData(direction: direction, ratio: splitNode.ratio, first: first, second: second))

        case .unrecognized:
            return nil
        }
    }
}
