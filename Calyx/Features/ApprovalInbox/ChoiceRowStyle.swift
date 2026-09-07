// ChoiceRowStyle.swift
// Calyx
//
// The full-width, leading-aligned row style `AgentQuestionBannerView`'s
// own inline option list uses -- the listed-option rows and the standing
// "Other" row (`optionButton(index:option:)`/`otherRow`), shown inline
// whenever the current question wants that layout (a multi-select
// question, or one where any option carries a `preview`; see that
// view's own file header) -- so every row in that list shares one click
// target and one hover/pressed/selected visual language. Mirrors the
// CLI's own dialog: a vertical list of full-width choices.
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
            return Color.primary.opacity(0.12)
        }
        return Color.primary.opacity(0.06)
    }

    private struct Row: View {
        let glyph: Glyph
        let isSelected: Bool
        let configuration: Configuration

        @State private var isHovering = false

        /// `.contentShape` after `.clipShape` makes the whole rounded rect the
        /// hit-test/hover target, not just the label text -- the row's own
        /// tinted background draws behind the label either way, but without
        /// this, hovering/clicking the row's own padding (outside the
        /// label's tight bounds) would neither highlight nor register a
        /// click.
        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Text(glyphText)
                    .font(.callout)
                    .frame(width: 16)
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

        private var glyphText: String {
            switch glyph {
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
        /// (a brighter `Color.primary` wash), resting (a faint
        /// `Color.primary` wash, always visible -- this is what makes the
        /// row read as a full-width strip spanning the banner even when
        /// idle, rather than bare text with no visible extent). Every
        /// tier uses `Color.primary` rather than a fixed RGB value, so it
        /// stays legible in both light and dark appearance.
        private var backgroundColor: Color {
            ChoiceRowStyle.backgroundColor(isSelected: isSelected, isHovering: isHovering, isPressed: configuration.isPressed)
        }
    }
}
