// AgentToolApprovalView.swift
// Calyx
//
// The approval banner's `.agentHook` mode (a CLI agent's own
// PermissionRequest-gated tool call, see `ApprovalRequest.Source`):
// everything the tool-approval form itself shows and does -- the raw
// payload, the vertical choice list mirroring the CLI's OWN dialog
// ("Yes", one row per `AgentHookOffers.permissionUpdates` always-allow
// suggestion, Calyx's own pane-scoped Always-Allow row only when the CLI
// doesn't already own persisting that choice itself, "No"), the "Amend…"
// flow (its revealed field rendered full-width below the payload/choice
// list, not in the right cluster), and the right cluster's [Cancel]
// (once `offers.canStop`)/[Answer in Pane] (once `offers.canAnswerInPane`)/
// ⋯ menu. Hosted by `ApprovalBannerView`, which renders only this view
// (plus the banner-level header and, separately, the queue navigator)
// for an `.agentHook`-sourced request -- mirrors `AgentQuestionBannerView`'s
// own split: takes plain closures, never `model`, and owns every choice
// row through `ChoiceRowStyle` -- see that type's own doc comment. The
// vertical choice list mirrors the CLI's own dialog: one full-width row
// per choice, including one row per `permission_suggestions` entry, so
// the human sees the CLI's own structured always-allow choices rather
// than a single generic button standing in for all of them.
//
// `offers.cliOwnsPersistence` decides whether Calyx's OWN pane-scoped
// Always-Allow row and the cross-actions menu's own "Always Allow ... in
// All Panes" item render at all -- true only when THIS request carries
// at least one CLI always-allow row (a non-empty `permissionUpdates`,
// only ever possible on a kind whose hook can accept
// `updatedPermissions`); when the CLI itself can persist an always-allow
// choice via one of those rows, recording a second, Calyx-side memory
// would be redundant and could silently diverge from it. A claude-code
// request whose payload offered no usable suggestion still carries
// `cliOwnsPersistence: false`, so Calyx's own row renders for it too.
//
// The amend field's `@FocusState`/root-level `.onDisappear` mirrors
// `AgentQuestionBannerView`'s own mechanism for its free-text field --
// see that view's own header comment for the full rationale: `.id(
// request.id)` at the `ApprovalBannerView` call site makes every removal
// cause go through this view's root `.onDisappear`, and `@FocusState` is
// only ever observed here, never set.

import SwiftUI

struct AgentToolApprovalView: View {
    let toolName: String
    let payload: String
    let offers: AgentHookOffers
    let totalPendingCount: Int
    let onAllow: () -> Void
    let onAllowWithPermissions: (AgentPermissionOffer) -> Void
    let onAlwaysAllow: () -> Void
    let onDeny: () -> Void
    /// The whole amended `tool_input`, built by `confirmAmend()` from
    /// `offers.originalToolInputJSON` with `offers.amendableField`
    /// replaced by the typed text.
    let onAllowWithInput: (Data) -> Void
    let onCancel: () -> Void
    let onAnswerInPane: () -> Void
    let onAllowAllPending: () -> Void
    let onAlwaysAllowAcrossPanes: () -> Void
    /// Called (deferred past the current transaction, see this view's own
    /// root-level `.onDisappear`) when the whole view is torn down while
    /// the amend field held focus.
    let onTextFieldRemoved: () -> Void

    @State private var showingAmend = false
    @State private var amendText = ""
    @FocusState private var amendFieldFocused: Bool

    /// Mirrors `amendFieldFocused` into a plain `@State` flag read by this
    /// view's own ROOT-level `.onDisappear` -- same mechanism and
    /// rationale as `AgentQuestionBannerView`'s own `textFieldWasFocused`
    /// (see that view's own doc comment): `@FocusState` clears
    /// automatically once its bound view disappears, with no documented
    /// ordering against the root view's own `.onDisappear`, so this flag
    /// is read instead of `amendFieldFocused` itself.
    @State private var amendFieldWasFocused = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                payloadView
                if showingAmend {
                    amendField
                }
                choiceList
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionCluster
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: amendFieldFocused) { _, newValue in amendFieldWasFocused = newValue }
        .onDisappear {
            guard amendFieldWasFocused else { return }
            amendFieldWasFocused = false
            Task { @MainActor in
                onTextFieldRemoved()
            }
        }
    }

    // MARK: - Content: payload + choice list

    /// Content-hugging payload -- same construction as `ApprovalBannerView.
    /// payloadView`'s own doc comment (a one-line command must never
    /// reserve blank space; `.frame(maxHeight: 120)` caps a long one).
    private var payloadView: some View {
        ScrollView(.vertical) {
            Text(ControlCharacterDisplay.render(payload))
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payload)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The CLI's own dialog choices, one full-width `ChoiceRowStyle` row
    /// each, in the CLI's own order: "Yes", every `AgentHookOffers.
    /// permissionUpdates` entry (already labeled by `AgentPermissionOffer.
    /// label(for:)`), Calyx's own pane-scoped Always-Allow (only when
    /// `!offers.cliOwnsPersistence`, i.e. this request carried no usable
    /// CLI always-allow row), "No". No leading glyph on any of
    /// these rows (`ChoiceRowStyle.Glyph.none`) -- unlike the question
    /// banner's option rows, none of these is a persisted "selection"
    /// the row itself needs to keep showing after the click; the click
    /// decides the request outright.
    private var choiceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            choiceRow(accessibilityID: AccessibilityID.ApprovalBanner.allowButton) {
                Text("Yes")
            } action: {
                onAllow()
            }

            ForEach(Array(offers.permissionUpdates.enumerated()), id: \.offset) { index, offer in
                choiceRow(accessibilityID: AccessibilityID.ApprovalBanner.choiceRow(index)) {
                    Text(offer.label)
                } action: {
                    onAllowWithPermissions(offer)
                }
            }

            if !offers.cliOwnsPersistence {
                choiceRow(accessibilityID: AccessibilityID.ApprovalBanner.alwaysAllowButton) {
                    Text("Always Allow \(ControlCharacterDisplay.render(toolName)) in This Pane")
                } action: {
                    onAlwaysAllow()
                }
            }

            choiceRow(accessibilityID: AccessibilityID.ApprovalBanner.denyButton) {
                Text("No")
            } action: {
                onDeny()
            }
        }
    }

    private func choiceRow(
        accessibilityID: String, @ViewBuilder label: () -> some View, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label().fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChoiceRowStyle(glyph: .none, isSelected: false))
        .accessibilityIdentifier(accessibilityID)
    }

    // MARK: - Right cluster: top-aligned actions

    /// [Amend…] (once `offers.amendableField != nil`), [Cancel] (once
    /// `offers.canStop`), [Answer in Pane] (once `offers.canAnswerInPane`),
    /// the ⋯ cross-actions menu -- the top-aligned button row alongside
    /// the now full-width content column. The amend flow's own revealed
    /// field + "Allow amended" button render BELOW the payload, full
    /// width, in the content column instead (see `body`'s own layout) --
    /// [Cancel]/[Answer in Pane]/the menu all stay reachable while
    /// amending.
    private var actionCluster: some View {
        HStack(spacing: 8) {
            if offers.amendableField != nil {
                amendButton
            }
            if offers.canStop {
                Button("Cancel") {
                    onCancel()
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.cancelButton)
            }
            if offers.canAnswerInPane {
                Button("Answer in Pane") {
                    onAnswerInPane()
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.answerInPaneButton)
            }

            crossActionsMenu
        }
        .fixedSize()
    }

    private var amendButton: some View {
        Button("Amend…") {
            revealAmendField()
        }
        .controlSize(.small)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.amendButton)
    }

    /// Reveals `amendText`'s field, prefilled with `offers.
    /// amendableField`'s CURRENT value read from `offers.
    /// originalToolInputJSON` -- one-directional, like `AgentQuestionFormState.
    /// chooseOther()`/`showNotes()`, so re-clicking [Amend…] never
    /// clobbers text the human has already started editing.
    private func revealAmendField() {
        guard !showingAmend else { return }
        if let field = offers.amendableField,
           let originalToolInputJSON = offers.originalToolInputJSON,
           let object = try? JSONSerialization.jsonObject(with: originalToolInputJSON) as? [String: Any],
           let currentValue = object[field] as? String {
            amendText = currentValue
        }
        showingAmend = true
    }

    private var amendField: some View {
        HStack(spacing: 8) {
            TextField(offers.amendableField ?? "", text: $amendText)
                .textFieldStyle(.roundedBorder)
                .focused($amendFieldFocused)
                .onSubmit { confirmAmend() }
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.amendTextField)

            Button("Allow amended") {
                confirmAmend()
            }
            .disabled(amendText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.amendConfirmButton)
        }
    }

    /// Builds the whole amended `tool_input` -- `offers.
    /// originalToolInputJSON` with `offers.amendableField`'s value
    /// replaced by `amendText` VERBATIM (untrimmed: the disabled-button
    /// guard above only blocks an all-whitespace value, it does not
    /// imply the surrounding whitespace of a non-empty value should be
    /// stripped from the command itself) -- then hands the whole object
    /// to `onAllowWithInput`. A no-op if `amendText` is all whitespace (so
    /// the Return key on an empty/blank field, same as the disabled
    /// button, does nothing), if `offers.amendableField`/`offers.
    /// originalToolInputJSON` is nil, or the original JSON fails to
    /// re-parse -- the latter two unreachable in practice, since
    /// `amendButton` only renders while `offers.amendableField != nil`,
    /// and `AgentHookOffers` never carries a non-nil `amendableField`
    /// without a non-nil `originalToolInputJSON` alongside it.
    private func confirmAmend() {
        guard !amendText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let field = offers.amendableField,
              let originalToolInputJSON = offers.originalToolInputJSON,
              var object = try? JSONSerialization.jsonObject(with: originalToolInputJSON) as? [String: Any] else { return }
        object[field] = amendText
        guard let amendedData = try? JSONSerialization.data(withJSONObject: object) else { return }
        onAllowWithInput(amendedData)
    }

    /// "Allow All Pending (N)" (always), "Always Allow ... in All Panes"
    /// (only when `!offers.cliOwnsPersistence`, i.e. this request carried
    /// no usable CLI always-allow row, same rationale as `choiceList`'s
    /// own pane-scoped row) -- content-hugging
    /// (`.fixedSize()`), same rationale as `payloadView`'s own header
    /// comment, so the compact ellipsis label never stretches the
    /// banner's action row.
    private var crossActionsMenu: some View {
        Menu {
            Button("Allow All Pending (\(totalPendingCount))") {
                onAllowAllPending()
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowAllPendingItem)

            if !offers.cliOwnsPersistence {
                Button("Always Allow \(ControlCharacterDisplay.render(toolName)) in All Panes") {
                    onAlwaysAllowAcrossPanes()
                }
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.alwaysAllowAllPanesItem)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.crossActionsMenu)
    }
}
