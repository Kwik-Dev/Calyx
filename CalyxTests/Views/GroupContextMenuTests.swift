// GroupContextMenuTests.swift
// CalyxTests
//
// Covers `GroupContextMenu.make(groupIndex:groupCount:currentColor:actions:)`
// and `GroupContextMenu.swatchImage(for:)`
// (Calyx/Views/Sidebar/GroupContextMenu.swift). The menu shown on
// right-click/Ctrl+click for a sidebar tab-group header must always
// contain exactly 6 items, in this exact order: "Close Group", "Close
// Other Groups", "Close Groups Below", a separator, "Rename Group...",
// "Color" (a submenu item with no action of its own). Enabled state for
// "Close Other Groups" is `groupCount > 1`; for "Close Groups Below" it
// is `groupIndex < groupCount - 1`. "Close Group" and "Rename Group..."
// are always enabled. The "Color" item's submenu holds
// `TabGroupColor.allCases` in order, one item per color, titled with
// `color.displayName`, imaged with `swatchImage(for:)`, and checked
// (`.on`) only for the color matching `currentColor`. Firing an item's
// `target`/`action` must invoke exactly the matching `Actions` closure.

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class GroupContextMenuTests: XCTestCase {

    // MARK: - Fixture

    /// One counter per `Actions` closure, so firing one item can be
    /// asserted to increment ONLY its own counter and none of the
    /// others. `setColorCalls` records every color `setColor` was
    /// invoked with, in call order, so a color-item test can assert
    /// both the count AND which color arrived.
    private final class ActionCounters {
        var close = 0
        var closeOthers = 0
        var closeBelow = 0
        var rename = 0
        var setColorCalls: [TabGroupColor] = []
    }

    private func makeCounters() -> (ActionCounters, GroupContextMenu.Actions) {
        let counters = ActionCounters()
        let actions = GroupContextMenu.Actions(
            close: { counters.close += 1 },
            closeOthers: { counters.closeOthers += 1 },
            closeBelow: { counters.closeBelow += 1 },
            rename: { counters.rename += 1 },
            setColor: { color in counters.setColorCalls.append(color) }
        )
        return (counters, actions)
    }

    // MARK: - Structure

    /// By hand, per spec: 6 top-level items, titles at indices 0/1/2/4/5
    /// exactly as listed, index 3 a separator, `autoenablesItems ==
    /// false` (so the enabled-state tests below are meaningful --
    /// AppKit would otherwise override them based on `target`/`action`
    /// validation).
    func test_make_sixItemsInOrder_separatorAt3_colorSubmenuAt5_autoenablesOff() {
        let (_, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)

        XCTAssertFalse(menu.autoenablesItems, "autoenablesItems must be false so enabled flags are set explicitly")
        XCTAssertEqual(menu.items.count, 6, "Menu must have exactly 6 items")
        XCTAssertEqual(menu.items[0].title, "Close Group")
        XCTAssertEqual(menu.items[1].title, "Close Other Groups")
        XCTAssertEqual(menu.items[2].title, "Close Groups Below")
        XCTAssertTrue(menu.items[3].isSeparatorItem, "Item at index 3 must be a separator")
        XCTAssertEqual(menu.items[4].title, "Rename Group...")
        XCTAssertEqual(menu.items[5].title, "Color")
        XCTAssertNotNil(menu.items[5].submenu, "The Color item must carry a submenu")
    }

    /// The Color submenu must hold exactly `TabGroupColor.allCases`, in
    /// that exact order, each titled with `displayName`, each imaged
    /// with a non-nil 12x12 swatch, all enabled (color choice is never
    /// disabled), and the submenu itself must not auto-enable its items.
    func test_colorSubmenu_tenItemsInAllCasesOrder_eachWithSwatch_autoenablesOff() throws {
        let (_, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)
        let submenu = try XCTUnwrap(menu.items[5].submenu)

        XCTAssertFalse(submenu.autoenablesItems, "Color submenu must also disable AppKit's own item auto-enabling")
        XCTAssertEqual(submenu.items.count, TabGroupColor.allCases.count)
        XCTAssertEqual(submenu.items.map(\.title), TabGroupColor.allCases.map(\.displayName))
        for item in submenu.items {
            XCTAssertNotNil(item.image, "Every color item must carry a swatch image")
            XCTAssertEqual(item.image?.size, NSSize(width: 12, height: 12), "Every swatch must be 12x12")
            XCTAssertTrue(item.isEnabled, "Every color item must be enabled")
        }
    }

    /// `currentColor: .teal` must check exactly one submenu item -- the
    /// one at teal's index in `TabGroupColor.allCases` (5, by hand:
    /// red, orange, yellow, green, mint, teal, cyan, blue, indigo,
    /// purple) -- and leave every other item unchecked.
    func test_colorSubmenu_checksOnlyCurrentColor() throws {
        let (_, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .teal, actions: actions)
        let submenu = try XCTUnwrap(menu.items[5].submenu)

        let onStates = submenu.items.map { $0.state == .on }
        XCTAssertEqual(onStates.filter { $0 }.count, 1, "Exactly one color item must be checked")
        XCTAssertEqual(submenu.items.firstIndex { $0.state == .on }, 5, "The checked item must be at teal's index (5)")
        XCTAssertEqual(TabGroupColor.allCases[5], .teal, "Sanity: teal really is at index 5 in allCases")
    }

    // MARK: - Enabled state

    /// (groupIndex 0, groupCount 1): the only group. "Close Other
    /// Groups" must be disabled (no other group exists to close) and
    /// "Close Groups Below" must be disabled (0 is not < 1 - 1 == 0).
    /// "Close Group" and "Rename Group..." are always enabled.
    func test_enabledState_singleGroup_disablesOthersAndBelow() {
        let (_, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 1, currentColor: .blue, actions: actions)

        XCTAssertTrue(menu.items[0].isEnabled, "Close Group must always be enabled")
        XCTAssertFalse(menu.items[1].isEnabled, "Close Other Groups must be disabled when groupCount == 1")
        XCTAssertFalse(menu.items[2].isEnabled, "Close Groups Below must be disabled for the last (only) group")
        XCTAssertTrue(menu.items[4].isEnabled, "Rename Group... must always be enabled")
    }

    /// (groupIndex 0, groupCount 3): first of three groups. "Close Other
    /// Groups" enabled (2 other groups exist), "Close Groups Below"
    /// enabled (0 < 3 - 1 == 2).
    func test_enabledState_firstOfThree_enablesBoth() {
        let (_, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)

        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isEnabled, "Close Other Groups must be enabled when groupCount > 1")
        XCTAssertTrue(menu.items[2].isEnabled, "Close Groups Below must be enabled when groupIndex < groupCount - 1")
        XCTAssertTrue(menu.items[4].isEnabled)
    }

    /// (groupIndex 2, groupCount 3): last of three groups. "Close Other
    /// Groups" enabled (2 other groups exist), "Close Groups Below"
    /// disabled (2 is not < 3 - 1 == 2).
    func test_enabledState_lastOfThree_enablesOthers_disablesBelow() {
        let (_, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 2, groupCount: 3, currentColor: .blue, actions: actions)

        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isEnabled, "Close Other Groups must be enabled when groupCount > 1")
        XCTAssertFalse(menu.items[2].isEnabled, "Close Groups Below must be disabled for the last group")
        XCTAssertTrue(menu.items[4].isEnabled)
    }

    // MARK: - Firing

    /// Firing "Close Group" must invoke ONLY the `close` closure, exactly
    /// once, and none of the other four.
    func test_firingCloseGroup_invokesOnlyClose() {
        let (counters, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)
        let item = menu.items[0]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired, "NSApp.sendAction must find a responder for the item's target/action")
        XCTAssertEqual(counters.close, 1)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeBelow, 0)
        XCTAssertEqual(counters.rename, 0)
        XCTAssertTrue(counters.setColorCalls.isEmpty)
    }

    /// Firing "Close Other Groups" must invoke ONLY the `closeOthers`
    /// closure, exactly once, and none of the other four.
    func test_firingCloseOtherGroups_invokesOnlyCloseOthers() {
        let (counters, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)
        let item = menu.items[1]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 1)
        XCTAssertEqual(counters.closeBelow, 0)
        XCTAssertEqual(counters.rename, 0)
        XCTAssertTrue(counters.setColorCalls.isEmpty)
    }

    /// Firing "Close Groups Below" must invoke ONLY the `closeBelow`
    /// closure, exactly once, and none of the other four.
    func test_firingCloseGroupsBelow_invokesOnlyCloseBelow() {
        let (counters, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)
        let item = menu.items[2]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeBelow, 1)
        XCTAssertEqual(counters.rename, 0)
        XCTAssertTrue(counters.setColorCalls.isEmpty)
    }

    /// Firing "Rename Group..." must invoke ONLY the `rename` closure,
    /// exactly once, and none of the other four.
    func test_firingRenameGroup_invokesOnlyRename() {
        let (counters, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)
        let item = menu.items[4]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeBelow, 0)
        XCTAssertEqual(counters.rename, 1)
        XCTAssertTrue(counters.setColorCalls.isEmpty)
    }

    /// Firing the indigo color item must invoke ONLY `setColor`, exactly
    /// once, with `.indigo` (by hand: index 8 in `TabGroupColor
    /// .allCases` -- red, orange, yellow, green, mint, teal, cyan, blue,
    /// indigo, purple), and none of the other four closures.
    func test_firingColorItem_invokesSetColorWithThatColor_only() throws {
        let (counters, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)
        let submenu = try XCTUnwrap(menu.items[5].submenu)
        XCTAssertEqual(TabGroupColor.allCases[8], .indigo, "Sanity: indigo really is at index 8 in allCases")
        let item = submenu.items[8]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.setColorCalls, [.indigo])
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeBelow, 0)
        XCTAssertEqual(counters.rename, 0)
    }

    // MARK: - Accessibility identifiers

    /// Every top-level item that is not a separator, plus every color
    /// submenu item, must carry the matching `AccessibilityID
    /// .GroupContextMenu` identifier, read back through the informal
    /// `NSObject.accessibilityIdentifier()` getter `setAccessibilityIdentifier`
    /// populates.
    func test_accessibilityIdentifiers_setOnEveryItem() throws {
        let (_, actions) = makeCounters()
        let menu = GroupContextMenu.make(groupIndex: 0, groupCount: 3, currentColor: .blue, actions: actions)

        XCTAssertEqual(menu.items[0].accessibilityIdentifier(), AccessibilityID.GroupContextMenu.close)
        XCTAssertEqual(menu.items[1].accessibilityIdentifier(), AccessibilityID.GroupContextMenu.closeOthers)
        XCTAssertEqual(menu.items[2].accessibilityIdentifier(), AccessibilityID.GroupContextMenu.closeBelow)
        XCTAssertEqual(menu.items[4].accessibilityIdentifier(), AccessibilityID.GroupContextMenu.rename)
        XCTAssertEqual(menu.items[5].accessibilityIdentifier(), AccessibilityID.GroupContextMenu.color)

        let submenu = try XCTUnwrap(menu.items[5].submenu)
        for (index, color) in TabGroupColor.allCases.enumerated() {
            XCTAssertEqual(
                submenu.items[index].accessibilityIdentifier(),
                AccessibilityID.GroupContextMenu.color(color),
                "Color item at index \(index) (\(color)) must carry its own identifier"
            )
        }
    }

    // MARK: - Swatch image

    /// `swatchImage(for:)` must return a 12x12 image regardless of
    /// color; used directly by the color submenu items above, and
    /// tested standalone here since it is part of the public API.
    func test_swatchImage_is12x12() {
        let image = GroupContextMenu.swatchImage(for: .red)
        XCTAssertEqual(image.size, NSSize(width: 12, height: 12))
    }
}
