// Tab.swift
// Calyx
//
// Represents a single terminal tab with its split layout.

import Foundation

enum TabContent: Sendable {
    case terminal
    case browser(url: URL)
    case diff(source: DiffSource)
}

/// Which of the two independent inline-rename UIs — `TabBarContentView`'s
/// `TabItemButton` (its own `@State isEditing`) or `SidebarContentView`'s
/// `TabRowItemView` (its own, separate `@State isEditing`) — should open
/// for a `GHOSTTY_ACTION_PROMPT_TITLE` request. Both can independently
/// render the SAME `Tab` at once (`MainContentView`: the tab bar always
/// shows `windowSession.activeGroup`'s tabs; the sidebar shows EVERY
/// group's tabs whenever `showSidebar` is true and that group isn't
/// collapsed), so `CalyxWindowController.renameHost(for:in:)` must pick
/// exactly one — otherwise `InlineTextField`'s local `NSEvent` monitor +
/// `onCommit` opens twice for one keybind and the loser silently
/// clobbers the winner's typed title.
enum TabRenameHost: String, Sendable {
    case tabBar
    case sidebar
}

/// A one-shot request to open `host`'s inline rename editor for a `Tab`,
/// set on `Tab.renameRequest` by `CalyxWindowController.processPromptTitle
/// (surfaceView:scope:)`. `id` is a fresh token on every request — even a
/// same-host repeat — purely so a SwiftUI `.onChange(of: tab.renameRequest)`
/// observer re-fires on a second keybind press while the editor from the
/// first request is still open; comparing by `host` alone would look
/// unchanged to SwiftUI and never re-trigger.
struct TabRenameRequest: Equatable, Sendable {
    let id: UUID
    let host: TabRenameHost
}

@MainActor @Observable
class Tab: Identifiable {
    let id: UUID
    var title: String
    var titleOverride: String?
    var pwd: String?
    var splitTree: SplitTree
    var content: TabContent
    var unreadNotifications: Int = 0
    var lastNotificationTime: Date?
    let registry: SurfaceRegistry
    /// calyx-session references for this tab's persistent-session
    /// leaves, keyed by leaf (surface) UUID. Empty for a tab with no
    /// persistent sessions. Mirrored to `TabSnapshot.sessionRefs` by
    /// `Tab.snapshot()` (as `nil` when empty) and restored back by
    /// `Tab.init(snapshot:)`.
    var sessionRefs: [UUID: SessionRef]
    /// Set by `CalyxWindowController.processPromptTitle(surfaceView:scope:)`
    /// (`GHOSTTY_ACTION_PROMPT_TITLE`) to request that `host`'s inline
    /// rename editor open for this tab. Purely transient UI-routing state:
    /// deliberately absent from both `init` below and `TabSnapshot`/
    /// `Tab.snapshot()` (Persistence §6 invariant — `SessionSnapshot`
    /// fields are enumerated explicitly, so simply never listing this one
    /// there is enough; no schema version bump needed) and never restored
    /// from a snapshot, so a pending request never survives a relaunch or
    /// an unrelated save/restore round-trip. Optional stored properties
    /// default to `nil` without needing an `init` parameter.
    var renameRequest: TabRenameRequest?

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        titleOverride: String? = nil,
        pwd: String? = nil,
        splitTree: SplitTree = SplitTree(),
        content: TabContent = .terminal,
        registry: SurfaceRegistry = SurfaceRegistry(),
        sessionRefs: [UUID: SessionRef] = [:]
    ) {
        self.id = id
        self.title = title
        self.titleOverride = titleOverride
        self.pwd = pwd
        self.splitTree = splitTree
        self.content = content
        self.registry = registry
        self.sessionRefs = sessionRefs
    }

    func clearUnreadNotifications() {
        unreadNotifications = 0
        lastNotificationTime = nil
    }
}

extension Tab {
    /// Drops any `sessionRefs` entries whose key is not a leaf
    /// currently present in `splitTree` — call after a restore that
    /// couldn't bring back every leaf (either a partial
    /// `AppDelegate.restoreTabSurfaces` failure, or
    /// `fallbackCreateSurface`'s single fresh leaf replacing the whole
    /// tree), so a `SessionRef` pointing at a leaf that no longer
    /// exists doesn't linger in the tab — and doesn't get written back
    /// out, orphaned, by the next snapshot.
    ///
    func pruneSessionRefs() {
        let liveLeafIDs = Set(splitTree.allLeafIDs())
        sessionRefs = sessionRefs.filter { liveLeafIDs.contains($0.key) }
    }
}
