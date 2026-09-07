// ApprovalBannerView.swift
// Calyx
//
// SwiftUI view for the Cockpit approval banner: shown when
// `model.current` is non-nil (see ApprovalBannerModel's own file header
// for the full ownership/visibility rules), hosted by the floating
// approval panel's `ApprovalPanelContentView.body` (`ApprovalPanelWindow`,
// Calyx/Features/ApprovalInbox/) -- an independent window, not a strip
// of the terminal window's own content.
//
// `request` is threaded in explicitly (rather than read from
// `model.current` inside `body`) so this view's content is never itself
// optional -- MainContentView already unwraps `model.current` once to
// decide whether to show this view at all.
//
// A macOS-notification-style shell, at `ApprovalPanelArranger.fixedWidth`
// or, for a request wanting inline option rows (`ApprovalRequest.
// prefersWideApprovalPanel`), `wideWidth`: a leading column (header row,
// a 1-2-line body, and any source-specific extras) beside a fixed-width
// trailing column holding
// one primary action button and an "Options" pull-down menu
// (`ApprovalActionColumn`) listing every choice the CLI offers beyond
// that primary action. One `HStack(alignment: .top, spacing: 12)` per
// `request.source` case, all sharing the same outer padding/background/
// `container` identifier applied once below the `switch` -- never more
// than one `container`-identified element per render.
//
// - `.mcpTool` (Calyx's own pane_run approval): entirely inline here --
//   `toolLeftColumn` (header row + tappable body + expanded payload) and
//   an `ApprovalActionColumn` whose primary is "Allow" and whose menu
//   lists "Always Allow"/"Deny".
// - `.agentHook` (a CLI agent's own PermissionRequest-gated tool call):
//   the SAME `toolLeftColumn` (its body is the hook call's own
//   `summary`, `ApprovalRequest.displayPayload` already picks the right
//   field per source) beside an `ApprovalActionColumn` fed by
//   `AgentToolApprovalView`, a stateless provider of the "Yes" primary
//   button and its menu items (one row per `AgentHookOffers.
//   permissionUpdates` offer, Calyx's own pane-scoped Always-Allow row
//   only when the CLI sent none of its own, "No").
// - `.agentQuestion` (Claude Code's AskUserQuestion): `AgentQuestionBannerView`
//   renders its OWN full two-column row (it owns `AgentQuestionFormState`
//   and the free-text fields' focus state, which a stateless provider
//   cannot safely expose to a separate render pass -- see that view's
//   own file header), taking this shell's `headerRow` as its `header`
//   parameter so the tool/target label and queue navigator still read
//   identically across all three sources.
//
// `AgentQuestionBannerView` is given `.id(request.id)`, so a different
// request tears its whole subtree (and `form`) down and creates a fresh
// one -- this shell keeps no request-specific `@State` of its own for
// it, only `isExpanded` (the tap-to-expand body toggle shared by
// `.mcpTool`/`.agentHook`), which the SAME `.id(request.id)` at THIS
// view's own call site (`ApprovalPanelContentView.glassWrapped(request:)`)
// resets identically. Every action routes through plain closures into
// `model`.
//
// Queue navigation: while `model.positionInfo.count > 1`, a Previous/
// Next chevron pair + "N / M" position label (see
// `queueNavigator(positionInfo:)`) renders on the header row -- the
// browse-then-decide loop (glance at each queued command, then click
// Previous/Next to compare before deciding) keeps the mouse in one
// place; the sequential loop never needs the arrows at all thanks to
// advance-on-decide (see ApprovalBannerModel.advanceCursor(
// pastDisplayed:excluding:)'s own doc comment). Drives
// `ApprovalBannerModel`'s own `selectedRequestID` cursor -- a single
// queued request renders no navigator at all, since there is nothing to
// step to.

import SwiftUI
import AppKit

struct ApprovalBannerView: View {
    let model: ApprovalBannerModel
    let request: ApprovalRequest
    /// The designated host window's active tab title, for a
    /// window-agnostic (nil `targetSurfaceID`) request's header (see
    /// `targetLabel`'s own doc comment). Already rendered through
    /// `ControlCharacterDisplay.render` by the caller
    /// (`ApprovalPanelContentView.glassWrapped(request:)`).
    let hostWindowTitle: String

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Whether the tap-to-expand body (`.mcpTool`/`.agentHook` only) is
    /// showing its full, scrolling payload below the 2-line summary.
    /// Reset per request by this view's own `.id(request.id)` at its
    /// call site, same as every other per-request `@State` in this
    /// feature.
    @State private var isExpanded = false

    /// Routed through `ControlCharacterDisplay.render` same as
    /// `request.displayPayload` below -- `displayToolName` comes from the
    /// same untrusted tool-call provenance as `displayPayload`, so it
    /// must not be able to smuggle a hidden/spoofing payload into the
    /// header just because it's a different field on `ApprovalRequest`.
    private var toolName: String {
        ControlCharacterDisplay.render(request.displayToolName)
    }

    /// Short, human-scannable target label -- the first 8 characters of
    /// the target surface's UUID (enough to disambiguate panes at a
    /// glance without printing a full UUID into the banner), or the
    /// designated host window's own active tab title for a
    /// window-agnostic (nil targetSurfaceID) request (e.g.
    /// `palette_execute`, which carries no target pane at all).
    private var targetLabel: String {
        guard let targetSurfaceID = request.targetSurfaceID else { return hostWindowTitle }
        return String(targetSurfaceID.uuidString.prefix(8))
    }

    private var headerText: String {
        "\(toolName) → \(targetLabel)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            switch request.source {
            case .mcpTool:
                toolLeftColumn
                ApprovalActionColumn(primary: AnyView(mcpPrimaryButton)) { mcpMenuItems }

            case .agentHook(let toolName, _, _, let offers):
                let provider = AgentToolApprovalView(
                    toolName: toolName,
                    offers: offers,
                    onAllow: { model.allow(id: request.id) },
                    onAllowWithPermissions: { offer in model.allowWithPermissions(id: request.id, offer: offer) },
                    onAlwaysAllow: { model.alwaysAllow(id: request.id) },
                    onDeny: { model.deny(id: request.id) }
                )
                toolLeftColumn
                ApprovalActionColumn(primary: AnyView(provider.primaryButton)) { provider.menuItems }

            case .agentQuestion(_, let prompt):
                AgentQuestionBannerView(
                    prompt: prompt,
                    onAnswer: { answers in model.answer(id: request.id, answers: answers) },
                    onChatAboutQuestion: { model.chatAboutQuestion(id: request.id) },
                    onTextFieldRemoved: { model.restoreTerminalFocusAfterInput(targetSurfaceID: request.targetSurfaceID) },
                    header: AnyView(headerRow)
                )
                .id(request.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.container)
    }

    // MARK: - `.mcpTool`/`.agentHook`: shared left column

    /// `headerRow`, the tappable 2-line body (`request.displayPayload`
    /// -- `payload` for `.mcpTool`, the hook call's own `summary` for
    /// `.agentHook`), and the expanded payload once `isExpanded`.
    private var toolLeftColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            bodyText
            if isExpanded {
                expandedPayload
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The 2-line, tap-to-expand body shared by `.mcpTool`/`.agentHook`.
    /// The accessibility label carries the FULL rendered text (an
    /// XCUITest suite reads it via `contains(marker)` while the on-
    /// screen text is visually clipped to 2 lines); the tap toggles
    /// `isExpanded`, revealing `expandedPayload` below. Not `.textSelection(
    /// .enabled)`: on macOS that backs a `Text` with a real AppKit
    /// selectable text view which consumes `mouseDown` for its own
    /// selection handling and never forwards it, so no gesture attached
    /// to this `Text` -- `.onTapGesture` or otherwise -- ever sees the
    /// click. The full payload stays selectable via `expandedPayload`,
    /// which this tap reveals.
    private var bodyText: some View {
        let rendered = ControlCharacterDisplay.render(request.displayPayload)
        return Text(rendered)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payload)
            .accessibilityLabel(Text(rendered))
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
    }

    /// The full, scrolling monospaced payload shown below `bodyText`
    /// while `isExpanded` -- same construction as the pre-notification
    /// banner's own payload view (a one-line command must never reserve
    /// blank space; `.frame(maxHeight: 120)` caps a long one, applied
    /// BEFORE `.fixedSize` so it clamps what content height gets
    /// reported).
    private var expandedPayload: some View {
        ScrollView(.vertical) {
            Text(ControlCharacterDisplay.render(request.displayPayload))
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payloadExpanded)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - `.mcpTool`: primary button + menu items

    private var mcpPrimaryButton: some View {
        Button("Allow") { model.allow(id: request.id) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowButton)
    }

    @ViewBuilder
    private var mcpMenuItems: some View {
        Button(Self.menuRowTitle("Always Allow")) { model.alwaysAllow(id: request.id) }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.alwaysAllowButton)
        Button(Self.menuRowTitle("Deny")) { model.deny(id: request.id) }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.denyButton)
    }

    // MARK: - Header row (shared by every source)

    /// `headerText` (the tool name/target label), then the queue
    /// navigator when more than one request is queued for this window.
    private var headerRow: some View {
        HStack {
            Text(headerText)
                .font(.callout)
                .fontWeight(.semibold)
            Spacer()
            if let positionInfo = model.positionInfo, positionInfo.count > 1 {
                queueNavigator(positionInfo: positionInfo)
            }
        }
    }

    /// Previous/Next chevron pair + "N / M" position label, rendered by
    /// `headerRow` trailing `headerText`. Shown only while more than one
    /// request is queued for this window (see the call site's own
    /// `positionInfo.count > 1` gate) -- mirrors `BrowserToolbarView`'s
    /// own chevron.left/chevron.right precedent
    /// (Calyx/Views/Browser/BrowserContainerView.swift). The label
    /// itself is a `Menu` wrapping the same "N / M" `Text`, listing this
    /// window's queued requests oldest-first (see
    /// `queueMenuItems`); clicking a row jumps straight to that request
    /// via `model.select(id:)`.
    ///
    /// That same "N / M" text is ALSO set as the `Menu`'s own
    /// `.accessibilityLabel`: on macOS SwiftUI collapses a `Menu` into a
    /// single pop-up element that surfaces neither the identifier nor
    /// the text of the views inside its label closure (field-verified --
    /// an XCUITest lookup for `AccessibilityID.ApprovalBanner.
    /// positionLabel` matched no element of any type while that
    /// identifier sat only on the inner `Text`), so the explicit label
    /// is what carries the position into the accessibility tree at all.
    /// The inner `Text` keeps that identifier, which the collapse leaves
    /// inert. `.buttonStyle(.borderless)` on the chevrons +
    /// `.menuStyle(.borderlessButton)` on the `Menu` + `.controlSize(
    /// .small)` + `.fixedSize()` throughout keep this content-hugging, so
    /// it never stretches the banner's header row. Disabled states are
    /// derived directly from the passed `positionInfo` (`index <= 1` /
    /// `index >= count`) rather than a separate `model.
    /// canSelectPrevious`/`canSelectNext` read -- one source (the same
    /// `positionInfo` already used for the label) for both the label and
    /// the chevrons' enabled state, rather than two independently-
    /// computed answers that could in principle disagree.
    /// `canSelectPrevious`/`canSelectNext` stay public on the model
    /// regardless -- `selectNext()`/`selectPrevious()` still guard on
    /// them internally, and CalyxTests/ApprovalInbox/
    /// ApprovalBannerModelTests.swift asserts them directly.
    private func queueNavigator(positionInfo: (index: Int, count: Int)) -> some View {
        HStack(spacing: 8) {
            Button(action: { model.selectPrevious() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(positionInfo.index <= 1)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.previousButton)

            Menu {
                queueMenuItems
            } label: {
                Text("\(positionInfo.index) / \(positionInfo.count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.positionLabel)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.queueMenu)
            .accessibilityLabel(Text("\(positionInfo.index) / \(positionInfo.count)"))

            Button(action: { model.selectNext() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(positionInfo.index >= positionInfo.count)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.nextButton)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
    }

    /// The queue preview menu's rows: one clickable
    /// `queueEntryLabel(_:)` per request `model.queueEntries` reports,
    /// oldest-first, with every entry listed. `NSMenu` scrolls a menu
    /// whose items do not fit on screen, so even a long backlog stays
    /// operable. No cap trimming the list from the front is applied:
    /// with the cursor past such a cap, neither the current row (the one
    /// carrying "▸") nor its neighbors would be drawn at all, leaving
    /// nothing in the menu to jump to them by -- and a backlog that
    /// large is exactly when this list is worth more than the chevrons.
    @ViewBuilder
    private var queueMenuItems: some View {
        ForEach(model.queueEntries) { entry in
            Button(queueEntryLabel(entry)) {
                model.select(id: entry.id)
            }
        }
    }

    /// A queue preview menu row's label: `"N. <rendered previewLine>"`,
    /// prefixed with "▸ " for the entry matching the currently displayed
    /// request, so the current page reads clearly at a glance among the
    /// rest of this window's backlog. `ControlCharacterDisplay.render`
    /// on `previewLine`, same untrusted-provenance caveat as `toolName`/
    /// `payloadText` above. Any literal newline the rendered text still
    /// carries folds to a space here: an `NSMenuItem` draws a newline in
    /// its title as a real line break, turning one row into a multi-line
    /// one. The only literal newline `render` can return is its own
    /// truncation suffix's leading one -- every C0 control in the input,
    /// U+000A included, comes back as caret notation, and line/paragraph
    /// separators come back as `<U+XXXX>` tokens.
    /// The finished row is fitted to `menuRowWidth` by
    /// `fittedToMenuWidth(_:)` rather than left as wide as its character
    /// count happens to draw -- the width cap must apply to the WHOLE
    /// prefixed row ("N. "/"▸ " included), so this does its own render+
    /// fold+fit rather than delegating to `menuRowTitle(_:)` (which fits
    /// its argument alone, before any prefix a caller might add).
    private func queueEntryLabel(_ entry: ApprovalBannerModel.QueueEntry) -> String {
        let rendered = ControlCharacterDisplay.render(entry.previewLine).replacingOccurrences(of: "\n", with: " ")
        let label = "\(entry.position). \(rendered)"
        let row = entry.isCurrent ? "▸ \(label)" : label
        return Self.fittedToMenuWidth(row)
    }

    /// Every "Options" pull-down's own row title -- claude-code-choice
    /// labels, permission-suggestion labels, question option labels/
    /// descriptions -- goes through this: `ControlCharacterDisplay.
    /// render`, fold any literal newline to a space (an `NSMenuItem`
    /// draws one as a real line break), then `fittedToMenuWidth(_:)`.
    /// Shared by `AgentToolApprovalView`/`AgentQuestionBannerView` (both
    /// in this module, so `ApprovalBannerView.menuRowTitle(_:)` is a
    /// plain cross-file call, no protocol needed) as well as this file's
    /// own `.mcpTool` menu items.
    static func menuRowTitle(_ text: String) -> String {
        let rendered = ControlCharacterDisplay.render(text).replacingOccurrences(of: "\n", with: " ")
        return fittedToMenuWidth(rendered)
    }

    /// The width, in points, a menu row is bounded to. A character count
    /// bounds how wide a row DRAWS only for one script: the same count is
    /// roughly 560pt of ASCII and roughly 1040pt of CJK, so the menu's
    /// width swung with whatever the payload happened to contain.
    /// Measuring in points is what actually bounds it.
    private static let menuRowWidth: CGFloat = 450

    /// Elides `row` in the MIDDLE until it draws within `menuRowWidth` in
    /// the menu font, keeping its tail: the end of a path or a command is
    /// usually what distinguishes one queued request (or choice) from
    /// another, and a trailing ellipsis drops exactly that. Binary search
    /// for the widest kept-`Character` count that fits, appending whole
    /// `Character`s only so a grapheme cluster is never split.
    private static func fittedToMenuWidth(_ row: String) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        func width(_ text: String) -> CGFloat { text.size(withAttributes: attributes).width }
        guard width(row) > menuRowWidth else { return row }

        let characters = Array(row)
        func elided(keeping keptCount: Int) -> String {
            let headCount = (keptCount + 1) / 2
            return String(characters.prefix(headCount)) + "…" + String(characters.suffix(keptCount - headCount))
        }

        var low = 0
        var high = characters.count - 1
        while low < high {
            let candidate = (low + high + 1) / 2
            if width(elided(keeping: candidate)) <= menuRowWidth {
                low = candidate
            } else {
                high = candidate - 1
            }
        }
        return elided(keeping: low)
    }
}

/// The notification shell's own trailing column, shared by every
/// `request.source` case: a primary action (optional -- `nil` renders
/// no button at all, only the menu, e.g. an `.agentQuestion` whose
/// single-select click already confirms without a separate confirm
/// step) above an "Options" pull-down listing every other choice.
/// `.frame(maxWidth: .infinity)` on both controls, inside a column
/// fixed to `width`, is what keeps them the same width as each other --
/// `.fixedSize()` would defeat that by letting each control hug its own
/// content instead.
struct ApprovalActionColumn<Items: View>: View {
    static var width: CGFloat { 96 }

    let primary: AnyView?
    @ViewBuilder let menuItems: () -> Items

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let primary {
                primary
                    .frame(maxWidth: .infinity)
            }
            Menu {
                menuItems()
            } label: {
                Text("Options")
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.optionsMenu)
            .accessibilityLabel(Text("Options"))
        }
        .controlSize(.small)
        .frame(width: Self.width)
    }
}
