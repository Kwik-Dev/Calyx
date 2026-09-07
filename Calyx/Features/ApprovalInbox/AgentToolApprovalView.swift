// AgentToolApprovalView.swift
// Calyx
//
// The approval banner's `.agentHook` mode (a CLI agent's own
// PermissionRequest-gated tool call, see `ApprovalRequest.Source`): a
// stateless provider of the primary action and the "Options" pull-down
// items `ApprovalBannerView` places into its shared `ApprovalActionColumn`
// -- this type carries no `@State` of its own (unlike `AgentQuestionBannerView`),
// so `ApprovalBannerView` can safely read `primaryButton`/`menuItems`
// directly on a locally-constructed instance without going through
// SwiftUI's own view-identity machinery; a stateful provider cannot do
// that safely, which is why `AgentQuestionBannerView` instead renders
// its own full row (see that file's own header comment).
//
// Primary: "Yes" (`allowButton`). Menu, mirroring the CLI's own dialog
// order: one row per `AgentHookOffers.permissionUpdates` always-allow
// suggestion (`choiceRow(_:)`, already labeled by `AgentPermissionOffer.
// label(for:)`), Calyx's own pane-scoped Always-Allow row
// (`alwaysAllowButton`) only when the CLI doesn't already own persisting
// that choice itself, "No" (`denyButton`). The body text itself (the
// hook call's own `summary`) is rendered by `ApprovalBannerView.
// toolLeftColumn`, which both `.mcpTool` and `.agentHook` share via
// `ApprovalRequest.displayPayload`.
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

/// `@MainActor`, unlike a typical stateless value type -- every stored
/// closure and computed property here builds `SwiftUI.View` content
/// (`Button`, `.buttonStyle`), which is main-actor-isolated API; this
/// type is only ever constructed and read from `ApprovalBannerView.body`,
/// itself already main-actor-isolated.
@MainActor
struct AgentToolApprovalView {
    let toolName: String
    let offers: AgentHookOffers
    let onAllow: () -> Void
    let onAllowWithPermissions: (AgentPermissionOffer) -> Void
    let onAlwaysAllow: () -> Void
    let onDeny: () -> Void

    var primaryButton: some View {
        Button("Yes") { onAllow() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowButton)
    }

    @ViewBuilder
    var menuItems: some View {
        ForEach(Array(offers.permissionUpdates.enumerated()), id: \.offset) { index, offer in
            Button(ApprovalBannerView.menuRowTitle(offer.label)) {
                onAllowWithPermissions(offer)
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.choiceRow(index))
        }

        if !offers.cliOwnsPersistence {
            Button(ApprovalBannerView.menuRowTitle("Always Allow \(toolName) in This Pane")) {
                onAlwaysAllow()
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.alwaysAllowButton)
        }

        Button(ApprovalBannerView.menuRowTitle("No")) {
            onDeny()
        }
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.denyButton)
    }
}
