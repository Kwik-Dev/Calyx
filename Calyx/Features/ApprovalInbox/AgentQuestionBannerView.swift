// AgentQuestionBannerView.swift
// Calyx
//
// The approval banner's `.agentQuestion` mode (Claude Code's
// AskUserQuestion, see `ApprovalRequest.Source`): everything the
// question form itself shows and does -- the per-question header chip,
// question text, option list (or, for a zero-option question, the
// free-text field directly -- a lenient decode, see
// `AgentHookToolCall.decodeQuestions`'s own doc comment), the standing
// "Other…" button, the side-by-side markdown preview box (when any
// option has a `preview`), the Next/Answer button, and the right
// column's "i / n" progress label plus [Answer in Pane]/[Skip]. Hosted
// by `ApprovalBannerView`, which renders only this view (plus the
// banner-level header and, separately, the queue navigator -- see that
// file's own header comment) for a `.agentQuestion`-sourced request.
//
// Owns `@State private var form: AgentQuestionFormState` -- the state
// machine, testable without SwiftUI (`AgentQuestionFormState.swift`).
// This view contains no answer-building or eligibility logic of its
// own: every rule (what a click does, what "Next"/"Answer" enables,
// which option's preview shows) lives in `form`.
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
// that ever needs to restore terminal focus -- not the free-text
// field's own `.onDisappear`, which also fires mid-prompt whenever the
// form advances past a question answered via "Other" while this view
// stays on screen. See `otherFieldWasFocused`'s own doc comment.
//
// The free-text field is never made first responder by this code (see
// RecoveryBarView's own header comment for why no bar/banner control
// here ever calls `makeFirstResponder` itself) -- `@FocusState` only
// OBSERVES whether the user's own click gave it focus.

import SwiftUI

struct AgentQuestionBannerView: View {
    let prompt: AgentQuestionPrompt
    let onAnswer: (AgentQuestionAnswers) -> Void
    let onSkip: () -> Void
    let onAnswerInPane: () -> Void
    /// Called (deferred past the current transaction, see this view's
    /// own root-level `.onDisappear`) when the whole question view is
    /// torn down while the free-text field held focus.
    let onFreeTextFieldRemoved: () -> Void

    @State private var form: AgentQuestionFormState
    @FocusState private var otherFieldFocused: Bool

    /// Mirrors `otherFieldFocused` into a plain `@State` flag read by
    /// this view's own ROOT-level `.onDisappear` (not the free-text
    /// field's) -- the field itself disappears mid-prompt too, whenever
    /// the form advances past a question answered via "Other" to the
    /// next question, and that transition must not restore terminal
    /// focus. Reading `otherFieldFocused` directly from the root
    /// `.onDisappear` is not reliable either: SwiftUI clears
    /// `@FocusState` automatically once its bound view disappears, but
    /// does not document that clearing's ordering relative to the root
    /// view's own `.onDisappear`. Because `ApprovalBannerView` gives
    /// this whole view `.id(request.id)`, every real removal cause
    /// (a different request displayed, hold-window expiry, pane close,
    /// `expireAll`, cancellation) tears this view down and recreates it
    /// fresh (see this file's own header comment), so the root
    /// `.onDisappear` firing is exactly the signal to restore focus on.
    @State private var otherFieldWasFocused = false

    init(
        prompt: AgentQuestionPrompt,
        onAnswer: @escaping (AgentQuestionAnswers) -> Void,
        onSkip: @escaping () -> Void,
        onAnswerInPane: @escaping () -> Void,
        onFreeTextFieldRemoved: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.onAnswer = onAnswer
        self.onSkip = onSkip
        self.onAnswerInPane = onAnswerInPane
        self.onFreeTextFieldRemoved = onFreeTextFieldRemoved
        self._form = State(initialValue: AgentQuestionFormState(prompt: prompt))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            questionContent
            Spacer(minLength: 16)
            actionColumn
        }
        // Fires only when this whole view (not just the free-text field)
        // is torn down -- `.id(request.id)` at the `ApprovalBannerView`
        // call site makes every removal cause (a different request
        // displayed, hold-window expiry, pane close, `expireAll`,
        // cancellation) go through this same root-level `.onDisappear`,
        // never a mid-prompt one. The field's own `.onDisappear` also
        // fires when the form advances past a question answered via
        // "Other" (the field is removed while this view stays up for the
        // next question) -- that transition must NOT restore terminal
        // focus, so this handler lives here instead.
        .onDisappear {
            guard otherFieldWasFocused else { return }
            otherFieldWasFocused = false
            Task { @MainActor in
                onFreeTextFieldRemoved()
            }
        }
    }

    // MARK: - Left column: question content

    /// The current question's header chip (if any) + text + option
    /// section (empty for a zero-option question) + free-text field
    /// (shown unconditionally for a zero-option question, or once
    /// "Other" is selected for one with options) + (once a confirm step
    /// is needed) the Next/Answer button.
    private var questionContent: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            if !form.isFreeTextOnly {
                questionOptionsSection
            }

            if form.showsFreeTextField {
                TextField("Type your answer", text: $form.otherText)
                    .textFieldStyle(.roundedBorder)
                    .focused($otherFieldFocused)
                    .onSubmit { confirm() }
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherTextField)
            }

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
        .onChange(of: otherFieldFocused) { _, newValue in otherFieldWasFocused = newValue }
    }

    /// The option-button list alone, or side by side with a markdown
    /// preview box when any option of the current question carries a
    /// non-nil `preview` -- the AskUserQuestion schema's own layout rule
    /// ("when any option has a preview, the UI switches to a side-by-side
    /// layout with a vertical option list on the left and the preview on
    /// the right"). Never rendered for a zero-option question -- see
    /// `questionContent`'s own `isFreeTextOnly` gate.
    private var questionOptionsSection: some View {
        Group {
            if form.hasPreviews {
                HStack(alignment: .top, spacing: 8) {
                    optionListView
                    previewBox
                }
            } else {
                optionListView
            }
        }
    }

    /// The option-button list + a standing "Other…" button. Content-
    /// hugging -- a short option list must never reserve blank space,
    /// and `maxHeight: 220` caps a long one instead of growing the
    /// banner unbounded. "Other…" is a STANDING choice appended after
    /// every question's own listed options -- Claude Code's own
    /// AskUserQuestion contract always offers it in addition to
    /// `options`, which itself never carries it (see `otherButton`'s own
    /// doc comment) -- never detected from an option's own label.
    private var optionListView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(form.currentQuestion.options.enumerated()), id: \.offset) { index, option in
                    optionButton(index: index, option: option)
                }
                otherButton
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

    /// One LISTED option's button, rendered and identified the same way
    /// regardless of what its own label happens to read (including the
    /// literal text "Other", should a future payload ever carry one
    /// among its listed options -- see `otherButton`'s own doc comment
    /// for why that string is never treated specially here). `.onHover`
    /// tracks `form.hoveredOptionIndex`, the highest-priority input to
    /// `form.previewText`.
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : nil)
        .controlSize(.small)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.optionButton(index))
        .onHover { isHovering in
            if isHovering {
                form.hoveredOptionIndex = index
            } else if form.hoveredOptionIndex == index {
                form.hoveredOptionIndex = nil
            }
        }
    }

    /// The standing "Other…" choice, appended after every question's own
    /// listed options -- NOT one of them. Claude Code's own AskUserQuestion
    /// tool always offers a free-text "Other" entry in addition to
    /// `tool_input.questions[].options`; the hook payload's own `options`
    /// array never carries it (`AgentHookToolCall.decode`'s own doc
    /// comment). Selecting it reveals the free-text field and deselects
    /// every listed option -- exclusive with them, single- or multi-select
    /// alike, same as selecting a listed option clears it (see
    /// `handleOptionClick`). Only rendered by `optionListView` -- a
    /// zero-option question shows the field directly instead (see
    /// `questionContent`'s own `isFreeTextOnly` gate), with no "Other…"
    /// click needed since there is nothing else to choose.
    private var otherButton: some View {
        Button {
            form.chooseOther()
        } label: {
            Text("Other…")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(form.otherSelected ? .accentColor : nil)
        .controlSize(.small)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.otherButton)
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

    // MARK: - Right column: actions

    /// [Answer in Pane]/[Skip] plus, while more than one question is
    /// queued in THIS prompt, an "i / n" progress label -- distinct from
    /// `ApprovalBannerView`'s own queue navigator "N / M", which browses
    /// every pending request queued for this WINDOW, not the questions
    /// within this one prompt.
    private var actionColumn: some View {
        HStack {
            if form.prompt.questions.count > 1 {
                Text("\(form.position.index) / \(form.position.count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.questionPosition)
            }

            Button("Answer in Pane") {
                onAnswerInPane()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.answerInPaneButton)

            Button("Skip") {
                onSkip()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.skipButton)
        }
    }
}
