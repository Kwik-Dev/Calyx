// ApprovalBannerView.swift
// Calyx
//
// SwiftUI view for the Cockpit approval banner: shown at the top of a
// window's content when `model.current` is non-nil (see
// ApprovalBannerModel's own file header for the full ownership/
// visibility rules). Hosted via `MainContentView.body`'s
// `mainContent.safeAreaInset(edge: .top)`, stacked with RecoveryBarView
// -- see RecoveryBarView's own file header for why neither bar is ever
// made first responder.
//
// `request` is threaded in explicitly (rather than read from
// `model.current` inside `body`) so this view's content is never itself
// optional -- MainContentView already unwraps `model.current` once to
// decide whether to show this view at all.
//
// Stage E: an `.agentHook`-sourced request (a CLI agent's PreToolUse
// hook call, see `ApprovalRequest.Source`) renders the same Deny/Always
// Allow/Allow row as an `.mcpTool`-sourced one, PLUS a compact
// cross-actions menu (see `crossActionsMenu(toolName:)`) with two
// broader actions. An `.mcpTool`-sourced request renders exactly as
// before -- no menu.
//
// Queue navigation: while `model.positionInfo.count > 1`, a Previous/
// Next chevron pair + "N / M" position label (see
// `queueNavigator(positionInfo:)`) renders at the action cluster's
// leading edge, adjacent to the decision buttons -- the browse-then-
// decide loop keeps the mouse in one place; the sequential loop never
// needs the arrows at all thanks to advance-on-decide (see
// ApprovalBannerModel.advanceCursor(pastDisplayed:excluding:)'s own doc
// comment). Drives `ApprovalBannerModel`'s own `selectedRequestID`
// cursor -- a single queued request renders no navigator at all, since
// there is nothing to step to. Owned entirely by this shell (it reads
// `model` directly), for both an ordinary request and an
// `.agentQuestion`-sourced one alike -- rendered just before whichever
// content follows it (the ordinary Deny/Always Allow/Allow row, or
// `AgentQuestionBannerView`, see below).
//
// An `.agentQuestion`-sourced request (Claude Code's AskUserQuestion,
// see `ApprovalRequest.Source`) renders neither the Deny/Always Allow/
// Allow row, the cross-actions menu, nor the raw payload -- instead this
// view renders only `AgentQuestionBannerView`, the ENTIRE question form
// (option list, free-text field, Next/Answer, the side-by-side preview
// box, and the right column's "i / n"/[Answer in Pane]/[Skip] --
// AgentQuestionBannerView's own file header comment covers that layout
// and its `AgentQuestionFormState` state machine in full). Given
// `.id(request.id)`, so a different request tears the whole child view
// down and creates a fresh one -- this shell keeps no question-specific
// `@State` of its own, and answering, skipping, or "Answer in Pane"
// route through plain closures into `model`.

import SwiftUI
import AppKit

struct ApprovalBannerView: View {
    let model: ApprovalBannerModel
    let request: ApprovalRequest

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var questionPrompt: AgentQuestionPrompt? {
        guard case .agentQuestion(_, let prompt) = request.source else { return nil }
        return prompt
    }

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
    /// glance without printing a full UUID into the banner), or "this
    /// window" for a window-agnostic (nil targetSurfaceID) request.
    private var targetLabel: String {
        guard let targetSurfaceID = request.targetSurfaceID else { return "this window" }
        return String(targetSurfaceID.uuidString.prefix(8))
    }

    /// Stage E: the CLI's own tool name alone (e.g. "Bash"), NOT
    /// `displayToolName`'s "Kind · toolName" combination -- used to title
    /// BOTH the main action row's pane-scoped "Always Allow <toolName> in
    /// This Pane" button (see `alwaysAllowButtonTitle` below) and the
    /// cross-actions menu's "Always Allow <toolName> in All Panes" label,
    /// so the two actions read as a parallel This-Pane/All-Panes contrast
    /// naming the same tool. `nil` for an `.mcpTool`-sourced request,
    /// which never shows the menu and keeps the main button's plain
    /// "Always Allow" label (see `alwaysAllowButtonTitle`). Routed through
    /// `ControlCharacterDisplay.render` same as `toolName` above -- it
    /// comes from the same untrusted tool-call provenance.
    private var agentHookToolName: String? {
        guard case .agentHook(let toolName, _, _) = request.source else { return nil }
        return ControlCharacterDisplay.render(toolName)
    }

    /// Stage E: the main action row's middle button's label. For an
    /// `.agentHook`-sourced request, `model.alwaysAllow(id:)` records
    /// PANE-scoped memory (this tool, THIS pane) -- so the label names
    /// the tool and says "This Pane" to contrast with the cross-actions
    /// menu's "Always Allow <toolName> in All Panes" item, which records
    /// CROSS memory instead. For an `.mcpTool`-sourced request the same
    /// button flips the global cockpit auto-approve toggle, so it keeps
    /// the unqualified "Always Allow" label.
    private var alwaysAllowButtonTitle: String {
        guard let agentHookToolName else { return "Always Allow" }
        return "Always Allow \(agentHookToolName) in This Pane"
    }

    private var headerText: String {
        "\(toolName) → \(targetLabel)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerText)
                    .font(.callout)
                    .fontWeight(.semibold)

                if questionPrompt == nil {
                    payloadView
                }
            }

            // Queue navigation: immediately adjacent to the decision
            // controls that follow it -- Deny/Always Allow/Allow for an
            // ordinary request, or `AgentQuestionBannerView`'s own
            // question form for an `.agentQuestion`-sourced one -- the
            // browse-then-decide loop (glance at each queued command,
            // then click Previous/Next to compare before deciding) keeps
            // the mouse in one place instead of ping-ponging across the
            // banner's full width to a header-area control. The purely
            // sequential loop (just clicking Allow/Deny down the queue)
            // never needs the arrows at all, since advance-on-decide
            // already moves the cursor forward on every decision (see
            // ApprovalBannerModel.advanceCursor(pastDisplayed:
            // excluding:)'s own doc comment). Only shown while more than
            // one request is queued for this window (a single request
            // has nothing to navigate to) -- see ApprovalBannerModel.
            // positionInfo's own doc comment. `AgentQuestionBannerView`
            // does not take `model`, so this is rendered once per branch
            // rather than hoisted above the split.
            if let questionPrompt {
                if let positionInfo = model.positionInfo, positionInfo.count > 1 {
                    queueNavigator(positionInfo: positionInfo)
                        .padding(.trailing, 8)
                }
                AgentQuestionBannerView(
                    prompt: questionPrompt,
                    onAnswer: { answers in model.answer(id: request.id, answers: answers) },
                    onSkip: { model.skip(id: request.id) },
                    onAnswerInPane: { model.answerInPane(id: request.id) },
                    onFreeTextFieldRemoved: { model.restoreTerminalFocusAfterInput() }
                )
                .id(request.id)
            } else {
                Spacer(minLength: 16)
                HStack {
                    if let positionInfo = model.positionInfo, positionInfo.count > 1 {
                        queueNavigator(positionInfo: positionInfo)
                            .padding(.trailing, 8)
                    }

                    Button("Deny") {
                        model.deny(id: request.id)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.denyButton)

                    Button(alwaysAllowButtonTitle) {
                        model.alwaysAllow(id: request.id)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.alwaysAllowButton)

                    Button("Allow") {
                        model.allow(id: request.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowButton)

                    // Stage E: only an `.agentHook`-sourced request has a
                    // cross-actions menu -- `.mcpTool` renders exactly as
                    // before it (no menu at all).
                    if let menuToolName = agentHookToolName {
                        crossActionsMenu(toolName: menuToolName)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.container)
    }

    /// Previous/Next chevron pair + "N / M" position label, rendered at
    /// the leading edge of the trailing action `HStack` (see this file's
    /// own header comment for why it sits there, adjacent to Deny/
    /// Always Allow/Allow, rather than up in the header area), shown
    /// only while more than one request is queued for this window (see
    /// the call site's own `positionInfo.count > 1` gate) -- mirrors
    /// `BrowserToolbarView`'s own chevron.left/chevron.right precedent
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
    /// .small)` + `.fixedSize()` throughout keep this content-hugging,
    /// same rationale as `crossActionsMenu`'s own header comment, so it
    /// never stretches the banner's action row. Disabled states are
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
    /// count happens to draw.
    private func queueEntryLabel(_ entry: ApprovalBannerModel.QueueEntry) -> String {
        let rendered = ControlCharacterDisplay.render(entry.previewLine).replacingOccurrences(of: "\n", with: " ")
        let label = "\(entry.position). \(rendered)"
        let row = entry.isCurrent ? "▸ \(label)" : label
        return Self.fittedToMenuWidth(row)
    }

    /// The width, in points, a queue preview menu row is bounded to. A
    /// character count bounds how wide a row DRAWS only for one script:
    /// the same count is roughly 560pt of ASCII and roughly 1040pt of
    /// CJK, so the menu's width swung with whatever the payload happened
    /// to contain. Measuring in points is what actually bounds it.
    private static let menuRowWidth: CGFloat = 450

    /// Elides `row` in the MIDDLE until it draws within `menuRowWidth` in
    /// the menu font, keeping its tail: the end of a path or a command is
    /// usually what distinguishes one queued request from another, and a
    /// trailing ellipsis drops exactly that. Binary search for the widest
    /// kept-`Character` count that fits, appending whole `Character`s
    /// only so a grapheme cluster is never split.
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

    /// Compact cross-actions menu, shown only for an `.agentHook`-sourced
    /// request (see `agentHookToolName`): two actions that go
    /// beyond this single request's own Deny/Always Allow/Allow --
    /// "Allow All Pending" drains every pending request store-wide, and
    /// "Always Allow ... in All Panes" records CROSS Always-Allow memory
    /// for this tool. Kept content-hugging (`.fixedSize()`), same
    /// rationale as `payloadView`'s own header comment, so the menu's
    /// compact ellipsis label never stretches the banner's action row.
    private func crossActionsMenu(toolName: String) -> some View {
        Menu {
            Button("Allow All Pending (\(model.totalPendingCount))") {
                model.allowAllPending()
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowAllPendingItem)

            Button("Always Allow \(toolName) in All Panes") {
                model.alwaysAllowAcrossPanes(id: request.id)
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.alwaysAllowAllPanesItem)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.crossActionsMenu)
    }

    /// Content-hugging payload: a one-line command must never reserve
    /// blank space (a ScrollView is normally GREEDY -- it claims its
    /// full proposed height even when its content is a single short
    /// line, which is what made the banner a mostly-blank band before
    /// this fix). `.fixedSize(vertical: true)` makes the ScrollView
    /// report its CONTENT height upward into this view's parent instead
    /// of the proposed one, so a one-line payload renders one line tall;
    /// `.frame(maxHeight: 120)`, applied BEFORE `.fixedSize` (so it
    /// clamps what content height gets reported), caps that at ~120pt so
    /// a long payload (bounded at 2000 characters by
    /// `ControlCharacterDisplay.render`'s own cap) still scrolls instead
    /// of growing the banner unbounded. Deliberately not
    /// `ViewThatFits(in: .vertical)` (an earlier attempt): a `.frame(
    /// maxHeight:)` wrapping the whole `ViewThatFits` proposes that same
    /// ~120pt height to WHICHEVER branch is chosen, including a
    /// plain-text branch -- floating a short line inside a still-120pt
    /// box instead of shrinking to it.
    private var payloadView: some View {
        ScrollView(.vertical) { payloadText }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var payloadText: some View {
        Text(ControlCharacterDisplay.render(request.displayPayload))
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payload)
    }
}
