// ClickContainerNSViewTrailingActionTests.swift
// CalyxTests
//
// Covers `ClickContainerNSView.trailingAction(at:)` and the trailing-action
// branch of `mouseDown(with:)` (Calyx/Views/TabBar/TabClickRecognizer.swift).
// `trailingActions` generalizes the existing close-button rect mechanism to
// an ordered list of AppKit-hit-tested rects, used by the sidebar group
// header's collapse chevron and close-all glyph (both visual-only images,
// no SwiftUI Button) so a Ctrl+click on them reaches this view's context
// menu dispatch instead of being swallowed by a Button.
//
// The view is flipped (`isFlipped == true`): local y grows downward. A
// `TrailingAction` rect is `size` square, vertically centered in `bounds`,
// with `insetFromTrailing` points between its trailing edge and
// `bounds.maxX`. For the 200x36 view used below, an action with
// `insetFromTrailing: 14, size: 20` occupies x in [166, 186], y in [8, 28].

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class ClickContainerNSViewTrailingActionTests: XCTestCase {

    private func makeView() -> ClickContainerNSView {
        ClickContainerNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
    }

    // MARK: - trailingAction(at:)

    /// A single enabled action's rect (inset 14, size 20) contains
    /// (176, 18): x 166...186, y 8...28. `trailingAction(at:)` must return
    /// that action.
    func test_trailingActionAt_insideEnabledRect_returnsThatAction() {
        let view = makeView()
        var actionRanCount = 0
        let action = TrailingAction(insetFromTrailing: 14, size: 20, isEnabled: true) {
            actionRanCount += 1
        }
        view.trailingActions = [action]

        let resolved = view.trailingAction(at: CGPoint(x: 176, y: 18))

        XCTAssertNotNil(resolved, "point inside the only action's rect must resolve to it")
        resolved?.action()
        XCTAssertEqual(actionRanCount, 1, "resolved action must be the one configured at that rect")
    }

    /// Two actions at distinct insets: chevron (inset 14, size 20) occupies
    /// x 166...186; closeAll (inset 34, size 20) occupies x 146...166.
    /// A point in each rect must resolve to the matching action, and a
    /// point in neither must resolve to nil.
    func test_trailingActionAt_secondActionRect_returnsSecond() {
        let view = makeView()
        var chevronCount = 0
        var closeAllCount = 0
        let chevron = TrailingAction(insetFromTrailing: 14, size: 20, isEnabled: true) {
            chevronCount += 1
        }
        let closeAll = TrailingAction(insetFromTrailing: 34, size: 20, isEnabled: true) {
            closeAllCount += 1
        }
        view.trailingActions = [chevron, closeAll]

        let resolvedCloseAll = view.trailingAction(at: CGPoint(x: 156, y: 18))
        resolvedCloseAll?.action()
        XCTAssertEqual(closeAllCount, 1, "(156, 18) is inside closeAll's rect only")
        XCTAssertEqual(chevronCount, 0, "(156, 18) must not run chevron's action")

        let resolvedChevron = view.trailingAction(at: CGPoint(x: 176, y: 18))
        resolvedChevron?.action()
        XCTAssertEqual(chevronCount, 1, "(176, 18) is inside chevron's rect only")
        XCTAssertEqual(closeAllCount, 1, "(176, 18) must not re-run closeAll's action")

        XCTAssertNil(view.trailingAction(at: CGPoint(x: 100, y: 18)), "(100, 18) is inside neither rect")
    }

    /// A disabled action's rect is transparent: a point inside it resolves
    /// to nil rather than to the disabled action.
    func test_trailingActionAt_disabledRect_isTransparent() {
        let view = makeView()
        let closeAll = TrailingAction(insetFromTrailing: 34, size: 20, isEnabled: false) {
            XCTFail("a disabled action must never run")
        }
        view.trailingActions = [closeAll]

        XCTAssertNil(view.trailingAction(at: CGPoint(x: 156, y: 18)), "disabled action's rect must be transparent")
    }

    /// When `onClose` is set and `closeButtonEnabled` is true, the close
    /// rect is checked before `trailingActions`, even when a trailing
    /// action shares the exact same inset/size and therefore the same
    /// rect.
    func test_trailingActionAt_closeButtonRectTakesPrecedence() {
        let view = makeView()
        var closeCount = 0
        var trailingCount = 0
        view.onClose = { closeCount += 1 }
        view.closeButtonEnabled = true
        view.closeButtonInsetFromTrailing = 14
        view.closeButtonSize = 16
        view.trailingActions = [
            TrailingAction(insetFromTrailing: 14, size: 16, isEnabled: true) {
                trailingCount += 1
            }
        ]

        let resolved = view.trailingAction(at: CGPoint(x: 178, y: 18))
        resolved?.action()

        XCTAssertEqual(closeCount, 1, "the close rect must win over a trailing action at the same geometry")
        XCTAssertEqual(trailingCount, 0, "the shadowed trailing action must not run")
    }

    /// A point outside `bounds` entirely (past the right edge) must
    /// resolve to nil, not to whichever action happens to be nearest.
    func test_trailingActionAt_pointOutsideBounds_returnsNil() {
        let view = makeView()
        view.trailingActions = [
            TrailingAction(insetFromTrailing: 14, size: 20, isEnabled: true) {
                XCTFail("no action should run for a point outside bounds")
            }
        ]

        XCTAssertNil(view.trailingAction(at: CGPoint(x: 250, y: 18)), "(250, 18) is outside the 200-wide view")
    }

    // MARK: - mouseDown(with:) dispatch

    /// `mouseDown` inside an enabled trailing action's rect must run the
    /// action and must not fire `onSingleClick`.
    ///
    /// The view has no window by default, and `convert(_:from: nil)`
    /// requires one to resolve window -> local coordinates correctly, so
    /// this embeds the view as a borderless window's content view sized
    /// to exactly match the view's frame (200x36). Because the chosen
    /// y (18) is the vertical midpoint of that 36pt height, the window's
    /// bottom-up y and the view's flipped top-down local y agree at this
    /// one point (36 - 18 == 18), so `NSEvent.mouseEvent(location:)` can
    /// use the same numeric y as the local-space assertions above.
    private func makeWindowedView() -> (view: ClickContainerNSView, window: NSWindow) {
        let view = makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return (view, window)
    }

    private func makeLeftMouseDown(location: NSPoint, windowNumber: Int, clickCount: Int = 1) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            )
        )
    }

    func test_mouseDown_insideEnabledTrailingRect_runsActionAndSkipsSingleClick() throws {
        let (view, window) = makeWindowedView()
        var actionCount = 0
        var singleClickCount = 0
        view.trailingActions = [
            TrailingAction(insetFromTrailing: 14, size: 20, isEnabled: true) {
                actionCount += 1
            }
        ]
        view.onSingleClick = { singleClickCount += 1 }

        let event = try makeLeftMouseDown(location: NSPoint(x: 176, y: 18), windowNumber: window.windowNumber)
        view.mouseDown(with: event)

        XCTAssertEqual(actionCount, 1, "the click landed inside the enabled trailing action's rect")
        XCTAssertEqual(singleClickCount, 0, "a trailing-action click must not also fire onSingleClick")
    }

    func test_mouseDown_outsideTrailingRects_firesSingleClick() throws {
        let (view, window) = makeWindowedView()
        var actionCount = 0
        var singleClickCount = 0
        view.trailingActions = [
            TrailingAction(insetFromTrailing: 14, size: 20, isEnabled: true) {
                actionCount += 1
            }
        ]
        view.onSingleClick = { singleClickCount += 1 }

        let event = try makeLeftMouseDown(location: NSPoint(x: 40, y: 18), windowNumber: window.windowNumber)
        view.mouseDown(with: event)

        XCTAssertEqual(actionCount, 0, "the click at (40, 18) is outside the trailing action's rect")
        XCTAssertEqual(singleClickCount, 1, "a click on the tab body must fire onSingleClick")
    }

    func test_mouseDown_disabledTrailingRect_fallsThroughToBody() throws {
        let (view, window) = makeWindowedView()
        var actionCount = 0
        var singleClickCount = 0
        view.trailingActions = [
            TrailingAction(insetFromTrailing: 14, size: 20, isEnabled: false) {
                actionCount += 1
            }
        ]
        view.onSingleClick = { singleClickCount += 1 }

        let event = try makeLeftMouseDown(location: NSPoint(x: 176, y: 18), windowNumber: window.windowNumber)
        view.mouseDown(with: event)

        XCTAssertEqual(actionCount, 0, "a disabled action must never run")
        XCTAssertEqual(singleClickCount, 1, "a disabled action's rect must be transparent, falling through to the tab body")
    }
}
