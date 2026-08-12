// HerdrHeuristicIngestionPolicy.swift
// Calyx
//
// Decides whether Calyx's own title-change / screen-classification
// heuristic ingestion (`AgentRegistry.handleTitleChange` /
// `.handleScreenClassification`, fed from `CalyxWindowController
// .handleSetTitleNotification` and
// `.pollScreenClassificationIfAgentsSidebarVisible`) should run for a
// given surface, extracted as an explicit, pure decision mirroring
// `HerdrChildExitedPolicy`'s own extraction shape: the
// caller resolves any raw domain lookup itself (here,
// `HerdrHostedSurfaces.shared.contains(surfaceID)`) into an
// already-computed `Bool` discriminator before calling in, rather than
// this function reaching into `HerdrHostedSurfaces` directly.
//
// Background: a herdr-hosted surface's "real" agent state
// arrives over herdr's own event stream and is recorded as an external
// `AgentRegistry` row (`AgentRegistry.upsertExternalEntry`), not
// through Calyx's title/screen heuristics. Left unguarded, both
// ingestion paths would race to describe the same agent, producing two
// Agents-sidebar rows for one pane -- this policy is the single skip
// decision both call sites must consult before feeding the heuristic
// pipeline.
//
// Extension: a surface bridged via `HerdrPaneRegistry` (a
// native-tab pane bridge, `HerdrPaneRegistry.isBridgeSurface(_:)`) must
// be skipped exactly like a `HerdrHostedSurfaces` member already is --
// its "real" state also arrives over herdr's own layout export/event
// stream. `isBridgeSurface` is REQUIRED, with no default: a defaulted
// parameter would let a call site compile unchanged without ever
// consulting `HerdrPaneRegistry`, silently keeping the old (wrong)
// behavior by omission -- mirrors this codebase's own
// `killSessionIfPersistent` precedent (`CalyxWindowController.swift`),
// whose own `isTerminating` parameter was made required for the
// identical reason.
enum HerdrHeuristicIngestionPolicy {

    /// `true`: proceed with heuristic ingestion for this surface --
    /// nothing else is describing it. `false` (herdr-hosted OR
    /// herdr-bridged): skip -- an external row already covers this pane
    /// authoritatively, so a second, Calyx-side heuristic row must never
    /// be created for it.
    static func shouldIngest(isHerdrHosted: Bool, isBridgeSurface: Bool) -> Bool {
        !isHerdrHosted && !isBridgeSurface
    }
}
