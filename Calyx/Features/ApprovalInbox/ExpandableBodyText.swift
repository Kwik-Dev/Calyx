// ExpandableBodyText.swift
// Calyx
//
// The 2-line, tap-to-pin-expanded body shared by `ApprovalBannerView`
// (`.mcpTool`/`.agentHook`'s payload) and `AgentQuestionBannerView`
// (`.agentQuestion`'s current question text). A stationary hover shows
// the full text in a Calyx-drawn tooltip (`ApprovalTooltipWindow`, via
// `ApprovalTooltipPresenter`) while collapsed; nothing in the panel
// moves on hover. AppKit's own `.help` tooltip cannot be used here: it
// is armed only when the first cursor registration on the window lands
// on the tooltip's own view, and `ApprovalPanelWindow` is a
// non-activating panel that never becomes key on hover -- a pointer
// entering the panel elsewhere (e.g. over the Allow button) and sliding
// onto this text never gets that first registration, so the system
// tooltip never appears.
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

    @Environment(\.approvalTooltipPresenter) private var tooltipPresenter

    /// Whether a click has pinned the expanded text open -- stays set
    /// until this view itself is torn down (the caller's own
    /// `.id(request.id)` resets it per request).
    @State private var isExpanded = false
    /// Whether the pointer is currently over `collapsedText`, tracked
    /// via `onAssumeInsideHover` (this panel uses `.activeAlways`
    /// tracking -- see that helper's own doc comment).
    @State private var isHoveringText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            collapsedText
            if isExpanded {
                expandedText
            }
        }
        .onChange(of: isHoveringText) {
            if isHoveringText, !isExpanded {
                tooltipPresenter?.scheduleShow(text: text)
            } else {
                tooltipPresenter?.hide()
            }
        }
        // The caller's own `.id(request.id)` tears this view down when
        // the displayed request changes -- a pending or already-shown
        // tooltip for the OLD text must never linger once that text is
        // gone.
        .onDisappear {
            tooltipPresenter?.hide()
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
    /// A stationary hover over this text schedules the Calyx-drawn
    /// tooltip (`tooltipPresenter.scheduleShow(text:)`, via
    /// `onAssumeInsideHover` below and `body`'s own `onChange(of:
    /// isHoveringText)`); unlike the tap, hovering never mutates
    /// `isExpanded` or moves anything else in the panel. Hover tracking
    /// stays attached regardless of `isExpanded` (`onAssumeInsideHover`
    /// itself has no bearing on layout), but scheduling a tooltip is
    /// skipped while `isExpanded`: once the tap has pinned the full text
    /// open below, a tooltip repeating that same text over the collapsed
    /// clip would pop over already-visible content.
    private var collapsedText: some View {
        collapsedTextBase
            .accessibilityHint("Click to expand the full text")
            .onAssumeInsideHover($isHoveringText)
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
                tooltipPresenter?.hide()
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
