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
    static let fixedWidth: CGFloat = 380
    /// The panel's width when the displayed request wants inline option
    /// rows (`ApprovalRequest.prefersWideApprovalPanel`) -- wide enough
    /// for the option list and its markdown preview box to each keep a
    /// readable minimum width side by side.
    static let wideWidth: CGFloat = 640

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
