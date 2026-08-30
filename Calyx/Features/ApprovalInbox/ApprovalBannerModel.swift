// ApprovalBannerModel.swift
// Calyx
//
// Per-window view-model behind the Cockpit approval banner, choosing
// which single pending ApprovalRequest (if any) this window should show
// and forwarding Allow/Deny/Always Allow/Allow All Pending to
// ApprovalInboxStore.decide(id:_:) / CockpitSettings.autoApproveEnabled /
// AgentHookApprovalMemory (Stage E -- see alwaysAllow(id:)'s own doc
// comment for the .mcpTool vs .agentHook source split).
// Mirrors RecoveryBarModel's shape: UI-independent, injected closures
// instead of reaching for CalyxWindowController/NSWindow directly, one
// instance per window.
//
// Queue navigation (prev/next cursor): a stored `selectedRequestID`
// lets a window step through every request visible to it via
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
    /// in this window's `visibleRequests`, oldest-first.
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
    private let ownsSurface: (UUID) -> Bool
    private let isKeyWindow: () -> Bool
    private let restoreTerminalFocus: () -> Void
    private let memory: AgentHookApprovalMemory

    /// This window's own navigation cursor -- see `current`'s own doc
    /// comment for the full selected-if-still-visible/inert-once-stale
    /// contract.
    private var selectedRequestID: UUID?

    init(
        store: ApprovalInboxStore,
        ownsSurface: @escaping (UUID) -> Bool,
        isKeyWindow: @escaping () -> Bool,
        restoreTerminalFocus: @escaping () -> Void = {},
        memory: AgentHookApprovalMemory = .shared
    ) {
        self.store = store
        self.ownsSurface = ownsSurface
        self.isKeyWindow = isKeyWindow
        self.restoreTerminalFocus = restoreTerminalFocus
        self.memory = memory
    }

    /// Whether this window should surface `request` at all. A
    /// surface-targeted request (e.g. a `pane_run` call) is visible only
    /// to the window that owns that surface; a window-agnostic request
    /// (nil `targetSurfaceID`, e.g. a palette-level tool call) is
    /// visible only while this window is key, so every open window
    /// doesn't surface the same banner at once.
    private func isVisible(_ request: ApprovalRequest) -> Bool {
        if let targetSurfaceID = request.targetSurfaceID {
            return ownsSurface(targetSurfaceID)
        }
        return isKeyWindow()
    }

    /// Every pending request visible to this window (same ownership/
    /// key-window filter as `isVisible`), in `store.pending`'s own
    /// oldest-first order (see `ApprovalInboxStore.submit`'s own doc
    /// comment) -- the queue `current`/`positionInfo`/`selectNext()`/
    /// `selectPrevious()`/`advanceCursor(pastDisplayed:)` all navigate.
    private var visibleRequests: [ApprovalRequest] {
        store.pending.filter { isVisible($0) }
    }

    /// The request this window currently displays: `selectedRequestID`
    /// while it is still pending AND visible to this window, else the
    /// oldest visible request (mirrors this property's original,
    /// pre-navigation behavior, and what a freshly-resolved selection
    /// falls back to). `selectedRequestID` is deliberately never cleared
    /// just because its request leaves `visibleRequests` -- it goes
    /// permanently INERT instead, rather than being reset to nil. That's
    /// safe because `ApprovalRequest.id` is a UUID: no future request
    /// can ever be assigned that same id, so a stale cursor can never
    /// accidentally resurrect and re-select some unrelated LATER
    /// request -- it just keeps missing every lookup here (falling back
    /// to the oldest visible request) until some action explicitly
    /// reassigns it (`selectNext()`/`selectPrevious()`/
    /// `advanceCursor(pastDisplayed:)`), or clears it outright
    /// (`allowAllPending()`).
    var current: ApprovalRequest? {
        let visible = visibleRequests
        guard !visible.isEmpty else { return nil }
        return visible[currentIndex(in: visible)]
    }

    /// Index within `visible` of the request this window displays:
    /// `selectedRequestID`'s own position while it is still present
    /// there, else 0 (the oldest visible request, which is what a stale
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

    /// This window's 1-based (index, count) position of `current` within
    /// `visibleRequests` -- nil exactly when `current` is nil. Backs the
    /// banner's "N / M" position label (`ApprovalBannerView.
    /// queueNavigator(positionInfo:)`), shown only while more than one
    /// request is queued for this window. Resolves the displayed
    /// request's index through `currentIndex(in:)` against its own
    /// already-computed `visible` local rather than calling `current`
    /// itself, which would re-filter `store.pending` a second time for
    /// the same answer.
    var positionInfo: (index: Int, count: Int)? {
        let visible = visibleRequests
        guard !visible.isEmpty else { return nil }
        return (index: currentIndex(in: visible) + 1, count: visible.count)
    }

    /// Whether `current` has a predecessor in `visibleRequests` to step
    /// back to -- false at the oldest (first) visible request, and
    /// whenever nothing is visible at all.
    var canSelectPrevious: Bool {
        guard let positionInfo else { return false }
        return positionInfo.index > 1
    }

    /// Whether `current` has a successor in `visibleRequests` to step
    /// forward to -- false at the newest (last) visible request, and
    /// whenever nothing is visible at all.
    var canSelectNext: Bool {
        guard let positionInfo else { return false }
        return positionInfo.index < positionInfo.count
    }

    /// Mirrors `current`'s own ownership filter: the count of every
    /// pending request this window owns/can see. `ApprovalBannerView`
    /// no longer reads this directly -- the queue navigator now gates
    /// on `positionInfo.count` instead (see that property's own doc
    /// comment), which is derived from the SAME `visibleRequests` this
    /// counts. Kept as its own model-level contract because
    /// CalyxTests/ApprovalInbox/ApprovalBannerModelTests.swift asserts
    /// it directly (`test_pendingCountForWindow_countsOnlyOwnedRequests`).
    var pendingCountForWindow: Int {
        visibleRequests.count
    }

    /// Store-wide pending count, with NO window/ownership visibility
    /// filter at all -- used by the cross-actions menu's "Allow All
    /// Pending (N)" label (see `ApprovalBannerView`), distinct from
    /// `pendingCountForWindow` above, which counts only requests this
    /// window owns/can see. Excludes every `.agentQuestion` request:
    /// "Allow All Pending" never decides one (see `allowAllPending()`),
    /// so counting it here would promise a number this action does not
    /// deliver.
    var totalPendingCount: Int {
        allowAllCandidates.count
    }

    /// Every store-wide pending request `allowAllPending()` may decide --
    /// every `.mcpTool`/`.agentHook` request, no `.agentQuestion`, no
    /// window/ownership visibility filter -- shared with `totalPendingCount`
    /// above so the count and the drain can never disagree about which
    /// requests qualify.
    private var allowAllCandidates: [ApprovalRequest] {
        store.pending.filter { !isAgentQuestion($0.source) }
    }

    /// Every request in `visibleRequests` (same ownsSurface/isKeyWindow
    /// filter as `current`/`pendingCountForWindow`), oldest-first, as a
    /// `QueueEntry` -- what `ApprovalBannerView`'s queue preview menu
    /// (`queueMenuItems`) draws its rows from. EVERY visible request is
    /// reported here, and that menu renders one row per entry.
    /// Resolves the current entry's index
    /// through `currentIndex(in:)` against its own local `visible`, the
    /// same single rule `current`/`positionInfo` resolve through, rather
    /// than reading either of them -- so `visibleRequests` is filtered
    /// from `store.pending` only once here (see `positionInfo`'s own doc
    /// comment for the same rationale). Empty whenever `visibleRequests`
    /// is.
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
    /// `ApprovalBannerView`, itself hosted from `MainContentView.body`'s
    /// own `safeAreaInset` closure, which reads `approvalBannerModel.
    /// current` directly (MainContentView.swift's `body`). Mutating
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
    /// is a member of THIS window's own `visibleRequests` -- checked
    /// there rather than `store.pending`, so a request pending
    /// store-wide but owned by another window can never be selected
    /// here.
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
    /// it must not make every open window rebuild its main content.
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
    /// `deny`/`alwaysAllow`/`alwaysAllowAcrossPanes`) -- for `allow`/
    /// `deny` that's still their very first line (neither has an
    /// intervening bail-out guard); for `alwaysAllow`'s `.agentHook`
    /// branch and `alwaysAllowAcrossPanes`, this call is placed AFTER
    /// their own early-return guards (a missing `targetSurfaceID`, or a
    /// `.mcpTool`-sourced click for `alwaysAllowAcrossPanes`) -- a path
    /// that bails out without deciding anything must never advance the
    /// cursor either. `store.pending` hasn't been mutated yet at the
    /// point this actually runs, so `visibleRequests` here still
    /// includes `id`, letting this compute its successor/predecessor
    /// within the PRE-removal queue, same as `selectNext()`/
    /// `selectPrevious()` do. A no-op unless `id` is the request this
    /// window is actually DISPLAYING right now (`current?.id`) -- a
    /// stale `id` (already decided by some other path, see `allow(id:)`'s
    /// own stale-id contract below) can never equal `current?.id` in the
    /// first place (a non-pending request is never in `visibleRequests`),
    /// so this guard also doubles as that same stale-id no-op, keeping
    /// the cursor exactly where `current` has already independently
    /// fallen back to.
    ///
    /// `drainedIDs` (default empty, used only by the batch-drain callers
    /// below) closes a gap the plain immediate-neighbor pick left open:
    /// `alwaysAllow`'s drains (the `.mcpTool` branch's all-visible-
    /// `.mcpTool` sweep; the `.agentHook` branch's same-(surface, kind,
    /// toolName) sweep) and `alwaysAllowAcrossPanes`'s same-(kind,
    /// toolName) store-wide sweep can decide MORE than just `id` in the
    /// very same call -- including the immediate successor this method
    /// would otherwise pick as the new cursor. Once that neighbor is
    /// itself swept, `current`'s `selectedRequestID` lookup misses and
    /// falls all the way back to the OLDEST visible request, snapping the
    /// banner backward instead of stepping to the nearest request that
    /// actually survives the drain. Scans forward from `index + 1` for
    /// the first element NOT in `drainedIDs`; if every forward element is
    /// drained, scans backward from `index - 1` for the nearest element
    /// NOT in `drainedIDs`; nil if nothing survives either direction.
    /// With `drainedIDs` empty (`allow(id:)`/`deny(id:)`'s case), every
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
    /// only `answer(id:answers:)`/`cancelQuestion(id:)`/
    /// `chatAboutQuestion(id:)`/`answerInPane(id:)` may decide (unlike
    /// `alwaysAllow(id:)` below, whose own guard covers
    /// its own extra side effects).
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

    /// `AgentToolApprovalView`'s per-`AgentHookOffers.permissionUpdates`
    /// choice row: accepts `offer`, the CLI's own always-allow choice
    /// (`.allowedWithPermissions(offer)`, echoed verbatim). A no-op for
    /// an `.agentQuestion`/`.mcpTool`-sourced `id` -- only an
    /// `.agentHook` request ever carries `AgentHookOffers.permissionUpdates`
    /// to click.
    func allowWithPermissions(id: UUID, offer: AgentPermissionOffer) {
        guard isPendingAgentHook(id) else { return }
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, .allowedWithPermissions(offer))
    }

    /// `AgentToolApprovalView`'s "Allow amended" action: accepts
    /// `toolInput`, the whole original `tool_input` with `AgentHookOffers.
    /// amendableField`'s value replaced (`.allowedWithInput(toolInput)`).
    /// A no-op for an `.agentQuestion`/`.mcpTool`-sourced `id`, same
    /// scoping as `allowWithPermissions(id:offer:)` above.
    func allowWithInput(id: UUID, toolInput: Data) {
        guard isPendingAgentHook(id) else { return }
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, .allowedWithInput(toolInput))
    }

    /// `AgentToolApprovalView`'s [Cancel] action, shown only while
    /// `AgentHookOffers.canStop`: resolves `.interrupted(.cancelled)`,
    /// telling the CLI to stop and wait for the human rather than that
    /// the call was refused. A no-op for an `.agentQuestion`/`.mcpTool`-
    /// sourced `id` -- an `.mcpTool` request has no CLI hook to interrupt
    /// at all, and a question's own cancel is `cancelQuestion(id:)` below.
    func cancel(id: UUID) {
        guard isPendingAgentHook(id) else { return }
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, .interrupted(.cancelled))
    }

    /// Whether `id` currently names a pending `.agentHook` request -- the
    /// scoping guard `allowWithPermissions(id:offer:)`/`allowWithInput(id:
    /// toolInput:)`/`cancel(id:)` share: none of the three ever applies to
    /// `.mcpTool` (no CLI hook behind it) or `.agentQuestion` (its own,
    /// separate action set below).
    private func isPendingAgentHook(_ id: UUID) -> Bool {
        guard let request = store.pending.first(where: { $0.id == id }) else { return false }
        guard case .agentHook = request.source else { return false }
        return true
    }

    /// Whether `id` currently names a pending request `answerInPane(id:)`
    /// may resolve: an `.agentQuestion` request always, an `.agentHook`
    /// request only when its own `offers.canAnswerInPane` is true,
    /// `.mcpTool` never, a stale (no longer pending) `id` never.
    private func canAnswerInPane(_ id: UUID) -> Bool {
        guard let request = store.pending.first(where: { $0.id == id }) else { return false }
        switch request.source {
        case .mcpTool:
            return false
        case .agentHook(_, _, _, let offers):
            return offers.canAnswerInPane
        case .agentQuestion:
            return true
        }
    }

    /// Whether `id` currently names a pending `.agentQuestion` request.
    /// `allow(id:)`/`deny(id:)` negate this as their own no-op guard:
    /// neither may ever decide a question, which is answered only
    /// through `answer(id:answers:)`/`cancelQuestion(id:)`/
    /// `chatAboutQuestion(id:)`/`answerInPane(id:)`; those last two use
    /// this same check directly, as their own no-op guard against ever
    /// deciding a non-`.agentQuestion` request. A stale (no longer
    /// pending) `id` is never an agent-question by this definition, which
    /// is fine -- `store.decide` itself already no-ops for a stale id.
    private func isPendingAgentQuestion(_ id: UUID) -> Bool {
        guard let request = store.pending.first(where: { $0.id == id }) else { return false }
        return isAgentQuestion(request.source)
    }

    private func isAgentQuestion(_ source: ApprovalRequest.Source) -> Bool {
        guard case .agentQuestion = source else { return false }
        return true
    }

    /// Shared body of `answer(id:answers:)`/`cancelQuestion(id:)`/
    /// `chatAboutQuestion(id:)`/`answerInPane(id:)`: advances the cursor
    /// exactly like `allow(id:)`/`deny(id:)`, resolves `decision`, then
    /// restores terminal focus once -- the banner's own text field (an
    /// `.agentQuestion` banner's "Other"/notes free-text field, or an
    /// `.agentHook` tool banner's amend field) may have taken first
    /// responder, and resolving the request removes the banner out from
    /// under it.
    private func resolveQuestion(id: UUID, _ decision: ApprovalDecision) {
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, decision)
        restoreTerminalFocus()
    }

    /// The approval banner's answer to an `.agentQuestion`-sourced
    /// request's `AskUserQuestion` prompt: resolves the awaiter
    /// `.answered(answers)`.
    func answer(id: UUID, answers: AgentQuestionAnswers) {
        resolveQuestion(id: id, .answered(answers))
    }

    /// The question banner's [Cancel] action (replaces the earlier
    /// "Skip"): resolves `.denied(.questionNotAnswered)` -- the human
    /// dismissed the question without answering it, distinct from
    /// declining an ordinary tool call. A no-op for a non-`.agentQuestion`
    /// `id`, unlike `cancel(id:)` above, which only ever makes sense for
    /// `.agentHook`.
    func cancelQuestion(id: UUID) {
        guard isPendingAgentQuestion(id) else { return }
        resolveQuestion(id: id, .denied(.questionNotAnswered))
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

    /// The banner's "Answer in Pane" action: resolves `.expired` -- no
    /// body reaches the hook (see `AgentHookPermissionResponse`'s own
    /// fail-safe contract), so that kind's own in-pane prompt takes over.
    /// Always applies to an `.agentQuestion`-sourced request. For an
    /// `.agentHook`-sourced request, a no-op unless its own `offers.
    /// canAnswerInPane` is true -- a kind whose hook has no prompt to hand
    /// the call over to (see `AgentHookOffers.canAnswerInPane`'s own doc
    /// comment) must never resolve `.expired` here, since for that kind
    /// `.expired` encodes as an explicit deny, not a handoff. Also a
    /// no-op for an `.mcpTool`-sourced or stale `id`.
    func answerInPane(id: UUID) {
        guard canAnswerInPane(id) else { return }
        resolveQuestion(id: id, .expired)
    }

    /// Called by `AgentQuestionBannerView`'s and `AgentToolApprovalView`'s
    /// own root-level `.onDisappear` when the whole view is torn down
    /// while one of its text fields (the question banner's "Other"/notes
    /// free-text field, or the tool banner's amend field) still held
    /// first responder -- covers every removal cause (the displayed
    /// request changing, the hold window expiring, the pane closing,
    /// `expireAll`, cancellation), since that root `.onDisappear` is the
    /// sole path this fires from (not the field's own `.onDisappear`,
    /// which also fires mid-prompt, e.g. on an ordinary question-to-
    /// question advance). Unlike `answer(id:)`/`cancelQuestion(id:)`/
    /// `chatAboutQuestion(id:)`/`answerInPane(id:)` above, this path
    /// decides nothing itself; it only restores terminal focus.
    func restoreTerminalFocusAfterInput() {
        restoreTerminalFocus()
    }

    /// Branches on the clicked request's own `source` (Stage E).
    ///
    /// For an `.mcpTool`-sourced request: turns on auto-approve for every
    /// FUTURE gated action, resolves the clicked `id` allowed first (the
    /// request the human actually looked at), then drains every OTHER
    /// `.mcpTool`-sourced request already queued and visible to THIS
    /// window -- otherwise the user would have to separately dismiss each
    /// banner already on screen right after turning auto-approve on.
    /// Deliberately scoped to this window: a pending request owned by a
    /// DIFFERENT window is left alone here (auto-approve only gates that
    /// request's future re-submits; that other window drains its own
    /// backlog the same way on its own next interaction). Also
    /// deliberately scoped by SOURCE (R2 fix-pin): a queued
    /// `.agentHook`-sourced request -- even one targeting the SAME
    /// surface -- is never swept into this drain, since flipping global
    /// auto-approve says nothing about that request's own, separate
    /// Always-Allow memory; only that request's own always-allow action
    /// (the `.agentHook` branch below) may ever decide it.
    ///
    /// For an `.agentHook`-sourced request (Stage E, new): NEVER touches
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
    /// `refreshHostingView()` per open window -- no matter how many
    /// requests the backlog contains, instead of one full main-content
    /// rebuild per drained request.
    func alwaysAllow(id: UUID) {
        guard let request = store.pending.first(where: { $0.id == id }) else { return }

        switch request.source {
        case .mcpTool:
            var idsToAllow = [id]
            idsToAllow.append(contentsOf: store.pending.filter { candidate in
                guard candidate.id != id, isVisible(candidate) else { return false }
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
            // `cancelQuestion(id:)`/`chatAboutQuestion(id:)`/
            // `answerInPane(id:)`.
            return
        }
    }

    /// Decides EVERY pending request in the store `.allowed`, store-wide,
    /// with NO window/ownership visibility filter at all, EXCEPT every
    /// `.agentQuestion` request -- this action must never answer a
    /// question on a human's behalf, same rationale as `allow(id:)`'s own
    /// no-op guard. Leaves no Always-Allow memory behind and never
    /// touches any setting -- called by the cross-actions menu's "Allow
    /// All Pending" item (see `ApprovalBannerView`). Clears the
    /// navigation cursor outright (rather than advancing it, unlike
    /// `allow(id:)`/`deny(id:)`/`alwaysAllow(id:)`/
    /// `alwaysAllowAcrossPanes(id:)` above): nothing this action decides
    /// is left pending store-wide to point at.
    func allowAllPending() {
        selectedRequestID = nil
        let idsToAllow = allowAllCandidates.map(\.id)
        store.decide(ids: idsToAllow, .allowed)
    }

    /// Only meaningful for an `.agentHook`-sourced request: records
    /// CROSS Always-Allow memory (`kind`, `toolName` only -- no
    /// `surfaceID`) via the injected `memory`, then drains every pending
    /// request store-wide sharing that (`kind`, `toolName`), regardless
    /// of window/pane ownership. A no-op (no memory recorded, nothing
    /// drained, no setting touched) if `id` is no longer pending, its
    /// source is `.mcpTool`, or its own `offers.cliOwnsPersistence` is
    /// true -- same rationale as `alwaysAllow(id:)`'s own guard.
    func alwaysAllowAcrossPanes(id: UUID) {
        guard let request = store.pending.first(where: { $0.id == id }) else { return }
        guard case .agentHook(let toolName, let kind, _, let offers) = request.source else { return }
        guard !offers.cliOwnsPersistence else { return }

        let idsToAllow = store.pending
            .filter { matchesAgentHook($0.source, kind: kind, toolName: toolName) }
            .map(\.id)
        advanceCursor(pastDisplayed: id, excluding: Set(idsToAllow))
        memory.rememberCross(kind: kind, toolName: toolName)
        store.decide(ids: idsToAllow, .allowed)
    }

    /// Whether `source` is an `.agentHook` request sharing the exact
    /// (`kind`, `toolName`) pair -- the batch-drain match key both the
    /// pane-scoped half of `alwaysAllow(id:)` and
    /// `alwaysAllowAcrossPanes(id:)` use, deliberately ignoring
    /// `summary`/`offers` (a per-call, human-readable description and
    /// this specific call's own offers, neither part of the tool
    /// identity these actions key off of).
    private func matchesAgentHook(_ source: ApprovalRequest.Source, kind: String, toolName: String) -> Bool {
        guard case .agentHook(let sourceToolName, let sourceKind, _, _) = source else { return false }
        return sourceToolName == toolName && sourceKind == kind
    }
}
