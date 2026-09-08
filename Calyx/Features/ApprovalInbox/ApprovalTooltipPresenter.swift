// ApprovalTooltipPresenter.swift
// Calyx
//
// Owns the single, lazily-created `ApprovalTooltipWindow` for the
// app-wide `ApprovalPanelController` (one presenter per app, mirroring
// that controller's own "one panel per app" shape) -- shows/hides the
// Calyx-drawn tooltip `ExpandableBodyText` hover schedules. Reached
// from SwiftUI through `\.approvalTooltipPresenter`, set on
// `ApprovalPanelContentView`'s own root by `ApprovalPanelController`.
//
// Owns the pending, delayed show as well as the shown window itself:
// `ExpandableBodyText` calls `scheduleShow(text:)` on hover start and
// `hide()` on hover end/tap/teardown, holding no work item of its own.
// This means every one of `ApprovalPanelController`'s own existing
// `hide()` calls (on order-out, on a displayed-request change, and on
// `tearDown()`) also cancels a still-pending show, not just an
// already-shown window -- a request that changes or a panel that orders
// out WHILE a tooltip is still counting down its own delay can no
// longer show a tooltip for content that is already gone.

import AppKit
import SwiftUI

@MainActor
final class ApprovalTooltipPresenter {
    private var window: ApprovalTooltipWindow?
    private var hostingController: NSHostingController<ApprovalTooltipContent>?
    /// The delayed `show(text:at:)` call scheduled by `scheduleShow(text:)`
    /// -- an unstructured `Task` (not `DispatchWorkItem`) so the
    /// delayed body can call this `@MainActor` type's own methods
    /// directly, with no `@Sendable` closure/`MainActor.assumeIsolated`
    /// escape hatch needed: a `Task` created from `@MainActor`-isolated
    /// code inherits that isolation.
    private var pendingShowTask: Task<Void, Never>?

    #if DEBUG
    /// Test seam: overrides `tooltipDelayMilliseconds` so a test can
    /// exercise `scheduleShow(text:)`/`cancelPending()` without waiting
    /// out a full real delay. `nil` (the default) leaves production
    /// behavior unchanged. DO NOT use from production code.
    var _delayMillisecondsForTesting: Int?
    /// Test seam: records every `scheduleShow(text:)` call that actually
    /// reached its own delayed body (i.e. was never cancelled first)
    /// instead of calling the real `show(text:at:)` -- mirrors
    /// `ApprovalPanelController._orderHookForTesting`'s identical shape.
    /// `nil` (the default) leaves production behavior unchanged. DO NOT
    /// use from production code.
    var _showHookForTesting: ((String, NSPoint) -> Void)?
    /// Test seam: records the exact `NSRect` `show(text:at:)` would pass
    /// to `NSWindow.setFrame(_:display:)`, in place of actually creating/
    /// resizing/ordering front the real window -- lets a test pin the
    /// measurement + placement math end to end (contentSize, then
    /// `frame(for:pointer:visibleFrame:)`) without ever showing a real
    /// window. `nil` (the default) leaves production behavior unchanged.
    /// DO NOT use from production code.
    var _setFrameHookForTesting: ((NSRect) -> Void)?
    #endif

    /// Schedules `show(text:at:)` after the tooltip delay (AppKit's own
    /// `NSInitialToolTipDelay` default when set on this machine, else
    /// its own undocumented 1000ms default), cancelling any
    /// already-pending or already-shown tooltip first -- only one
    /// tooltip is ever pending or shown at a time, matching one hovered
    /// text region at a time. `NSEvent.mouseLocation` is read once the
    /// delay actually elapses, not at schedule time, so the tooltip
    /// anchors to wherever the pointer has come to rest by then.
    func scheduleShow(text: String) {
        hide()
        var delayMilliseconds = Self.tooltipDelayMilliseconds
        #if DEBUG
        if let overridden = _delayMillisecondsForTesting { delayMilliseconds = overridden }
        #endif
        pendingShowTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingShowTask = nil
            let pointer = NSEvent.mouseLocation
            #if DEBUG
            if let hook = self._showHookForTesting {
                hook(text, pointer)
                return
            }
            #endif
            self.show(text: text, at: pointer)
        }
    }

    /// Cancels a pending `scheduleShow(text:)` without affecting an
    /// already-shown window -- `hide()` below is the only caller that
    /// needs both together.
    private func cancelPending() {
        pendingShowTask?.cancel()
        pendingShowTask = nil
    }

    /// `AppKit`'s own default initial tooltip delay
    /// (`NSInitialToolTipDelay`, a `UserDefaults` key AppKit itself
    /// reads and honors) in milliseconds, when set on this machine;
    /// AppKit's own undocumented default of 1000ms otherwise. Reads
    /// through `NSNumber.intValue` (not `as? Int`) so a value stored as
    /// a plist double is honored too, not silently ignored.
    private static var tooltipDelayMilliseconds: Int {
        if let milliseconds = UserDefaults.standard.object(forKey: "NSInitialToolTipDelay") as? NSNumber {
            return milliseconds.intValue
        }
        return 1000
    }

    /// Shows the tooltip for `text`, positioned relative to `pointer`
    /// (AppKit screen coordinates, e.g. `NSEvent.mouseLocation`) --
    /// lazily creates the window on first use. `pointer` must already
    /// reflect wherever the cursor is at call time; this method takes no
    /// further reading of it. A no-op if no screen actually contains
    /// `pointer` (e.g. mid screen-configuration change) -- there is no
    /// designed fallback screen to anchor an unclamped tooltip to.
    /// Called only through `scheduleShow(text:)`'s own delayed body in
    /// production; kept as its own method (rather than folded into that
    /// closure) so the placement/measurement logic itself stays directly
    /// callable/testable independent of the delay.
    func show(text: String, at pointer: NSPoint) {
        guard let screenVisibleFrame = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) })?.visibleFrame else {
            return
        }
        let naturalSize = Self.measureContentSize(text: text)
        // Caps the height in plain Swift arithmetic, not through a
        // SwiftUI `.frame(maxHeight:)` node inside `ApprovalTooltipContent`
        // itself -- see that struct's own doc comment for the measured
        // defect that rules that out. The window this size becomes is
        // itself the hard clip boundary macOS enforces at the compositor
        // level, so a natural size taller than this cap simply cannot
        // draw past it.
        let maxHeight = screenVisibleFrame.height - 36
        let contentSize = NSSize(width: naturalSize.width, height: min(naturalSize.height, maxHeight))
        let frame = Self.frame(for: contentSize, pointer: pointer, visibleFrame: screenVisibleFrame)
        #if DEBUG
        if let hook = _setFrameHookForTesting {
            hook(frame)
            return
        }
        #endif
        let (theWindow, theHostingController) = ensureWindowAndHostingController()
        theHostingController.rootView = ApprovalTooltipContent(text: text)
        theWindow.setFrame(frame, display: true)
        theWindow.orderFrontRegardless()
    }

    /// Measures `ApprovalTooltipContent(text:)`'s own natural fitting
    /// size: builds a FRESH, throwaway `NSHostingController` (never the
    /// persisted one `show(text:at:)` installs into the window -- the
    /// persisted controller must not be measured right after its own
    /// `rootView` is reassigned, since its `sizeThatFits(in:)` can still
    /// answer for the PREVIOUS `rootView`'s layout at that point) and
    /// calls `sizeThatFits(in:)` on it with a proposal of
    /// `maxTextWidth + chromeWidth` wide (so `Text` itself still sees a
    /// 400pt-wide proposal to wrap its own text against, after this
    /// hosting view's own padding/background chrome is subtracted back
    /// out by SwiftUI's layout -- see `ApprovalTooltipContent.body`'s own
    /// doc comment for why no `.frame(maxWidth:)` is applied there
    /// instead) and unbounded height, so the returned size is always the
    /// content's own true natural size, uncapped -- `show(text:at:)`
    /// applies the `maxHeight` cap itself afterward. Rounded up to whole
    /// points -- the two 1pt border/inner-line rings are drawn at
    /// hairline width, and a fractional size (SwiftUI's own text
    /// measurement is not pixel-quantized) would blur them across two
    /// pixels at 1x instead of landing crisply on one.
    private static func measureContentSize(text: String) -> NSSize {
        let hostingController = NSHostingController(rootView: ApprovalTooltipContent(text: text))
        hostingController.safeAreaRegions = []
        let measured = hostingController.sizeThatFits(
            in: CGSize(
                width: ApprovalTooltipContent.maxTextWidth + ApprovalTooltipContent.chromeWidth,
                height: .greatestFiniteMagnitude
            )
        )
        return NSSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    /// Cancels any pending `scheduleShow(text:)` AND orders an
    /// already-shown window out -- the one call every caller (
    /// `ExpandableBodyText` on hover end/tap, `ApprovalPanelController`
    /// on order-out/request change/`tearDown()`) needs, regardless of
    /// which of those two states the tooltip is actually in right now.
    func hide() {
        cancelPending()
        window?.orderOut(nil)
    }

    /// Torn down alongside `ApprovalPanelController.tearDown()` -- the
    /// tooltip window survives its own `close()`
    /// (`isReleasedWhenClosed == false`), same shape as
    /// `ApprovalPanelWindow`'s own teardown.
    func tearDown() {
        cancelPending()
        window?.orderOut(nil)
        window?.contentViewController = nil
        window?.close()
        window = nil
        hostingController = nil
    }

    /// Pure placement: the box's top-left corner sits at `pointer +
    /// (0, -18)` in AppKit's own bottom-up screen coordinates (directly
    /// below the cursor, left-aligned with it -- `+18` in top-left
    /// terms becomes `-18` here since a LOWER on-screen position is a
    /// SMALLER y in AppKit's coordinate space), then clamped fully
    /// inside `visibleFrame`.
    static func frame(for contentSize: NSSize, pointer: NSPoint, visibleFrame: NSRect) -> NSRect {
        let unclampedOriginX = pointer.x
        let unclampedOriginY = pointer.y - 18 - contentSize.height
        let clampedX = min(max(unclampedOriginX, visibleFrame.minX), visibleFrame.maxX - contentSize.width)
        let clampedY = min(max(unclampedOriginY, visibleFrame.minY), visibleFrame.maxY - contentSize.height)
        return NSRect(origin: NSPoint(x: clampedX, y: clampedY), size: contentSize)
    }

    private func ensureWindowAndHostingController() -> (ApprovalTooltipWindow, NSHostingController<ApprovalTooltipContent>) {
        if let window, let hostingController {
            return (window, hostingController)
        }
        let theWindow = ApprovalTooltipWindow()
        let theHostingController = NSHostingController(rootView: ApprovalTooltipContent(text: ""))
        theHostingController.safeAreaRegions = []
        // Without this, `NSHostingController` re-asserts its own
        // idealized layout size onto the owning window after
        // `show(text:at:)`'s own explicit `setFrame(_:display:)` runs,
        // growing the window past the size `frame(for:pointer:visibleFrame:)`
        // computed.
        theHostingController.sizingOptions = []
        theWindow.contentViewController = theHostingController
        window = theWindow
        hostingController = theHostingController
        return (theWindow, theHostingController)
    }
}

/// SwiftUI environment access for `ExpandableBodyText` -- optional and
/// nil by default so a preview or a test host without a real
/// `ApprovalPanelController` does nothing on hover, rather than
/// crashing on a missing presenter.
private struct ApprovalTooltipPresenterKey: EnvironmentKey {
    static let defaultValue: ApprovalTooltipPresenter? = nil
}

extension EnvironmentValues {
    var approvalTooltipPresenter: ApprovalTooltipPresenter? {
        get { self[ApprovalTooltipPresenterKey.self] }
        set { self[ApprovalTooltipPresenterKey.self] = newValue }
    }
}
