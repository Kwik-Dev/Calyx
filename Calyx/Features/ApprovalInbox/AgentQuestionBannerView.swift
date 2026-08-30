// AgentQuestionBannerView.swift
// Calyx
//
// The approval banner's `.agentQuestion` mode (Claude Code's
// AskUserQuestion, see `ApprovalRequest.Source`): everything the
// question form itself shows and does -- the per-question header chip,
// question text, choice rows (or, for a zero-option question, the
// free-text field directly -- a lenient decode, see
// `AgentHookToolCall.decodeQuestions`'s own doc comment), the standing
// "Other" row with its own inline text field, the "Add notes" field, the
// side-by-side markdown preview box (when any option has a `preview`),
// the Next/Answer button, and the right cluster's "i / n" progress
// label plus [Back]/[Answer in Pane]/[Chat about this]/[Cancel]. Hosted
// by `ApprovalBannerView`, which renders only this view (plus the
// banner-level header and, separately, the queue navigator -- see that
// file's own header comment) for a `.agentQuestion`-sourced request.
//
// The question content spans the WHOLE banner width (`questionContent`'s
// own `.frame(maxWidth: .infinity, alignment: .leading)`, and this
// view's own root claiming the same from `ApprovalBannerView`'s outer
// HStack) -- the earlier layout squeezed it into a narrow middle column
// with unused space on both sides, since neither this view's own root
// nor its `questionContent` child ever told their parent HStack they
// could expand. Choice rows share `ChoiceRowStyle` with
// `AgentToolApprovalView`'s own rows, which visibly tracks hover/
// pressed/selected -- the earlier plain `.buttonStyle(.bordered)` gave
// no hover feedback at all. [Cancel] (`.denied(.questionNotAnswered)`)
// and [Chat about this] (`.interrupted(.chatAboutQuestion)`) are now two
// separate, explicitly labeled actions -- the earlier single "Skip"
// button conflated the TUI's own distinct "3: cancel" and "4: chat about
// this" options into one.
//
// Owns `@State private var form: AgentQuestionFormState` -- the state
// machine, testable without SwiftUI (`AgentQuestionFormState.swift`).
// This view contains no answer-building or eligibility logic of its
// own -- every rule (what a click does, what "Next"/"Answer" enables,
// which option's preview shows, what `goBack()` restores) lives in
// `form`.
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
// on screen. Both the "Other"/zero-option free-text field and the notes
// field can hold first responder, and the root `.onDisappear` restores
// terminal focus for either. See `textFieldWasFocused`'s own doc
// comment.
//
// Neither text field is ever made first responder by this code (see
// RecoveryBarView's own header comment for why no bar/banner control
// here ever calls `makeFirstResponder` itself) -- `@FocusState` only
// OBSERVES whether the user's own click gave either field focus, and the
// "Other" row's own click handler (`onTapGesture`, not a `Button`, so the
// field's own click-to-focus keeps working underneath it) only selects
// the row and enables its field -- it never programmatically focuses it
// either.

import SwiftUI

struct AgentQuestionBannerView: View {
    let prompt: AgentQuestionPrompt
    let onAnswer: (AgentQuestionAnswers) -> Void
    /// The right cluster's [Cancel] action -- replaces the earlier
    /// "Skip". Resolves `.denied(.questionNotAnswered)` via
    /// `ApprovalBannerModel.cancelQuestion(id:)`.
    let onCancel: () -> Void
    /// The right cluster's [Chat about this] action, the TUI's own
    /// "4: chat about this" choice. Resolves `.interrupted(
    /// .chatAboutQuestion)` via `ApprovalBannerModel.chatAboutQuestion(
    /// id:)`.
    let onChatAboutQuestion: () -> Void
    let onAnswerInPane: () -> Void
    /// Called (deferred past the current transaction, see this view's
    /// own root-level `.onDisappear`) when the whole question view is
    /// torn down while either text field ("Other"/the zero-option
    /// free-text field, or the notes field) held focus.
    let onTextFieldRemoved: () -> Void

    @State private var form: AgentQuestionFormState

    /// Which of this view's two text fields currently holds focus, if
    /// either -- the "Other" row's field and the zero-option question's
    /// own field share `.other` (only one of the two ever renders at
    /// once, see `questionContent`'s own `isFreeTextOnly` gate), the
    /// notes field uses `.notes`.
    private enum FocusedField: Hashable {
        case other, notes
    }
    @FocusState private var focusedField: FocusedField?

    /// Mirrors `focusedField` into a plain `@State` flag read by this
    /// view's own ROOT-level `.onDisappear` (not either field's own) --
    /// both fields disappear mid-prompt too (the "Other"/zero-option
    /// field whenever the form advances past a question answered via
    /// "Other" to the next question; the notes field the same way), and
    /// that transition must not restore terminal focus. Reading
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
        onCancel: @escaping () -> Void,
        onChatAboutQuestion: @escaping () -> Void,
        onAnswerInPane: @escaping () -> Void,
        onTextFieldRemoved: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.onAnswer = onAnswer
        self.onCancel = onCancel
        self.onChatAboutQuestion = onChatAboutQuestion
        self.onAnswerInPane = onAnswerInPane
        self.onTextFieldRemoved = onTextFieldRemoved
        self._form = State(initialValue: AgentQuestionFormState(prompt: prompt))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            questionContent
            actionCluster
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Content: full-width question body

    /// The current question's header chip (if any) + text + choice rows
    /// (or, for a zero-option question, the free-text field directly)
    /// + "Add notes" + (once a confirm step is needed) the Next/Answer
    /// button. Claims the FULL remaining banner width -- see this file's
    /// own header comment for why.
    private var questionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = form.currentQuestion.header, !header.isEmpty {
                Text(ControlCharacterDisplay.render(header))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            Text(ControlCharacterDisplay.render(form.currentQuestion.text))
                .font(.callout)
                .fontWeight(.semibold)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.questionText)

            if form.isFreeTextOnly {
                freeTextField
            } else {
                questionOptionsSection
            }

            notesSection

            // A confirm step is needed whenever the value isn't submitted
            // by the option click itself: every multi-select question
            // (toggling never submits on its own), and any question whose
            // free-text field is showing (either because "Other" was
            // chosen or the question has zero options -- the typed text
            // still needs confirming either way). A plain single-select
            // click on a listed option bypasses this entirely (see
            // `handleOptionClick`).
            if form.currentQuestion.multiSelect || form.showsFreeTextField {
                Button(form.isLastQuestion ? "Answer" : "Next") {
                    confirm()
                }
                .disabled(!form.canConfirm)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.answerButton)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focusedField) { _, newValue in textFieldWasFocused = newValue != nil }
    }

    /// The option-row list alone, or side by side with a markdown
    /// preview box (each taking half the available width) when any
    /// option of the current question carries a non-nil `preview` -- the
    /// AskUserQuestion schema's own layout rule ("when any option has a
    /// preview, the UI switches to a side-by-side layout with a vertical
    /// option list on the left and the preview on the right"). Never
    /// rendered for a zero-option question -- see `questionContent`'s
    /// own `isFreeTextOnly` gate.
    private var questionOptionsSection: some View {
        Group {
            if form.hasPreviews {
                HStack(alignment: .top, spacing: 12) {
                    optionListView.frame(maxWidth: .infinity, alignment: .leading)
                    previewBox.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                optionListView
            }
        }
    }

    /// The option-row list + the standing "Other" row. Content-hugging
    /// -- a short option list must never reserve blank space, and
    /// `maxHeight: 220` caps a long one instead of growing the banner
    /// unbounded. "Other" is a STANDING choice appended after every
    /// question's own listed options -- Claude Code's own AskUserQuestion
    /// contract always offers it in addition to `options`, which itself
    /// never carries it (see `otherRow`'s own doc comment) -- never
    /// detected from an option's own label.
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
    /// (`form.previewText` changes on hover); `optionListView` and
    /// `payloadView` hug their content instead because their content
    /// only changes when the whole view is torn down and recreated for
    /// a different question or request.
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
    /// why that string is never treated specially here). Shares
    /// `ChoiceRowStyle` with every other choice row in both banners --
    /// see that type's own doc comment. `.onHover` tracks `form.
    /// hoveredOptionIndex`, the highest-priority input to `form.
    /// previewText`.
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
        .onHover { isHovering in
            if isHovering {
                form.hoveredOptionIndex = index
            } else if form.hoveredOptionIndex == index {
                form.hoveredOptionIndex = nil
            }
        }
    }

    /// The standing "Other" choice, appended after every question's own
    /// listed options -- NOT one of them. Claude Code's own AskUserQuestion
    /// tool always offers a free-text "Other" entry in addition to
    /// `tool_input.questions[].options`; the hook payload's own `options`
    /// array never carries it (`AgentHookToolCall.decode`'s own doc
    /// comment). The label and its inline text field sit on the SAME
    /// row (the TUI's own layout), rather than the field only appearing
    /// once "Other" is chosen: clicking the row (anywhere but directly
    /// inside the field, which keeps its own click-to-focus) selects it
    /// and ENABLES the field (`.disabled(!form.otherSelected)`) -- the
    /// field itself is never programmatically focused, only enabled, so
    /// it still only takes focus by the user's own click into it. Not a
    /// `Button` (unlike `optionButton`/the tool-approval banner's rows):
    /// a `TextField` nested inside a `Button`'s own label loses its own
    /// click-to-focus/type behavior on macOS, since the enclosing
    /// `Button` claims the whole row's hit-testing -- `.onTapGesture`
    /// here, plus the row's own background/hover state built the same
    /// way `ChoiceRowStyle` computes its own (`ChoiceRowStyle.
    /// backgroundColor(isSelected:isHovering:)`, exposed for exactly this
    /// case), sidesteps that without losing the field's own interaction.
    /// Only rendered by `optionListView` -- a zero-option question shows
    /// the field directly instead (see `questionContent`'s own
    /// `isFreeTextOnly` gate), with no "Other" row needed since there is
    /// nothing else to choose.
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
        .onHover { otherRowHovering = $0 }
        .onTapGesture {
            form.chooseOther()
        }
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherButton)
    }

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
    /// the TUI's own two distinct placeholders. Shared by the "Other"
    /// row's own inline field and a zero-option question's field, since a
    /// zero-option question IS the free-text choice (see `isFreeTextOnly`'s
    /// own doc comment).
    private var otherPlaceholder: String {
        form.currentQuestion.multiSelect ? "Type something" : "Type something."
    }

    /// A zero-option question's own field -- shown unconditionally, with
    /// no row/selection state around it (there is nothing else to
    /// choose), unlike the "Other" row's field above.
    private var freeTextField: some View {
        TextField(otherPlaceholder, text: $form.otherText)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .other)
            .onSubmit { confirm() }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherTextField)
    }

    /// The TUI's own "n: add notes" affordance: a button that reveals a
    /// field bound to `form.notesText`, shown below the options (or the
    /// free-text field, for a zero-option question) -- Return confirms,
    /// same as the "Other" field, the zero-option field, and the tool
    /// banner's amend field.
    private var notesSection: some View {
        Group {
            if form.notesVisible {
                TextField("Add notes", text: $form.notesText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .notes)
                    .onSubmit { confirm() }
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.notesTextField)
            } else {
                Button("Add notes") {
                    form.showNotes()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.notesButton)
            }
        }
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

    // MARK: - Right cluster: top-aligned actions

    /// "i / n" (while more than one question is queued in THIS prompt --
    /// distinct from `ApprovalBannerView`'s own queue navigator "N / M",
    /// which browses every pending request queued for this WINDOW, not
    /// the questions within this one prompt), [Back] (once `form.
    /// canGoBack`), [Answer in Pane], [Chat about this], [Cancel] --
    /// top-aligned alongside the now full-width `questionContent`.
    private var actionCluster: some View {
        HStack(spacing: 8) {
            if form.prompt.questions.count > 1 {
                Text("\(form.position.index) / \(form.position.count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.questionPosition)
            }

            if form.canGoBack {
                Button("Back") {
                    form.goBack()
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.backButton)
            }

            Button("Answer in Pane") {
                onAnswerInPane()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.answerInPaneButton)

            Button("Chat about this") {
                onChatAboutQuestion()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.chatButton)

            Button("Cancel") {
                onCancel()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.cancelButton)
        }
        .fixedSize()
    }
}
