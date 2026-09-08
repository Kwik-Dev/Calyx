// ApprovalPanelContentView.swift
// Calyx
//
// SwiftUI content of the floating `ApprovalPanelWindow`: hosts
// `ApprovalBannerView` inside a vertically scrolling, width-clamped
// glass container, independent of `MainContentView`'s own
// `safeAreaInset`.
//
// Reads `model.current` directly in `body` (not threaded in as a
// parameter): `selectNext()`/`selectPrevious()` mutate
// `ApprovalBannerModel`'s `@Observable` state without posting an
// explicit change notification, relying on whichever view reads
// `current` inside its own `body` to re-render (see `selectNext()`'s own
// doc comment in ApprovalBannerModel.swift) -- this view is that reader.
//
// The root shape -- `ScrollView` clamped to `layout.heightCap +
// 2*gutter`, `.fixedSize(horizontal: false, vertical: true)` before
// `.frame(width: layout.width + 2*gutter)` -- now spans the SHEET plus
// `ApprovalPanelArranger.gutter` on EVERY axis, UNIFORMLY (see the
// dismiss-button paragraph below for why the gutter has to live INSIDE
// the `ScrollView` at all, and `ApprovalPanelWindow`'s own header for why
// the gutter is uniform rather than top/left-only now). The
// `onGeometryChange` that reports content height to
// `onContentSizeChange` stays attached to `glassWrapped(request:)`
// itself, the pre-padding, pre-gutter node, so it still reports the
// SHEET's own size for the displayed request (`layout.width`, one of
// `ApprovalPanelArranger.fixedWidth`/`wideWidth`, never measured from
// content itself, see `ApprovalPanelArranger.panelWidth(for:
// visibleFrame:)`), matching what
// `ApprovalPanelController.measureFrame(hostingController:)` expects
// back through `applyContentHeight(_:)`; the `gutter` padding (all four
// sides) is applied AFTER that node, inside the `ScrollView`, so
// `NSHostingController.sizeThatFits(in:)` -- which measures the WHOLE
// content view -- still sees the same gutter-inflated total it always
// did, just assembled inside the `ScrollView` now instead of outside it.
//
// The dismiss button (`dismissButton`, `isPanelHovered`) lives HERE, not
// on `ApprovalBannerView`'s own root, but it is applied as an
// `.overlay` INSIDE `glassWrapped(request:)`'s own `GlassEffectContainer`
// (on `ApprovalBannerView` itself, before `.id(request.id)`) -- see the
// z-order paragraph below for why it has to sit there rather than
// outside the container. A `ScrollView` clips its content to its own
// bounds, so the gutter the × straddles into must be PART of that
// content, not outside it: the `ScrollView`'s own frame is therefore
// widened by `gutter` on every axis (above), and `glassWrapped(request:)`'s
// own `gutter` padding (all four sides, applied at the call site in
// `body`) centers the sheet -- × included, since it travels with it as
// an overlay -- inside that widened frame, leaving exactly `gutter` of
// transparent, still-in-bounds space on every side. All four gutters
// stay unpainted (`ApprovalPanelWindow` is non-opaque, so the window
// server routes a click there to whatever window sits behind the panel,
// not the panel itself) -- the top and left ones also give the dismiss
// disc room to straddle the sheet's own top-left corner without getting
// clipped.
//
// Z-order: a view's Liquid Glass content -- anything placed INSIDE a
// `GlassEffectContainer`'s own content closure -- composites ABOVE that
// container's glass background; a view placed OUTSIDE the container (a
// sibling `.overlay` on the container itself, even a later, "higher" one
// in SwiftUI's own declaration order) composites BENEATH it instead
// (confirmed by screenshot across two failed attempts: field-verified,
// not a documentation inference -- an `.overlay` on the container drew
// only the sliver of the × outside the sheet's own corner, and a plain-
// color disc in that same position drew nothing at all). The × is
// therefore inside `glassWrapped(request:)`'s `GlassEffectContainer`
// content, alongside `ApprovalBannerView`, not on the `ScrollView`
// around it. It is drawn with PLAIN colors (`Circle().fill(...)`/
// `.strokeBorder(...)`), not `.glassEffect`/`.thinMaterial`/any other
// backdrop-based fill, so it does not blend with the container's own
// glass background the way a second glass shape sharing that container
// would.
//
// `ApprovalPanelWindow` is non-opaque with a `.clear` background, so the
// window server delivers mouse events only over painted pixels -- the
// gutter itself is unpainted (transparent) except for the × once shown,
// so hover tracking cannot be attached to the padded root (see
// `isPanelHovered`'s own doc comment for the two regions actually
// tracked, and why).
//
// Glass: the panel uses the same untinted regular glass as macOS
// notification banners, independent of the Calyx theme -- a `Color.clear`
// `.glassEffect(.regular, in: .rect(cornerRadius: 20))` behind the
// content. The `reduceTransparency` path fills the same rounded rect with
// `.windowBackgroundColor` instead. No theme-color tint, no atmosphere
// layer, no inactive-window dimming: unlike the main window, this panel
// never reads the Calyx theme at all.
//
// Rim: `ApprovalPanelWindow.hasShadow` is `false` (see that file's own
// header for why) and this sheet draws no shadow of its own either -- a
// drawn shadow would paint pixels into the transparent gutter, and
// `ApprovalPanelWindow` routes a click by pixel alpha, so a painted
// gutter would capture a click meant for whatever window sits behind
// the panel instead of passing it through. The sheet draws only its OWN
// 1pt rim -- a `strokeBorder` on TOP of the glass fill, at the SAME 20pt
// corner radius as the glass shape -- so it still reads as a distinct
// surface without the system shadow's own outline. The
// `reduceTransparency` path keeps the same rim on top of its solid fill.
// `.rect(cornerRadius: 20)`/`RoundedRectangle(cornerRadius: 20)` is
// therefore the panel's entire visible outline in every appearance and
// every `reduceTransparency` state alike -- `ApprovalPanelWindow` itself
// carries no shadow or outline of its own at all.

import SwiftUI
import AppKit

struct ApprovalPanelContentView: View {
    let model: ApprovalBannerModel
    let layout: ApprovalPanelLayout
    /// `ApprovalBannerView.targetLabel`'s own source for a surface-
    /// targeted request -- see `ApprovalPanelController`'s own stored
    /// property of the same name for the full chain.
    let targetTabTitle: (UUID) -> String?
    /// Handed to `ExpandableBodyText` (through `AgentQuestionBannerView`/
    /// `ApprovalBannerView`) via `\.approvalTooltipPresenter` -- see
    /// `ApprovalTooltipPresenter`'s own header.
    let tooltipPresenter: ApprovalTooltipPresenter
    let onContentSizeChange: (CGSize) -> Void
    let onRequestChange: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Whether the pointer is over the glass sheet itself
    /// (`sheetHovered`) or over the painted dismiss button
    /// (`dismissButtonHovered`) -- `ApprovalPanelWindow` is non-opaque
    /// with a `.clear` background, so the window server delivers mouse
    /// events only over painted pixels: the transparent gutter never
    /// receives one (except over the × once it is shown), so tracking a
    /// single region spanning the padded root (gutter included) would
    /// never see the pointer enter that gutter at all. Two separate
    /// `onAssumeInsideHover` calls instead, one on the sheet itself
    /// (`glassWrapped(request:)`'s own node at the `body` call site,
    /// always painted -- NOT the `ScrollView` around it, which now also
    /// spans the gutter) and one on the dismiss button itself (painted
    /// only once `isPanelHovered` is already true) --
    /// moving the pointer FROM the sheet ONTO the now-painted × keeps the
    /// × shown (`dismissButtonHovered` picks up where `sheetHovered` left
    /// off); moving it outward, off both regions, hides it. Before the ×
    /// is ever painted the button's own tracking view is itself
    /// unpainted, so it cannot be the FIRST region the pointer enters --
    /// only the sheet can arm the hover from a cold start. Both calls
    /// pass `layout.hoverRecheckToken` as `recheckToken`, so a pointer
    /// position missed while the panel was hidden is re-evaluated once
    /// the panel is ordered front again -- see `AssumeInsideHover
    /// .updateNSView(_:context:)`'s own doc comment for why that recheck
    /// must be token-gated rather than run on every SwiftUI update.
    @State private var sheetHovered = false
    @State private var dismissButtonHovered = false

    private var isPanelHovered: Bool { sheetHovered || dismissButtonHovered }

    var body: some View {
        Group {
            if let request = model.current {
                ScrollView(.vertical) {
                    glassWrapped(request: request)
                        .onAssumeInsideHover($sheetHovered, recheckToken: layout.hoverRecheckToken)
                        .onGeometryChange(for: CGSize.self) { proxy in
                            proxy.size
                        } action: { size in
                            Task { @MainActor in
                                onContentSizeChange(size)
                            }
                        }
                        .padding(ApprovalPanelArranger.gutter)
                }
                .frame(maxHeight: layout.heightCap + (2 * ApprovalPanelArranger.gutter))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: layout.width + (2 * ApprovalPanelArranger.gutter))
                .onChange(of: request.id) {
                    Task { @MainActor in
                        onRequestChange()
                    }
                }
            } else {
                EmptyView()
            }
        }
        .environment(\.approvalTooltipPresenter, tooltipPresenter)
    }

    /// The panel's own top-left ×, styled like a macOS notification's
    /// own dismiss control -- "Calyx does not answer this request",
    /// applying to every `request.source` alike, but only ACTIONABLE
    /// while `request.isDismissible` (see that property's own doc
    /// comment): someone other than Calyx -- that request's own CLI, or
    /// the calling MCP agent -- must still be able to decide it once
    /// Calyx declines to. For a non-dismissible request (grok/pi, whose
    /// gate is their own only prompt), the button stays in the SAME spot
    /// rather than disappearing (`.disabled(true)`, its glyph greyed to
    /// `.tertiary`), with an accessibility hint explaining why and, on
    /// hover, the same Calyx-drawn tooltip `ExpandableBodyText` uses
    /// (`glassWrapped(request:)`'s own `onChange(of: dismissButtonHovered)`
    /// calls `tooltipPresenter.scheduleShow(text:)`/`.hide()` directly --
    /// `ApprovalPanelWindow` never becomes key on hover, so AppKit's own
    /// `.help` tooltip would never arm here either) -- never a caption
    /// under the body, which would shift every OTHER source's layout
    /// too. `dismissButton` identifies both states alike, so a test can
    /// assert `isEnabled` directly.
    ///
    /// A 20pt circle whose center sits at `(sheet.minX + 4, sheet.top +
    /// 5)` -- matching a 1x pixel dump of macOS's own native notification
    /// × placement. `glassWrapped(request:)`'s own `.overlay(alignment:
    /// .topLeading)` places the button's own top-left corner AT the
    /// sheet's (`ApprovalBannerView`'s, the overlay's base), and the
    /// `.offset(x: -6, y: -5)` there then shifts it there (the circle's
    /// own top-left corner, 10pt above and left of its center, lands at
    /// `4 - 10 = -6` and `5 - 10 = -5`).
    ///
    /// The disc is drawn OPAQUE (`discFillColor`, `41/255` white in dark
    /// appearance) so it keeps its own contrast against the translucent
    /// sheet over any background, with a faint 1pt INNER highlight
    /// (`discInnerHighlightColor`) just inside its own edge -- matching a
    /// macOS notification's own ×, which reads as a separate, physically
    /// distinct control rather than a tinted region of the sheet itself.
    ///
    /// Show-on-hover (`isPanelHovered`) fades the fill/highlight/glyph
    /// via `.clear` rather than `.opacity`: `.opacity` also zeroes the
    /// element's accessibility geometry, which would remove the button
    /// from hit-testing and from assistive technology entirely. Color
    /// alpha leaves the `Button`'s layout frame, and therefore its
    /// accessibility geometry and SwiftUI hit-testing, untouched. One
    /// layer below SwiftUI, `ApprovalPanelWindow`'s own `isOpaque = false`
    /// means the WINDOW SERVER routes a click by the pixel's own alpha,
    /// not by SwiftUI's hit-testing tree -- while hidden, every layer
    /// here is `.clear`, so a click landing on the button before any
    /// hover has painted it opaque falls through to whatever is behind
    /// the panel instead of reaching this `Button` at all. The button is
    /// only actually clickable once `isPanelHovered` has painted it in,
    /// which is also the only state a sighted user could see it in.
    @ViewBuilder
    private func dismissButton(request: ApprovalRequest) -> some View {
        let fillStyle: AnyShapeStyle = isPanelHovered
            ? AnyShapeStyle(Self.discFillColor)
            : AnyShapeStyle(.clear)
        let innerHighlightStyle: AnyShapeStyle = isPanelHovered
            ? AnyShapeStyle(Self.discInnerHighlightColor)
            : AnyShapeStyle(.clear)
        let glyphOpacity: Double = request.isDismissible ? 1 : 0.4
        let glyphStyle: AnyShapeStyle = isPanelHovered
            ? AnyShapeStyle(Self.discGlyphColor.opacity(glyphOpacity))
            : AnyShapeStyle(.clear)

        let button = Button(action: { model.dismiss(id: request.id) }) {
            Circle()
                .fill(fillStyle)
                .overlay(Circle().strokeBorder(innerHighlightStyle, lineWidth: 1))
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(glyphStyle)
                }
                .frame(width: 20, height: 20)
                .animation(.easeInOut(duration: 0.15), value: isPanelHovered)
        }
        .buttonStyle(.plain)
        .disabled(!request.isDismissible)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.dismissButton)
        .accessibilityLabel("Dismiss")

        if request.isDismissible {
            button
        } else {
            button
                .accessibilityHint(Self.notDismissibleHint)
        }
    }

    /// `dismissButton(request:)`'s own tooltip/accessibility hint for a
    /// non-dismissible (grok/pi) request.
    private static let notDismissibleHint = "This CLI has no prompt of its own; choose Allow or an option here."

    /// `dismissButton(request:)`'s own opaque disc fill, matching a 1x
    /// pixel dump of macOS's own native notification × values:
    /// `NSColor(white: 41/255, alpha: 1)` in dark appearance, `NSColor
    /// (white: 0.93, alpha: 1)` in light. An `NSColor(name:content:)`
    /// dynamic provider, not a `@Environment(\.colorScheme)` read, so it
    /// resolves against whatever `NSAppearance` is actually active for
    /// this view at draw time (including an app-wide override), the same
    /// mechanism `.windowBackgroundColor`/`.separatorColor` elsewhere in
    /// this file already rely on.
    private static let discFillColor = Color(nsColor: .dynamic(
        dark: NSColor(white: 41.0 / 255.0, alpha: 1),
        light: NSColor(white: 0.93, alpha: 1)
    ))

    /// `dismissButton(request:)`'s own 1pt inner highlight, drawn just
    /// inside the fill's own edge: `Color.white.opacity(0.06)` in dark
    /// appearance, `Color.black.opacity(0.08)` in light.
    private static let discInnerHighlightColor = Color(nsColor: .dynamic(
        dark: NSColor.white.withAlphaComponent(0.06),
        light: NSColor.black.withAlphaComponent(0.08)
    ))

    /// `dismissButton(request:)`'s own glyph color before the
    /// non-dismissible `glyphOpacity` multiplier: `Color.white.opacity
    /// (0.58)` in dark appearance, `Color.black.opacity(0.6)` in light.
    private static let discGlyphColor = Color(nsColor: .dynamic(
        dark: NSColor.white.withAlphaComponent(0.58),
        light: NSColor.black.withAlphaComponent(0.6)
    ))

    /// `glassWrapped(request:)`'s own 1pt rim, drawn on top of the glass
    /// (or `reduceTransparency` solid) fill: `Color.white.opacity(0.07)`
    /// in dark appearance, `Color.black.opacity(0.10)` in light -- the
    /// sheet's own substitute for the system window shadow's rim, now
    /// that `ApprovalPanelWindow.hasShadow` is `false`.
    private static let rimColor = Color(nsColor: .dynamic(
        dark: NSColor.white.withAlphaComponent(0.07),
        light: NSColor.black.withAlphaComponent(0.10)
    ))

    /// `layout.hostWindowController?.activeTabDisplayTitle` (its active
    /// tab's own title) falling back to the window's own `title`, then to
    /// "Calyx" while no host is designated -- both reads go through
    /// `layout`, an `@Observable` reference this view tracks directly, so
    /// SwiftUI re-renders both when the designated host WINDOW changes
    /// (`layout.hostWindowController` reassigned by `ApprovalPanelController
    /// .render()`) and when its active tab is renamed in place (`Tab.
    /// displayTitle`, itself `@Observable`, read through that same
    /// reference).
    private func glassWrapped(request: ApprovalRequest) -> some View {
        let title = layout.hostWindowController?.activeTabDisplayTitle
            ?? layout.hostWindowController?.window?.title
            ?? "Calyx"
        return GlassEffectContainer {
            ApprovalBannerView(
                model: model, request: request,
                hostWindowTitle: ControlCharacterDisplay.render(title), targetTabTitle: targetTabTitle
            )
            .overlay(alignment: .topLeading) {
                dismissButton(request: request)
                    .onAssumeInsideHover($dismissButtonHovered, recheckToken: layout.hoverRecheckToken)
                    .offset(x: -6, y: -5)
            }
            .onChange(of: dismissButtonHovered) {
                guard !request.isDismissible else { return }
                if dismissButtonHovered {
                    tooltipPresenter.scheduleShow(text: Self.notDismissibleHint)
                } else {
                    tooltipPresenter.hide()
                }
            }
            .id(request.id)
        }
        .background {
            ZStack {
                Group {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .windowBackgroundColor))
                    } else {
                        Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                }
                RoundedRectangle(cornerRadius: 20).strokeBorder(Self.rimColor, lineWidth: 1)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}
