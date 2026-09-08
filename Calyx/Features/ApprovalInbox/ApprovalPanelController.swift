// ApprovalPanelController.swift
// Calyx
//
// Owns the single, app-wide floating `ApprovalPanelWindow`: lazily
// creates it the first time `model.current` is non-nil, sizes/positions
// it via `ApprovalPanelArranger`, and orders it front/out. One instance
// for the whole app, owned by `AppDelegate.approvalPanelController` --
// the panel is not a Calyx window, and every pending request pages
// through this same panel via `ApprovalBannerModel`'s own Previous/Next
// queue navigation.
//
// `render()` is called whenever `model.current` might have changed:
// `ApprovalInboxStore` mutation, the current window changing, or the
// current window's own geometry changing (screen, full screen).
//
// See CalyxTests/ApprovalInbox/ApprovalPanelControllerTests.swift for
// the specced render()/reanchor()/tearDown() lifecycle.

import AppKit
import SwiftUI

/// The app-wide floating panel's own layout state: `width` holds the
/// glass SHEET's own width for the currently displayed request
/// (`ApprovalPanelArranger.panelWidth(for:visibleFrame:)` -- `fixedWidth`
/// or `wideWidth`, whichever that request wants), read by
/// `ApprovalPanelContentView`'s root `.frame(width:)` -- the WINDOW
/// itself is `2 * ApprovalPanelArranger.gutter` points wider, see
/// `ApprovalPanelController.measureFrame(hostingController:)`'s own doc
/// comment. `heightCap`
/// mirrors `ApprovalPanelArranger.heightCap(visibleFrame:)` for the
/// screen this panel currently sits on. `hostWindowController` is the
/// designated host window controller as of the last `render()` --
/// `ApprovalPanelContentView` reads its `activeTabDisplayTitle`/`window?.
/// title` directly from this `@Observable` property, so it re-renders
/// both when the designated host WINDOW changes (this property is
/// reassigned) and when its active tab is renamed in place (`Tab.
/// displayTitle`, a property read reached through this same reference,
/// is itself `@Observable`).
@MainActor
@Observable
final class ApprovalPanelLayout {
    var width: CGFloat = ApprovalPanelArranger.fixedWidth
    var heightCap: CGFloat = 0
    weak var hostWindowController: CalyxWindowController?
    /// `AssumeInsideHover`'s own `recheckToken` for both
    /// `ApprovalPanelContentView` hover regions (the sheet and the
    /// dismiss button) -- bumped by `ApprovalPanelController.render()`
    /// exactly when the panel transitions from hidden to ordered front, a
    /// HIDDEN window being the only case that can miss real
    /// `mouseEntered`/`mouseExited` events. See `AssumeInsideHover
    /// .updateNSView(_:context:)`'s own doc comment for why this must NOT
    /// happen on every re-render instead.
    var hoverRecheckToken: Int = 0
}

@MainActor
final class ApprovalPanelController: NSObject {
    enum OrderIntent {
        case orderFront(NSRect)
        case orderOut
    }

    private let model: ApprovalBannerModel
    private let hostWindow: () -> NSWindow?
    private let visibleFrame: () -> NSRect
    /// Hands key status back to the pane that asked, called with
    /// `lastRenderedTargetSurfaceID` -- see `handOffKeyIfNeeded()`'s own
    /// doc comment. `{ _ in }` by default so every existing test-only
    /// `ApprovalPanelController` construction (none of which cares about
    /// key hand-off) keeps compiling unchanged.
    private let handOffKey: (UUID?) -> Void
    /// `ApprovalPanelLayout.hostWindowController`'s own source -- see that
    /// property's doc comment. `{ nil }` by default, same rationale as
    /// `handOffKey`.
    private let hostWindowController: () -> CalyxWindowController?
    /// `ApprovalPanelContentView`'s own source for a surface-targeted
    /// request's target label (`ApprovalBannerView.targetLabel`) -- the
    /// owning tab's `displayTitle`, or nil if no open window owns the
    /// surface. `AppDelegate` supplies `{ [weak self] id in self?.
    /// windowController(owningSurface: id)?.tabDisplayTitle(owningSurface:
    /// id) }`. `{ _ in nil }` by default, same rationale as `handOffKey`/
    /// `hostWindowController` above -- every existing test-only
    /// construction (none of which cares about the target label) keeps
    /// compiling unchanged.
    private let targetTabTitle: (UUID) -> String?
    private let layout = ApprovalPanelLayout()
    /// One tooltip presenter for the app-wide panel, handed to
    /// `ApprovalPanelContentView` through `\.approvalTooltipPresenter` --
    /// see `ApprovalTooltipPresenter`'s own header.
    private let tooltipPresenter = ApprovalTooltipPresenter()

    private(set) var panel: ApprovalPanelWindow?
    private(set) var isTornDown = false
    private var lastAppliedContentHeight: CGFloat?

    /// The `model.current?.id` `render()` last actually applied to the
    /// panel (nil once nothing is displayed) -- lets `render()` tell a
    /// genuine request change from an idempotent re-render of the SAME
    /// request (e.g. `applyContentHeight(_:)`'s own re-measure), and lets
    /// `handleRequestChange()` skip a render the notification-driven path
    /// already performed for the same change (see that method's own doc
    /// comment).
    private var lastRenderedRequestID: UUID?

    /// `lastRenderedRequestID`'s own `targetSurfaceID`, written alongside
    /// it -- the pane `handOffKeyIfNeeded()` hands key back to is always
    /// the one the DISPLAYED (about to be replaced or hidden) request
    /// targeted, never the incoming one.
    private var lastRenderedTargetSurfaceID: UUID?

    #if DEBUG
    /// Test seam: records every order intent this controller would have
    /// issued instead of actually calling `orderFrontRegardless()`/
    /// `orderOut(_:)`, mirroring
    /// `QuickTerminalController._requestHideHookForTesting`'s identical
    /// shape -- when set, it REPLACES the real AppKit call entirely
    /// (never supplements it), so no test in this file ever shows a real
    /// window. `nil` (the default) leaves production behavior
    /// unchanged. DO NOT use from production code.
    var _orderHookForTesting: ((OrderIntent) -> Void)?

    /// Test seam: stands in for `panel?.isKeyWindow` wherever
    /// `handOffKeyIfNeeded()` reads it, so `handOffKey(_:)` invocation can
    /// be exercised in the unit-test host without ever making a real
    /// window key (an XCTest host cannot reliably do that -- see this
    /// file's own `_orderHookForTesting` doc comment for the identical
    /// constraint on showing a real window at all). `nil` (the default)
    /// falls through to the real `panel?.isKeyWindow` read, leaving
    /// production behavior unchanged. DO NOT use from production code.
    var _panelIsKeyForTesting: Bool?
    #endif

    /// `panel?.isKeyWindow`, or `_panelIsKeyForTesting` when that test
    /// seam is set (`#if DEBUG` only) -- the single read `handOffKeyIfNeeded()`
    /// uses to decide whether the panel currently holds key.
    private var panelIsKey: Bool {
        #if DEBUG
        if let overridden = _panelIsKeyForTesting { return overridden }
        #endif
        return panel?.isKeyWindow == true
    }

    init(
        model: ApprovalBannerModel,
        hostWindow: @escaping () -> NSWindow?,
        visibleFrame: (() -> NSRect)? = nil,
        handOffKey: @escaping (UUID?) -> Void = { _ in },
        hostWindowController: @escaping () -> CalyxWindowController? = { nil },
        targetTabTitle: @escaping (UUID) -> String? = { _ in nil }
    ) {
        self.model = model
        self.hostWindow = hostWindow
        self.handOffKey = handOffKey
        self.hostWindowController = hostWindowController
        self.targetTabTitle = targetTabTitle
        // Same NSScreen.main?.visibleFrame fallback shape as
        // AppDelegate's own screen-frame lookups: a real screen may be
        // unavailable, and `.zero` would collapse every subsequent
        // width/height clamp in `ApprovalPanelArranger` to nothing,
        // rather than a usable fallback size.
        self.visibleFrame = visibleFrame ?? {
            (hostWindow()?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Reflects `model.current` into the floating panel: nil orders it
    /// out (a no-op if no panel has ever been created), non-nil lazily
    /// creates the panel and re-measures/re-positions it via
    /// `ApprovalPanelArranger`. A complete no-op once `tearDown()` has
    /// run.
    ///
    /// Writes `layout.hostWindowController` from `hostWindowController()`
    /// before either branch below, but only when it actually names a
    /// different controller (identity, since `hostWindowController()` is
    /// resolved fresh on every call) -- `@Observable` invalidates this
    /// property's readers on assignment regardless of whether the new
    /// value differs, and `ApprovalPanelContentView`'s content body is one
    /// such reader, so a same-controller re-render (e.g. a content-height
    /// re-measure) must not reassign it. See
    /// `ApprovalPanelLayout.hostWindowController`'s own doc comment.
    ///
    /// Before applying either change, hands key status back via
    /// `handOffKeyIfNeeded()` if the panel currently holds it AND the
    /// change is either an order-out or a genuine request change
    /// (`request.id != lastRenderedRequestID`) -- key status the panel
    /// took (only the question form's free-text field takes it; Allow/
    /// Deny/a choice row, the Options menu, and the payload body's
    /// tap-to-expand never do) must return to the pane it came from, not
    /// linger on a panel about to disappear or show unrelated content. An
    /// idempotent re-render of the SAME still-displayed request
    /// (`applyContentHeight(_:)`'s own re-measure) never hands key back,
    /// since nothing the user is looking at is changing. Every removal
    /// cause routes through this same `render()` call -- hold-window
    /// expiry (`ApprovalHookTiming`), `ApprovalInboxStore.expireAll`/
    /// `expireForSurface`, and paging (`selectNext()`/`selectPrevious()`
    /// via `handleRequestChange()`) all clear or change `model.current`,
    /// which reaches here the same way a decision does -- so the pane
    /// that asked always gets key status back through this one path
    /// (`handOffKeyIfNeeded()`'s own doc comment covers how this relates
    /// to `ApprovalBannerModel`'s own, separate first-responder restore).
    func render() {
        guard !isTornDown else { return }
        let designatedHost = hostWindowController()
        if layout.hostWindowController !== designatedHost {
            layout.hostWindowController = designatedHost
        }

        guard let request = model.current else {
            if let panel {
                handOffKeyIfNeeded()
                tooltipPresenter.hide()
                performOrderOut(panel: panel)
            }
            lastRenderedRequestID = nil
            lastRenderedTargetSurfaceID = nil
            return
        }

        if request.id != lastRenderedRequestID {
            handOffKeyIfNeeded()
            tooltipPresenter.hide()
        }
        lastRenderedRequestID = request.id
        lastRenderedTargetSurfaceID = request.targetSurfaceID

        let (thePanel, hostingController) = ensurePanelAndHostingController()
        let frame = measureFrame(hostingController: hostingController)
        thePanel.setFrame(frame, display: true)
        performOrderFront(frame: frame, panel: thePanel)
    }

    /// Hands KEY status from the panel to whichever pane asked, only if
    /// the panel actually holds key right now -- called BEFORE the
    /// order-out/re-render that follows, so `panel?.isKeyWindow` still
    /// reads true for the request about to be replaced or hidden.
    /// `lastRenderedTargetSurfaceID` is the DISPLAYED request's own
    /// target (not the incoming one, which `render()` has not yet
    /// written it to), passed to `handOffKey(_:)` -- `AppDelegate` wires
    /// this to `restoreTerminalFocusAfterApproval(targetSurfaceID:)`,
    /// which resolves the owning window (or `currentWindowController` for
    /// a window-agnostic request) and computes `reclaimKey` from
    /// `panel?.isKeyWindow` at that same call, still true at this point --
    /// that method's own guard (visible, not miniaturized, on the active
    /// Space) is what actually decides whether `makeKey()` runs, mirroring
    /// `CalyxWindowController.restoreTerminalFocusAfterApproval(reclaimKey:)`'s
    /// own guard.
    ///
    /// This is a DIFFERENT question from `ApprovalBannerModel
    /// .resolveQuestion(id:_:)`'s own `restoreTerminalFocus(_:)` call (and
    /// `dismiss(id:)`'s matching call for `.mcpTool`/`.agentHook`): this
    /// method only runs while the panel holds key, and answers "who
    /// should be KEY window now" -- `resolveQuestion`/`dismiss` restore
    /// FIRST RESPONDER inside the owning window regardless of whether the
    /// panel ever held key (an Options-menu answer, "Chat about this", or
    /// a × dismiss never take key at all, since none of those click
    /// targets is the question's free-text field). Both reach the same
    /// `restoreTerminalFocusAfterApproval(targetSurfaceID:)`, and both run
    /// synchronously on the main actor with no `await` between them, so
    /// there is no race: whichever runs second finds `CalyxWindowController
    /// .restoreTerminalFocusAfterApproval(reclaimKey:)`'s own
    /// first-responder restore already idempotent.
    private func handOffKeyIfNeeded() {
        guard panelIsKey else { return }
        handOffKey(lastRenderedTargetSurfaceID)
    }

    /// Tears the app-wide floating panel down for good: the panel
    /// survives its own `close()` (`isReleasedWhenClosed == false`), but
    /// every subsequent `render()` is a complete no-op. Never routes
    /// through `_orderHookForTesting` -- unlike `render()`'s own
    /// intents, this is teardown bookkeeping, not a decision a test
    /// needs to observe as an "order" action.
    func tearDown() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel?.close()
        tooltipPresenter.tearDown()
        NotificationCenter.default.removeObserver(self)
        isTornDown = true
    }

    /// Re-measures and re-positions the panel via the SAME path
    /// `render()` itself takes -- called when the screen configuration
    /// changes, or the current window's own screen/full-screen
    /// state changes. A screen swap can change the available width/
    /// height cap, not just the panel's origin, so a cheap "just move
    /// the existing frame" shortcut would leave a stale cap in place;
    /// re-measuring from scratch is the only path that picks up a new
    /// screen's own caps too. A no-op once torn down.
    func reanchor() {
        guard !isTornDown else { return }
        render()
    }

    // MARK: - Panel / hosting controller

    private func ensurePanelAndHostingController() -> (ApprovalPanelWindow, NSHostingController<ApprovalPanelContentView>) {
        if let panel, let hostingController = panel.contentViewController as? NSHostingController<ApprovalPanelContentView> {
            return (panel, hostingController)
        }

        let thePanel = panel ?? ApprovalPanelWindow()
        let content = ApprovalPanelContentView(
            model: model,
            layout: layout,
            targetTabTitle: targetTabTitle,
            tooltipPresenter: tooltipPresenter,
            onContentSizeChange: { [weak self] size in self?.applyContentHeight(size) },
            onRequestChange: { [weak self] in self?.handleRequestChange() }
        )
        let hostingController = NSHostingController(rootView: content)
        // ApprovalPanelWindow carries no title bar (no `.titled` in its
        // styleMask), so there is no title bar inset to exclude here --
        // this instead ensures the hosting controller reserves no safe
        // area of its own at all, so `measureFrame(hostingController:)`'s
        // own `sizeThatFits(in:)` measures exactly the sheet's own
        // content height, with nothing else folded in.
        hostingController.safeAreaRegions = []
        thePanel.contentViewController = hostingController
        panel = thePanel
        return (thePanel, hostingController)
    }

    /// Single-pass measure: the glass SHEET's width is settled for the
    /// currently displayed request before any layout pass
    /// (`ApprovalPanelArranger.panelWidth(for:visibleFrame:)` --
    /// `fixedWidth` or `wideWidth`, whichever `model.current` wants, see
    /// `ApprovalRequest.prefersWideApprovalPanel`), so this measures
    /// height only, at that width. `layout.heightCap`/`layout.width` are
    /// only reassigned when the freshly computed value actually differs
    /// from what is already there -- `@Observable` invalidates every
    /// reader on assignment regardless of whether the value changed, and
    /// `ApprovalPanelContentView`'s content body is one such reader, so a
    /// same-input re-render must not invalidate it. `layout` is
    /// `@Observable`, but `NSHostingController.sizeThatFits(in:)` does not
    /// itself pump the Observation update from a property mutation into a
    /// fresh layout pass -- forcing `needsLayout`/`layoutSubtreeIfNeeded()`
    /// after the mutation, before `sizeThatFits`, is what makes that call
    /// see this measurement's own latest `layout.width`/`layout.heightCap`
    /// rather than whatever was current as of some earlier call, whether
    /// or not either was actually reassigned just now.
    ///
    /// `hostingController.sizeThatFits(in:)` measures the WHOLE content
    /// view, which includes `ApprovalPanelContentView`'s own `gutter`
    /// padding on all four sides around the sheet -- its returned height
    /// is therefore `sheetHeight + 2*gutter`, and its returned width
    /// `sheetWidth + 2*gutter`, so `2*gutter` is subtracted back out of
    /// the height here before this measurement's own `heightCap` (a
    /// SHEET-height cap) clamps it, and before it is handed to
    /// `ApprovalPanelArranger.windowFrame(sheetSize:visibleFrame:)`,
    /// which itself re-adds that same `2*gutter` to compute the WINDOW's
    /// own frame. `lastAppliedContentHeight` is set to the SHEET height
    /// (not the gutter-inflated one), matching what
    /// `ApprovalPanelContentView`'s own `onGeometryChange` -- attached to
    /// the pre-padding node, see that file's own header -- reports back
    /// through `onContentSizeChange` -> `applyContentHeight(_:)`.
    private func measureFrame(hostingController: NSHostingController<ApprovalPanelContentView>) -> NSRect {
        let frame = visibleFrame()
        let heightCap = ApprovalPanelArranger.heightCap(visibleFrame: frame)
        let width = ApprovalPanelArranger.panelWidth(for: model.current, visibleFrame: frame)
        if layout.heightCap != heightCap {
            layout.heightCap = heightCap
        }
        if layout.width != width {
            layout.width = width
        }

        hostingController.view.needsLayout = true
        hostingController.view.layoutSubtreeIfNeeded()
        // The content view includes `ApprovalPanelContentView`'s own
        // `gutter` padding on all four sides, so the size proposed to
        // `sizeThatFits(in:)` carries `2*gutter` on both axes, matching
        // what the content view actually occupies at the SHEET's own
        // `width`/`heightCap`.
        let measuredSize = hostingController.sizeThatFits(
            in: CGSize(width: width + (2 * ApprovalPanelArranger.gutter), height: heightCap + (2 * ApprovalPanelArranger.gutter))
        )
        let sheetHeight = min(measuredSize.height - (2 * ApprovalPanelArranger.gutter), heightCap)
        let sheetSize = CGSize(width: width, height: sheetHeight)

        // Set here (not left for `applyContentHeight(_:)`'s own first
        // call to discover) so the content view's own measured-size echo
        // (`onContentSizeChange` -> `applyContentHeight(_:)`), once it
        // reports back this SAME height, reads as a no-op rather than a
        // change worth re-rendering for.
        lastAppliedContentHeight = sheetSize.height

        return ApprovalPanelArranger.windowFrame(sheetSize: sheetSize, visibleFrame: frame)
    }

    /// `ApprovalPanelContentView.onContentSizeChange`: a later, purely
    /// runtime content-height change (e.g. the question form's notes
    /// field appearing) while the SAME request is still showing at the
    /// SAME width `render()`'s own measurement already settled on for
    /// it.
    /// Ignores any report against a stale width and any report that
    /// doesn't actually change the height, so this can never loop
    /// against `render()`'s own measurement pass.
    private func applyContentHeight(_ size: CGSize) {
        guard !isTornDown, size.width == layout.width else { return }
        if let lastAppliedContentHeight, abs(lastAppliedContentHeight - size.height) < 0.5 { return }
        lastAppliedContentHeight = size.height
        render()
    }

    /// `ApprovalPanelContentView.onRequestChange`: fires for EVERY
    /// `request.id` change the content view observes, including one
    /// `render()`'s own notification-driven path (`decide()` ->
    /// `.calyxApprovalInboxChanged` -> `AppDelegate
    /// .handleApprovalInboxChangedForPanel` -> `render()`) already
    /// applied before this callback runs -- re-rendering there again
    /// would be a redundant, needless second measure/order pass for the
    /// same change. Only `selectNext()`/`selectPrevious()` reach here
    /// with a request `render()` has not already applied (those two
    /// deliberately post no change notification of their own -- see
    /// `ApprovalBannerModel.selectNext()`'s own doc comment), so this
    /// re-renders only when `model.current`'s id genuinely does not match
    /// what was last rendered. `render()` -> `measureFrame(hostingController:)`
    /// already re-measures from scratch for the new request, so this
    /// performs no reset of its own.
    private func handleRequestChange() {
        guard !isTornDown else { return }
        guard model.current?.id != lastRenderedRequestID else { return }
        render()
    }

    // MARK: - Order intents

    private func performOrderFront(frame: NSRect, panel: ApprovalPanelWindow) {
        #if DEBUG
        if let hook = _orderHookForTesting {
            hook(.orderFront(frame))
            return
        }
        #endif
        if !panel.isVisible {
            panel.orderFrontRegardless()
            // Only a HIDDEN window can have missed real `mouseEntered`/
            // `mouseExited` events -- see `ApprovalPanelLayout
            // .hoverRecheckToken`'s own doc comment.
            layout.hoverRecheckToken += 1
        }
    }

    private func performOrderOut(panel: ApprovalPanelWindow) {
        #if DEBUG
        if let hook = _orderHookForTesting {
            hook(.orderOut)
            return
        }
        #endif
        panel.orderOut(nil)
    }

    // MARK: - Screen parameter changes

    @objc private func handleScreenParametersChanged(_ notification: Notification) {
        reanchor()
    }
}
