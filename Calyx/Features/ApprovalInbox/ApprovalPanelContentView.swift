// ApprovalPanelContentView.swift
// Calyx
//
// SwiftUI content of the floating `ApprovalPanelWindow`: hosts
// `ApprovalBannerView` inside a vertically scrolling, width-clamped,
// theme-glass container, independent of `MainContentView`'s own
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
// panel's own width for the displayed request (`layout.width`, one of
// `ApprovalPanelArranger.fixedWidth`/`wideWidth`, never measured from
// content itself, see `ApprovalPanelArranger.panelWidth(for:
// visibleFrame:)`), so `ApprovalPanelController.render()`'s single
// measurement pass sees the content's actual height at that width.
//
// Glass: the same sheet construction as `MainContentView`'s own root
// glass sheet -- a `Color.clear` `.background` behind the content,
// `.glassEffect(.clear.tint(...))` on that clear color, `.ignoresSafeArea()`
// and `.allowsHitTesting(false)`, then `GlassAtmosphereBackground` behind
// that -- so the two read as one material (this panel's own rounded
// corners come from the titled window itself, so no extra corner radius
// is applied here). No `GlassInactiveTintModifier`: unlike the main
// window, this panel is never expected to visibly darken just because
// it isn't key. `ApprovalBannerView`'s own `RecoveryBarBackgroundModifier`
// stays -- on this glass path it only picks text/button colors, since the
// actual translucent surface is this sheet's.

import SwiftUI
import AppKit

struct ApprovalPanelContentView: View {
    let model: ApprovalBannerModel
    let layout: ApprovalPanelLayout
    let onContentSizeChange: (CGSize) -> Void
    let onRequestChange: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    var body: some View {
        Group {
            if let request = model.current {
                ScrollView(.vertical) {
                    glassWrapped(request: request)
                }
                .frame(maxHeight: layout.heightCap)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: layout.width)
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
    }

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
            ApprovalBannerView(model: model, request: request, hostWindowTitle: ControlCharacterDisplay.render(title))
                .id(request.id)
        }
        .background {
            Group {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Color.clear
                        .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .modifier(GlassAtmosphereBackground(themeColor: themeColor, glassOpacity: glassOpacity, reduceTransparency: reduceTransparency, specularStroke: false))
    }
}
