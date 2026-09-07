// CurrentWindowTracker.swift
// Calyx
//
// This type supplies the LAST of the three tiers `AppDelegate.
// currentWindowController` resolves through -- its own
// `lastKeyWindowController` -- while `CurrentWindowResolver.resolve(
// key:frontMostVisible:lastKey:ordered:)` below implements the full
// three-tier rule as a pure function: the key `CalyxWindowController`
// first, then the front-most member of `NSApp.orderedWindows` that is both
// visible and on the active Space (never-shown, minimized, and off-Space
// windows are all skipped -- a window on another Space cannot take key
// without a Space switch), and only once BOTH of those find nothing (every
// Calyx window is minimized, off-Space, or not yet shown) does tier 3 --
// `lastKey` while still a member of `ordered`, else `ordered.first` --
// decide. `AppDelegate.currentWindowController` calls this resolver
// directly, passing its own already-resolved key/front-most-visible
// candidates and `currentWindowTracker.lastKeyWindowController`; see that
// property's own doc comment for the full three-tier contract as consumed
// in production.
//
// See CalyxTests/App/CurrentWindowTrackerTests.swift for the specced
// contract.

import Foundation

/// Pure resolution rule, identity (`===`) based -- never structural
/// equality, so two distinct instances occupying the same "logical"
/// slot are never conflated.
nonisolated enum CurrentWindowResolver {
    /// The full three-tier rule `AppDelegate.currentWindowController`
    /// implements, as a pure function: `key` wins if non-nil, else
    /// `frontMostVisible` if non-nil, else tier 3 (`lastKey` while still a
    /// member of `ordered`, else `ordered.first`). Callers supply each
    /// tier's already-resolved candidate (or nil) rather than raw window
    /// state, so this stays testable with plain stand-in hosts.
    static func resolve<Host: AnyObject>(
        key: Host?,
        frontMostVisible: Host?,
        lastKey: Host?,
        ordered: [Host]
    ) -> Host? {
        if let key { return key }
        if let frontMostVisible { return frontMostVisible }
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
    /// `CurrentWindowResolver.resolve` falls back to its `ordered`
    /// argument's first element.
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
}
