// ApprovalPanelArranger.swift
// Calyx
//
// Pure geometry for the single, app-wide floating approval panel
// (`ApprovalPanelWindow`, driven by `ApprovalPanelController`): top-right
// anchoring, and a height-clamped panel against a screen's
// `visibleFrame`. The panel is a macOS-notification-style shell -- one
// of exactly two fixed widths (`fixedWidth`/`wideWidth`, see
// `panelWidth(for:visibleFrame:margin:)`), never measured from content
// -- so there is no ideal-width measurement here, only a cap for a
// screen too narrow to fit whichever of the two the displayed request
// wants. One page-style panel for the whole app -- there is never more
// than one to position, so there is no stacking to compute.
// `nonisolated`, no AppKit window state, so every function here is
// exact arithmetic testable without touching a real window.
//
// `fixedWidth`/`wideWidth`/`heightCap` describe the glass SHEET
// (`ApprovalPanelContentView`'s `.glassEffect` rounded rect), never the
// WINDOW -- the window is `dismissGutter` points larger on its top and
// left sides, an ordinary transparent gutter that lets the dismiss
// button's circle draw and hit-test outside the sheet's own top-left
// corner. `windowFrame(sheetSize:visibleFrame:margin:)` is the one
// function that accounts for that gutter, converting a measured SHEET
// size into the WINDOW's own frame; `anchor(size:visibleFrame:margin:)`
// stays gutter-agnostic pure top-right anchoring for any other caller.
//
// See CalyxTests/ApprovalInbox/ApprovalPanelArrangerTests.swift for the
// specced contract.

import Foundation
import AppKit

nonisolated enum ApprovalPanelArranger {
    /// Inset, in points, from both the right and top edges of a
    /// screen's `visibleFrame`.
    static let margin: CGFloat = 12
    /// The panel's own default fixed width, mirroring a macOS
    /// notification banner's shell.
    static let fixedWidth: CGFloat = 344
    /// The panel's width when the displayed request wants inline option
    /// rows (`ApprovalRequest.prefersWideApprovalPanel`) -- wide enough
    /// for the option list and its markdown preview box to each keep a
    /// readable minimum width side by side.
    static let wideWidth: CGFloat = 640
    /// The transparent gutter the WINDOW carries beyond the glass sheet
    /// on its top and left sides only -- lets the dismiss button's 22pt
    /// circle straddle the sheet's own top-left corner (its center at
    /// `(sheet.minX + 3, sheet.top + 7)`, 8pt of the disc left of the
    /// sheet and 4pt above it, so most of the disc lies outside the
    /// painted sheet, into the corner's own 20pt rounded-corner cutout)
    /// while still drawing and hit-testing, since a window clips
    /// everything outside its own frame. No gutter on the bottom or
    /// right: the sheet's own bottom-right corner still meets the
    /// window's own bottom-right corner exactly, as it did before this
    /// gutter existed.
    ///
    /// Set equal to `margin` so the window's own top edge lands exactly
    /// on `visibleFrame`'s own top edge (`windowFrame(sheetSize:visibleFrame:margin:)`'s
    /// `maxY` doc comment below derives this) -- a gutter any larger
    /// would push the window's top edge above the visible frame, under
    /// the menu bar.
    static let dismissGutter: CGFloat = margin

    /// The top-right corner of `visibleFrame`, inset by `margin` on both
    /// axes, sized to `size`.
    static func anchor(size: CGSize, visibleFrame: NSRect, margin: CGFloat = margin) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - margin - size.width,
            y: visibleFrame.maxY - margin - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The WINDOW's own frame for a glass sheet measuring `sheetSize`,
    /// built on `anchor(size:visibleFrame:margin:)` so the SHEET's own
    /// anchoring rule (top-right corner, `margin` inside `visibleFrame`
    /// on both axes) exists in exactly one place: `anchor` places the
    /// sheet itself, and this function enlarges that rect by
    /// `dismissGutter` on the top and left only (the gutter sits there
    /// alone, so the sheet's own right and bottom edges still meet the
    /// window's own right and bottom edges exactly) -- window width =
    /// `sheetSize.width + dismissGutter`, height = `sheetSize.height +
    /// dismissGutter`, right edge (`maxX`) = `visibleFrame.maxX - margin`
    /// (unaffected, since the gutter never sits on the right), top edge
    /// (`maxY`) = `visibleFrame.maxY - margin + dismissGutter`. Since
    /// `dismissGutter` is defined as `margin`, that top edge reduces to
    /// exactly `visibleFrame.maxY` -- the window's own top edge lands on
    /// the visible frame's own top edge.
    static func windowFrame(sheetSize: CGSize, visibleFrame: NSRect, margin: CGFloat = margin) -> NSRect {
        let sheet = anchor(size: sheetSize, visibleFrame: visibleFrame, margin: margin)
        return NSRect(
            x: sheet.minX - dismissGutter,
            y: sheet.minY,
            width: sheet.width + dismissGutter,
            height: sheet.height + dismissGutter
        )
    }

    /// `wideWidth` for a request whose displayed prompt wants inline
    /// option rows (`ApprovalRequest.prefersWideApprovalPanel`), else
    /// `fixedWidth`, either way clamped down to `visibleFrame.width -
    /// 2*margin` when that cap itself falls below the desired width (a
    /// narrow screen) -- a panel can never be wider than the available
    /// space no matter how small that space is. `request` is `nil` while
    /// nothing is pending, in which case this reads identically to
    /// `fixedWidth`, clamped the same way.
    static func panelWidth(for request: ApprovalRequest?, visibleFrame: NSRect, margin: CGFloat = margin) -> CGFloat {
        let cap = visibleFrame.width - (2 * margin)
        let desiredWidth = (request?.prefersWideApprovalPanel == true) ? wideWidth : fixedWidth
        return min(desiredWidth, cap)
    }

    /// The height a panel's content may grow to before it must scroll:
    /// `visibleFrame.height - 2*margin`.
    static func heightCap(visibleFrame: NSRect, margin: CGFloat = margin) -> CGFloat {
        visibleFrame.height - (2 * margin)
    }
}
