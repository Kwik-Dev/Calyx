// ExpandableBodyText.swift
// Calyx
//
// The 2-line, tap-or-hover-to-expand body shared by `ApprovalBannerView`
// (`.mcpTool`/`.agentHook`'s payload) and `AgentQuestionBannerView`
// (`.agentQuestion`'s current question text).
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

    /// Set by hovering the collapsed text past `hoverExpandDelay`,
    /// cleared the moment the pointer leaves -- distinct from
    /// `isExpanded` (a click), which stays set once toggled on. The
    /// expanded text renders whenever either is true.
    @State private var hoverExpanded = false

    /// The pending hover-expand `DispatchWorkItem`, cancelled on any exit
    /// before it fires -- same debounce shape as `SearchBarView`'s own
    /// `searchDebounce` (Calyx/Features/Search/SearchBarView.swift).
    @State private var hoverExpandWorkItem: DispatchWorkItem?

    /// Whether the pointer is over the whole body (`collapsedText` and,
    /// once shown, `expandedText`), tracked through
    /// `onAssumeInsideHover($isHoveringBody)` on `body`'s own `VStack`
    /// rather than plain SwiftUI `.onHover` -- this view is hosted inside
    /// the floating approval panel (`ApprovalPanelWindow`), a
    /// non-activating window that never becomes key, so `.onHover`'s
    /// underlying tracking area never fires there at all; same fix as
    /// `ApprovalBannerView.isPanelHovered`. Tracked on the whole `VStack`,
    /// not `collapsedText` alone: the pointer moving down into
    /// `expandedText` once it appears must stay counted as "still over
    /// the body", otherwise that move itself would read as a mouse-exit
    /// and collapse the text out from under the cursor.
    @State private var isHoveringBody = false

    /// How long the pointer must stay over the body before it expands.
    private static let hoverExpandDelay: TimeInterval = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            collapsedText
            if isExpanded || hoverExpanded {
                expandedText
            }
        }
        .onAssumeInsideHover($isHoveringBody)
        .onChange(of: isHoveringBody) { _, isHovering in
            hoverExpandWorkItem?.cancel()
            if isHovering {
                let workItem = DispatchWorkItem { hoverExpanded = true }
                hoverExpandWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandDelay, execute: workItem)
            } else {
                hoverExpandWorkItem = nil
                hoverExpanded = false
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
    /// A click that turns `isExpanded` OFF also cancels any pending
    /// hover-expand work item and clears `hoverExpanded` -- otherwise the
    /// pointer, still resting on the text right after the click that
    /// just un-pinned it, would re-expand it out from under the user a
    /// moment later even though nothing asked for that. Hover-expansion
    /// re-arms itself the next time the pointer actually leaves and
    /// re-enters the body (`isHoveringBody` only starts a new debounce on
    /// a `false -> true` transition), so a real user moving the pointer
    /// away and back still gets the normal hover-to-expand behavior.
    private var collapsedText: some View {
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
                if !isExpanded {
                    hoverExpandWorkItem?.cancel()
                    hoverExpandWorkItem = nil
                    hoverExpanded = false
                }
            }
    }

    /// The full, scrolling text shown below `collapsedText` while
    /// `isExpanded`/`hoverExpanded` -- a one-line body must never reserve
    /// blank space; `.frame(maxHeight: 120)` caps a long one, applied
    /// BEFORE `.fixedSize` so it clamps what content height gets
    /// reported.
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
