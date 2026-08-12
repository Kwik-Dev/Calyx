//
//  TabSnapshotHerdrRefsTests.swift
//  CalyxTests
//
//  TDD Red Phase for herdr-pane-bridge persistence layer:
//  Tab.herdrPaneRefs ([UUID: HerdrPaneRef], leaf-UUID keyed, mirrors
//  Tab.sessionRefs exactly) and TabSnapshot.herdrPaneRefs (an OPTIONAL
//  field, mirroring TabSnapshot.sessionRefs's own "nil for a snapshot
//  with none, synthesized Codable decodeIfPresent/encodeIfPresent
//  handles absent-key backward compatibility for free" shape --
//  SessionSnapshot.swift's sessionRefs declaration and Tab.snapshot()'s
//  "let refs = sessionRefs.isEmpty ? nil : sessionRefs" line).
//
//  Also covers Tab.pruneHerdrPaneRefs(keeping:) -- the herdr-bridge
//  counterpart of Tab.pruneSessionRefs(), parameterized with an
//  explicit kept-leaf-ID set rather than deriving it from splitTree
//  internally.
//
//  Coverage:
//  - TabSnapshot(herdrPaneRefs:) round-trips through encode/decode
//    (mirrors SessionSnapshotV6Tests's own sessionRefs round-trip test,
//    pinning the new init parameter itself)
//  - A minimal pre-Stage-3 TabSnapshot JSON (only the fields TabSnapshot
//    currently requires: id, title, splitTree -- no herdrPaneRefs key at
//    all) decodes with herdrPaneRefs == nil, and Tab(snapshot:) restores
//    an empty herdrPaneRefs dict from it
//  - A TabSnapshot produced from a Tab with an EMPTY herdrPaneRefs dict
//    writes NO "herdrPaneRefs" key at all (nil-when-empty, matching
//    sessionRefs's own Tab.snapshot() isEmpty ? nil : self pattern) --
//    asserted directly on the encoded JSON object's keys
//  - A Tab with two herdrPaneRefs (distinct leaf UUIDs, distinct pane
//    ids) round-trips through snapshot() -> encode -> decode ->
//    Tab(snapshot:) identically
//  - SessionSnapshot.migrate(_:) passes a pre-herdrPaneRefs v6 snapshot
//    through with herdrPaneRefs nil/absent, never crashing (mirrors
//    SessionSnapshotV6Tests's own v6JSONFixtureWithoutZoomedLeafID
//    precedent -- an optional field added within schema v6 needs no
//    version bump)
//  - Tab.pruneHerdrPaneRefs(keeping:) drops entries for leaves not in
//    the kept set, keeps the rest
//

import XCTest
@testable import Calyx

@MainActor
final class TabSnapshotHerdrRefsTests: XCTestCase {

    // MARK: - TabSnapshot(herdrPaneRefs:) round trip

    func test_tabSnapshot_withHerdrPaneRefs_roundTripsThroughEncodeDecode() throws {
        let leafID = UUID()
        let herdrPaneRefs: [UUID: HerdrPaneRef] = [
            leafID: HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1"),
        ]
        let original = TabSnapshot(
            id: UUID(),
            title: "Terminal",
            splitTree: SplitTree(leafID: leafID),
            herdrPaneRefs: herdrPaneRefs
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        XCTAssertEqual(decoded, original, "A TabSnapshot with herdrPaneRefs must round-trip identically")
        XCTAssertEqual(decoded.herdrPaneRefs, herdrPaneRefs)
    }

    // MARK: - Pre-Stage-3 backward compatibility

    /// Minimal standalone TabSnapshot JSON: only the fields TabSnapshot
    /// currently requires (id, title, splitTree -- every other field,
    /// including titleOverride/pwd/browserURL/sessionRefs, is Optional
    /// and therefore omittable). The nested splitTree shape
    /// ("focusedLeafID" + "root": {"leaf": {"id": ...}}) is copied
    /// byte-for-byte from SessionSnapshotV6Tests.swift's own proven
    /// v5JSONFixture, not hand-guessed -- that shape is already the
    /// wire-verified output of this exact codebase's SplitNode/SplitTree
    /// Codable synthesis.
    private var minimalLegacyTabSnapshotJSON: String {
        """
        {
            "id": "00000000-0000-0000-0000-000000000020",
            "title": "Terminal",
            "splitTree": {
                "focusedLeafID": "00000000-0000-0000-0000-000000000030",
                "root": {"leaf": {"id": "00000000-0000-0000-0000-000000000030"}}
            }
        }
        """
    }

    func test_minimalLegacyJSON_decodesWithHerdrPaneRefsNil_andRestoresTabWithEmptyRefs() throws {
        let data = Data(minimalLegacyTabSnapshotJSON.utf8)

        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        XCTAssertEqual(decoded.id, UUID(uuidString: "00000000-0000-0000-0000-000000000020"))
        XCTAssertEqual(decoded.title, "Terminal")
        XCTAssertNil(decoded.herdrPaneRefs,
                     "A pre-Stage-3 TabSnapshot with no herdrPaneRefs key anywhere must decode to nil, " +
                     "not throw or default to [:]")

        let tab = Tab(snapshot: decoded)
        XCTAssertTrue(tab.herdrPaneRefs.isEmpty,
                      "Tab(snapshot:) must restore an empty herdrPaneRefs dict from a nil TabSnapshot.herdrPaneRefs")
    }

    // MARK: - Nil-when-empty write

    func test_tabSnapshot_fromTabWithEmptyHerdrPaneRefs_omitsHerdrPaneRefsKeyEntirely() throws {
        let tab = Tab(splitTree: SplitTree(leafID: UUID()))
        // tab.herdrPaneRefs defaults to [:] -- never mutated here, so
        // this exercises the true default, not just an explicitly-reset
        // one.

        let snapshot = try XCTUnwrap(tab.snapshot(), "a .terminal Tab must produce a non-nil TabSnapshot")
        XCTAssertNil(snapshot.herdrPaneRefs,
                     "Tab.snapshot() must nil-out an empty herdrPaneRefs dict, mirroring sessionRefs's own " +
                     "isEmpty ? nil : self pattern")

        let data = try JSONEncoder().encode(snapshot)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let jsonObject = try XCTUnwrap(rawObject as? [String: Any], "encoded TabSnapshot must decode as a JSON object")

        XCTAssertFalse(jsonObject.keys.contains("herdrPaneRefs"),
                       "A TabSnapshot encoded from a Tab with empty herdrPaneRefs must write NO herdrPaneRefs " +
                       "key at all, not an empty {} or [] value")
    }

    // MARK: - Tab round trip (non-empty)

    func test_tab_withTwoHerdrPaneRefs_roundTripsThroughSnapshotEncodeDecodeRestore() throws {
        let leafA = UUID()
        let (tree, leafB) = SplitTree(leafID: leafA).insert(at: leafA, direction: .horizontal)
        let refA = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        let refB = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wC:p1")

        let tab = Tab(splitTree: tree)
        tab.herdrPaneRefs = [leafA: refA, leafB: refB]

        let snapshot = try XCTUnwrap(tab.snapshot())
        let data = try JSONEncoder().encode(snapshot)
        let decodedSnapshot = try JSONDecoder().decode(TabSnapshot.self, from: data)
        let restored = Tab(snapshot: decodedSnapshot)

        XCTAssertEqual(restored.herdrPaneRefs, [leafA: refA, leafB: refB],
                       "A Tab's two herdrPaneRefs (distinct leaf UUIDs, distinct pane ids) must survive " +
                       "snapshot() -> encode -> decode -> Tab(snapshot:) identically")
    }

    // MARK: - migrate passthrough

    /// Full v6 SessionSnapshot fixture, copied structurally from
    /// SessionSnapshotV6Tests.swift's own proven
    /// v6JSONFixtureWithoutZoomedLeafID (same precedent: an optional
    /// field added within schema v6 needs no version bump, so this is a
    /// legitimate CURRENT v6 file that simply predates herdrPaneRefs --
    /// no "herdrPaneRefs" key anywhere).
    private var v6JSONFixtureWithoutHerdrPaneRefs: String {
        """
        {
            "schemaVersion": 6,
            "windows": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "frame": [[0, 0], [800, 600]],
                    "groups": [
                        {
                            "id": "00000000-0000-0000-0000-000000000010",
                            "name": "Default",
                            "color": "blue",
                            "tabs": [
                                {
                                    "id": "00000000-0000-0000-0000-000000000020",
                                    "title": "Terminal",
                                    "titleOverride": null,
                                    "pwd": "/Users/dev/repo",
                                    "splitTree": {
                                        "focusedLeafID": "00000000-0000-0000-0000-000000000030",
                                        "root": {"leaf": {"id": "00000000-0000-0000-0000-000000000030"}}
                                    },
                                    "browserURL": null
                                }
                            ],
                            "activeTabID": "00000000-0000-0000-0000-000000000020",
                            "isCollapsed": false
                        }
                    ],
                    "activeGroupID": "00000000-0000-0000-0000-000000000010",
                    "showSidebar": true,
                    "sidebarWidth": 260,
                    "isFullScreen": false
                }
            ]
        }
        """
    }

    func test_migrate_v6JSONWithoutHerdrPaneRefsKey_passesThroughWithNilRefs_neverCrashing() throws {
        let data = Data(v6JSONFixtureWithoutHerdrPaneRefs.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let tabBeforeMigrate = try XCTUnwrap(decoded.windows.first?.groups.first?.tabs.first)
        XCTAssertNil(tabBeforeMigrate.herdrPaneRefs, "Precondition: the pre-herdrPaneRefs fixture decodes with herdrPaneRefs nil")

        let migrated = SessionSnapshot.migrate(decoded)

        XCTAssertEqual(migrated.schemaVersion, SessionSnapshot.currentSchemaVersion)
        let migratedTab = try XCTUnwrap(migrated.windows.first?.groups.first?.tabs.first)
        XCTAssertNil(migratedTab.herdrPaneRefs,
                     "migrate(_:) must pass a nil/absent herdrPaneRefs straight through without crashing")
        XCTAssertEqual(migratedTab.id, UUID(uuidString: "00000000-0000-0000-0000-000000000020"))
    }

    // MARK: - pruneHerdrPaneRefs(keeping:)

    func test_pruneHerdrPaneRefs_keeping_removesRefsForLeavesNotInKeptSet() {
        let survivingLeaf = UUID()
        let goneLeaf = UUID()
        let survivingRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        let goneRef = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wC:p1")

        let tab = Tab(splitTree: SplitTree(leafID: survivingLeaf))
        tab.herdrPaneRefs = [survivingLeaf: survivingRef, goneLeaf: goneRef]

        tab.pruneHerdrPaneRefs(keeping: [survivingLeaf])

        XCTAssertEqual(tab.herdrPaneRefs, [survivingLeaf: survivingRef],
                       "pruneHerdrPaneRefs(keeping:) must drop entries for leaves not in the kept set, " +
                       "keeping only the ones that are")
    }
}
