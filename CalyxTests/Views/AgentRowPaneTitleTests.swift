//
//  AgentRowPaneTitleTests.swift
//  CalyxTests
//
//  Regression pin for the Agents sidebar row's primary label sourcing
//  each pane's OWN recorded title (SurfacePropertyStore.title(for:))
//  rather than the owning tab's title. CalyxWindowController's
//  handleSetTitleNotification writes tab.title only for the ACTIVE
//  tab's FOCUSED split leaf, so a per-tab title source collapses two
//  agent panes split inside one tab to a single shared row label.
//  Exercises the real mechanism end to end: a real SurfacePropertyStore
//  fed by a real NotificationCenter.default.post(.ghosttySetTitle, ...)
//  and the real AgentRowDisplay.primaryLabel(title:), with no stub or
//  fake standing in for either.
//
//  Coverage:
//  - two distinct surfaces posting two distinct titles resolve to two
//    distinct SurfacePropertyStore.title(for:) results -- the case a
//    per-tab title source would collapse to one shared value
//  - the same pair rendered through AgentRowDisplay.primaryLabel still
//    differ, and each equals its own posted title verbatim
//  - a surface that never posted a title resolves to "N/A" rather than
//    borrowing a sibling surface's recorded title
//  - a later title update to one surface leaves a different, already-
//    tracked surface's recorded title untouched
//  - a bridged herdr row (.external source, focusSurfaceID set) composes
//    its label through focusSurfaceID, not its own surfaceID -- the
//    herdr pane id itself never resolves to a title in the store
//  - an unbridged herdr row (.external source, no focusSurfaceID) has no
//    resolvable focus target and composes to "N/A"
//  - a native (.hooks) row with no focusSurfaceID composes its label
//    through its own surfaceID
//

import XCTest
@testable import Calyx

@MainActor
final class AgentRowPaneTitleTests: XCTestCase {

    private var store: SurfacePropertyStore!

    override func setUp() {
        super.setUp()
        store = SurfacePropertyStore()
    }

    /// `store._stopObserving()` undoes this test's own `startObserving()`
    /// call -- without it, this test's `SurfacePropertyStore` instance
    /// stays registered with `NotificationCenter` for the rest of the
    /// test process (a leaked observer per test method). `SurfaceLocator
    /// .shared` is a separate global singleton that persists across test
    /// cases within the same process too -- without resetting it, a view
    /// registered via `_testInsert` in one test would still resolve in a
    /// later test's lookups.
    override func tearDown() {
        store._stopObserving()
        store = nil
        SurfaceLocator.shared._testReset()
        super.tearDown()
    }

    // MARK: - Two distinct surfaces resolve two distinct titles

    func test_setTitleNotification_twoSurfaces_recordDistinctTitles() {
        let registry = SurfaceRegistry()
        let idA = UUID()
        let idB = UUID()
        let viewA = SurfaceView(frame: .zero)
        let viewB = SurfaceView(frame: .zero)
        registry._testInsert(view: viewA, id: idA)
        registry._testInsert(view: viewB, id: idB)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: viewA, userInfo: ["title": "Refactor billing service"])
        NotificationCenter.default.post(name: .ghosttySetTitle, object: viewB, userInfo: ["title": "請求書サービスのリファクタリング"])

        let titleA = store.title(for: idA)
        let titleB = store.title(for: idB)

        XCTAssertEqual(titleA, "Refactor billing service",
                       "surface A's own recorded title must be exactly what its own .ghosttySetTitle notification posted")
        XCTAssertEqual(titleB, "請求書サービスのリファクタリング",
                       "surface B's own recorded title must be exactly what its own .ghosttySetTitle notification posted")
        XCTAssertNotEqual(titleA, titleB,
                          "two split panes in the same tab must resolve two distinct titles from their own per-surface records -- this is the case that fails if the title source ever regresses back to a single per-tab value shared by both panes")
    }

    // MARK: - The pair rendered through AgentRowDisplay.primaryLabel

    func test_primaryLabel_twoSurfaces_rendersDistinctLabels() {
        let registry = SurfaceRegistry()
        let idA = UUID()
        let idB = UUID()
        let viewA = SurfaceView(frame: .zero)
        let viewB = SurfaceView(frame: .zero)
        registry._testInsert(view: viewA, id: idA)
        registry._testInsert(view: viewB, id: idB)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: viewA, userInfo: ["title": "Refactor billing service"])
        NotificationCenter.default.post(name: .ghosttySetTitle, object: viewB, userInfo: ["title": "請求書サービスのリファクタリング"])

        let labelA = AgentRowDisplay.primaryLabel(title: store.title(for: idA))
        let labelB = AgentRowDisplay.primaryLabel(title: store.title(for: idB))

        XCTAssertEqual(labelA, "Refactor billing service",
                       "the row's primary label for surface A must equal surface A's own posted title verbatim")
        XCTAssertEqual(labelB, "請求書サービスのリファクタリング",
                       "the row's primary label for surface B must equal surface B's own posted title verbatim")
        XCTAssertNotEqual(labelA, labelB,
                          "two split panes' rendered row labels must differ when their own recorded titles differ -- pinning the same per-tab-collapse regression at the label-derivation boundary the sidebar row actually renders, not just the store")
    }

    // MARK: - An unreported surface does not borrow a sibling's title

    func test_primaryLabel_surfaceNeverReportedTitle_doesNotBorrowSiblingTitle() {
        let registry = SurfaceRegistry()
        let reportedID = UUID()
        let neverReportedID = UUID()
        let reportedView = SurfaceView(frame: .zero)
        let neverReportedView = SurfaceView(frame: .zero)
        registry._testInsert(view: reportedView, id: reportedID)
        registry._testInsert(view: neverReportedView, id: neverReportedID)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: reportedView, userInfo: ["title": "Refactor billing service"])

        XCTAssertEqual(store.title(for: reportedID), "Refactor billing service",
                       "precondition: the sibling surface's own title must be recorded before checking the unreported surface")
        XCTAssertNil(store.title(for: neverReportedID),
                     "a surface that never posted .ghosttySetTitle must have no recorded title of its own, even while a sibling surface has one")
        XCTAssertEqual(AgentRowDisplay.primaryLabel(title: store.title(for: neverReportedID)), "N/A",
                       "an unreported pane's row must fall back to N/A rather than borrowing a sibling split pane's recorded title")
    }

    // MARK: - A later title update to one surface leaves the other untouched

    func test_setTitleNotification_laterUpdateToOneSurface_leavesOtherSurfaceUntouched() {
        let registry = SurfaceRegistry()
        let idA = UUID()
        let idB = UUID()
        let viewA = SurfaceView(frame: .zero)
        let viewB = SurfaceView(frame: .zero)
        registry._testInsert(view: viewA, id: idA)
        registry._testInsert(view: viewB, id: idB)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: viewA, userInfo: ["title": "Refactor billing service"])
        NotificationCenter.default.post(name: .ghosttySetTitle, object: viewB, userInfo: ["title": "請求書サービスのリファクタリング"])

        NotificationCenter.default.post(name: .ghosttySetTitle, object: viewA, userInfo: ["title": "Run integration tests"])

        XCTAssertEqual(store.title(for: idA), "Run integration tests",
                       "surface A's later title update must replace its own previously recorded title")
        XCTAssertEqual(store.title(for: idB), "請求書サービスのリファクタリング",
                       "surface B's recorded title must be untouched by a later .ghosttySetTitle notification posted for a different surface")
    }

    // MARK: - Bridged herdr row resolves its label through focusSurfaceID

    /// Pins the composition `AgentRowView.displayName` performs --
    /// `AgentRowDisplay.primaryLabel(source:surfaceID:focusSurfaceID:
    /// paneTitle:)` -- for a BRIDGED herdr row. An `.external` entry's
    /// own `surfaceID` is a herdr pane id, never a `SurfaceRegistry` id,
    /// so only `focusSurfaceID` can reach the bridging Calyx surface's
    /// recorded title in `SurfacePropertyStore`.
    func test_primaryLabel_bridgedHerdrRow_resolvesThroughFocusSurfaceID() {
        let registry = SurfaceRegistry()
        let calyxSurfaceID = UUID()
        let herdrPaneID = UUID()
        let calyxView = SurfaceView(frame: .zero)
        registry._testInsert(view: calyxView, id: calyxSurfaceID)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: calyxView, userInfo: ["title": "Refactor billing service"])

        XCTAssertNil(store.title(for: herdrPaneID),
                     "a herdr pane id that was never registered with SurfaceLocator must have no recorded title of its own -- otherwise the assertion below could pass from this id coincidentally already carrying a title rather than from resolving through focusSurfaceID")

        let label = AgentRowDisplay.primaryLabel(
            source: .external,
            surfaceID: herdrPaneID,
            focusSurfaceID: calyxSurfaceID,
            paneTitle: store.title(for:)
        )

        XCTAssertEqual(label, "Refactor billing service",
                       "a bridged herdr row must reach its pane's title through focusSurfaceID -- reading the entry's own surfaceID instead would return \"N/A\"")
    }

    // MARK: - Unbridged herdr row has no resolvable label

    /// An `.external` row with no `focusSurfaceID` (every UNBRIDGED
    /// herdr pane -- `HerdrAgentMirror` only resolves one for a pane the
    /// pane registry actually bridges) has no resolvable focus target at
    /// all, so the composed label falls back to "N/A" rather than
    /// resolving through the row's own (herdr) surfaceID.
    func test_primaryLabel_unbridgedHerdrRow_returnsNA() {
        let herdrPaneID = UUID()

        let focusTarget = AgentRowFocusTarget.resolve(source: .external, surfaceID: herdrPaneID, focusSurfaceID: nil)

        XCTAssertNil(focusTarget,
                     "an unbridged herdr row (.external source, no focusSurfaceID) must have no resolvable focus target")

        let label = AgentRowDisplay.primaryLabel(
            source: .external,
            surfaceID: herdrPaneID,
            focusSurfaceID: nil,
            paneTitle: store.title(for:)
        )

        XCTAssertEqual(label, "N/A",
                       "an unbridged herdr row's composed label must fall back to \"N/A\" rather than resolving through its own herdr surfaceID")
    }

    // MARK: - Native row resolves its label through its own surfaceID

    /// A `.hooks` row's own `surfaceID` IS a real `SurfaceRegistry` id
    /// (see `AgentRowFocusTarget.resolve`'s doc comment), so with no
    /// `focusSurfaceID` set the composed label resolves through that
    /// surfaceID directly.
    func test_primaryLabel_nativeRow_resolvesThroughOwnSurfaceID() {
        let registry = SurfaceRegistry()
        let surfaceID = UUID()
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: surfaceID)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: view, userInfo: ["title": "Run integration tests"])

        let label = AgentRowDisplay.primaryLabel(
            source: .hooks,
            surfaceID: surfaceID,
            focusSurfaceID: nil,
            paneTitle: store.title(for:)
        )

        XCTAssertEqual(label, "Run integration tests",
                       "a native (.hooks) row with no focusSurfaceID must resolve its composed label through its own surfaceID")
    }
}
