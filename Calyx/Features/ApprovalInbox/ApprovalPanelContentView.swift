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
// The root shape -- `ScrollView` clamped to `layout.heightCap`,
// `.fixedSize(horizontal: false, vertical: true)` before `.frame(width:
// layout.width)` -- reports this view's own content height at the
// glass SHEET's own width for the displayed request (`layout.width`, one
// of `ApprovalPanelArranger.fixedWidth`/`wideWidth`, never measured from
// content itself, see `ApprovalPanelArranger.panelWidth(for:
// visibleFrame:)`), so `ApprovalPanelController.render()`'s single
// measurement pass sees the content's actual height at that width.
// `onGeometryChange` (below) is attached to that SAME pre-padding node,
// so it reports the sheet's own size, never the gutter-inflated one --
// `dismissGutter` padding wraps this whole `Group` from OUTSIDE that
// node (top and leading only), so it never reaches `onContentSizeChange`
// at all; only `NSHostingController.sizeThatFits(in:)`, read directly by
// `ApprovalPanelController.measureFrame(hostingController:)`, sees the
// gutter-inflated total.
//
// The dismiss button (`dismissButton`, `isPanelHovered`) lives HERE, not
// on `ApprovalBannerView`'s own root: it must draw and hit-test OUTSIDE
// the glass sheet (straddling its top-left corner, into the transparent
// gutter `ApprovalPanelArranger.dismissGutter` reserves in the WINDOW),
// and a `ScrollView` clips its content to its own bounds -- an overlay
// on anything inside `glassWrapped(request:)` would be clipped by the
// `ScrollView` around it. Anchored to the `ScrollView`'s own frame
// instead (the sheet itself), which the window's gutter surrounds on
// its top and left, so nothing here clips it.
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
    /// `onAssumeInsideHover` calls instead, one on the sheet
    /// (`ScrollView`, always painted) and one on the dismiss button
    /// itself (painted only once `isPanelHovered` is already true) --
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
                }
                .frame(maxHeight: layout.heightCap)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: layout.width)
                .onAssumeInsideHover($sheetHovered, recheckToken: layout.hoverRecheckToken)
                .overlay(alignment: .topLeading) {
                    dismissButton(request: request)
                        .onAssumeInsideHover($dismissButtonHovered, recheckToken: layout.hoverRecheckToken)
                        .offset(x: -10 + 1, y: -10 + 1)
                }
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    Task { @MainActor in
                        onContentSizeChange(size)
                    }
                }
                .onChange(of: request.id) {
                    Task { @MainActor in
                        onRequestChange()
                    }
                }
            } else {
                EmptyView()
            }
        }
        .padding(.top, ApprovalPanelArranger.dismissGutter)
        .padding(.leading, ApprovalPanelArranger.dismissGutter)
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
    /// A 20pt circle, its center 1pt inside the sheet's own top-left
    /// corner on both axes -- that corner itself lies inside the sheet's
    /// own 20pt rounded-corner cutout, so most of the disc lies outside
    /// the painted sheet, into the window's transparent `dismissGutter`.
    /// `.overlay(alignment: .topLeading)` places the button's own
    /// top-left corner AT the sheet's, and the `.offset(x: -10 + 1, y:
    /// -10 + 1)` above then shifts it by minus the circle's own radius
    /// plus that 1pt inset.
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
            ? (reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.thinMaterial))
            : AnyShapeStyle(.clear)
        let borderStyle: AnyShapeStyle = isPanelHovered ? AnyShapeStyle(.separator) : AnyShapeStyle(.clear)
        let glyphStyle: AnyShapeStyle = isPanelHovered
            ? (request.isDismissible ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            : AnyShapeStyle(.clear)

        let button = Button(action: { model.dismiss(id: request.id) }) {
            Circle()
                .fill(fillStyle)
                .overlay(Circle().strokeBorder(borderStyle, lineWidth: 0.5))
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
