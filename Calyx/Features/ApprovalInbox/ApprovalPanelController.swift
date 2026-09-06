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

/// The app-wide floating panel's own layout state: `width` is nil while
/// `render()`'s first measurement pass is in flight (letting
/// `ApprovalPanelContentView`'s root report its own unconstrained ideal
/// width via `.fixedSize(horizontal: true)`), then holds the clamped,
/// final width for every subsequent layout pass. `heightCap` mirrors
/// `ApprovalPanelArranger.heightCap(visibleFrame:)` for the screen this
/// panel currently sits on.
@MainActor
@Observable
final class ApprovalPanelLayout {
    var width: CGFloat?
    var heightCap: CGFloat = 0
}

@MainActor
final class ApprovalPanelController: NSObject {
    enum OrderIntent {
        case orderFront(NSRect)
        case orderOut
    }

    private let model: ApprovalBannerModel
    private let hostWindow: () -> NSWindow?
    private let hostWindowTitle: () -> String
    private let visibleFrame: () -> NSRect
    private let layout = ApprovalPanelLayout()

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
    #endif

    init(
        model: ApprovalBannerModel,
        hostWindow: @escaping () -> NSWindow?,
        hostWindowTitle: @escaping () -> String,
        visibleFrame: (() -> NSRect)? = nil
    ) {
        self.model = model
        self.hostWindow = hostWindow
        self.hostWindowTitle = hostWindowTitle
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
    /// Before applying either change, hands key status back to
    /// `hostWindow()` if the panel currently holds it AND the change is
    /// either an order-out or a genuine request change (`request.id !=
    /// lastRenderedRequestID`) -- key status the panel took (e.g. the
    /// question form's free-text field, or `NSHostingView
    /// .needsPanelToBecomeKey` answering true for an Allow/Deny click)
    /// must return to the window it came from, not linger on a panel
    /// about to disappear or show unrelated content. An idempotent
    /// re-render of the SAME still-displayed request (`applyContentHeight
    /// (_:)`'s own re-measure) never hands key back, since nothing the
    /// user is looking at is changing.
    func render() {
        guard !isTornDown else { return }

        guard let request = model.current else {
            if let panel {
                handOffKeyIfNeeded()
                performOrderOut(panel: panel)
            }
            lastRenderedRequestID = nil
            return
        }

        if request.id != lastRenderedRequestID {
            handOffKeyIfNeeded()
        }
        lastRenderedRequestID = request.id

        let (thePanel, hostingController) = ensurePanelAndHostingController()
        let frame = measureFrame(hostingController: hostingController)
        thePanel.setFrame(frame, display: true)
        performOrderFront(frame: frame, panel: thePanel)
    }

    /// Hands key status from the panel to `hostWindow()`, only if the
    /// panel actually holds it right now and `hostWindow()` is actually
    /// showable (visible, not miniaturized, on the active Space) --
    /// reclaiming key for a minimized or off-Space window would silently
    /// deminiaturize/Space-switch it out from under the user, mirroring
    /// `CalyxWindowController.restoreTerminalFocusAfterApproval(reclaimKey:)`'s
    /// own guard.
    private func handOffKeyIfNeeded() {
        guard panel?.isKeyWindow == true else { return }
        guard let window = hostWindow(), window.isVisible, !window.isMiniaturized, window.isOnActiveSpace else { return }
        window.makeKey()
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
            hostWindowTitle: hostWindowTitle,
            onContentSizeChange: { [weak self] size in self?.applyContentHeight(size) },
            onRequestChange: { [weak self] in self?.handleRequestChange() }
        )
        let hostingController = NSHostingController(rootView: content)
        // Excludes the titled window's own titlebar safe area from this
        // content: `.fullSizeContentView` + `.titled` reserves a
        // titlebar-height top inset for ANY content view controller's
        // view, even with `titleVisibility = .hidden` and no visible
        // traffic lights -- measured directly (a stray, constant +32pt
        // folded into every `sizeThatFits(in:)` height otherwise), and
        // it would also push the panel's own top edge that same 32pt
        // below the screen's visible top once shown.
        hostingController.safeAreaRegions = []
        thePanel.contentViewController = hostingController
        panel = thePanel
        return (thePanel, hostingController)
    }

    /// Two-pass measure: the first pass (`layout.width = nil`) lets
    /// `ApprovalPanelContentView`'s root report its own unconstrained
    /// ideal width; the second, at the clamped width, reports the
    /// content's actual height at that width. `layout` is `@Observable`,
    /// but `NSHostingController.sizeThatFits(in:)` does not itself pump
    /// the Observation update from a property mutation into a fresh
    /// layout pass -- forcing `needsLayout`/`layoutSubtreeIfNeeded()`
    /// after EACH mutation, before its corresponding `sizeThatFits`
    /// call, is what makes that call see this measurement's own latest
    /// `layout.width`/`layout.heightCap` rather than whatever was
    /// current as of some earlier call.
    private func measureFrame(hostingController: NSHostingController<ApprovalPanelContentView>) -> NSRect {
        let frame = visibleFrame()
        let heightCap = ApprovalPanelArranger.heightCap(visibleFrame: frame)
        let widthCap = ApprovalPanelArranger.clampWidth(ideal: .greatestFiniteMagnitude, visibleFrame: frame)
        layout.heightCap = heightCap

        layout.width = nil
        hostingController.view.needsLayout = true
        hostingController.view.layoutSubtreeIfNeeded()
        let idealSize = hostingController.sizeThatFits(in: CGSize(width: widthCap, height: heightCap))
        let width = ApprovalPanelArranger.clampWidth(ideal: idealSize.width, visibleFrame: frame)

        layout.width = width
        hostingController.view.needsLayout = true
        hostingController.view.layoutSubtreeIfNeeded()
        let finalSize = hostingController.sizeThatFits(in: CGSize(width: width, height: heightCap))
        let size = CGSize(width: width, height: min(finalSize.height, heightCap))

        // Set here (not left for `applyContentHeight(_:)`'s own first
        // call to discover) so the content view's own measured-size echo
        // (`onContentSizeChange` -> `applyContentHeight(_:)`), once it
        // reports back this SAME height, reads as a no-op rather than a
        // change worth re-rendering for.
        lastAppliedContentHeight = size.height

        return ApprovalPanelArranger.anchor(size: size, visibleFrame: frame)
    }

    /// `ApprovalPanelContentView.onContentSizeChange`: a later, purely
    /// runtime content-height change (e.g. the question form's notes
    /// field appearing) while the SAME request is still showing at the
    /// SAME clamped width `render()`'s own measurement already settled
    /// on. Ignores any report against a stale/intermediate width (the
    /// unclamped first pass, or a width from before a request change
    /// resets `layout.width` to nil) and any report that doesn't
    /// actually change the height, so this can never loop against
    /// `render()`'s own measurement passes.
    private func applyContentHeight(_ size: CGSize) {
        guard !isTornDown, let width = layout.width, size.width == width else { return }
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
    /// already resets `layout.width` to nil and re-measures from scratch
    /// for the new request, so this performs no reset of its own.
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
