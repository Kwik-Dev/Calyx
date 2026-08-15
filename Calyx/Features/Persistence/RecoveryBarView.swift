// RecoveryBarView.swift
// Calyx
//
// Chrome-style in-app "your previous session was preserved" bar,
// shown at the top of a window's content when `model.showRecoveryBar`
// is true (see RecoveryBarModel's own file header for the full
// design-decision writeup). Hosted via `MainContentView.body`'s
// `mainContent.safeAreaInset(edge: .top)`, above the tab bar/pane
// content -- never intercepts first responder/keyboard focus, since
// neither the bar nor its buttons are ever made first responder by any
// code path.

import SwiftUI

struct RecoveryBarView: View {
    let model: RecoveryBarModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            Text("Your previous session was preserved.")
                .font(.callout)

            Spacer()

            Button("Restore") {
                model.restore()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.restoreButton)

            Button("Dismiss") {
                model.dismiss()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.dismissButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.RecoveryBar.container)
    }
}

/// Same chrome legibility treatment as `TabBarContentView`'s own
/// `TabBarBackgroundModifier` (the closest existing precedent: another
/// horizontal bar sitting directly above/adjacent to the tab strip) --
/// ties this bar's colors to the user's theme color + glass opacity
/// instead of a fixed `.thinMaterial`, so it reads as part of the window
/// chrome rather than a foreign overlay.
///
/// Deliberately applies no `.glassEffect(...)` and no seam stroke of its
/// own: this bar is hosted via `mainContent.safeAreaInset(edge: .top)`
/// in `MainContentView`, and `MainContentView`'s own root glass sheet (a
/// single `.background` with `.ignoresSafeArea()`, covering the whole
/// window rather than any one region) already paints straight through
/// this strip with the exact same `GlassTheme.chromeTint(...)` formula
/// used below, seamlessly continuous with the titlebar above and the tab
/// strip below. Every pixel under that sheet must get its tint pass
/// exactly once: adding a second `.glassEffect` here would stack two
/// passes of the identical tint in this one strip, reading visibly
/// darker than the single-pass chrome above and below it. This modifier
/// now only supplies text/button legibility handling; the glass surface
/// itself is inherited from the root sheet. The reduceTransparency path
/// keeps its plain `Divider()`: that flat, non-glass mode has no shared
/// surface to stay seamless with, so it still needs an explicit
/// separator.
///
/// Reused as-is by `ApprovalBannerView`: both bars are hosted inside the
/// same `MainContentView.body`'s `safeAreaInset(edge: .top)` VStack,
/// sharing the identical root glass surface this modifier's own doc
/// comment above describes. Also reused by `BrowserContainerView`'s
/// toolbar, which sits on the same root sheet and needs the same
/// avoid-double-tint treatment; its lower neighbor is an opaque
/// `WKWebView` rather than more glass chrome, so the continuity argument
/// above holds only on the toolbar's top edge, not its bottom -- the
/// flat path's `Divider()` still runs there, and the glass path still
/// has no separator. This modifier supplies legibility handling to the
/// bars and the browser toolbar; the glass surface itself comes from
/// the root sheet.
struct RecoveryBarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool
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

    private var chromeScheme: ColorScheme {
        let tint = GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
        return ColorLuminance.prefersDarkText(for: tint) ? .light : .dark
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
        } else {
            content
                .environment(\.colorScheme, chromeScheme)
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
        }
    }
}
