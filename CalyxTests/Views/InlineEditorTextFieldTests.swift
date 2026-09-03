//
//  InlineEditorTextFieldTests.swift
//  CalyxTests
//
//  Covers the fix for InlineTextField's focus race: makeNSView used to
//  request focus via a fixed DispatchQueue.main.async delay, which fires
//  before SwiftUI attaches the field to a window when that attachment is
//  slow. InlineEditorTextField ties the focus request to attachment
//  instead: viewDidMoveToWindow() requests focus the first time the
//  field lands in a non-nil window, and never again on later
//  re-attachments.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class InlineEditorTextFieldTests: XCTestCase {

    // MARK: - Fixtures

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Tests

    /// Attaching the field to a window is what must trigger the focus
    /// request, not a fixed delay measured from creation: spinning
    /// before attachment must let any time-based focus request fire and
    /// do nothing, then attaching must still take focus.
    func test_attachedAfterCreation_takesFocusOnAttach() {
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)

        let field = InlineEditorTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "abc"

        spin(0.05)
        XCTAssertNil(field.currentEditor(),
                     "before attachment, no focus request must have taken effect")

        window.contentView?.addSubview(field)
        spin(0.05)

        XCTAssertNotNil(field.currentEditor(),
                        "attaching to a window must request focus")
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === field,
                      "the window's field editor must be installed for this field")
        XCTAssertEqual((field.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: 3),
                       "focus must select the field's entire text")
    }

    /// Focus is requested only on the field's first attachment: removing
    /// first responder status and re-attaching the field must not
    /// re-trigger the focus request.
    func test_reattach_doesNotRetakeFocus() {
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)

        let field = InlineEditorTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "abc"

        window.contentView?.addSubview(field)
        spin(0.05)
        XCTAssertNotNil(field.currentEditor(), "first attachment must take focus")

        window.makeFirstResponder(nil)
        XCTAssertNil(field.currentEditor(), "resigning first responder must clear the field's editor")

        field.removeFromSuperview()
        window.contentView?.addSubview(field)
        spin(0.05)

        XCTAssertNil(field.currentEditor(),
                     "re-attachment must not re-request focus after the first attachment already did")
    }

    /// A field that is never attached to a window must never crash and
    /// must never take focus, however long it spins.
    func test_detachedField_neverRequestsFocus() {
        let field = InlineEditorTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "abc"

        spin(0.1)

        XCTAssertNil(field.currentEditor(), "a never-attached field must never take focus")
        XCTAssertNil(field.window, "a never-attached field must have no window")
    }
}
