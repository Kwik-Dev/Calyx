// GroupContextMenuUITests.swift
// CalyxUITests
//
// E2E tests for the right-click/Ctrl+click context menu on a sidebar
// tab-group header (`GroupContextMenu`, `Calyx/Views/Sidebar/
// GroupContextMenu.swift`). `CalyxUITests` does not import the app
// module, so every menu-item accessibility identifier is hardcoded here
// as a private constant, mirroring `AccessibilityID.GroupContextMenu`'s
// own values.
//
// Coverage:
// - Right-click the only group header -> Close Other Groups/Close
//   Groups Below disabled
// - Right-click a header, Rename Group... -> inline editor opens
//   without activating that group
// - Close Groups Below / Close Other Groups / Close Group -> the
//   right-clicked group survives, the others close
// - The color submenu can be navigated and a color chosen without
//   closing the group or leaving a stray menu open
// - The collapse chevron accepts both right-click and Ctrl+click for
//   the same menu, and Ctrl+click never collapses the group

import XCTest

final class GroupContextMenuUITests: CalyxUITestCase {

    // MARK: - Hardcoded identifiers (mirrors AccessibilityID.GroupContextMenu)

    private let closeItemID = "calyx.groupMenu.close"
    private let closeOthersItemID = "calyx.groupMenu.closeOthers"
    private let closeBelowItemID = "calyx.groupMenu.closeBelow"
    private let renameItemID = "calyx.groupMenu.rename"
    private let colorItemID = "calyx.groupMenu.color"
    private let colorPurpleItemID = "calyx.groupMenu.color.purple"

    // MARK: - Group creation helpers (same palette path as GroupManagementUITests)

    private func createSecondGroup() {
        createGroupViaCommandPalette(expectingGroupCount: 2)
    }

    private func createThirdGroup() {
        createGroupViaCommandPalette(expectingGroupCount: 3)
    }

    // MARK: - Group header lookup

    private func groupHeader(at index: Int) -> XCUIElement {
        groupHeadersQuery().element(boundBy: index)
    }

    // MARK: - Tests

    func test_rightClickSingleGroupHeader_closeOthersAndBelowDisabled() {
        XCTAssertEqual(groupHeaderCount(), 1, "Should start with exactly one group")

        groupHeader(at: 0).rightClick()

        let closeOthersItem = app.menuItems[closeOthersItemID]
        XCTAssertTrue(waitFor(closeOthersItem, timeout: 3), "Close Other Groups menu item should appear")
        XCTAssertFalse(closeOthersItem.isEnabled, "Close Other Groups must be disabled for the only group")

        let closeBelowItem = app.menuItems[closeBelowItemID]
        XCTAssertFalse(closeBelowItem.isEnabled, "Close Groups Below must be disabled for the only group")

        app.typeKey(.escape, modifierFlags: [])
    }

    func test_rightClickGroupHeader_renameGroup_opensInlineEditor_withoutActivatingGroup() {
        let firstGroupTabIdentifiers = currentTabBarTabIdentifiers()
        createSecondGroup()

        // `createNewGroup()` makes the new group active (`CalyxWindowController
        // .createNewGroup()` sets `windowSession.activeGroupID` explicitly), so
        // header 0 -- the original, now-first group in sidebar order -- must be
        // the NON-active group at this point: the tab bar's own identifier set
        // must have moved away from `firstGroupTabIdentifiers`.
        let tabsBefore = currentTabBarTabIdentifiers()
        XCTAssertNotEqual(
            tabsBefore, firstGroupTabIdentifiers,
            "Creating a second group must switch the active group away from the first, so header 0 starts non-active"
        )

        groupHeader(at: 0).rightClick()

        let renameItem = app.menuItems[renameItemID]
        XCTAssertTrue(waitFor(renameItem, timeout: 3), "Rename Group... menu item should appear")
        renameItem.click()

        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'calyx.sidebar.groupNameTextField.'"))
            .firstMatch
        XCTAssertTrue(waitFor(renameField, timeout: 3), "Inline rename editor should open after choosing Rename Group...")

        renameField.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(renameField)

        XCTAssertEqual(
            currentTabBarTabIdentifiers(), tabsBefore,
            "Right-clicking and renaming a group must not activate it (the tab bar must show the same group's tabs)"
        )
    }

    func test_closeGroupsBelow_removesLowerGroup_keepsRightClicked() {
        createSecondGroup()
        XCTAssertEqual(groupHeaderCount(), 2)

        let survivorIdentifier = groupHeader(at: 0).identifier

        groupHeader(at: 0).rightClick()

        let closeBelowItem = app.menuItems[closeBelowItemID]
        XCTAssertTrue(waitFor(closeBelowItem, timeout: 3), "Close Groups Below menu item should appear")
        closeBelowItem.click()

        XCTAssertEqual(waitForCount(groupHeaderCount, toEqual: 1), 1, "Only the right-clicked group should remain")
        XCTAssertEqual(groupHeader(at: 0).identifier, survivorIdentifier, "The right-clicked group must survive")
    }

    func test_closeOtherGroups_keepsRightClickedGroup() {
        createSecondGroup()
        createThirdGroup()
        XCTAssertEqual(groupHeaderCount(), 3)

        let survivorIdentifier = groupHeader(at: 1).identifier

        groupHeader(at: 1).rightClick()

        let closeOthersItem = app.menuItems[closeOthersItemID]
        XCTAssertTrue(waitFor(closeOthersItem, timeout: 3), "Close Other Groups menu item should appear")
        closeOthersItem.click()

        XCTAssertEqual(waitForCount(groupHeaderCount, toEqual: 1), 1, "Only the right-clicked group should remain")
        XCTAssertEqual(groupHeader(at: 0).identifier, survivorIdentifier, "The right-clicked group must survive")
    }

    func test_closeGroup_viaContextMenu_closesThatGroup() {
        createSecondGroup()
        XCTAssertEqual(groupHeaderCount(), 2)

        let survivorIdentifier = groupHeader(at: 1).identifier

        groupHeader(at: 0).rightClick()

        let closeItem = app.menuItems[closeItemID]
        XCTAssertTrue(waitFor(closeItem, timeout: 3), "Close Group menu item should appear")
        closeItem.click()

        XCTAssertEqual(waitForCount(groupHeaderCount, toEqual: 1), 1, "Only the surviving group should remain")
        XCTAssertEqual(groupHeader(at: 0).identifier, survivorIdentifier, "The former second group must survive")
    }

    func test_colorSubmenu_selectColor_menuDismisses_groupSurvives() {
        XCTAssertEqual(groupHeaderCount(), 1)
        let headerIdentifier = groupHeader(at: 0).identifier

        groupHeader(at: 0).rightClick()

        let colorItem = app.menuItems[colorItemID]
        XCTAssertTrue(waitFor(colorItem, timeout: 3), "Color menu item should appear")
        colorItem.hover()

        let purpleItem = app.menuItems[colorPurpleItemID]
        XCTAssertTrue(waitFor(purpleItem, timeout: 3), "Purple color submenu item should appear")
        purpleItem.click()

        XCTAssertEqual(groupHeaderCount(), 1, "Choosing a color must not close the group")
        XCTAssertEqual(groupHeader(at: 0).identifier, headerIdentifier, "The same group must still be present")
        waitForNonExistence(app.menuItems[closeOthersItemID])
    }

    func test_rightClickCollapseChevron_opensGroupMenu() {
        let chevron = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'calyx.sidebar.groupCollapseButton.'"))
            .firstMatch
        XCTAssertTrue(waitFor(chevron, timeout: 5), "The group collapse chevron should exist")

        chevron.rightClick()

        let closeOthersItem = app.menuItems[closeOthersItemID]
        XCTAssertTrue(waitFor(closeOthersItem, timeout: 3), "Close Other Groups menu item should appear from the chevron")

        app.typeKey(.escape, modifierFlags: [])
    }

    func test_ctrlClickCollapseChevron_opensGroupMenu_doesNotCollapse() {
        let chevron = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'calyx.sidebar.groupCollapseButton.'"))
            .firstMatch
        XCTAssertTrue(waitFor(chevron, timeout: 5), "The group collapse chevron should exist")

        // `perform(withKeyModifiers:block:)` is a type method, not an
        // instance method: it runs `block` with the modifier keys held
        // down for its duration, it does not dispatch on `chevron`.
        XCUIElement.perform(withKeyModifiers: .control) {
            chevron.click()
        }

        let closeOthersItem = app.menuItems[closeOthersItemID]
        XCTAssertTrue(waitFor(closeOthersItem, timeout: 3), "Close Other Groups menu item should appear from a Ctrl+click on the chevron")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertGreaterThanOrEqual(
            countElements(matching: "calyx.sidebar.tab."), 1,
            "Ctrl+click on the chevron must not collapse the group -- its tabs must still be visible"
        )
    }
}
