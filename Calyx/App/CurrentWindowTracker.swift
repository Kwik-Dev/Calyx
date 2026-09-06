// CurrentWindowTracker.swift
// Calyx
//
// The window the user is working in: the key `CalyxWindowController`,
// else the last one that was key, else the first open window. Every
// consumer that needs a "which window" answer with no more specific
// signal -- the app-wide floating approval panel, a target-pane-less
// MCP tool call, a new-tab/attach flow with no explicit source window
// -- resolves through this instead of its own local `isKeyWindow`
// lookup. `AppDelegate.currentWindowController` exposes this app-wide.
//
// See CalyxTests/App/CurrentWindowTrackerTests.swift for the specced
// contract.

import Foundation

/// Pure resolution rule, identity (`===`) based -- never structural
/// equality, so two distinct instances occupying the same "logical"
/// slot are never conflated.
nonisolated enum CurrentWindowResolver {
    static func resolve<Host: AnyObject>(lastKey: Host?, ordered: [Host]) -> Host? {
        if let lastKey, ordered.contains(where: { $0 === lastKey }) {
            return lastKey
        }
        return ordered.first
    }
}

/// Tracks which `CalyxWindowController` most recently became key, so
/// the window the user is working in stays resolvable even while some
/// OTHER kind of window (Settings, Session Browser, the floating
/// approval panel itself) currently holds key status. Updated only on
/// become-key, never cleared on resign: AppKit delivers resign before
/// the next become-key, and clearing here would create a moment with no
/// designated current window at all.
@MainActor
final class CurrentWindowTracker {
    /// `weak`: once every strong reference to the designated controller
    /// is released, this reads nil rather than a dangling reference, and
    /// `resolve(in:)` falls back to the given list's first element.
    private(set) weak var lastKeyWindowController: CalyxWindowController?

    /// Designates `controller` as the most-recently-key window. Returns
    /// true only when the designated window actually changes (first
    /// designation, or a switch to a different controller) -- false on
    /// every repeat call with the same controller already designated.
    func didBecomeKey(_ controller: CalyxWindowController) -> Bool {
        guard lastKeyWindowController !== controller else { return false }
        lastKeyWindowController = controller
        return true
    }

    /// The current window among `ordered`: `lastKeyWindowController`
    /// while it's still a member, else `ordered.first`, nil when
    /// `ordered` is empty.
    func resolve(in ordered: [CalyxWindowController]) -> CalyxWindowController? {
        CurrentWindowResolver.resolve(lastKey: lastKeyWindowController, ordered: ordered)
    }
}
