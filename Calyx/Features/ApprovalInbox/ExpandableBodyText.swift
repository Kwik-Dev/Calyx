// ExpandableBodyText.swift
// Calyx
//
// The 2-line, tap-to-pin-expanded body shared by `ApprovalBannerView`
// (`.mcpTool`/`.agentHook`'s payload) and `AgentQuestionBannerView`
// (`.agentQuestion`'s current question text). A stationary hover shows
// the full text in the system tooltip (`.help`) while collapsed; nothing
// in the panel moves on hover.
//
// `text` is already rendered (`ControlCharacterDisplay.render`, run once
// by the caller per body evaluation) -- this view never re-renders it,
// and reuses the same string for both the collapsed clip and the
// expanded scroll. `collapsedFont`/`expandedFont` differ per caller
// (monospaced for a tool/hook payload, regular for a question), and
// `collapsedIdentifier` is the caller's own accessibility identifier for
// the collapsed `Text` (`AccessibilityID.ApprovalBanner.payload`/
// `.questionText`) -- the expanded `Text` always carries `payloadExpanded`,
// the one "the full text is showing" identifier both callers share.
// `collapsedForegroundIsSecondary` selects the collapsed color: true for
// `ApprovalBannerView`'s payload (`.secondary` collapsed, default
// primary once expanded), false for `AgentQuestionBannerView`'s question
// text (default primary in both states).

import SwiftUI

struct ExpandableBodyText: View {
    let text: String
    let collapsedFont: Font
    let collapsedIdentifier: String
    let expandedFont: Font
    let collapsedForegroundIsSecondary: Bool

    /// Whether a click has pinned the expanded text open -- stays set
    /// until this view itself is torn down (the caller's own
    /// `.id(request.id)` resets it per request).
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            collapsedText
            if isExpanded {
                expandedText
            }
        }
    }

    /// Accessibility label carries the FULL text (an XCUITest suite
    /// reads it via `contains(marker)` while the on-screen text is
    /// visually clipped to 2 lines); the tap toggles `isExpanded`,
    /// revealing `expandedText` below. Not `.textSelection(.enabled)`:
    /// on macOS that backs a `Text` with a real AppKit selectable text
    /// view which consumes `mouseDown` for its own selection handling
    /// and never forwards it, so no gesture attached to this `Text` --
    /// `.onTapGesture` or otherwise -- ever sees the click. The full text
    /// stays selectable via `expandedText`, which this tap reveals.
    ///
    /// `.help(text)` shows the same full text in the system tooltip on a
    /// stationary hover -- unlike the tap, this never mutates any state,
    /// so hovering never moves anything else in the panel. Applied only
    /// while `!isExpanded`: once the tap has pinned the full text open
    /// below, a tooltip repeating that same text over the collapsed clip
    /// would pop over already-visible content. Apple's `help(_:)`
    /// documentation states it "configures the view's accessibility hint
    /// and its help tag (tooltip)" -- that hint duplicates VoiceOver's own
    /// label announcement (already the full text, via
    /// `.accessibilityLabel` above) rather than describing the tap
    /// action. Apple's docs do not state whether a later
    /// `.accessibilityHint` overrides the hint `.help` sets; applying it
    /// AFTER `.help` here follows SwiftUI's general later-applied-modifier-
    /// wins pattern for a single-value property (documented for other
    /// modifiers, e.g. `.disabled(_:)`, where an outer/later value wins
    /// over an inner/earlier one). Applied identically in both branches
    /// below so the hint reads the same whether or not `.help` is also
    /// present.
    @ViewBuilder
    private var collapsedText: some View {
        if isExpanded {
            collapsedTextBase
                .accessibilityHint("Click to expand the full text")
        } else {
            collapsedTextBase
                .help(text)
                .accessibilityHint("Click to expand the full text")
        }
    }

    private var collapsedTextBase: some View {
        Text(text)
            .font(collapsedFont)
            .lineLimit(2)
            .foregroundStyle(collapsedForegroundIsSecondary ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(collapsedIdentifier)
            .accessibilityLabel(Text(text))
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.toggle()
            }
    }

    /// The full, scrolling text shown below `collapsedText` while
    /// `isExpanded` -- a one-line body must never reserve blank space;
    /// `.frame(maxHeight: 120)` caps a long one, applied BEFORE
    /// `.fixedSize` so it clamps what content height gets reported.
    private var expandedText: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(expandedFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payloadExpanded)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
    }
}
