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
// panel's own width for the displayed request (`layout.width`, one of
// `ApprovalPanelArranger.fixedWidth`/`wideWidth`, never measured from
// content itself, see `ApprovalPanelArranger.panelWidth(for:
// visibleFrame:)`), so `ApprovalPanelController.render()`'s single
// measurement pass sees the content's actual height at that width.
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
    let onContentSizeChange: (CGSize) -> Void
    let onRequestChange: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
