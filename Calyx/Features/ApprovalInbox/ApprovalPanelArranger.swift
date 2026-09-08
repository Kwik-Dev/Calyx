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
// WINDOW -- the window is `gutter` points larger on EVERY side, an
// ordinary transparent margin that lets the dismiss button's circle
// straddle the sheet's own top-left corner and gives the sheet's own
// soft shadow (`ApprovalPanelContentView.glassWrapped(request:)`) room
// to blur outward on every edge without getting clipped by the window's
// own frame. `windowFrame(sheetSize:visibleFrame:margin:)` is the one
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
    /// The transparent gutter the WINDOW carries beyond the glass sheet,
    /// UNIFORMLY on all four sides -- lets the dismiss button's 20pt
    /// circle straddle the sheet's own top-left corner (its center at
    /// `(sheet.minX + 4, sheet.top + 5)`, 6pt of the disc left of the
    /// sheet and 5pt above it, so part of the disc lies outside the
    /// painted sheet, into the corner's own 20pt rounded-corner cutout)
    /// while still drawing and hit-testing, since a window clips
    /// everything outside its own frame, and gives the sheet's own soft
    /// shadow room to blur outward without clipping on any edge.
    ///
    /// Set equal to `margin` so the window's own top and right edges
    /// land exactly on `visibleFrame`'s own top and right edges
    /// (`windowFrame(sheetSize:visibleFrame:margin:)`'s `maxX`/`maxY` doc
    /// comments below derive this: the `-margin` the sheet is inset by
    /// and the `+gutter` the window is enlarged by cancel exactly) -- a
    /// gutter any larger would push the window's top edge above the
    /// visible frame, under the menu bar.
    static let gutter: CGFloat = margin

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
    /// sheet itself, and this function enlarges that rect by `gutter` on
    /// EVERY side -- window width = `sheetSize.width + 2*gutter`, height
    /// = `sheetSize.height + 2*gutter`, right edge (`maxX`) =
    /// `visibleFrame.maxX - margin + gutter`, top edge (`maxY`) =
    /// `visibleFrame.maxY - margin + gutter`. Since `gutter` is defined
    /// as `margin`, both reduce to exactly `visibleFrame.maxX`/`maxY` --
    /// the window's own top and right edges land on the visible frame's
    /// own top and right edges, with the sheet itself still inset
    /// `margin` inside them.
    static func windowFrame(sheetSize: CGSize, visibleFrame: NSRect, margin: CGFloat = margin) -> NSRect {
        let sheet = anchor(size: sheetSize, visibleFrame: visibleFrame, margin: margin)
        return NSRect(
            x: sheet.minX - gutter,
            y: sheet.minY - gutter,
            width: sheet.width + (2 * gutter),
            height: sheet.height + (2 * gutter)
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
