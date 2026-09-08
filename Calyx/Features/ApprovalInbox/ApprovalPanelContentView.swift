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
// dismissGutter`, `.fixedSize(horizontal: false, vertical: true)` before
// `.frame(width: layout.width + dismissGutter)` -- now spans the SHEET
// plus the gutter on every axis (see the dismiss-button paragraph below
// for why the gutter has to live INSIDE the `ScrollView` at all). The
// `onGeometryChange` that reports content height to
// `onContentSizeChange` stays attached to `glassWrapped(request:)`
// itself, the pre-padding, pre-gutter node, so it still reports the
// SHEET's own size for the displayed request (`layout.width`, one of
// `ApprovalPanelArranger.fixedWidth`/`wideWidth`, never measured from
// content itself, see `ApprovalPanelArranger.panelWidth(for:
// visibleFrame:)`), matching what
// `ApprovalPanelController.measureFrame(hostingController:)` expects
// back through `applyContentHeight(_:)`; the `dismissGutter` padding
// (top and leading) is applied AFTER that node, inside the `ScrollView`,
// so `NSHostingController.sizeThatFits(in:)` -- which measures the
// WHOLE content view -- still sees the same gutter-inflated total it
// always did, just assembled inside the `ScrollView` now instead of
// outside it.
//
// The dismiss button (`dismissButton`, `isPanelHovered`) lives HERE, not
// on `ApprovalBannerView`'s own root, but it is applied as an
// `.overlay` INSIDE `glassWrapped(request:)`'s own `GlassEffectContainer`
// (on `ApprovalBannerView` itself, before `.id(request.id)`) -- see the
// z-order paragraph below for why it has to sit there rather than
// outside the container. A `ScrollView` clips its content to its own
// bounds, so the gutter the × straddles into must be PART of that
// content, not outside it: the `ScrollView`'s own frame is therefore
// widened by `dismissGutter` on every axis (above), and
// `glassWrapped(request:)`'s own `dismissGutter` padding (top and
// leading, applied at the call site in `body`) shifts the sheet -- ×
// included, since it travels with it as an overlay -- into the bottom-
// right corner of that widened frame, leaving exactly `dismissGutter`
// of transparent, still-in-bounds space above and to its left for the ×
// to straddle into.
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
// content, `.ignoresSafeArea()` and `.allowsHitTesting(false)`. The
// `reduceTransparency` path fills the same rounded rect with
// `.windowBackgroundColor` instead. No theme-color tint, no atmosphere
// layer, no inactive-window dimming: unlike the main window, this panel
// never reads the Calyx theme at all.
//
// Rounded outline ownership: `ApprovalPanelWindow` stays `.titled`
// because `.glassEffect` needs a titled window to render at all (see
// `QuickTerminalWindow` for the sibling panel this mirrors), but its
// background is `.clear` with `isOpaque = false`, so the titled frame's
// own corner mask -- smaller than this view's 20pt radius -- clips
// nothing this view draws. The `.rect(cornerRadius: 20)` shape below is
// therefore the panel's entire visible outline, the window shadow
// (`hasShadow = true`) follows that same shape, and the
// `reduceTransparency` fill reuses the identical 20pt shape so both
// paths show the same corners.

import SwiftUI
import AppKit

struct ApprovalPanelContentView: View {
    let model: ApprovalBannerModel
    let layout: ApprovalPanelLayout
    /// `ApprovalBannerView.targetLabel`'s own source for a surface-
    /// targeted request -- see `ApprovalPanelController`'s own stored
    /// property of the same name for the full chain.
    let targetTabTitle: (UUID) -> String?
    let onContentSizeChange: (CGSize) -> Void
    let onRequestChange: () -> Void
    /// Called whenever `isPanelHovered` changes -- see that property's
    /// own doc comment for why the window's shadow needs recomputing on
    /// this same edge. `{}` by default so every existing test-only
    /// construction of this view keeps compiling unchanged;
    /// `ApprovalPanelController` supplies the real
    /// `panel?.invalidateShadow()` call.
    var panelHoverChanged: () -> Void = {}

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
                        .padding(.top, ApprovalPanelArranger.dismissGutter)
                        .padding(.leading, ApprovalPanelArranger.dismissGutter)
                }
                .frame(maxHeight: layout.heightCap + ApprovalPanelArranger.dismissGutter)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: layout.width + ApprovalPanelArranger.dismissGutter)
                .onChange(of: request.id) {
                    Task { @MainActor in
                        onRequestChange()
                    }
                }
            } else {
                EmptyView()
            }
        }
        .onChange(of: isPanelHovered) {
            panelHoverChanged()
        }
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
    /// `.tertiary`), with a tooltip (`.help`) and accessibility hint
    /// explaining why -- never a caption under the body, which would
    /// shift every OTHER source's layout too. `dismissButton` identifies
    /// both states alike, so a test can assert `isEnabled` directly.
    ///
    /// A 22pt circle whose center sits at `(sheet.minX + 3, sheet.top +
    /// 7)` -- 8pt of the disc left of the sheet's own left edge and 4pt
    /// above its top edge, both distances inside the 12pt
    /// `dismissGutter`, matching a macOS notification banner's own ×
    /// placement. `glassWrapped(request:)`'s own `.overlay(alignment:
    /// .topLeading)` places the button's own top-left corner AT the
    /// sheet's (`ApprovalBannerView`'s, the overlay's base), and the
    /// `.offset(x: -8, y: -4)` there then shifts it there (the circle's
    /// own top-left corner, 11pt above and left of its center, lands at
    /// `3 - 11 = -8` and `7 - 11 = -4`).
    ///
    /// Show-on-hover (`isPanelHovered`) fades the fill/border/glyph via
    /// `.clear` rather than `.opacity`: `.opacity` also zeroes the
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
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(.clear)
        let borderStyle: AnyShapeStyle = isPanelHovered ? AnyShapeStyle(Color(nsColor: .separatorColor)) : AnyShapeStyle(.clear)
        let glyphStyle: AnyShapeStyle = isPanelHovered
            ? (request.isDismissible ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            : AnyShapeStyle(.clear)

        let button = Button(action: { model.dismiss(id: request.id) }) {
            Circle()
                .fill(fillStyle)
                .overlay(Circle().strokeBorder(borderStyle, lineWidth: 1))
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(glyphStyle)
                }
                .frame(width: 22, height: 22)
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
                .help(Self.notDismissibleHint)
                .accessibilityHint(Self.notDismissibleHint)
        }
    }

    /// `dismissButton(request:)`'s own tooltip/accessibility hint for a
    /// non-dismissible (grok/pi) request.
    private static let notDismissibleHint = "This CLI has no prompt of its own; choose Allow or an option here."

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
                    .offset(x: -8, y: -4)
            }
            .id(request.id)
        }
        .background {
            Group {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}
