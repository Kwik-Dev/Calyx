// AssumeInsideHover.swift
// Calyx
//
// NSTrackingArea-based hover that detects cursor already inside on view creation.
// Fixes SwiftUI .onHover not firing when a view appears under a stationary cursor.

import AppKit
import SwiftUI

struct AssumeInsideHover: NSViewRepresentable {
    @Binding var isHovering: Bool
    /// Bumped by a caller to request a fresh `reportPointerInside()` check
    /// outside a bounds change or a real `mouseEntered`/`mouseExited`
    /// event -- see `updateNSView(_:context:)`'s own doc comment. `0` by
    /// default, so a caller that never changes it (every hover site
    /// outside the approval panel) never triggers a recheck here, the
    /// same no-op `updateNSView` left in place before this existed.
    var recheckToken: Int = 0

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.lastHandledToken = recheckToken
        view.onHoverChanged = { [self] hovering in
            DispatchQueue.main.async { isHovering = hovering }
        }
        return view
    }

    /// Re-runs `reportPointerInside()` only when `recheckToken` differs
    /// from the token this view last handled -- NOT on every SwiftUI
    /// update. A mouse-exited event fired through the sheet's own
    /// rounded-corner cutout (outside the painted shape but still inside
    /// this view's rectangular `bounds`) must stay exited: rechecking on
    /// every update would see that cutout point as "inside" again and
    /// immediately re-report `true`, a stuck hover that never receives a
    /// correcting event once the pointer has left the window entirely.
    /// The pointer position only needs re-evaluating when a HIDDEN window
    /// can have missed real enter/exit events while it was not visible --
    /// `ApprovalPanelController.render()` bumps
    /// `ApprovalPanelLayout.hoverRecheckToken` exactly at that point, each
    /// time the panel is ordered front.
    func updateNSView(_ nsView: TrackingView, context: Context) {
        guard nsView.lastHandledToken != recheckToken else { return }
        nsView.lastHandledToken = recheckToken
        nsView.reportPointerInside()
    }

    final class TrackingView: NSView {
        var onHoverChanged: ((Bool) -> Void)?
        /// The last `recheckToken` this view has already handled -- see
        /// `updateNSView(_:context:)`'s own doc comment.
        fileprivate var lastHandledToken: Int = 0

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            // A non-activating panel (the floating approval panel) never
            // becomes key, so `.activeInKeyWindow` would never fire there;
            // every other window uses `.activeInKeyWindow`, since a
            // sidebar/tab-bar hover state is meaningless for a background
            // window.
            let activeOptions: NSTrackingArea.Options =
                window?.styleMask.contains(.nonactivatingPanel) == true ? .activeAlways : .activeInKeyWindow
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, activeOptions, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)

            reportPointerInside()
        }

        /// Whether `window.mouseLocationOutsideOfEventStream`, converted
        /// into this view's own coordinates, falls inside `bounds` --
        /// unconditionally dispatched through `onHoverChanged`. A no-op
        /// while `window` is nil (the view has not yet been installed).
        fileprivate func reportPointerInside() {
            guard let window else { return }
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            let mouseInView = convert(mouseInWindow, from: nil)
            let inside = bounds.contains(mouseInView)
            onHoverChanged?(inside)
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }
    }
}

extension View {
    func onAssumeInsideHover(_ isHovering: Binding<Bool>, recheckToken: Int = 0) -> some View {
        background(AssumeInsideHover(isHovering: isHovering, recheckToken: recheckToken))
    }
}
