// AgentQuestionPrompt.swift
// Calyx
//
// Decoded form of Claude Code's AskUserQuestion tool_input.questions
// array -- populated by AgentHookToolCall.decode(from:kind:) only for a
// claude-code AskUserQuestion call (see that method's own doc comment),
// and rendered by the approval banner (AgentQuestionBannerView, driven
// by AgentQuestionFormState) as option buttons instead of a Deny/Always
// Allow/Allow row. AgentQuestionAnswers is the human's response, free of
// any wire encoding -- threaded back through ApprovalDecision.answered(_:)
// into AgentHookPermissionResponse.encodeAnswered, the ONE place that
// knows how Claude Code's own hook wants each answer spelled (see that
// method's own doc comment).

import Foundation

struct AgentQuestionPrompt: Sendable, Equatable {
    struct Option: Sendable, Equatable {
        let label: String
        let description: String?
        /// Markdown, rendered by `AgentQuestionBannerView` in a monospace
        /// preview box (AskUserQuestion's own schema: "rendered as
        /// markdown in a monospace box"). `nil` keeps the question's
        /// single-column layout; a non-nil preview on any option switches
        /// that question to the side-by-side option-list/preview layout.
        let preview: String?
    }

    struct Question: Sendable, Equatable {
        let text: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool
    }

    let questions: [Question]

    /// The whole `tool_input` object (not just `questions`) re-serialized
    /// verbatim with `JSONSerialization` -- unknown top-level keys (e.g.
    /// `metadata`, `annotations`) and unknown option fields all survive,
    /// and it is never derived from `AgentHookToolCall.payload`, which
    /// truncates at `maxPayloadBytes` and could therefore cut it short.
    /// `AgentHookPermissionResponse.encodeAnswered` parses this back and
    /// sends it, plus `answers`, as the whole `updatedInput` object --
    /// Claude Code's own hook contract says `updatedInput` REPLACES the
    /// entire input object, so every unchanged field must round-trip
    /// through here, not just `questions`.
    let originalToolInputJSON: Data
}

/// One question's answer exactly as the user gave it -- free of any wire
/// encoding. Which case a question produces is a function of `Question.
/// multiSelect`/`options.isEmpty`, decided by `AgentQuestionFormState`;
/// how a case is spelled on the wire is decided ONLY by
/// `AgentHookPermissionResponse.encodeAnswered` (`AgentQuestionAnswer`
/// itself carries no encoding logic, and no production code outside
/// that encoder may run one of these through
/// `selectedLabelsAnswerValue`).
enum AgentQuestionAnswer: Sendable, Equatable {
    /// A single-select question's chosen option label, raw.
    case selectedOne(String)
    /// A multi-select question's chosen option labels, in the order they
    /// appear in `Question.options` (not click order).
    case selectedMany([String])
    /// The typed text for a free-text "Other" choice (or a zero-option
    /// question, which is free-text-only), already trimmed and non-empty.
    case freeText(String)
}

/// The human's answer to an `AgentQuestionPrompt`: one `Entry` per
/// question, in question order.
struct AgentQuestionAnswers: Sendable, Equatable {
    /// One question's answer plus its optional "Add notes" text -- the
    /// TUI's own "n: add notes" affordance. `notes` is `nil` when the
    /// human never opened or never typed into that field (trimmed to nil
    /// at commit time by `AgentQuestionFormState`, not by this type or by
    /// the encoder -- see `AgentQuestionFormState.showNotes()`'s own doc
    /// comment).
    struct Entry: Sendable, Equatable {
        let answer: AgentQuestionAnswer
        let notes: String?
    }

    let prompt: AgentQuestionPrompt
    let entries: [Entry]
}
