// ChoiceRowStyle.swift
// Calyx
//
// The full-width, leading-aligned row style every choice row in both
// approval banners uses -- the question banner's option/"Other" rows
// (`AgentQuestionBannerView`) and the tool-approval banner's "Yes"/
// permission-suggestion/"Always allow ... in this pane"/"No" rows
// (`AgentToolApprovalView`) -- so a click target and its hover/pressed/
// selected visual states read identically no matter which banner mode
// is on screen. Mirrors the CLI's own dialog: a vertical list of full-
// width choices.
//
// A `ButtonStyle` (not a plain `View`) so `Button { action } label: {
// content }` keeps supplying `configuration.isPressed`, and so every
// call site stays a plain SwiftUI `Button` -- no bespoke tap-gesture
// handling duplicated per caller.
//
// `@State` cannot live directly on a `ButtonStyle` value (it is a
// struct with no storage SwiftUI retains across renders) -- the hover
// tracking instead lives on a private inner `View` (`Row`) that
// `makeBody(configuration:)` returns, which SwiftUI DOES give its own
// persistent `@State` storage for the row's lifetime.

import SwiftUI

struct ChoiceRowStyle: ButtonStyle {
    enum Glyph {
        /// A tool-approval row -- "Yes", a permission-suggestion choice,
        /// "No" -- carries no leading glyph at all.
        case none
        /// A single-select question option: ◯ unselected, ● selected.
        case singleSelect
        /// A multi-select question option: ☐ unselected, ☑ selected.
        case multiSelect
    }

    let glyph: Glyph
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(glyph: glyph, isSelected: isSelected, configuration: configuration)
    }

    /// The same four-tier background computation `Row` uses internally,
    /// exposed for `AgentQuestionBannerView.otherRow` -- the "Other" row
    /// is not a `Button` (a `TextField` nested inside one loses its own
    /// click-to-focus on macOS, see `otherRow`'s own doc comment), so it
    /// cannot go through `makeBody(configuration:)`'s own
    /// `configuration.isPressed`, but still needs the identical hover/
    /// selected visual language every other choice row uses. `isPressed`
    /// defaults to false -- a plain `HStack` with `.onTapGesture` has no
    /// pressed-state signal to report.
    static func backgroundColor(isSelected: Bool, isHovering: Bool, isPressed: Bool = false) -> Color {
        if isPressed {
            return isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.18)
        }
        if isSelected {
            return Color.accentColor.opacity(0.25)
        }
        if isHovering {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }

    private struct Row: View {
        let glyph: Glyph
        let isSelected: Bool
        let configuration: Configuration

        @State private var isHovering = false

        /// `.contentShape` after `.clipShape` makes the whole rounded rect the
        /// hit-test/hover target, not just the label text, since the row's
        /// background is `.clear` when neither selected nor hovered.
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                if let glyphText {
                    Text(glyphText)
                        .font(.callout)
                        .frame(width: 16)
                }
                configuration.label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovering = $0 }
        }

        /// `nil` for `.none` -- the tool-approval banner's own rows carry
        /// no leading glyph, so no fixed-width column is reserved for
        /// one there either.
        private var glyphText: String? {
            switch glyph {
            case .none: return nil
            case .singleSelect: return isSelected ? "●" : "◯"
            case .multiSelect: return isSelected ? "☑" : "☐"
            }
        }

        /// Four tiers, checked most- to least-specific in
        /// `ChoiceRowStyle.backgroundColor(isSelected:isHovering:
        /// isPressed:)`: pressed (darkest, wins over even a
        /// selected+hovered row -- the row IS being clicked right now),
        /// selected (accent tint, so the chosen row/answer stays
        /// visually distinct even after the pointer moves away), hovered
        /// (a light `Color.primary` wash -- neutral, works in both light
        /// and dark appearance since it is relative to the current
        /// foreground color rather than a fixed RGB value), plain (no
        /// fill at all, letting the banner's own background show
        /// through).
        private var backgroundColor: Color {
            ChoiceRowStyle.backgroundColor(isSelected: isSelected, isHovering: isHovering, isPressed: configuration.isPressed)
        }
    }
}
