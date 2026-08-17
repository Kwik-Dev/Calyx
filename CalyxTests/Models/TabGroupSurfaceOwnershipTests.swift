// TabGroupSurfaceOwnershipTests.swift
// CalyxTests
//
// Coverage for TabGroup.tab(owningSurface:) and
// [TabGroup].tabAndGroup(owningSurface:), the shared surface-ownership
// primitives every "find the tab that owns this surface" call site routes
// through -- plus Tab.displayTitle, the shared title-precedence primitive
// every tab-name display site routes through.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class TabGroupSurfaceOwnershipTests: XCTestCase {

    // MARK: - Fixture

    /// A tab whose registry owns `surfaceID`, via the same
    /// `_testInsert(view:id:)` seam `AppDelegateFocusExistingSessionTests`
    /// and friends use to give a tab a live surface without a real
    /// ghostty app.
    private func makeTab(owning surfaceID: UUID, title: String) -> Tab {
        let registry = SurfaceRegistry()
        registry._testInsert(view: SurfaceView(frame: .zero), id: surfaceID)
        return Tab(title: title, registry: registry)
    }

    // MARK: - TabGroup.tab(owningSurface:)

    func test_tabOwningSurface_returnsTheTabThatOwnsIt() {
        let surfaceID = UUID()
        let owner = makeTab(owning: surfaceID, title: "Owner")
        let group = TabGroup(tabs: [Tab(title: "Unrelated"), owner])

        XCTAssertTrue(group.tab(owningSurface: surfaceID) === owner,
                      "tab(owningSurface:) must return the tab whose registry owns the surface, even " +
                      "alongside a sibling tab that does not own it")
    }

    func test_tabOwningSurface_returnsNil_whenNoTabInTheGroupOwnsIt() {
        let group = TabGroup(tabs: [Tab(title: "A"), Tab(title: "B")])

        XCTAssertNil(group.tab(owningSurface: UUID()),
                     "tab(owningSurface:) must return nil when no tab in the group owns the surface")
    }

    func test_tabOwningSurface_returnsNil_whenTheOwningTabIsInADifferentGroup() {
        let surfaceID = UUID()
        let owner = makeTab(owning: surfaceID, title: "Owner")
        let ownerGroup = TabGroup(tabs: [owner])
        let otherGroup = TabGroup(tabs: [Tab(title: "Unrelated")])

        XCTAssertNil(otherGroup.tab(owningSurface: surfaceID),
                     "otherGroup does not contain the owning tab, so it must not report ownership")
        XCTAssertTrue(ownerGroup.tab(owningSurface: surfaceID) === owner,
                      "Precondition: ownerGroup is the one that actually owns the surface")
    }

    // MARK: - [TabGroup].tabAndGroup(owningSurface:)

    func test_tabAndGroup_findsTheOwningTabAndItsGroup_whenTheOwnerIsInAnotherGroupInTheSequence() {
        let surfaceID = UUID()
        let owner = makeTab(owning: surfaceID, title: "Owner")
        let ownerGroup = TabGroup(name: "Owning Group", tabs: [owner])
        let otherGroup = TabGroup(name: "Other Group", tabs: [Tab(title: "Unrelated")])

        let result = [otherGroup, ownerGroup].tabAndGroup(owningSurface: surfaceID)

        XCTAssertTrue(result?.tab === owner,
                      "tabAndGroup(owningSurface:) must return the tab whose registry owns the surface, " +
                      "not a tab from an unrelated group")
        XCTAssertTrue(result?.group === ownerGroup,
                      "tabAndGroup(owningSurface:) must return the group that actually contains the " +
                      "owning tab, not the first group in the sequence")
    }

    func test_tabAndGroup_returnsNil_whenNoTabInAnyGroupOwnsIt() {
        let groupA = TabGroup(tabs: [Tab(title: "A")])
        let groupB = TabGroup(tabs: [Tab(title: "B")])

        XCTAssertNil([groupA, groupB].tabAndGroup(owningSurface: UUID()),
                     "tabAndGroup(owningSurface:) must return nil when no tab in any group owns the surface")
    }

    // MARK: - Tab.displayTitle

    func test_displayTitle_withTitleOverrideSet_returnsTheOverride() {
        let tab = Tab(title: "Terminal", titleOverride: "Custom Name")

        XCTAssertEqual(tab.displayTitle, "Custom Name",
                       "displayTitle must return titleOverride when one is set, not the underlying title")
    }

    func test_displayTitle_withNilTitleOverride_returnsTheTitle() {
        let tab = Tab(title: "Terminal")

        XCTAssertEqual(tab.displayTitle, "Terminal",
                       "displayTitle must fall back to title when titleOverride is nil")
    }

    func test_displayTitle_withEmptyStringTitleOverride_returnsTheEmptyString() {
        let tab = Tab(title: "Terminal", titleOverride: "")

        XCTAssertEqual(tab.displayTitle, "",
                       "displayTitle performs no emptiness special-casing of its own: an empty but " +
                       "non-nil titleOverride must still take precedence over title")
    }
}
