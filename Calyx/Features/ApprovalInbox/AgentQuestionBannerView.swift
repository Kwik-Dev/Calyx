// AgentQuestionBannerView.swift
// Calyx
//
// The approval banner's `.agentQuestion` mode (Claude Code's
// AskUserQuestion, see `ApprovalRequest.Source`): renders the WHOLE
// two-column notification row for this source -- `ApprovalBannerView`
// only supplies its own `headerRow` (the tool/target label + queue
// navigator, identical across every source) as `header`, everything
// else is this view's own.
//
// This view owns `@State private var form: AgentQuestionFormState` and
// `@FocusState`, so unlike `.agentHook`'s primary button/menu items
// (`ApprovalBannerView.agentHookPrimaryButton`/`agentHookMenuItems(
// toolName:offers:)`, plain computed properties/functions `ApprovalBannerView`
// itself owns) this view CANNOT expose `primaryButton`/`menuItems` as
// computed properties for `ApprovalBannerView` to read: accessing a `@State`
// property outside of SwiftUI's own render pass for the view that owns
// it reads back only that property's `State(initialValue:)`, never the
// persisted value from a prior interaction -- concretely, calling
// `AgentQuestionBannerView(...).menuItems` from a DIFFERENT view's
// `body` would always show the pristine first-question state, and any
// action captured inside would write to a `State` location SwiftUI
// never installed. This view's own `body`, rendering its own leading
// column AND its own `ApprovalActionColumn`, is the only place `form`/
// `focusedField` may be read.
//
// Left column: `header`, the current question's own header chip (if
// any) + "i / n" position (only while more than one question is queued
// in THIS prompt -- distinct from `ApprovalBannerView`'s own queue
// navigator "N / M", which browses every pending request queued for
// this WINDOW, not the questions within this one prompt) + a tap/hover-
// to-expand question text (`ExpandableBodyText`, shared with
// `ApprovalBannerView`'s own tool/hook payload), then source-specific
// extras:
// the inline option-list layout (plus a side-by-side markdown preview
// box when any option carries a `preview`) for a multi-select question
// or one with any preview -- AskUserQuestion's own schema for the
// preview case ("when any option has a preview, the UI switches to a
// side-by-side layout with a vertical option list on the left and the
// preview on the right"), extended to every multi-select question too,
// since toggling never submits on its own and its rows must stay
// reachable without reopening the menu per click -- else the standing
// free-text field whenever `form.showsFreeTextField` (a zero-option
// question, or "Other…" chosen from the Options menu), then the "Add
// notes" field once revealed. A request whose prompt wants this inline
// layout for any of its questions gets the wide floating panel instead
// of the default notification width (`ApprovalRequest.
// prefersWideApprovalPanel`, `ApprovalPanelArranger.wideWidth`).
//
// Right column (`ApprovalActionColumn`): "Next"/"Answer" only while a
// confirm step is needed (a multi-select question, or a visible
// free-text field -- a plain single-select click on a listed option
// confirms immediately, see `handleOptionClick`), disabled until
// `form.canConfirm`. For a single-select question with no previews, the
// Options menu lists each listed option (`optionMenuItem(index:option:)`,
// a `Button` that confirms immediately) plus "Other…", then "Add
// notes"/"Back"/"Chat about this". For a multi-select question or one
// with any preview, the options themselves -- AND the standing "Other"
// choice -- stay in the inline layout instead (a hover-driven preview
// has no menu equivalent, a multi-select row must stay reachable
// without reopening the menu per click, and the inline "Other" row
// mirrors the CLI's own list layout), so the menu holds only "Add
// notes"/"Back"/"Chat about this", no "Other…" of its own. Choice rows
// share `ChoiceRowStyle` with the inline layout's own option rows.
//
// `ApprovalBannerView` gives this view `.id(request.id)`, so a
// different request tears this whole view (and its `form`) down and
// creates a fresh one -- there is no `.onChange(of:)` reset here. The
// same teardown covers every OTHER removal cause too (hold-window
// expiry via `ApprovalHookTiming`, `ApprovalInboxStore.
// expireForSurface` when the target pane closes, `expireAll`, or the
// long-poll awaiter's own cancellation all clear `ApprovalBannerModel.
// current`, which removes this view from the hierarchy the same way),
// so this view's own ROOT-level `.onDisappear` is the ONE mechanism
// that ever needs to restore terminal focus -- not either text field's
// own `.onDisappear`, which also fires mid-prompt whenever the form
// advances past a question answered via "Other" while this view stays
// on screen. Both the free-text field and the notes field can hold
// first responder, and the root `.onDisappear` restores terminal focus
// for either. See `textFieldWasFocused`'s own doc comment.
//
// Neither text field is ever made first responder by this code (see
// RecoveryBarView's own header comment for why no bar/banner control
// here ever calls `makeFirstResponder` itself) -- `@FocusState` only
// OBSERVES whether the user's own click gave either field focus.

import SwiftUI

struct AgentQuestionBannerView: View {
    let prompt: AgentQuestionPrompt
    let onAnswer: (AgentQuestionAnswers) -> Void
    /// The Options menu's "Chat about this" action, the TUI's own
    /// "4: chat about this" choice. Resolves `.interrupted(
    /// .chatAboutQuestion)` via `ApprovalBannerModel.chatAboutQuestion(
    /// id:)`.
    let onChatAboutQuestion: () -> Void
    /// Called (deferred past the current transaction, see this view's
    /// own root-level `.onDisappear`) when the whole question view is
    /// torn down while either text field (the free-text field or the
    /// notes field) held focus.
    let onTextFieldRemoved: () -> Void
    /// `ApprovalBannerView.headerRow`, type-erased at the call site so
    /// this view need not be generic over it.
    let header: AnyView

    @State private var form: AgentQuestionFormState

    /// Which of this view's two text fields currently holds focus, if
    /// either -- the standing free-text field (shown either because the
    /// question has zero options, or because "Other…" was chosen from
    /// the Options menu) uses `.other`, the notes field uses `.notes`.
    private enum FocusedField: Hashable {
        case other, notes
    }
    @FocusState private var focusedField: FocusedField?

    /// Mirrors `focusedField` into a plain `@State` flag read by this
    /// view's own ROOT-level `.onDisappear` (not either field's own) --
    /// both fields disappear mid-prompt too (the free-text field
    /// whenever the form advances past a question answered via "Other"
    /// to the next question; the notes field the same way), and that
    /// transition must not restore terminal focus. Reading
    /// `focusedField` directly from the root `.onDisappear` is not
    /// reliable either: SwiftUI clears `@FocusState` automatically once
    /// its bound view disappears, but does not document that clearing's
    /// ordering relative to the root view's own `.onDisappear`. Because
    /// `ApprovalBannerView` gives this whole view `.id(request.id)`,
    /// every real removal cause (a different request displayed, hold-
    /// window expiry, pane close, `expireAll`, cancellation) tears this
    /// view down and recreates it fresh (see this file's own header
    /// comment), so the root `.onDisappear` firing is exactly the signal
    /// to restore focus on.
    @State private var textFieldWasFocused = false

    init(
        prompt: AgentQuestionPrompt,
        onAnswer: @escaping (AgentQuestionAnswers) -> Void,
        onChatAboutQuestion: @escaping () -> Void,
        onTextFieldRemoved: @escaping () -> Void,
        header: AnyView
    ) {
        self.prompt = prompt
        self.onAnswer = onAnswer
        self.onChatAboutQuestion = onChatAboutQuestion
        self.onTextFieldRemoved = onTextFieldRemoved
        self.header = header
        self._form = State(initialValue: AgentQuestionFormState(prompt: prompt))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leftColumn
            ApprovalActionColumn(primary: primaryButton) { menuItems }
        }
        // Fires only when this whole view (not just one of its text
        // fields) is torn down -- `.id(request.id)` at the
        // `ApprovalBannerView` call site makes every removal cause (a
        // different request displayed, hold-window expiry, pane close,
        // `expireAll`, cancellation) go through this same root-level
        // `.onDisappear`, never a mid-prompt one. Either field's own
        // `.onDisappear` also fires when the form advances past a
        // question answered via "Other"/with notes (the field is removed
        // while this view stays up for the next question) -- that
        // transition must NOT restore terminal focus, so this handler
        // lives here instead.
        .onDisappear {
            guard textFieldWasFocused else { return }
            textFieldWasFocused = false
            Task { @MainActor in
                onTextFieldRemoved()
            }
        }
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            if let questionHeader = form.currentQuestion.header, !questionHeader.isEmpty {
                Text(ControlCharacterDisplay.render(questionHeader))
                    .font(.system(size: 11))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            if form.prompt.questions.count > 1 {
                Text("\(form.position.index) / \(form.position.count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.questionPosition)
            }

            ExpandableBodyText(
                text: ControlCharacterDisplay.render(form.currentQuestion.text),
                collapsedFont: .system(size: 12),
                collapsedIdentifier: AccessibilityID.ApprovalBanner.questionText,
                expandedFont: .callout,
                collapsedForegroundIsSecondary: false
            )

            extrasSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focusedField) { _, newValue in textFieldWasFocused = newValue != nil }
    }

    /// The inline option-list layout (`questionOptionsSection`) whenever
    /// the current question wants it (`AgentQuestionPrompt.Question.
    /// wantsInlineOptionList`: a non-empty option list that is either
    /// multi-select -- toggling never submits on its own, so its rows
    /// must stay reachable without reopening the menu for every click --
    /// or carries a `preview` on any option, which has no menu
    /// equivalent) -- else the standing free-text field whenever `form.
    /// showsFreeTextField` (a zero-option question, or "Other…" chosen
    /// from the Options menu) -- mutually exclusive with the inline
    /// layout, since that layout's own `optionListView` already carries
    /// its own inline "Other" row (`otherRow`) sharing the same `form.
    /// otherText`/`otherSelected` state `freeTextField` binds to; the
    /// Options menu's own "Other…" item (`menuItems`) reaches that SAME
    /// state either way, so choosing it from the menu while the inline
    /// layout is showing enables `otherRow`'s own field rather than
    /// opening a second one. A zero-option multi-select question (no
    /// options to list inline) falls through to `freeTextField` here,
    /// same as a zero-option single-select one. The "Add notes" field,
    /// once revealed, renders below either.
    @ViewBuilder
    private var extrasSection: some View {
        if form.currentQuestion.wantsInlineOptionList {
            questionOptionsSection
        } else if form.showsFreeTextField {
            freeTextField
        }

        if form.notesVisible {
            notesField
        }
    }

    /// `optionListView` alone for a multi-select question with no
    /// preview, or side by side with a markdown preview box (each taking
    /// half the available width, `minWidth: 200` apiece so neither
    /// collapses on a narrower wide panel) once `form.hasPreviews` -- the
    /// AskUserQuestion schema's own layout rule ("when any option has a
    /// preview, the UI switches to a side-by-side layout with a vertical
    /// option list on the left and the preview on the right").
    @ViewBuilder
    private var questionOptionsSection: some View {
        if form.hasPreviews {
            HStack(alignment: .top, spacing: 12) {
                optionListView.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                previewBox.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            }
        } else {
            optionListView
        }
    }

    /// The option-row list + the standing "Other" row -- rendered
    /// whenever `extrasSection` shows the inline layout (see that
    /// property's own doc comment); every other question renders its
    /// options through the Options menu instead (`menuItems`'s own
    /// `optionMenuItem(index:option:)`). Content-hugging -- a short
    /// option list must never reserve blank space, and `maxHeight: 220`
    /// caps a long one instead of growing the banner unbounded. "Other"
    /// is a STANDING choice appended after every question's own listed
    /// options -- Claude Code's own AskUserQuestion contract always
    /// offers it in addition to `options`, which itself never carries it
    /// (see `otherRow`'s own doc comment) -- never detected from an
    /// option's own label.
    private var optionListView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(form.currentQuestion.options.enumerated()), id: \.offset) { index, option in
                    optionButton(index: index, option: option)
                }
                otherRow
            }
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The markdown preview box `questionOptionsSection` shows next to
    /// the option list -- plain monospaced text (no markdown rendering
    /// engine here; `ControlCharacterDisplay.render` only escapes control
    /// characters), selectable, scrolling both directions inside a
    /// fixed-size box (same 220pt height cap as the option list) so a
    /// long line or a tall preview scrolls instead of widening the
    /// banner or growing it unbounded. Deliberately no `.fixedSize
    /// (horizontal: false, vertical: true)` here, unlike `optionListView`
    /// -- this box always reserves the full 220pt height so it does not
    /// resize as the pointer moves between previews of different lengths
    /// (`form.previewText` changes on hover); `optionListView` hugs its
    /// content instead because its content only changes when the whole
    /// view is torn down and recreated for a different question or
    /// request.
    private var previewBox: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(verbatim: ControlCharacterDisplay.render(form.previewText ?? ""))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.previewText)
        }
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
    }

    /// One LISTED option's row, rendered and identified the same way
    /// regardless of what its own label happens to read (including the
    /// literal text "Other", should a future payload ever carry one
    /// among its listed options -- see `otherRow`'s own doc comment for
    /// why that string is never treated specially here). Rendered
    /// whenever `extrasSection` shows the inline layout -- see
    /// `optionListView`'s own doc comment. Shares `ChoiceRowStyle` with
    /// `otherRow` below. `onAssumeInsideHover` (not plain SwiftUI
    /// `.onHover`: this row is rendered inside the floating approval
    /// panel, a non-activating window that never becomes key, where
    /// `.onHover`'s underlying tracking area never fires) tracks
    /// `form.hoveredOptionIndex`, the highest-priority input to
    /// `form.previewText`, through a synthetic `Binding<Bool>` since
    /// `hoveredOptionIndex` is one `Int?` shared across every row rather
    /// than a per-row `Bool`.
    private func optionButton(index: Int, option: AgentQuestionPrompt.Option) -> some View {
        let selected = form.selectedOptionIndices.contains(index)
        return Button {
            handleOptionClick(index: index)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(ControlCharacterDisplay.render(option.label))
                    .fontWeight(.semibold)
                if let description = option.description {
                    Text(ControlCharacterDisplay.render(description))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChoiceRowStyle(
            glyph: form.currentQuestion.multiSelect ? .multiSelect : .singleSelect, isSelected: selected
        ))
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.optionButton(index))
        .onAssumeInsideHover(Binding(
            get: { form.hoveredOptionIndex == index },
            set: { isHovering in
                if isHovering {
                    form.hoveredOptionIndex = index
                } else if form.hoveredOptionIndex == index {
                    form.hoveredOptionIndex = nil
                }
            }
        ))
    }

    /// The standing "Other" choice, appended after every question's own
    /// listed options -- NOT one of them (see `optionListView`'s own doc
    /// comment). Claude Code's own AskUserQuestion tool always offers a
    /// free-text "Other" entry in addition to `tool_input.questions[].
    /// options`; the hook payload's own `options` array never carries it
    /// (`AgentHookToolCall.decode`'s own doc comment). Rendered whenever
    /// `extrasSection` shows the inline layout -- that same condition is
    /// what `menuItems` uses to omit its OWN "Other…" item (see that
    /// property's own doc comment), so exactly one "Other" affordance
    /// exists per question: this row for the inline layout, or the
    /// menu's "Other…" (revealing `freeTextField` below the body instead)
    /// for a question rendering only through the menu. The label and its
    /// inline text field sit on the SAME
    /// row (the TUI's own layout), rather than the field only appearing
    /// once "Other" is chosen: clicking the row (anywhere but directly
    /// inside the field, which keeps its own click-to-focus) selects it
    /// and ENABLES the field (`.disabled(!form.otherSelected)`) -- the
    /// field itself is never programmatically focused, only enabled, so
    /// it still only takes focus by the user's own click into it. Not a
    /// `Button` (unlike `optionButton`): a `TextField` nested inside a
    /// `Button`'s own label loses its own click-to-focus/type behavior
    /// on macOS, since the enclosing `Button` claims the whole row's
    /// hit-testing -- `.onTapGesture` here, plus the row's own
    /// background/hover state built the same way `ChoiceRowStyle`
    /// computes its own (`ChoiceRowStyle.backgroundColor(isSelected:
    /// isHovering:)`, exposed for exactly this case), sidesteps that
    /// without losing the field's own interaction.
    private var otherRow: some View {
        HStack(spacing: 8) {
            Text(otherRowGlyph)
                .font(.callout)
                .frame(width: 16)
            Text("Other")
                .fontWeight(.semibold)
            TextField(otherPlaceholder, text: $form.otherText)
                .textFieldStyle(.plain)
                .disabled(!form.otherSelected)
                .focused($focusedField, equals: .other)
                .onSubmit { confirm() }
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherTextField)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(ChoiceRowStyle.backgroundColor(isSelected: form.otherSelected, isHovering: otherRowHovering))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onAssumeInsideHover($otherRowHovering)
        .onTapGesture {
            form.chooseOther()
        }
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherButton)
    }

    /// Tracked through `onAssumeInsideHover` rather than plain SwiftUI
    /// `.onHover`: this row is rendered inside the floating approval
    /// panel, a non-activating window that never becomes key, where
    /// `.onHover`'s underlying tracking area never fires.
    @State private var otherRowHovering = false

    /// ◯/● for a single-select question, ☐/☑ for multi-select -- the
    /// same glyph rule `ChoiceRowStyle` draws for a listed option, kept
    /// here as plain text rather than through `ChoiceRowStyle` itself
    /// since `otherRow` is not a `Button` (see `otherRow`'s own doc
    /// comment for why).
    private var otherRowGlyph: String {
        form.currentQuestion.multiSelect
            ? (form.otherSelected ? "☑" : "☐")
            : (form.otherSelected ? "●" : "◯")
    }

    /// "Type something." for a single-select question (its own trailing
    /// period), "Type something" for multi-select (no trailing period) --
    /// the TUI's own two distinct placeholders. Shared by `freeTextField`
    /// below and `otherRow`'s own inline field, since both are the same
    /// underlying `form.otherText` binding.
    private var otherPlaceholder: String {
        form.currentQuestion.multiSelect ? "Type something" : "Type something."
    }

    /// The standing free-text field shown below the body whenever
    /// `form.showsFreeTextField` and `!form.currentQuestion.
    /// wantsInlineOptionList` -- a zero-option question's own answer, or
    /// the field "Other…" (chosen
    /// from the Options menu) reveals. No row/selection chrome around it
    /// (unlike `otherRow`): for a zero-option question there is nothing
    /// else to choose, and for "Other…" the choice was already made by
    /// picking that menu item.
    private var freeTextField: some View {
        TextField(otherPlaceholder, text: $form.otherText)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .other)
            .onSubmit { confirm() }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherTextField)
    }

    /// The TUI's own "n: add notes" affordance: a field bound to
    /// `form.notesText`, revealed once `form.showNotes()` runs (the
    /// Options menu's own "Add notes" item) and shown below the other
    /// extras. Return confirms, same as the free-text field.
    private var notesField: some View {
        TextField("Add notes", text: $form.notesText)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .notes)
            .onSubmit { confirm() }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.notesTextField)
    }

    private func handleOptionClick(index: Int) {
        if let answers = form.selectOption(index) {
            onAnswer(answers)
        }
    }

    private func confirm() {
        if let answers = form.confirm() {
            onAnswer(answers)
        }
    }

    // MARK: - Right column: primary button + Options menu

    /// "Next"/"Answer" only while a confirm step is needed: every
    /// multi-select question (toggling never submits on its own), and
    /// any question whose free-text field is showing (either because
    /// "Other…" was chosen or the question has zero options -- the typed
    /// text still needs confirming either way). A plain single-select
    /// click on a listed option bypasses this entirely (see
    /// `handleOptionClick`), so the Options menu is the column's only
    /// content then.
    private var primaryButton: AnyView? {
        guard form.currentQuestion.multiSelect || form.showsFreeTextField else { return nil }
        return AnyView(
            Button(form.isLastQuestion ? "Answer" : "Next") { confirm() }
                .disabled(!form.canConfirm)
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.answerButton)
        )
    }

    /// Whenever `extrasSection` shows the inline layout (`form.
    /// currentQuestion.wantsInlineOptionList`), the options themselves --
    /// AND the standing "Other" choice (`otherRow`, the CLI's own list
    /// layout) -- stay in that layout instead (a hover-driven preview has
    /// no menu equivalent, and a multi-select row must stay reachable
    /// without reopening the menu per click), so this holds only
    /// `notesAndNavigationItems`, no "Other…" of its own. A zero-option
    /// question (`form.isFreeTextOnly`, for which `wantsInlineOptionList`
    /// is always false -- an empty `options` array has nothing to list or
    /// toggle) offers no options and no "Other…" either (there is nothing
    /// to choose an alternative to; its own free-text field is already
    /// showing directly below the body, via `extrasSection`'s own
    /// `showsFreeTextField` branch) -- same, just `notesAndNavigationItems`.
    /// Otherwise (single-select, no previews, where nothing renders
    /// inline): one row per listed option (`optionMenuItem(index:option:)`),
    /// "Other…" (`otherButton`), a `Divider()`, then
    /// `notesAndNavigationItems`.
    @ViewBuilder
    private var menuItems: some View {
        if form.isFreeTextOnly || form.currentQuestion.wantsInlineOptionList {
            notesAndNavigationItems
        } else {
            ForEach(Array(form.currentQuestion.options.enumerated()), id: \.offset) { index, option in
                optionMenuItem(index: index, option: option)
            }
            Button(ApprovalBannerView.menuRowTitle("Other…")) {
                form.chooseOther()
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherButton)
            Divider()
            notesAndNavigationItems
        }
    }

    /// One listed option's Options-menu row: a `Button` that confirms
    /// immediately, same as `handleOptionClick`'s own single-select
    /// branch -- only ever reached for a single-select question with no
    /// previews (see `menuItems`'s own doc comment); a multi-select or
    /// preview-carrying question renders its options through the inline
    /// layout instead (`optionButton`), never through this menu. Two
    /// `Text`s placed DIRECTLY in the label closure, not wrapped in a
    /// `VStack` -- macOS renders a menu item's second `Text` as its
    /// subtitle only when it is a sibling of the first, not a child of an
    /// intermediate container. The title stays EXACTLY `option.label`
    /// rendered through `ApprovalBannerView.menuRowTitle(_:)` (no
    /// description folded in), so a title-only lookup (e.g. an XCUITest's
    /// `title == "Red"` predicate) still matches.
    private func optionMenuItem(index: Int, option: AgentQuestionPrompt.Option) -> some View {
        let title = ApprovalBannerView.menuRowTitle(option.label)
        let description = option.description.map(ApprovalBannerView.menuRowTitle)
        return Button {
            handleOptionClick(index: index)
        } label: {
            Text(title)
            if let description {
                Text(description)
            }
        }
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.optionButton(index))
    }

    /// "Add notes" (only while `!form.notesVisible`), "Back" (only while
    /// `form.canGoBack`), "Chat about this" -- shared by every
    /// `menuItems` branch. No accessibility identifiers: every row here
    /// lands in a SwiftUI `Menu`, which macOS exposes as plain
    /// `NSMenuItem`s with no identifier of their own -- an XCUITest finds
    /// these rows by title instead, same as every other `Menu` row in
    /// this feature.
    @ViewBuilder
    private var notesAndNavigationItems: some View {
        if !form.notesVisible {
            Button(ApprovalBannerView.menuRowTitle("Add notes")) {
                form.showNotes()
            }
        }
        if form.canGoBack {
            Button(ApprovalBannerView.menuRowTitle("Back")) {
                form.goBack()
            }
        }
        Button(ApprovalBannerView.menuRowTitle("Chat about this")) {
            onChatAboutQuestion()
        }
    }
}
