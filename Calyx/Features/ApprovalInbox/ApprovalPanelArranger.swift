// ApprovalPanelArranger.swift
// Calyx
//
// Pure geometry for the single, app-wide floating approval panel
// (`ApprovalPanelWindow`, driven by `ApprovalPanelController`): top-right
// anchoring, and width/height clamping against a screen's `visibleFrame`.
// One page-style panel for the whole app -- there is never more than one
// to position, so there is no stacking to compute. `nonisolated`, no
// AppKit window state, so every function here is exact arithmetic
// testable without touching a real window.
//
// See CalyxTests/ApprovalInbox/ApprovalPanelArrangerTests.swift for the
// specced contract.

import Foundation
import AppKit

nonisolated enum ApprovalPanelArranger {
    /// Inset, in points, from both the right and top edges of a
    /// screen's `visibleFrame`.
    static let margin: CGFloat = 12
    /// The narrowest a panel may ever be, regardless of its content's
    /// own ideal width.
    static let minimumWidth: CGFloat = 360

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

    /// Clamps `ideal` into `[minimum, cap]`, where `cap` is
    /// `visibleFrame.width - 2*margin`. When `cap` itself falls below
    /// `minimum` (a narrow screen), `cap` wins: a panel can never be
    /// wider than the available space no matter how small that space is.
    static func clampWidth(ideal: CGFloat, minimum: CGFloat = minimumWidth, visibleFrame: NSRect, margin: CGFloat = margin) -> CGFloat {
        let cap = visibleFrame.width - (2 * margin)
        let effectiveMinimum = min(minimum, cap)
        return max(effectiveMinimum, min(ideal, cap))
    }

    /// The height a panel's content may grow to before it must scroll:
    /// `visibleFrame.height - 2*margin`.
    static func heightCap(visibleFrame: NSRect, margin: CGFloat = margin) -> CGFloat {
        visibleFrame.height - (2 * margin)
    }
}
