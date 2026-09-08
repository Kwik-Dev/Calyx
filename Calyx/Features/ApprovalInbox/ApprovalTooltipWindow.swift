// ApprovalTooltipWindow.swift
// Calyx
//
// A Calyx-drawn replacement for AppKit's own `.help` tooltip, used by
// `ExpandableBodyText` inside the floating `ApprovalPanelWindow` and by
// `ApprovalPanelContentView`'s own disabled dismiss button. AppKit's
// tooltip is armed only when the first cursor registration on a window
// lands on the tooltip's own view; a pointer that enters
// `ApprovalPanelWindow` elsewhere (e.g. over the Allow button) and then
// slides onto the payload text never triggers that registration, so the
// system tooltip never appears. This window reproduces the native
// tooltip's own look (dark appearance, 1x) under Calyx's own control
// instead: shown/hidden explicitly by `ApprovalTooltipPresenter`.
//
// Non-activating, click-through, and always above the approval panel's
// own floating level -- a tooltip never takes any input of its own and
// must never itself become key or main.

import AppKit
import SwiftUI

final class ApprovalTooltipWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        isRestorable = false
        // The approval panel this tooltip serves must keep working while
        // Calyx is not the active app (ApprovalPanelWindow.hidesOnDeactivate's
        // own doc comment) -- NSPanel defaults this to true, which would
        // hide an already-shown tooltip the instant Calyx deactivates.
        hidesOnDeactivate = false
        identifier = NSUserInterfaceItemIdentifier("com.calyx.approvalTooltip")
    }
}

/// The tooltip's own drawn content: a single, possibly wrapped line of
/// text inside a two-line box (an outer 1pt border, an inner 1pt line,
/// then the fill), matching macOS's own native tooltip. Square corners,
/// no shadow -- `ApprovalTooltipWindow` itself carries none either.
///
/// Dark appearance, 1x: border `NSColor(white: 68/255)`, inner line
/// `NSColor(white: 42/255)`, fill `NSColor(white: 35/255)`, text
/// `NSFont.toolTipsFont(ofSize: 11)` in `NSColor(white: 233/255)`. For
/// "echo HOVER_MARKER" (118.7pt wide text) the native box is 132x19pt,
/// giving insets (inside the two 1pt lines) of top 0, leading 4, bottom
/// 1, trailing 5 -- the native box's own top inset is tighter than its
/// bottom one, not symmetric. Light appearance values match the
/// standard macOS light tooltip look rather than a native sample:
/// border `NSColor(white: 199/255)`, inner line `NSColor(white:
/// 250/255)`, fill `NSColor(white: 245/255)`, text `NSColor(white:
/// 30/255)`.
struct ApprovalTooltipContent: View {
    let text: String

    var body: some View {
        // Three concentric bands, outside in: a 1pt border, a 1pt inner
        // line, then the fill holding the text at its own insets --
        // built as nested padding + background rather than overlaid
        // strokes, so each band is a true separate ring rather than one
        // drawn on top of another (`Rectangle().strokeBorder` centers on
        // the current bounds' own edge, which would overlap the fill by
        // 1pt instead of sitting outside it). No `.frame(maxWidth:)`
        // here: a max-only flexible frame fills its own PROPOSAL up to
        // that max (the same mechanism `.frame(maxWidth: .infinity)`
        // uses to fill), which would measure every tooltip at the full
        // 400pt regardless of the text's own length -- the 400pt wrap
        // cap is instead enforced by the PROPOSAL `ApprovalTooltipPresenter
        // .show(text:at:)` passes to `sizeThatFits(in:)`
        // (`maxTextWidth + Self.chromeWidth`), so `Text` measures its
        // own true width up to that cap and only wraps once it exceeds
        // it. No `.frame(maxHeight:)` either, for the equivalent reason
        // on the vertical axis: a `.frame(maxHeight:)` node, queried with
        // the unconstrained height proposal `ApprovalTooltipPresenter
        // .measureContentSize(text:)` uses, reports its own `maxHeight`
        // value directly rather than the child's smaller natural size --
        // confirmed by a failing measurement test, not a documentation
        // inference. The height cap for an oversized text is therefore
        // applied in `ApprovalTooltipPresenter.show(text:at:)` itself,
        // in plain Swift arithmetic on the already-measured natural
        // size, and the window (a hard clip boundary macOS itself
        // enforces at the compositor level) is what keeps any content
        // taller than that cap from drawing past its own frame.
        Text(text)
            .font(Font(NSFont.toolTipsFont(ofSize: 11)))
            .foregroundStyle(Color(nsColor: Self.textColor))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.tooltip)
            .padding(EdgeInsets(top: 0, leading: 4, bottom: 1, trailing: 5))
            .background(Color(nsColor: Self.fillColor))
            .padding(1)
            .background(Color(nsColor: Self.innerLineColor))
            .padding(1)
            .background(Color(nsColor: Self.borderColor))
    }

    /// The text's own layout box wraps at 400pt -- the box measured for
    /// "echo HOVER_MARKER" (132pt, well under this cap) never wraps.
    static let maxTextWidth: CGFloat = 400

    /// The two 1pt lines (2pt each side, 4pt total on each axis) plus
    /// the insets' own non-text-hugging margin (leading 4 + trailing 5
    /// horizontally; top 1 + bottom 1 vertically) -- the total the
    /// measurement proposal in `ApprovalTooltipPresenter.show(text:at:)`
    /// must add on top of `maxTextWidth` so `Text` itself still sees a
    /// 400pt-wide proposal to wrap against, not a narrower one that
    /// already has this chrome subtracted out of it.
    static let chromeWidth: CGFloat = 13

    private static let borderColor = NSColor.dynamic(
        dark: NSColor(white: 68.0 / 255.0, alpha: 1),
        light: NSColor(white: 199.0 / 255.0, alpha: 1)
    )
    private static let innerLineColor = NSColor.dynamic(
        dark: NSColor(white: 42.0 / 255.0, alpha: 1),
        light: NSColor(white: 250.0 / 255.0, alpha: 1)
    )
    private static let fillColor = NSColor.dynamic(
        dark: NSColor(white: 35.0 / 255.0, alpha: 1),
        light: NSColor(white: 245.0 / 255.0, alpha: 1)
    )
    private static let textColor = NSColor.dynamic(
        dark: NSColor(white: 233.0 / 255.0, alpha: 1),
        light: NSColor(white: 30.0 / 255.0, alpha: 1)
    )
}
