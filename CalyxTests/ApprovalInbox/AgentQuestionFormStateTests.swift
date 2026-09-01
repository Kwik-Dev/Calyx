//
//  AgentQuestionFormStateTests.swift
//  CalyxTests
//
//  Covers AgentQuestionFormState: the AskUserQuestion form's own state
//  machine (which question of a multi-question AgentQuestionPrompt is
//  displayed, the in-progress selection for it, and every answer
//  already collected for an earlier question), extracted out of
//  AgentQuestionBannerView so it is testable without SwiftUI.
//
//  Coverage:
//  - single-select: a listed click completes a one-question prompt with
//    .selectedOne(label); a multi-question prompt accumulates collected
//    answers, advances position, and completes on the last question
//  - multi-select: toggling membership (select/deselect), selectedMany
//    order follows option order regardless of click order, toggling
//    clears otherSelected
//  - chooseOther clears the selection and shows the free-text field
//  - confirm trims whitespace, requires non-empty text while the field
//    is showing, and is a true no-op (state completely unchanged) when
//    !canConfirm
//  - a zero-option question is free-text-only and yields .freeText
//  - single-select canConfirm is false with only options selectable and
//    true once the free-text field is showing with non-empty text
//  - hasPreviews / previewText priority chain, including the skip rule
//    for an interacted-but-preview-less option
//  - per-question state (selection/other/text/hover/lastInteracted)
//    resets after advancing to the next question
//  - isLastQuestion
//

import XCTest
@testable import Calyx

final class AgentQuestionFormStateTests: XCTestCase {

    // MARK: - Helpers

    private func option(_ label: String, description: String? = nil, preview: String? = nil) -> AgentQuestionPrompt.Option {
        AgentQuestionPrompt.Option(label: label, description: description, preview: preview)
    }

    private func question(
        _ text: String, header: String? = nil, options: [AgentQuestionPrompt.Option], multiSelect: Bool = false
    ) -> AgentQuestionPrompt.Question {
        AgentQuestionPrompt.Question(text: text, header: header, options: options, multiSelect: multiSelect)
    }

    private func prompt(_ questions: [AgentQuestionPrompt.Question]) -> AgentQuestionPrompt {
        let toolInput: [String: Any] = ["questions": questions.map { q in
            ["question": q.text, "options": q.options.map { ["label": $0.label] }]
        }]
        return AgentQuestionPrompt(
            questions: questions,
            originalToolInputJSON: try! JSONSerialization.data(withJSONObject: toolInput)
        )
    }

    // MARK: - single-select: one question completes immediately

    func test_selectOption_singleSelect_oneQuestion_completesWithSelectedOne() throws {
        let q = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q]))

        let answers = try XCTUnwrap(form.selectOption(0))
        XCTAssertEqual(answers.entries.map(\.answer), [.selectedOne("zsh")])
        XCTAssertNil(answers.entries[0].notes, "notesText was never populated, so notes must be nil")
    }

    // MARK: - single-select: two questions accumulate, advance, complete on last

    func test_selectOption_singleSelect_twoQuestions_accumulatesAdvancesCompletes() throws {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))

        XCTAssertFalse(form.isLastQuestion, "precondition: two questions, first is not last")
        let firstResult = form.selectOption(1)

        XCTAssertNil(firstResult, "the first of two questions must not complete the prompt")
        XCTAssertEqual(form.questionIndex, 1, "answering the first question must advance to the second")
        XCTAssertEqual(form.collected.map(\.answer), [.selectedOne("bash")])
        XCTAssertEqual(form.position.index, 2)
        XCTAssertEqual(form.position.count, 2)
        XCTAssertTrue(form.isLastQuestion)

        let answers = try XCTUnwrap(form.selectOption(0))
        XCTAssertEqual(answers.entries.map(\.answer), [.selectedOne("bash"), .selectedOne("vim")],
                       "the completed answers must carry both questions' answers in question order")
    }

    // MARK: - multi-select: toggling membership, order-of-options in selectedMany

    func test_selectOption_multiSelect_toggleSelectAndDeselect() {
        let q = question("Which editors?", options: [option("vim"), option("emacs"), option("nano")], multiSelect: true)
        var form = AgentQuestionFormState(prompt: prompt([q]))

        XCTAssertNil(form.selectOption(0), "a multi-select click must never complete the prompt on its own")
        XCTAssertEqual(form.selectedOptionIndices, [0])

        XCTAssertNil(form.selectOption(0))
        XCTAssertEqual(form.selectedOptionIndices, [], "clicking a selected option again must deselect it")
    }

    func test_confirm_multiSelect_selectedManyFollowsOptionOrder_notClickOrder() throws {
        let q = question("Which editors?", options: [option("vim"), option("emacs"), option("nano")], multiSelect: true)
        var form = AgentQuestionFormState(prompt: prompt([q]))

        // Click nano (index 2) first, then vim (index 0) -- reverse of option order.
        _ = form.selectOption(2)
        _ = form.selectOption(0)

        let answers = try XCTUnwrap(form.confirm())
        XCTAssertEqual(answers.entries.map(\.answer), [.selectedMany(["vim", "nano"])],
                       "selectedMany must list labels in the question's own option order, regardless of click order")
    }

    func test_selectOption_multiSelect_clearsOtherSelected() {
        let q = question("Which editors?", options: [option("vim"), option("emacs")], multiSelect: true)
        var form = AgentQuestionFormState(prompt: prompt([q]))
        form.chooseOther()
        XCTAssertTrue(form.otherSelected, "precondition: Other is active")

        _ = form.selectOption(0)

        XCTAssertFalse(form.otherSelected, "selecting a listed option must clear the standing Other choice")
        XCTAssertEqual(form.selectedOptionIndices, [0])
    }

    // MARK: - chooseOther

    func test_chooseOther_clearsSelectionAndShowsField() {
        let q = question("Which editors?", options: [option("vim"), option("emacs")], multiSelect: true)
        var form = AgentQuestionFormState(prompt: prompt([q]))
        _ = form.selectOption(0)
        XCTAssertEqual(form.selectedOptionIndices, [0], "precondition: an option is selected")

        form.chooseOther()

        XCTAssertTrue(form.otherSelected)
        XCTAssertEqual(form.selectedOptionIndices, [], "chooseOther must clear every selected option")
        XCTAssertTrue(form.showsFreeTextField)
    }

    // MARK: - confirm: trims, requires non-empty, no-op when !canConfirm

    func test_confirm_freeText_trimsWhitespace() throws {
        let q = question("Anything else?", options: [option("Other")])
        var form = AgentQuestionFormState(prompt: prompt([q]))
        form.chooseOther()
        form.otherText = "  install ripgrep  "

        let answers = try XCTUnwrap(form.confirm())
        XCTAssertEqual(answers.entries.map(\.answer), [.freeText("install ripgrep")])
    }

    func test_confirm_freeText_emptyAfterTrim_isNoOp() {
        let q = question("Anything else?", options: [option("Other")])
        var form = AgentQuestionFormState(prompt: prompt([q]))
        form.chooseOther()
        form.otherText = "   "
        XCTAssertFalse(form.canConfirm, "whitespace-only text must not satisfy canConfirm")

        let before = form
        let result = form.confirm()

        XCTAssertNil(result, "confirm() must return nil when !canConfirm")
        XCTAssertEqual(form, before, "confirm() must leave state completely untouched when !canConfirm")
    }

    func test_confirm_multiSelect_noSelection_isNoOp_stateUnchanged() {
        let q = question("Which editors?", options: [option("vim"), option("emacs")], multiSelect: true)
        var form = AgentQuestionFormState(prompt: prompt([q]))
        XCTAssertFalse(form.canConfirm, "no option selected yet")

        let before = form
        let result = form.confirm()

        XCTAssertNil(result)
        XCTAssertEqual(form, before, "confirm() must leave state completely untouched when !canConfirm")
    }

    // MARK: - zero-option question: free-text-only, yields .freeText

    func test_zeroOptionQuestion_isFreeTextOnly_confirmYieldsFreeText() throws {
        let q = question("Anything to add?", options: [])
        var form = AgentQuestionFormState(prompt: prompt([q]))

        XCTAssertTrue(form.isFreeTextOnly)
        XCTAssertTrue(form.showsFreeTextField, "a zero-option question must show the field without an explicit Other click")

        form.otherText = "please also install fd"
        let answers = try XCTUnwrap(form.confirm())
        XCTAssertEqual(answers.entries.map(\.answer), [.freeText("please also install fd")])
    }

    // MARK: - single-select canConfirm: false with options only, true once free text shows

    func test_singleSelect_canConfirm_falseWithOptionsOnly_trueOnceOtherTextShows() {
        let q = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q]))

        XCTAssertFalse(form.canConfirm, "a single-select question with only listed options must not be confirmable " +
                       "without Other -- a listed click advances immediately instead")

        form.chooseOther()
        XCTAssertFalse(form.canConfirm, "Other showing with empty text must still not be confirmable")

        form.otherText = "fish"
        XCTAssertTrue(form.canConfirm, "Other showing with non-empty text must be confirmable")
    }

    // MARK: - hasPreviews / previewText priority chain

    func test_hasPreviews_falseWhenNoOptionCarriesOne() {
        let q = question("Which shell?", options: [option("zsh"), option("bash")])
        let form = AgentQuestionFormState(prompt: prompt([q]))

        XCTAssertFalse(form.hasPreviews)
        XCTAssertNil(form.previewText)
    }

    func test_previewText_hoveredOptionWithPreview_wins() {
        let q = question("Which shell?", options: [
            option("zsh", preview: "zsh preview"), option("bash", preview: "bash preview"),
        ])
        var form = AgentQuestionFormState(prompt: prompt([q]))
        form.hoveredOptionIndex = 1

        XCTAssertTrue(form.hasPreviews)
        XCTAssertEqual(form.previewText, "bash preview")
    }

    /// The hovered option carries no preview of its own -- falls through
    /// to the last-interacted option's preview rather than blanking the
    /// box.
    func test_previewText_hoveredOptionWithoutPreview_fallsThroughToLastInteracted() {
        let q = question("Which shell?", options: [
            option("zsh", preview: "zsh preview"), option("bash", preview: nil),
        ], multiSelect: true)
        var form = AgentQuestionFormState(prompt: prompt([q]))
        _ = form.selectOption(0)
        form.hoveredOptionIndex = 1

        XCTAssertEqual(form.previewText, "zsh preview",
                       "hovering a preview-less option must fall through to the last-interacted option's preview")
    }

    /// Neither hovered nor last-interacted carries a preview -- falls
    /// through to the first option that has one at all.
    func test_previewText_neitherHoveredNorLastInteracted_fallsThroughToFirstWithPreview() {
        let q = question("Which shell?", options: [
            option("zsh", preview: nil), option("bash", preview: "bash preview"), option("fish", preview: "fish preview"),
        ])
        let form = AgentQuestionFormState(prompt: prompt([q]))

        XCTAssertEqual(form.previewText, "bash preview",
                       "with nothing hovered or interacted, previewText must fall through to the first option carrying one")
    }

    // MARK: - per-question state reset after advancing

    func test_advancingToNextQuestion_resetsPerQuestionState() {
        let q1 = question("Which editors?", options: [option("vim"), option("emacs")], multiSelect: true)
        let q2 = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))

        _ = form.selectOption(0)
        form.hoveredOptionIndex = 1
        form.otherText = "leftover text"
        form.chooseOther()
        XCTAssertTrue(form.otherSelected, "precondition: Other is active on question 1")

        _ = form.confirm()

        XCTAssertEqual(form.questionIndex, 1, "precondition: advanced to question 2")
        XCTAssertEqual(form.selectedOptionIndices, [], "selection must reset on advance")
        XCTAssertFalse(form.otherSelected, "otherSelected must reset on advance")
        XCTAssertEqual(form.otherText, "", "otherText must reset on advance")
        XCTAssertNil(form.hoveredOptionIndex, "hoveredOptionIndex must reset on advance")
        XCTAssertNil(form.lastInteractedOptionIndex, "lastInteractedOptionIndex must reset on advance")
    }

    // MARK: - isLastQuestion

    func test_isLastQuestion_trueOnlyOnFinalQuestion() {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))

        XCTAssertFalse(form.isLastQuestion)

        _ = form.selectOption(0)

        XCTAssertTrue(form.isLastQuestion)
    }

    // MARK: - notes: showNotes / notesText committed into Entry.notes

    func test_showNotes_makesNotesVisible() {
        let q = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q]))

        XCTAssertFalse(form.notesVisible, "notes must start hidden")
        form.showNotes()
        XCTAssertTrue(form.notesVisible)
    }

    func test_selectOption_commitsTrimmedNotesText_intoEntryNotes() throws {
        let q = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q]))
        form.showNotes()
        form.notesText = "  please double check  "

        let answers = try XCTUnwrap(form.selectOption(0))
        XCTAssertEqual(answers.entries[0].notes, "please double check", "notes must be trimmed")
    }

    func test_selectOption_emptyNotesText_commitsNilNotes() throws {
        let q = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q]))
        form.showNotes()
        form.notesText = "   "

        let answers = try XCTUnwrap(form.selectOption(0))
        XCTAssertNil(answers.entries[0].notes, "whitespace-only notes must trim to nil")
    }

    func test_confirm_commitsTrimmedNotesText_intoEntryNotes() throws {
        let q = question("Anything else?", options: [option("Other")])
        var form = AgentQuestionFormState(prompt: prompt([q]))
        form.chooseOther()
        form.otherText = "install ripgrep"
        form.showNotes()
        form.notesText = "for the search feature"

        let answers = try XCTUnwrap(form.confirm())
        XCTAssertEqual(answers.entries[0].answer, .freeText("install ripgrep"))
        XCTAssertEqual(answers.entries[0].notes, "for the search feature")
    }

    func test_advancingToNextQuestion_resetsNotesTextAndVisibility() {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))
        form.showNotes()
        form.notesText = "leftover notes"

        _ = form.selectOption(0)

        XCTAssertFalse(form.notesVisible, "notesVisible must reset on advance")
        XCTAssertEqual(form.notesText, "", "notesText must reset on advance")
    }

    // MARK: - goBack

    func test_canGoBack_falseOnFirstQuestion_trueAfterAdvancing() {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))

        XCTAssertFalse(form.canGoBack, "the first question has nothing to go back to")

        _ = form.selectOption(0)

        XCTAssertTrue(form.canGoBack)
    }

    func test_goBack_onFirstQuestion_isNoOp() {
        let q = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q]))
        let before = form

        form.goBack()

        XCTAssertEqual(form, before, "goBack() on the first question must leave state completely untouched")
    }

    func test_goBack_removesLastCollectedEntry_movesBackOneQuestion() {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))
        _ = form.selectOption(0)
        XCTAssertEqual(form.questionIndex, 1, "precondition: advanced to question 2")

        form.goBack()

        XCTAssertEqual(form.questionIndex, 0, "goBack() must move back one question")
        XCTAssertEqual(form.collected, [], "goBack() must remove the last collected entry")
    }

    func test_goBack_restoresSelectedOne_intoSelectedOptionIndices() {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))
        _ = form.selectOption(1) // "bash", index 1

        form.goBack()

        XCTAssertEqual(form.selectedOptionIndices, [1], "goBack() must restore the .selectedOne answer's own option index")
        XCTAssertFalse(form.otherSelected)
    }

    func test_goBack_restoresSelectedMany_intoSelectedOptionIndices() {
        let q1 = question("Which editors?", options: [option("vim"), option("emacs"), option("nano")], multiSelect: true)
        let q2 = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))
        _ = form.selectOption(2) // nano
        _ = form.selectOption(0) // vim
        _ = form.confirm() // .selectedMany(["vim", "nano"]) -> advances to q2

        form.goBack()

        XCTAssertEqual(form.selectedOptionIndices, [0, 2], "goBack() must restore every selected index of the .selectedMany answer")
    }

    func test_goBack_restoresFreeText_intoOtherSelectedAndOtherText() {
        let q1 = question("Anything else?", options: [option("Other")])
        let q2 = question("Which shell?", options: [option("zsh"), option("bash")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))
        form.chooseOther()
        form.otherText = "install ripgrep"
        _ = form.confirm()

        form.goBack()

        XCTAssertTrue(form.otherSelected, "goBack() must restore otherSelected for a .freeText answer")
        XCTAssertEqual(form.otherText, "install ripgrep", "goBack() must restore the typed free text")
    }

    func test_goBack_restoresNotesTextAndVisibility() {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))
        form.showNotes()
        form.notesText = "please double check"
        _ = form.selectOption(0)
        XCTAssertFalse(form.notesVisible, "precondition: notes reset on advance")

        form.goBack()

        XCTAssertTrue(form.notesVisible, "goBack() must restore notesVisible from the removed entry's own notes")
        XCTAssertEqual(form.notesText, "please double check", "goBack() must restore notesText from the removed entry")
    }

    func test_goBack_noNotesOnRemovedEntry_leavesNotesHidden() {
        let q1 = question("Which shell?", options: [option("zsh"), option("bash")])
        let q2 = question("Which editor?", options: [option("vim"), option("emacs")])
        var form = AgentQuestionFormState(prompt: prompt([q1, q2]))
        _ = form.selectOption(0)

        form.goBack()

        XCTAssertFalse(form.notesVisible, "an entry with no notes must restore notesVisible as false")
        XCTAssertEqual(form.notesText, "")
    }
}
