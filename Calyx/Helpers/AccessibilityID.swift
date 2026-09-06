// AccessibilityID.swift
// Calyx
//
// Stable accessibility identifiers for XCUITest element lookup.

import Foundation

enum AccessibilityID {
    enum Sidebar {
        static let container = "calyx.sidebar"
        static let newGroupButton = "calyx.sidebar.newGroupButton"
        static let agentModeButton = "calyx.sidebar.agentModeButton"
        static func group(_ id: UUID) -> String { "calyx.sidebar.group.\(id.uuidString)" }
        static func tab(_ id: UUID) -> String { "calyx.sidebar.tab.\(id.uuidString)" }
        static func groupNameTextField(_ id: UUID) -> String { "calyx.sidebar.groupNameTextField.\(id.uuidString)" }
        static func groupCollapseButton(_ id: UUID) -> String { "calyx.sidebar.groupCollapseButton.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calyx.sidebar.tab.\(id.uuidString).closeButton" }
        static func groupCloseAllButton(_ id: UUID) -> String { "calyx.sidebar.group.\(id.uuidString).closeAllButton" }
        static func tabNameTextField(_ id: UUID) -> String { "calyx.sidebar.tabNameTextField.\(id.uuidString)" }
        static func tabAtIndex(_ groupID: UUID, _ index: Int) -> String {
            "calyx.sidebar.group.\(groupID.uuidString).tab.index.\(index)"
        }
        static func agentRow(id: UUID) -> String { "calyx.sidebar.agentRow.\(id.uuidString)" }
        static func agentRowDisclosure(id: UUID) -> String { "calyx.sidebar.agentRowDisclosure.\(id.uuidString)" }
        static func agentSubRow(id: String) -> String { "calyx.sidebar.agentSubRow.\(id)" }
        static let agentHooksIssuesBanner = "calyx.sidebar.agentHooksIssuesBanner"
        static let agentMonitoringDisabledBanner = "calyx.sidebar.agentMonitoringDisabledBanner"
    }
    enum GroupContextMenu {
        static let close = "calyx.groupMenu.close"
        static let closeOthers = "calyx.groupMenu.closeOthers"
        static let closeBelow = "calyx.groupMenu.closeBelow"
        static let rename = "calyx.groupMenu.rename"
        static let color = "calyx.groupMenu.color"
        static func color(_ color: TabGroupColor) -> String { "calyx.groupMenu.color.\(color.rawValue)" }
    }
    enum TabBar {
        static let container = "calyx.tabBar"
        static let newTabButton = "calyx.tabBar.newTabButton"
        static func tab(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString).closeButton" }
        static func tabNameTextField(_ id: UUID) -> String { "calyx.tabBar.tabNameTextField.\(id.uuidString)" }
        static func tabAtIndex(_ index: Int) -> String { "calyx.tabBar.tab.index.\(index)" }
    }
    enum CommandPalette {
        static let container = "calyx.commandPalette"
        static let searchField = "calyx.commandPalette.searchField"
        static let resultsTable = "calyx.commandPalette.resultsTable"
    }
    enum Compose {
        static let container = "calyx.compose"
        static let textView = "calyx.compose.textView"
        static let placeholder = "calyx.compose.placeholder"
    }
    enum Search {
        static let container = "calyx.search"
        static let searchField = "calyx.search.searchField"
        static let matchCount = "calyx.search.matchCount"
        static let previousButton = "calyx.search.previousButton"
        static let nextButton = "calyx.search.nextButton"
        static let closeButton = "calyx.search.closeButton"
    }
    enum Browser {
        static let toolbar = "calyx.browser.toolbar"
        static let backButton = "calyx.browser.backButton"
        static let forwardButton = "calyx.browser.forwardButton"
        static let reloadButton = "calyx.browser.reloadButton"
        static let urlDisplay = "calyx.browser.urlDisplay"
        static let errorBanner = "calyx.browser.errorBanner"
    }
    enum Git {
        static let changesContainer = "calyx.git.changes"
        static let refreshButton = "calyx.git.refreshButton"
        static let modeToggle = "calyx.git.modeToggle"
        static let stagedSection = "calyx.git.staged"
        static let unstagedSection = "calyx.git.unstaged"
        static let untrackedSection = "calyx.git.untracked"
        static let commitsSection = "calyx.git.commits"
        static func fileEntry(_ path: String) -> String { "calyx.git.file.\(path)" }
        static func commitRow(_ hash: String) -> String { "calyx.git.commit.\(hash)" }
        /// `id` is the repository's work-tree root path.
        static func repoSection(_ id: String) -> String { "calyx.git.repoSection.\(id)" }
        /// `id` is the repository's work-tree root path.
        static func refPicker(_ id: String) -> String { "calyx.git.refPicker.\(id)" }
    }
    /// Sessions pane of the Settings window
    /// (Calyx/Features/Settings/SettingsWindowController.swift). Applied
    /// to the four toggle NSSwitch controls so an XCUITest suite can
    /// locate a specific switch by a stable identifier instead of an
    /// ordinal position (`app.switches.firstMatch`), which silently
    /// breaks the moment a row is reordered or another switch is added
    /// above it.
    enum Settings {
        static let persistentSessionsSwitch = "calyx.settings.sessions.persistentSessionsSwitch"
        static let historyPersistenceSwitch = "calyx.settings.sessions.historyPersistenceSwitch"
        static let agentResumeSwitch = "calyx.settings.sessions.agentResumeSwitch"
        static let agentResumeAutoExecuteSwitch = "calyx.settings.sessions.agentResumeAutoExecuteSwitch"
        static let commandTrackingSwitch = "calyx.settings.sessions.commandTrackingSwitch"
        static let smoothScrollingSwitch = "calyx.settings.appearance.smoothScrollingSwitch"
        static let glassOpacityCellsSwitch = "calyx.settings.appearance.glassOpacityCellsSwitch"
        static let lspAutoInstallSwitch = "calyx.settings.lsp.lspAutoInstallSwitch"
        static let lspRequireConfirmationSwitch = "calyx.settings.lsp.lspRequireConfirmationSwitch"
        static let cockpitAutoApproveSwitch = "calyx.settings.sessions.cockpitAutoApproveSwitch"
        static let agentHookApprovalSwitch = "calyx.settings.sessions.agentHookApprovalSwitch"
    }
    enum SessionBrowser {
        static func row(_ id: String) -> String { "calyx.sessionBrowser.row.\(id)" }
        static func attachButton(_ id: String) -> String { "calyx.sessionBrowser.row.\(id).attachButton" }
        static func killButton(_ id: String) -> String { "calyx.sessionBrowser.row.\(id).killButton" }
        static func remoteHostRow(_ host: String) -> String { "calyx.sessionBrowser.remoteHost.\(host)" }
        static func remoteHostAttachButton(_ host: String) -> String { "calyx.sessionBrowser.remoteHost.\(host).attachButton" }
        static func remoteHostInstallButton(_ host: String) -> String { "calyx.sessionBrowser.remoteHost.\(host).installButton" }
        static func herdrRow(_ id: String) -> String { "calyx.sessionBrowser.herdr.\(id)" }
        static func herdrCreateButton(_ id: String) -> String { "calyx.sessionBrowser.herdr.\(id).createButton" }
        static func herdrWorkspaceRow(_ id: String) -> String { "calyx.sessionBrowser.herdrWorkspace.\(id)" }
        static func herdrWorkspaceAttachButton(_ id: String) -> String { "calyx.sessionBrowser.herdrWorkspace.\(id).attachButton" }
        static func herdrWorkspaceKillButton(_ id: String) -> String { "calyx.sessionBrowser.herdrWorkspace.\(id).killButton" }
    }
    /// Chrome-style in-app "your previous session was preserved" bar,
    /// shown at the top of a window when AppDelegate
    /// .hasPreservedSessionSnapshot is true (see RecoveryBarModel,
    /// Calyx/Features/Persistence/). Deliberately `calyx.recoveryBar.*`
    /// (a container + two per-window action buttons), not the bare
    /// `calyx.recoveryBar` some other single-container enums here use
    /// (e.g. Sidebar.container == "calyx.sidebar"), since this bar's own
    /// two buttons need distinguishable identifiers alongside it.
    enum RecoveryBar {
        static let container = "calyx.recoveryBar.container"
        static let restoreButton = "calyx.recoveryBar.restoreButton"
        static let dismissButton = "calyx.recoveryBar.dismissButton"
    }
    /// Cockpit approval banner, shown in a floating panel
    /// (ApprovalPanelWindow) at the screen's top-right corner when
    /// ApprovalBannerModel.current is non-nil (see ApprovalBannerModel,
    /// Calyx/Features/ApprovalInbox/). Same `calyx.approvalBanner.*`
    /// shape as RecoveryBar (a container + its action buttons), plus a
    /// `payload` identifier so an XCUITest suite can assert the rendered
    /// (control-character-escaped) command text. Queue navigation adds
    /// `previousButton`/`nextButton`/`positionLabel`, shown only while
    /// more than one request is queued for this window (see
    /// ApprovalBannerModel.positionInfo). The queue preview menu wraps
    /// that same position label in a `Menu` (`queueMenu`) listing every
    /// request in ApprovalBannerModel.queueEntries, so a click can jump
    /// straight to any queued request via ApprovalBannerModel.select(id:).
    /// macOS collapses that `Menu` into one accessibility element, which
    /// leaves `positionLabel` unreachable from the accessibility tree:
    /// the "N / M" text is exposed as `queueMenu`'s own accessibility
    /// label instead (see ApprovalBannerView.queueNavigator(positionInfo:)).
    /// An `.agentQuestion`-sourced request renders choice rows instead of
    /// the Deny/Always Allow/Allow row -- `questionText`/`optionButton(_:)`/
    /// `otherButton`/`otherTextField`/`answerButton`/`chatButton`/
    /// `backButton`/`notesButton`/`notesTextField`/`questionPosition`
    /// cover that alternate layout (`AgentQuestionBannerView`).
    /// `previewText` is the side-by-side markdown preview box shown only
    /// when an option carries a `preview`. An `.agentHook`-sourced
    /// request renders its own choice rows through `AgentToolApprovalView`
    /// -- `choiceRow(_:)` covers that layout, alongside the ones this enum
    /// already shares with `.agentQuestion` (`allowButton`/`denyButton`/
    /// `alwaysAllowButton`, reused for its own "Yes"/"No"/"Always allow
    /// ... in this pane" rows). Every choice row in an `.agentHook`
    /// banner is the sole clickable content of that banner mode.
    enum ApprovalBanner {
        static let container = "calyx.approvalBanner.container"
        static let allowButton = "calyx.approvalBanner.allowButton"
        static let denyButton = "calyx.approvalBanner.denyButton"
        static let alwaysAllowButton = "calyx.approvalBanner.alwaysAllowButton"
        static let payload = "calyx.approvalBanner.payload"
        static let previousButton = "calyx.approvalBanner.previousButton"
        static let nextButton = "calyx.approvalBanner.nextButton"
        static let positionLabel = "calyx.approvalBanner.positionLabel"
        static let queueMenu = "calyx.approvalBanner.queueMenu"
        static let questionText = "calyx.approvalBanner.questionText"
        static func optionButton(_ index: Int) -> String { "calyx.approvalBanner.optionButton.\(index)" }
        static let otherButton = "calyx.approvalBanner.otherButton"
        static let otherTextField = "calyx.approvalBanner.otherTextField"
        static let answerButton = "calyx.approvalBanner.answerButton"
        static let questionPosition = "calyx.approvalBanner.questionPosition"
        static let previewText = "calyx.approvalBanner.previewText"
        /// One `AgentToolApprovalView` row per `AgentHookOffers.
        /// permissionUpdates` element, indexed the same way `optionButton
        /// (_:)` indexes a question's options.
        static func choiceRow(_ index: Int) -> String { "calyx.approvalBanner.choiceRow.\(index)" }
        static let chatButton = "calyx.approvalBanner.chatButton"
        static let backButton = "calyx.approvalBanner.backButton"
        static let notesButton = "calyx.approvalBanner.notesButton"
        static let notesTextField = "calyx.approvalBanner.notesTextField"
    }
    enum Diff {
        static let container = "calyx.diff"
        static let toolbar = "calyx.diff.toolbar"
        static let content = "calyx.diff.content"
        static let lineNumberGutter = "calyx.diff.lineNumbers"
    }
    enum DiffReview {
        static let submitButton = "calyx.diff.review.submitButton"
        static let discardButton = "calyx.diff.review.discardButton"
        static let commentBadge = "calyx.diff.review.commentBadge"
        static let commentPopover = "calyx.diff.review.commentPopover"
        static let submitAllButton = "calyx.diff.review.submitAllButton"
        static let discardAllButton = "calyx.diff.review.discardAllButton"
    }
}
