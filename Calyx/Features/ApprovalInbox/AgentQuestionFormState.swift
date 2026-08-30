// AgentQuestionFormState.swift
// Calyx
//
// The AskUserQuestion form's own state machine, extracted out of the
// view so it is testable without SwiftUI: which question of a
// multi-question AgentQuestionPrompt is currently displayed, the
// in-progress selection for it, and every answer already collected for
// an earlier question. AgentQuestionBannerView owns exactly one of
// these (as @State) and contains no answer-building or eligibility
// logic of its own -- every rule (what counts as a valid selection,
// what an option click or a confirm does, which option's preview shows)
// lives here.
//
// A value type, not a class: SwiftUI's @State re-renders on assignment,
// and Equatable lets a test assert the whole state after one action
// without hand-picking fields.

import Foundation

struct AgentQuestionFormState: Equatable {
    let prompt: AgentQuestionPrompt

    /// Which question of `prompt.questions` is displayed. `prompt.
    /// questions` is guaranteed non-empty by `AgentHookToolCall.
    /// decodeQuestions`'s own contract, so this is always a valid index.
    private(set) var questionIndex = 0

    /// One `AgentQuestionAnswer` per question already confirmed, in
    /// question order -- does NOT include the question currently being
    /// answered.
    private(set) var collected: [AgentQuestionAnswer] = []

    /// The in-progress multi-select membership for `currentQuestion`.
    /// Meaningless (and always empty) while `otherSelected` is true --
    /// `selectOption(_:)` clears one whenever it sets the other.
    private(set) var selectedOptionIndices: Set<Int> = []

    /// Whether the standing "Other…" choice is active for
    /// `currentQuestion` -- mutually exclusive with `selectedOptionIndices`
    /// (see `selectOption(_:)`/`chooseOther()`).
    private(set) var otherSelected = false

    /// The free-text field's own contents -- bound directly by the view
    /// (`var`, not `private(set)`, so `$form.otherText` produces a
    /// `Binding`), reset to `""` whenever the question advances.
    var otherText = ""

    /// The most recently clicked option of `currentQuestion` -- a
    /// single-select click (which advances immediately) or a
    /// multi-select toggle (add or remove) -- regardless of the
    /// pointer's current hover target. Second priority for
    /// `previewText`, below `hoveredOptionIndex`.
    private(set) var lastInteractedOptionIndex: Int?

    /// The option currently under the pointer -- set/cleared directly by
    /// the view's own `.onHover` (`var`, not `private(set)`). Highest
    /// priority for `previewText`.
    var hoveredOptionIndex: Int?

    init(prompt: AgentQuestionPrompt) {
        self.prompt = prompt
    }

    /// `prompt.questions[questionIndex]` -- always valid, see
    /// `questionIndex`'s own doc comment.
    var currentQuestion: AgentQuestionPrompt.Question {
        prompt.questions[questionIndex]
    }

    var isLastQuestion: Bool {
        questionIndex == prompt.questions.count - 1
    }

    /// 1-based (index, count) position within `prompt.questions`, for the
    /// banner's own "i / n" progress label.
    var position: (index: Int, count: Int) {
        (questionIndex + 1, prompt.questions.count)
    }

    /// A lenient decode (`AgentHookToolCall.decodeQuestions`) can produce
    /// a question with zero options -- it renders free-text-only, with no
    /// "Other…" click needed to reveal the field (see `showsFreeTextField`).
    var isFreeTextOnly: Bool {
        currentQuestion.options.isEmpty
    }

    /// Whether the free-text field is showing: "Other" was explicitly
    /// chosen, or the question has no options to choose from at all.
    var showsFreeTextField: Bool {
        otherSelected || isFreeTextOnly
    }

    /// Whether `confirm()` would do anything right now: while the
    /// free-text field is showing, a non-empty trimmed answer; otherwise
    /// (multi-select, options only), at least one selected option. A
    /// single-select question without "Other" active never reaches this
    /// at all -- `selectOption(_:)` advances immediately on a listed
    /// click, so `confirm()`/`canConfirm` only matter once the free-text
    /// field is showing or the question is multi-select.
    var canConfirm: Bool {
        if showsFreeTextField {
            return !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !selectedOptionIndices.isEmpty
    }

    /// Whether any option of `currentQuestion` carries a non-nil
    /// `preview` -- switches the banner to the side-by-side option-list/
    /// preview layout (AskUserQuestion's own schema).
    var hasPreviews: Bool {
        currentQuestion.options.contains { $0.preview != nil }
    }

    /// Which option's `preview` the side-by-side box shows: the hovered
    /// option's own preview if it has one, else the most recently
    /// interacted option's, else the first option that has a preview at
    /// all -- `nil` only when no option in `currentQuestion` has one. An
    /// option that IS hovered/last-interacted but carries no preview of
    /// its own falls through to the next rule rather than blanking the
    /// box, so hovering a plain option never hides a preview already
    /// showing.
    var previewText: String? {
        let options = currentQuestion.options
        if let hoveredOptionIndex, options.indices.contains(hoveredOptionIndex),
           let preview = options[hoveredOptionIndex].preview {
            return preview
        }
        if let lastInteractedOptionIndex, options.indices.contains(lastInteractedOptionIndex),
           let preview = options[lastInteractedOptionIndex].preview {
            return preview
        }
        return options.first(where: { $0.preview != nil })?.preview
    }

    /// A listed option's own click. Single-select: records
    /// `.selectedOne(label)` and advances immediately -- returns the
    /// completed `AgentQuestionAnswers` when this was the last question,
    /// else `nil` after moving to the next one. Multi-select: toggles
    /// membership, clears `otherSelected` (exclusive with it, same as
    /// `chooseOther()`'s own reverse), records `lastInteractedOptionIndex`,
    /// always returns `nil` -- a multi-select question is never completed
    /// by an option click alone, only by `confirm()`.
    mutating func selectOption(_ index: Int) -> AgentQuestionAnswers? {
        lastInteractedOptionIndex = index
        let question = currentQuestion
        guard question.multiSelect else {
            return advance(with: .selectedOne(question.options[index].label))
        }
        otherSelected = false
        if selectedOptionIndices.contains(index) {
            selectedOptionIndices.remove(index)
        } else {
            selectedOptionIndices.insert(index)
        }
        return nil
    }

    /// The standing "Other…" choice's own click: reveals the free-text
    /// field and deselects every listed option -- exclusive with them,
    /// single- or multi-select alike, same as a listed click clears this
    /// (see `selectOption(_:)`).
    mutating func chooseOther() {
        otherSelected = true
        selectedOptionIndices = []
    }

    /// The Next/Answer button's and the free-text field's Return key's
    /// shared action: a no-op (`nil`) unless `canConfirm`. Commits
    /// `.freeText(trimmed)` while the free-text field is showing (free
    /// text is meant to reach the CLI unencoded, so nothing here encodes
    /// it), else `.selectedMany(labels)` with every selected option's
    /// label in `currentQuestion.options` order (not click order).
    /// Advances the same way `selectOption(_:)`'s single-select branch
    /// does: returns the completed `AgentQuestionAnswers` on the last
    /// question, else `nil` after moving to the next one.
    mutating func confirm() -> AgentQuestionAnswers? {
        guard canConfirm else { return nil }
        if showsFreeTextField {
            let text = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
            return advance(with: .freeText(text))
        }
        let labels = selectedOptionIndices.sorted().map { currentQuestion.options[$0].label }
        return advance(with: .selectedMany(labels))
    }

    /// Records `answer` as `currentQuestion`'s answer. Moves to the next
    /// question (resetting only the per-question selection state, not
    /// `questionIndex`/`collected` themselves) while more remain, else
    /// returns the completed `AgentQuestionAnswers` with every collected
    /// answer in question order.
    private mutating func advance(with answer: AgentQuestionAnswer) -> AgentQuestionAnswers? {
        collected.append(answer)
        guard questionIndex + 1 < prompt.questions.count else {
            return AgentQuestionAnswers(prompt: prompt, answers: collected)
        }
        questionIndex += 1
        resetSelection()
        return nil
    }

    private mutating func resetSelection() {
        selectedOptionIndices = []
        otherSelected = false
        otherText = ""
        hoveredOptionIndex = nil
        lastInteractedOptionIndex = nil
    }
}
