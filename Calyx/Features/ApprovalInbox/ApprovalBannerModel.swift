// ApprovalBannerModel.swift
// Calyx
//
// View-model behind the Cockpit approval banner, choosing which single
// pending ApprovalRequest (if any) to show and forwarding Allow/Deny/
// Always Allow to ApprovalInboxStore.decide(id:_:) /
// CockpitSettings.autoApproveEnabled / AgentHookApprovalMemory (see
// alwaysAllow(id:)'s own doc comment for the .mcpTool vs .agentHook
// source split).
// Mirrors RecoveryBarModel's shape: UI-independent, injected closures
// instead of reaching for CalyxWindowController/NSWindow directly.
// `AppDelegate` owns exactly one instance of this class app-wide, hosted
// by the single floating approval panel (`ApprovalPanelController.swift`):
// every pending request, regardless of which surface it targets or
// whether it targets one at all, sits in the same app-wide queue.
//
// Queue navigation (prev/next cursor): a stored `selectedRequestID`
// lets the panel step through every pending request via
// `selectNext()`/`selectPrevious()`, instead of only ever showing the
// oldest one -- see `current`'s own doc comment for the full contract,
// and `advanceCursor(pastDisplayed:)` for how deciding the DISPLAYED
// request keeps the cursor moving forward through the backlog. See
// CalyxTests/ApprovalInbox/ApprovalBannerModelTests.swift for the
// specced contract.

import Foundation

@MainActor
@Observable
final class ApprovalBannerModel {

    /// A single row of the queue preview menu (`queueEntries`, rendered
    /// by `ApprovalBannerView`'s queue navigator Menu): one per request
    /// in the app-wide `visibleRequests`, oldest-first.
    struct QueueEntry: Identifiable, Equatable, Sendable {
        let id: UUID
        /// 1-based index into `visibleRequests`, matching `positionInfo`'s
        /// own indexing.
        let position: Int
        let previewLine: String
        /// True only for the entry matching `ApprovalBannerModel.current`'s
        /// own id.
        let isCurrent: Bool
    }

    private let store: ApprovalInboxStore
    private let restoreTerminalFocus: (UUID?) -> Void
    private let memory: AgentHookApprovalMemory

    /// The app-wide navigation cursor -- see `current`'s own doc comment
    /// for the full selected-if-still-pending/inert-once-stale contract.
    private var selectedRequestID: UUID?

    init(
        store: ApprovalInboxStore,
        restoreTerminalFocus: @escaping (UUID?) -> Void = { _ in },
        memory: AgentHookApprovalMemory = .shared
    ) {
        self.store = store
        self.restoreTerminalFocus = restoreTerminalFocus
        self.memory = memory
    }

    /// Every pending request, in `store.pending`'s own oldest-first
    /// order (see `ApprovalInboxStore.submit`'s own doc comment) -- the
    /// single app-wide queue `current`/`positionInfo`/`selectNext()`/
    /// `selectPrevious()`/`advanceCursor(pastDisplayed:)` all navigate.
    private var visibleRequests: [ApprovalRequest] {
        store.pending
    }

    /// The request the app-wide panel currently displays:
    /// `selectedRequestID` while it is still pending, else the oldest
    /// pending request (mirrors this property's original, pre-navigation
    /// behavior, and what a freshly-resolved selection falls back to).
    /// `selectedRequestID` is deliberately never cleared just because its
    /// request leaves `visibleRequests` -- it goes permanently INERT
    /// instead, rather than being reset to nil. That's safe because
    /// `ApprovalRequest.id` is a UUID: no future request can ever be
    /// assigned that same id, so a stale cursor can never accidentally
    /// resurrect and re-select some unrelated LATER request -- it just
    /// keeps missing every lookup here (falling back to the oldest
    /// pending request) until some action explicitly reassigns it
    /// (`selectNext()`/`selectPrevious()`/`advanceCursor(pastDisplayed:)`).
    var current: ApprovalRequest? {
        let visible = visibleRequests
        guard !visible.isEmpty else { return nil }
        return visible[currentIndex(in: visible)]
    }

    /// Index within `visible` of the request the panel displays:
    /// `selectedRequestID`'s own position while it is still present
    /// there, else 0 (the oldest pending request, which is what a stale
    /// or unset cursor falls back to -- see `current`'s own doc comment).
    /// The single resolution rule `current`, `positionInfo` and
    /// `queueEntries` all share, so the three can never disagree about
    /// which request is the current one. An empty `visible` also yields
    /// 0, which is not a valid subscript: a caller that indexes into
    /// `visible` must guard emptiness itself first.
    private func currentIndex(in visible: [ApprovalRequest]) -> Int {
        guard let selectedRequestID,
              let index = visible.firstIndex(where: { $0.id == selectedRequestID }) else { return 0 }
        return index
    }

    /// The app-wide 1-based (index, count) position of `current` within
    /// `visibleRequests` -- nil exactly when `current` is nil. Backs the
    /// banner's "N / M" position label (`ApprovalBannerView.
    /// queueNavigator(positionInfo:)`), shown only while more than one
    /// request is queued app-wide. Resolves the displayed request's
    /// index through `currentIndex(in:)` against its own already-computed
    /// `visible` local rather than calling `current` itself, which would
    /// re-filter `store.pending` a second time for the same answer.
    var positionInfo: (index: Int, count: Int)? {
        let visible = visibleRequests
        guard !visible.isEmpty else { return nil }
        return (index: currentIndex(in: visible) + 1, count: visible.count)
    }

    /// Whether `current` has a predecessor in `visibleRequests` to step
    /// back to -- false at the oldest (first) pending request, and
    /// whenever nothing is pending at all.
    var canSelectPrevious: Bool {
        guard let positionInfo else { return false }
        return positionInfo.index > 1
    }

    /// Whether `current` has a successor in `visibleRequests` to step
    /// forward to -- false at the newest (last) pending request, and
    /// whenever nothing is pending at all.
    var canSelectNext: Bool {
        guard let positionInfo else { return false }
        return positionInfo.index < positionInfo.count
    }

    /// Every request in `visibleRequests` (same order as
    /// `current`/`positionInfo`), oldest-first, as a `QueueEntry` --
    /// what `ApprovalBannerView`'s queue preview menu (`queueMenuItems`)
    /// draws its rows from. EVERY pending request is reported here, and
    /// that menu renders one row per entry. Resolves the current entry's
    /// index through `currentIndex(in:)` against its own local `visible`,
    /// the same single rule `current`/`positionInfo` resolve through,
    /// rather than reading either of them -- so `visibleRequests` is read
    /// only once here (see `positionInfo`'s own doc comment for the same
    /// rationale). Empty whenever `visibleRequests` is.
    var queueEntries: [QueueEntry] {
        let visible = visibleRequests
        let currentEntryIndex = currentIndex(in: visible)
        return visible.enumerated().map { index, request in
            QueueEntry(id: request.id, position: index + 1, previewLine: request.previewLine, isCurrent: index == currentEntryIndex)
        }
    }

    /// Neither this nor `selectPrevious()` below calls
    /// `refreshHostingView()` or posts `.calyxApprovalInboxChanged`: both
    /// are invoked from an in-hierarchy SwiftUI `Button` inside
    /// `ApprovalBannerView`, itself hosted from the floating approval
    /// panel's `ApprovalPanelContentView.body`, which reads
    /// `approvalBannerModel.current` directly. Mutating
    /// `selectedRequestID` (a tracked, stored `@Observable` property)
    /// therefore invalidates that already-rendered `body` the same way
    /// `RecoveryBarModel.dismiss()` does for `recoveryBarModel.
    /// showRecoveryBar` right alongside it (RecoveryBarModel.swift's
    /// `dismiss()` mutates `isDismissed` with no explicit refresh either)
    /// -- the explicit-refresh doctrine (`ApprovalInboxStore.swift`'s own
    /// `.calyxApprovalInboxChanged` doc comment) exists for mutations
    /// made from OUTSIDE the currently rendered view hierarchy (e.g. a
    /// store change landing from a background MCP call), not for a click
    /// handler already running inside it.
    ///
    /// Steps `current` forward to its successor in `visibleRequests`.
    /// Clamped: a no-op once already at the newest (last) visible
    /// request, or when nothing is visible at all. Navigates from
    /// `current` (not the raw, possibly-inert `selectedRequestID`), so a
    /// stale cursor resolves relative to wherever `current` has already
    /// fallen back to, not from wherever it was last pointing.
    func selectNext() {
        guard canSelectNext, let current, let index = visibleRequests.firstIndex(where: { $0.id == current.id }) else { return }
        selectedRequestID = visibleRequests[index + 1].id
    }

    /// Steps `current` back to its predecessor in `visibleRequests`.
    /// Clamped: a no-op once already at the oldest (first) visible
    /// request, or when nothing is visible at all. Same from-`current`
    /// navigation rationale, and same no-explicit-refresh-needed
    /// rationale (see `selectNext()`'s own doc comment above), as
    /// `selectNext()`.
    func selectPrevious() {
        guard canSelectPrevious, let current, let index = visibleRequests.firstIndex(where: { $0.id == current.id }) else { return }
        selectedRequestID = visibleRequests[index - 1].id
    }

    /// The queue preview menu's row-click action
    /// (`ApprovalBannerView`'s `queueNavigator(positionInfo:)` Menu):
    /// jump straight to a chosen request instead of stepping one at a
    /// time via `selectNext()`/`selectPrevious()`. A no-op unless `id`
    /// is a member of `visibleRequests` -- i.e. still pending.
    ///
    /// Unlike `selectNext()`/`selectPrevious()` above, this DOES post
    /// `.calyxApprovalInboxChanged` explicitly: those two are clicked
    /// from an in-hierarchy SwiftUI `Button`, while this one is clicked
    /// from an `NSMenuItem` of the queue preview `Menu`, whose action
    /// runs on AppKit's own menu event loop rather than from inside the
    /// currently rendered view hierarchy -- exactly the outside-the-
    /// hierarchy mutation the explicit-refresh doctrine covers (see
    /// `ApprovalInboxStore.swift`'s own `.calyxApprovalInboxChanged` doc
    /// comment). Posted only when the cursor's stored value actually
    /// changes: re-picking the row already selected mutates nothing, so
    /// it must not trigger a needless re-render of the app-wide panel.
    /// `object` carries the store, same as every post
    /// `ApprovalInboxStore` makes itself, so the notification's object
    /// is one type across all senders.
    func select(id: UUID) {
        guard visibleRequests.contains(where: { $0.id == id }), selectedRequestID != id else { return }
        selectedRequestID = id
        NotificationCenter.default.post(name: .calyxApprovalInboxChanged, object: store)
    }

    /// Called immediately before the `store.decide`/`store.decide(ids:)`
    /// that actually resolves `id`, in every action below (`allow`/
    /// `deny`/`alwaysAllow`) -- for `allow`/`deny` that's still their very
    /// first line (neither has an intervening bail-out guard); for
    /// `alwaysAllow`'s `.agentHook` branch, this call is placed AFTER its
    /// own early-return guard (a missing `targetSurfaceID`) -- a path that
    /// bails out without deciding anything must never advance the cursor
    /// either. `store.pending` hasn't been mutated yet at the point this
    /// actually runs, so `visibleRequests` here still includes `id`,
    /// letting this compute its successor/predecessor within the
    /// PRE-removal queue, same as `selectNext()`/`selectPrevious()` do. A
    /// no-op unless `id` is the request the panel is actually
    /// DISPLAYING right now (`current?.id`) -- a stale `id` (already
    /// decided by some other path, see `allow(id:)`'s own stale-id
    /// contract below) can never equal `current?.id` in the first place
    /// (a non-pending request is never in `visibleRequests`), so this
    /// guard also doubles as that same stale-id no-op, keeping the cursor
    /// exactly where `current` has already independently fallen back to.
    ///
    /// `drainedIDs` (default empty, used only by `alwaysAllow`'s own
    /// batch drains -- the `.mcpTool` branch's all-visible-`.mcpTool`
    /// sweep, the `.agentHook` branch's same-(surface, kind, toolName)
    /// sweep) closes a gap the plain immediate-neighbor pick left open:
    /// either drain can decide MORE than just `id` in the very same call
    /// -- including the immediate successor this method would otherwise
    /// pick as the new cursor. Once that neighbor is itself swept,
    /// `current`'s `selectedRequestID` lookup misses and falls all the
    /// way back to the OLDEST visible request, snapping the banner
    /// backward instead of stepping to the nearest request that actually
    /// survives the drain. Scans forward from `index + 1` for the first
    /// element NOT in `drainedIDs`; if every forward element is drained,
    /// scans backward from `index - 1` for the nearest element NOT in
    /// `drainedIDs`; nil if nothing survives either direction. With
    /// `drainedIDs` empty (`allow(id:)`/`deny(id:)`'s case), every
    /// forward/backward element trivially survives the exclusion check,
    /// so this reduces exactly to the plain immediate-neighbor behavior.
    private func advanceCursor(pastDisplayed id: UUID, excluding drainedIDs: Set<UUID> = []) {
        guard current?.id == id else { return }
        let visible = visibleRequests
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        if let forwardSurvivor = visible[(index + 1)...].first(where: { !drainedIDs.contains($0.id) }) {
            selectedRequestID = forwardSurvivor.id
        } else if let backwardSurvivor = visible[..<index].last(where: { !drainedIDs.contains($0.id) }) {
            selectedRequestID = backwardSurvivor.id
        } else {
            selectedRequestID = nil
        }
    }

    /// `id` is the request the CALLER actually rendered (threaded in by
    /// `ApprovalBannerView` from its own `request.id`), not re-derived
    /// from `current` -- `current` can advance between a render and a
    /// click (another decide()/expire() landing first), so re-reading it
    /// here could resolve a DIFFERENT request than the one the human
    /// looked at and clicked Allow/Deny on. A stale `id` (no longer
    /// pending) is a safe no-op -- `store.decide` itself already no-ops
    /// for that case. The one guard this DOES need,
    /// `isPendingAgentQuestion(_:)`, is not about staleness: it stops
    /// this from ever deciding a live `.agentQuestion` request, which
    /// only `answer(id:answers:)`/`chatAboutQuestion(id:)` may decide
    /// (unlike `alwaysAllow(id:)` below, whose own guard covers its own
    /// extra side effects).
    func allow(id: UUID) {
        guard !isPendingAgentQuestion(id) else { return }
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, .allowed)
    }

    func deny(id: UUID) {
        guard !isPendingAgentQuestion(id) else { return }
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, .denied(.userRejected))
    }

    /// `ApprovalBannerView.agentHookMenuItems(toolName:offers:)`'s
    /// per-`AgentHookOffers.permissionUpdates` choice row: accepts
    /// `offer`, the CLI's own always-allow choice
    /// (`.allowedWithPermissions(offer)`, echoed verbatim). A no-op for
    /// an `.agentQuestion`/`.mcpTool`-sourced `id` -- only an
    /// `.agentHook` request ever carries `AgentHookOffers.permissionUpdates`
    /// to click.
    func allowWithPermissions(id: UUID, offer: AgentPermissionOffer) {
        guard isPendingAgentHook(id) else { return }
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, .allowedWithPermissions(offer))
    }

    /// Whether `id` currently names a pending `.agentHook` request -- the
    /// scoping guard `allowWithPermissions(id:offer:)` uses: it never
    /// applies to `.mcpTool` (no CLI hook behind it) or `.agentQuestion`
    /// (its own, separate action set below).
    private func isPendingAgentHook(_ id: UUID) -> Bool {
        guard let request = store.pending.first(where: { $0.id == id }) else { return false }
        guard case .agentHook = request.source else { return false }
        return true
    }

    /// Whether `id` currently names a pending `.agentQuestion` request.
    /// `allow(id:)`/`deny(id:)` negate this as their own no-op guard:
    /// neither may ever decide a question, which is answered only through
    /// `answer(id:answers:)`/`chatAboutQuestion(id:)`; that latter uses
    /// this same check directly, as its own no-op guard against ever
    /// deciding a non-`.agentQuestion` request. A stale (no longer
    /// pending) `id` is never an agent-question by this definition, which
    /// is fine -- `store.decide` itself already no-ops for a stale id.
    private func isPendingAgentQuestion(_ id: UUID) -> Bool {
        guard let request = store.pending.first(where: { $0.id == id }) else { return false }
        guard case .agentQuestion = request.source else { return false }
        return true
    }

    /// Shared body of `answer(id:answers:)`/`chatAboutQuestion(id:)`:
    /// advances the cursor exactly like `allow(id:)`/`deny(id:)`, restores
    /// terminal focus, THEN resolves `decision` -- the question banner's
    /// own "Other"/notes free-text field may have taken first responder,
    /// and resolving the request removes the banner out from under it.
    /// Focus restoration runs first because `store.decide` posts
    /// `.calyxApprovalInboxChanged` synchronously, which re-renders (and
    /// may order out) the app-wide approval panel before this method's
    /// caller returns -- reclaiming key status after that would inspect a
    /// panel already off screen.
    private func resolveQuestion(id: UUID, _ decision: ApprovalDecision) {
        let targetSurfaceID = store.pending.first(where: { $0.id == id })?.targetSurfaceID
        advanceCursor(pastDisplayed: id)
        restoreTerminalFocus(targetSurfaceID)
        store.decide(id: id, decision)
    }

    /// The approval banner's answer to an `.agentQuestion`-sourced
    /// request's `AskUserQuestion` prompt: resolves the awaiter
    /// `.answered(answers)`.
    func answer(id: UUID, answers: AgentQuestionAnswers) {
        resolveQuestion(id: id, .answered(answers))
    }

    /// The question banner's [Chat about this] action: resolves
    /// `.interrupted(.chatAboutQuestion)` -- the human wants to reply
    /// free-form in the pane instead of answering the structured prompt.
    /// `resolveQuestion(id:_:)`'s own `restoreTerminalFocus()` call is
    /// exactly what lets the human start typing in the pane right away.
    /// A no-op for a non-`.agentQuestion` `id`.
    func chatAboutQuestion(id: UUID) {
        guard isPendingAgentQuestion(id) else { return }
        resolveQuestion(id: id, .interrupted(.chatAboutQuestion))
    }

    /// Called by `AgentQuestionBannerView`'s own root-level `.onDisappear`
    /// when the whole view is torn down while its "Other"/notes free-text
    /// field still held first responder -- covers every removal cause
    /// (the displayed request changing, the hold window expiring, the
    /// pane closing, `expireAll`, cancellation), since that root
    /// `.onDisappear` is the sole path this fires from (not the field's
    /// own `.onDisappear`, which also fires mid-prompt, e.g. on an
    /// ordinary question-to-question advance). Unlike `answer(id:)`/
    /// `chatAboutQuestion(id:)` above, this path decides nothing itself;
    /// it only restores terminal focus. `targetSurfaceID` is the removed
    /// request's own (threaded in by `ApprovalBannerView` from its
    /// `request.targetSurfaceID`, same as `allow(id:)`/`deny(id:)`
    /// thread in `request.id`): the decision on a question goes to the
    /// pane that asked it, not to whatever window is merely current.
    func restoreTerminalFocusAfterInput(targetSurfaceID: UUID?) {
        restoreTerminalFocus(targetSurfaceID)
    }

    /// Branches on the clicked request's own `source`.
    ///
    /// For an `.mcpTool`-sourced request: turns on auto-approve for every
    /// FUTURE gated action, resolves the clicked `id` allowed first (the
    /// request the human actually looked at), then drains every OTHER
    /// `.mcpTool`-sourced request pending app-wide -- otherwise the user
    /// would have to separately page through and dismiss each request
    /// already queued right after turning auto-approve on. Also
    /// deliberately scoped by SOURCE: a queued `.agentHook`-sourced
    /// request -- even one targeting the SAME surface -- is never swept
    /// into this drain, since flipping global
    /// auto-approve says nothing about that request's own, separate
    /// Always-Allow memory; only that request's own always-allow action
    /// (the `.agentHook` branch below) may ever decide it.
    ///
    /// For an `.agentHook`-sourced request: NEVER touches
    /// `CockpitSettings.autoApproveEnabled` at all. Instead records PANE
    /// Always-Allow memory (the clicked request's own `targetSurfaceID`,
    /// `kind`, `toolName`) via the injected `memory`, then drains only
    /// the pending requests matching that EXACT tuple (store-wide is
    /// fine -- the same `targetSurfaceID` already implies the same
    /// window). An agent-hook request always carries a target surface
    /// (the endpoint that submits it 400s otherwise), but this
    /// guard-lets and bails gracefully rather than assuming so.
    ///
    /// Either way, a no-op (no setting change, no memory recorded, no
    /// drain) if `id` is no longer pending -- a stale click must never
    /// silently turn auto-approve on or record memory.
    ///
    /// The whole drain goes through `ApprovalInboxStore.decide(ids:_:)`
    /// (the batched form) rather than one `decide(id:_:)` call per
    /// request, so this posts exactly ONE `.calyxApprovalInboxChanged`
    /// change notification -- and therefore triggers exactly one
    /// re-render of the app-wide panel -- no matter how many requests the
    /// backlog contains, instead of one re-render per drained request.
    func alwaysAllow(id: UUID) {
        guard let request = store.pending.first(where: { $0.id == id }) else { return }

        switch request.source {
        case .mcpTool:
            var idsToAllow = [id]
            idsToAllow.append(contentsOf: store.pending.filter { candidate in
                guard candidate.id != id else { return false }
                guard case .mcpTool = candidate.source else { return false }
                return true
            }.map(\.id))
            advanceCursor(pastDisplayed: id, excluding: Set(idsToAllow))
            CockpitSettings.autoApproveEnabled = true
            store.decide(ids: idsToAllow, .allowed)

        case .agentHook(let toolName, let kind, _, let offers):
            // `cliOwnsPersistence`: the CLI itself already offers (and
            // can persist) its own always-allow choices for this kind --
            // see `AgentHookOffers.cliOwnsPersistence`'s own doc comment
            // for why recording Calyx's OWN pane memory alongside that
            // would be redundant. This action is gated on the CLICKED
            // request's own `offers`, never on `kind` alone -- keeping
            // kind-specific knowledge confined to the wire boundary
            // (`AgentHookToolCall.decode`), not duplicated here.
            guard !offers.cliOwnsPersistence else { return }
            guard let targetSurfaceID = request.targetSurfaceID else { return }
            let idsToAllow = store.pending
                .filter { $0.targetSurfaceID == targetSurfaceID && matchesAgentHook($0.source, kind: kind, toolName: toolName) }
                .map(\.id)
            advanceCursor(pastDisplayed: id, excluding: Set(idsToAllow))
            memory.rememberPane(surfaceID: targetSurfaceID, kind: kind, toolName: toolName)
            store.decide(ids: idsToAllow, .allowed)

        case .agentQuestion:
            // A question is never decided by this action: see
            // `allow(id:)`'s own doc comment on why `.agentQuestion`
            // requests only ever resolve through `answer(id:answers:)`/
            // `chatAboutQuestion(id:)`.
            return
        }
    }

    /// Whether `source` is an `.agentHook` request sharing the exact
    /// (`kind`, `toolName`) pair -- the batch-drain match key
    /// `alwaysAllow(id:)`'s own pane-scoped branch uses, deliberately
    /// ignoring `summary`/`offers` (a per-call, human-readable
    /// description and this specific call's own offers, neither part of
    /// the tool identity this action keys off of).
    private func matchesAgentHook(_ source: ApprovalRequest.Source, kind: String, toolName: String) -> Bool {
        guard case .agentHook(let sourceToolName, let sourceKind, _, _) = source else { return false }
        return sourceToolName == toolName && sourceKind == kind
    }
}
