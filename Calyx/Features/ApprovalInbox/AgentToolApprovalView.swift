// AgentToolApprovalView.swift
// Calyx
//
// The approval banner's `.agentHook` mode (a CLI agent's own
// PermissionRequest-gated tool call, see `ApprovalRequest.Source`):
// everything the tool-approval form itself shows and does -- the raw
// payload, and the vertical choice list mirroring the CLI's OWN dialog
// ("Yes", one row per `AgentHookOffers.permissionUpdates` always-allow
// suggestion, Calyx's own pane-scoped Always-Allow row only when the CLI
// doesn't already own persisting that choice itself, "No"). Hosted by
// `ApprovalBannerView`, which renders only this view (plus the
// banner-level header and, separately, the queue navigator) for an
// `.agentHook`-sourced request -- mirrors `AgentQuestionBannerView`'s own
// split: takes plain closures, never `model`, and owns every choice row
// through `ChoiceRowStyle` -- see that type's own doc comment. The
// vertical choice list mirrors the CLI's own dialog: one full-width row
// per choice, including one row per `permission_suggestions` entry, so
// the human sees the CLI's own structured always-allow choices rather
// than a single generic button standing in for all of them. The choice
// rows are the ONLY clickable content in this view.
//
// `offers.cliOwnsPersistence` decides whether Calyx's OWN pane-scoped
// Always-Allow row renders at all -- true only when THIS request carries
// at least one CLI always-allow row (a non-empty `permissionUpdates`,
// only ever possible on a kind whose hook can accept
// `updatedPermissions`); when the CLI itself can persist an always-allow
// choice via one of those rows, recording a second, Calyx-side memory
// would be redundant and could silently diverge from it. A claude-code
// request whose payload offered no usable suggestion still carries
// `cliOwnsPersistence: false`, so Calyx's own row renders for it too.

import SwiftUI

struct AgentToolApprovalView: View {
    let toolName: String
    let payload: String
    let offers: AgentHookOffers
    let onAllow: () -> Void
    let onAllowWithPermissions: (AgentPermissionOffer) -> Void
    let onAlwaysAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            payloadView
            choiceList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
