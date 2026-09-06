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
// `.fixedSize(horizontal: layout.width == nil, ...)` before
// `.frame(width: layout.width)` -- lets `ApprovalPanelController.render()`
// measure this view's own ideal (unclamped) width on a first pass
// (`layout.width == nil`), then re-measure at its final, clamped width
// on a second pass, WITHOUT changing this view's own structure between
// passes: only `layout.width` changes, so `AgentQuestionFormState`'s
// `@State` (owned deeper inside `ApprovalBannerView`) is created exactly
// once per request.
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
    /// Invoked inside `body` so the `@Observable` `Tab.displayTitle` read
    /// it wraps is tracked by SwiftUI, and this view re-renders when the
    /// designated host's active tab is renamed while a request is
    /// pending.
    let hostWindowTitle: () -> String
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
                .fixedSize(horizontal: layout.width == nil, vertical: true)
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

    private func glassWrapped(request: ApprovalRequest) -> some View {
        GlassEffectContainer {
            ApprovalBannerView(model: model, request: request, hostWindowTitle: ControlCharacterDisplay.render(hostWindowTitle()))
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
