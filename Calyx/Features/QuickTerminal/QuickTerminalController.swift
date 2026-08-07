import AppKit
import SwiftUI
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "QuickTerminalController"
)

@MainActor
class QuickTerminalController: NSObject, NSWindowDelegate {
    private(set) var visible: Bool = false
    private var previousApp: NSRunningApplication?
    private var quickWindow: QuickTerminalWindow?
    private var tab: Tab?
    private var splitContainerView: SplitContainerView?

    private var position: QuickTerminalPosition = .top
    private var animationDuration: Double = 0.2
    private var autoHide: Bool = true
    private var spaceBehavior: QuickTerminalSpaceBehavior = .move
    private var terminalSize: QuickTerminalSize = QuickTerminalSize()
    private var quickTerminalScreen: QuickTerminalScreen = .main
    nonisolated(unsafe) private var hiddenDock: HiddenDock?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigChange(_:)),
            name: .ghosttyConfigChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hiddenDock = nil
    }

    // MARK: - Public API

    func toggle() {
        if visible {
            animateOut()
        } else {
            animateIn()
        }
    }

    #if DEBUG
    /// Test seam: overrides `visible` directly, mirroring
    /// `CalyxWindowController._setHasAppliedInitialSizeForTesting`'s
    /// override-seam shape — lets a test represent "the quick terminal
    /// is currently shown" without driving the real `animateIn()` (a
    /// real window/screen/animation, unsafe in this test host; see
    /// `ensureWindow()`/`animateIn()`'s own bodies). DO NOT use from
    /// production code.
    func _setVisibleForTesting(_ value: Bool) {
        visible = value
    }

    /// Test seam: mirrors `CalyxWindowController
    /// ._processCloseWindowHookForTesting`'s exact "hook right before
    /// the actually-unsafe-to-drive-in-tests real work" shape, for
    /// `requestHide()`'s eventual `animateOut()` call (real window
    /// animation, unsafe here — see `animateOut()`'s own body). `nil`
    /// (the default) leaves production behavior unchanged. DO NOT use
    /// from production code.
    var _requestHideHookForTesting: (() -> Void)?
    #endif

    /// GitHub issue #45 follow-on: `QuickTerminalWindow.calyxPerformClose(_:)`'s
    /// intended receiver — Cmd+W on the quick terminal must HIDE it
    /// (mirroring `autoHide`'s existing `animateOut()` on key resign),
    /// never destroy/close the window for real: `handleSurfaceClosed()`
    /// is the only path that tears down `tab`/`splitContainerView`, and
    /// this window's persistent-session surface (if any) must survive a
    /// Cmd+W exactly like it survives an autoHide.
    func requestHide() {
        guard visible else { return }
        #if DEBUG
        if let hook = _requestHideHookForTesting {
            hook()
            return
        }
        #endif
        animateOut()
    }

    // MARK: - Window Setup

    private func ensureWindow() -> QuickTerminalWindow {
        if let existing = quickWindow { return existing }

        let window = QuickTerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.collectionBehavior = spaceBehavior.collectionBehavior
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        quickWindow = window
        return window
    }

    private func ensureSurface() {
        guard tab == nil else { return }
        guard let app = GhosttyAppController.shared.app else {
            logger.error("Cannot create quick terminal surface: no ghostty app")
            return
        }

        let newTab = Tab()
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(quickWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        guard let surfaceID = newTab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create quick terminal surface")
            return
        }
        newTab.splitTree = SplitTree(leafID: surfaceID)
        self.tab = newTab

        let containerView = SplitContainerView(registry: newTab.registry)
        containerView.updateLayout(tree: newTab.splitTree)
        self.splitContainerView = containerView

        let hostView = QuickTerminalContentView(splitContainerView: containerView)
        let hostingView = NSHostingView(rootView: hostView)
        quickWindow?.contentView = hostingView
    }

    // MARK: - Animation

    private func animateIn() {
        let window = ensureWindow()

        guard !visible else { return }
        visible = true

        if !NSApp.isActive {
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previousApp = frontApp
            }
        }

        ensureSurface()

        guard let screen = quickTerminalScreen.screen else {
            logger.warning("No screen available for quick terminal")
            visible = false
            return
        }

        position.setInitial(in: window, on: screen, terminalSize: terminalSize)

        window.level = .popUpMenu
        window.makeKeyAndOrderFront(nil)

        if position.conflictsWithDock(on: screen) {
            if hiddenDock == nil { hiddenDock = HiddenDock() }
            hiddenDock?.hide()
        } else {
            hiddenDock = nil
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setFinal(in: window.animator(), on: screen, terminalSize: terminalSize)
        }, completionHandler: {
            guard self.visible else {
                self.hiddenDock = nil
                return
            }
            window.level = .floating

            if let tab = self.tab,
               let surfaceID = tab.registry.allIDs.first,
               let surfaceView = tab.registry.view(for: surfaceID) {
                window.makeFirstResponder(surfaceView)
            }

            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        })
    }

    private func animateOut() {
        guard let window = quickWindow else { return }
        guard visible else { return }
        visible = false

        hiddenDock = nil

        guard let screen = window.screen ?? NSScreen.main else {
            window.orderOut(self)
            return
        }

        if let previousApp = self.previousApp {
            self.previousApp = nil
            if !previousApp.isTerminated {
                _ = previousApp.activate(options: [])
            }
        }

        window.level = .popUpMenu

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = .init(name: .easeIn)
            position.setInitial(in: window.animator(), on: screen, terminalSize: terminalSize)
        }, completionHandler: {
            window.orderOut(self)
        })
    }

    // MARK: - Config

    @objc private func handleConfigChange(_ notification: Notification) {
        quickWindow?.collectionBehavior = spaceBehavior.collectionBehavior
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard visible else { return }
            guard quickWindow?.attachedSheet == nil else { return }
            if NSApp.isActive {
                self.previousApp = nil
            }
            hiddenDock?.restore()
            if autoHide {
                animateOut()
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if visible {
                animateOut()
            }
        }
    }

    // MARK: - Surface Lifecycle

    func handleSurfaceClosed() {
        if visible {
            animateOut()
        }
        tab = nil
        splitContainerView = nil
        quickWindow?.contentView = nil
    }

    // MARK: - Hidden Dock Helper

    private class HiddenDock {
        let previousAutoHide: Bool
        private var hidden: Bool = false

        init() {
            previousAutoHide = Dock.autoHideEnabled
        }

        deinit {
            restore()
        }

        func hide() {
            guard !hidden else { return }
            Dock.autoHideEnabled = true
            hidden = true
        }

        func restore() {
            guard hidden else { return }
            Dock.autoHideEnabled = previousAutoHide
            hidden = false
        }
    }
}
