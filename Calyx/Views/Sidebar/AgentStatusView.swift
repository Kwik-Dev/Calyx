// AgentStatusView.swift
// Calyx
//
// Sidebar view that displays AI agent panes and their lifecycle state,
// sourced live from `AgentRegistry.shared`.

import AppKit
import SwiftUI

struct AgentStatusView: View {
    /// The rows block's rendered height, published by the
    /// `.onGeometryChange` modifier on the rows block in `content`.
    /// Read by `content` to give `monitoringDisabledPlaceholder` the
    /// viewport space left over below the rows to center itself in.
    /// Measured from the rendered view rather than derived from
    /// `entries.count` and a row-height constant, which would silently
    /// drift the moment row height, spacing, or padding change.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        content
            // Tracks how many windows currently have this view mounted
            // (Agents sidebar mode + sidebar visible) via
            // `AgentRegistry.agentsSidebarVisibleCount`, so
            // `CalyxWindowController`'s screen-classification poll can
            // gate on "visible in any window" rather than each window's
            // own local sidebar state -- see that property's doc comment.
            // Also the herdr integration's third start() trigger
            // (alongside app launch / `applicationDidBecomeActive`) --
            // see `AppDelegate.startHerdrIntegrationIfNeeded()`'s own
            // doc comment.
            .onAppear {
                AgentRegistry.shared.incrementAgentsSidebarVisible()
                (NSApp.delegate as? AppDelegate)?.startHerdrIntegrationIfNeeded()
            }
            .onDisappear { AgentRegistry.shared.decrementAgentsSidebarVisible() }
    }

    private var content: some View {
        Group {
            // Observes AgentRegistry.isServerRunning rather than
            // CalyxMCPServer.isRunning: CalyxMCPServer is a plain
            // @MainActor class, not @Observable, so a view reading its
            // isRunning directly would never get a re-render signal when
            // the server starts/stops. Also reads hasExternalEntries
            // (registering the @Observable dependency on externalEntries
            // too) so a herdr row appearing/disappearing while the IPC
            // server is stopped re-renders this gate on its own -- see
            // AgentSidebarGate.decide's doc comment. Both are captured
            // once here and reused below for
            // AgentSidebarGate.showsMonitoringDisabledBanner, decide's
            // companion -- see that function's own doc comment.
            let isServerRunning = AgentRegistry.shared.isServerRunning
            let hasExternal = AgentRegistry.shared.hasExternalEntries
            if !AgentSidebarGate.decide(isServerRunning: isServerRunning, hasExternal: hasExternal) {
                disabledPlaceholder
            } else {
                let entries = AgentRegistry.shared.sortedEntries
                let hooksIssues = AgentRegistry.shared.hooksIssues
                VStack(spacing: 0) {
                    if !hooksIssues.isEmpty {
                        hooksIssuesBanner(hooksIssues)
                    }
                    if entries.isEmpty {
                        emptyPlaceholder
                    } else {
                        // TimelineView re-renders every second so each row's
                        // relative "time ago" label stays live; it also stops
                        // firing automatically while the sidebar isn't visible.
                        //
                        // Wrapped in a GeometryReader purely to measure the
                        // viewport height for monitoringDisabledPlaceholder's
                        // centering below -- layout-neutral for the rows
                        // themselves, since TimelineView/ScrollView both
                        // accept whatever size is proposed and fill it
                        // exactly as they filled their parent before this
                        // was added.
                        GeometryReader { viewport in
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                ScrollView {
                                    // A single VStack, not bare ScrollView
                                    // siblings, so the scroll content's total
                                    // height is exactly rowsHeight plus the
                                    // placeholder block's own height -- no
                                    // implicit, unmeasured inter-sibling
                                    // spacing to throw off the minHeight math
                                    // below.
                                    VStack(spacing: 0) {
                                        VStack(spacing: 4) {
                                            ForEach(entries) { entry in
                                                AgentRowView(entry: entry, now: context.date)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .onGeometryChange(for: CGFloat.self) { proxy in
                                            proxy.size.height
                                        } action: { height in
                                            rowsHeight = height
                                        }

                                        if AgentSidebarGate.showsMonitoringDisabledBanner(isServerRunning: isServerRunning, hasExternal: hasExternal) && rowsHeight > 0 {
                                            monitoringDisabledPlaceholder(
                                                minHeight: max(0, (viewport.size.height - rowsHeight).rounded(.down) - 1)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Hooks Issues Banner

    /// Persistent warning banner surfacing hook-install failures
    /// (`AgentRegistry.hooksIssues`, set by `CalyxWindowController.
    /// enableIPC`), so a symlink/permissions failure that used to degrade
    /// the sidebar silently (only a one-shot alert at enable time) is
    /// visible for as long as it remains unresolved. Rendered as plain,
    /// quiet text -- no icon, no background -- matching
    /// `disabledPlaceholder` / `emptyPlaceholder` below rather than a
    /// designed warning box, so nothing opaque paints over
    /// `MainContentView`'s single root glass sheet showing through the
    /// sidebar.
    private func hooksIssuesBanner(_ issues: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Some agent hooks failed to install")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(issues, id: \.self) { issue in
                Text(issue)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityIdentifier(AccessibilityID.Sidebar.agentHooksIssuesBanner)
    }

    // MARK: - Placeholders

    private var disabledPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("AI Agent IPC is disabled")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Open Command Palette → Enable AI Agent IPC")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No agents connected yet.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    /// Same two lines, same typography, as `disabledPlaceholder` above
    /// (the fact is the same: AI Agent IPC is disabled) but shown below
    /// the rows rather than in place of them, for the case where herdr
    /// rows keep the sidebar showing rows even while Calyx's own IPC
    /// server is stopped. Gated by
    /// `AgentSidebarGate.showsMonitoringDisabledBanner`.
    ///
    /// `minHeight` is the viewport space left over below the rows
    /// (`content`'s `GeometryReader` minus the rows height measured by
    /// `.onGeometryChange`), so the block centers the way
    /// `emptyPlaceholder` centers in an empty list: few rows leave a lot
    /// of leftover space and the block sits in the middle of it; many
    /// rows leave none (`minHeight` clamped to 0) and the block just
    /// follows the rows with its own padding.
    ///
    /// The caller (`content`) rounds that leftover down and subtracts
    /// one more point, so the scroll content is always at least 1pt
    /// shorter than the viewport: fractional measurement can otherwise
    /// round `rowsHeight + minHeight` up past the viewport height by a
    /// hair, which is enough for `ScrollView` to draw a phantom
    /// scrollbar with nothing to actually scroll to. The caller also
    /// withholds this call entirely until `rowsHeight > 0` (the first
    /// real measurement has landed), since `rowsHeight`'s default `0`
    /// on the very first frame would otherwise read as "rows measure
    /// zero" and hand this a `minHeight` of the FULL viewport for one
    /// frame, forcing a scrollbar flash before the real measurement
    /// corrects it.
    private func monitoringDisabledPlaceholder(minHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            Text("AI Agent IPC is disabled")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Open Command Palette → Enable AI Agent IPC")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .frame(minHeight: minHeight, alignment: .center)
        .accessibilityIdentifier(AccessibilityID.Sidebar.agentMonitoringDisabledBanner)
    }
}

// MARK: - Sidebar Gate

/// Pure decision behind `AgentStatusView.content`'s placeholder branch,
/// extracted so it's directly testable without mounting the view --
/// mirrors `HerdrChildExitedPolicy`'s own extraction shape (herdr Stage
/// 1): the caller resolves its own inputs (`AgentRegistry.shared
/// .isServerRunning` / `.hasExternalEntries`) before calling in.
enum AgentSidebarGate {

    /// Whether the sidebar should render its entries list (`true`)
    /// rather than the "AI Agent IPC is disabled" placeholder
    /// (`false`). An external (herdr) row must keep the sidebar showing
    /// rows even while Calyx's own IPC server is stopped, since it
    /// doesn't depend on it -- so the placeholder is shown only when
    /// BOTH `isServerRunning` is `false` AND there are no external
    /// entries.
    static func decide(isServerRunning: Bool, hasExternal: Bool) -> Bool {
        isServerRunning || hasExternal
    }

    /// Companion to `decide(isServerRunning:hasExternal:)`: whether the
    /// rows branch should ALSO show `monitoringDisabledPlaceholder`, an
    /// explanatory notice that Calyx's own agent monitoring is disabled,
    /// rendered below the rows (not stacked at the top of the rows
    /// branch's `VStack` like `hooksIssuesBanner`) and centered in
    /// whatever viewport space is left over once the rows are measured
    /// -- see that view's own doc comment. Keeps the `...Banner` name
    /// here for API/test stability even though the gated view is named
    /// `monitoringDisabledPlaceholder` and matches `disabledPlaceholder`'s
    /// typography rather than `hooksIssuesBanner`'s.
    ///
    /// The old all-or-nothing gate was incoherent either way: hiding
    /// everything while herdr was connected threw away real, useful
    /// rows; showing rows with no indication was silently misleading,
    /// since a user's own locally-run agents (which DO depend on
    /// Calyx's own IPC server) would be missing from the list with no
    /// explanation. The coherent design shows the rows AND flags why
    /// Calyx's own agents might be absent -- so this is `true` only when
    /// Calyx's own server is off AND something else (herdr) is why rows
    /// are showing at all: `isServerRunning == true` never warns (Calyx's
    /// own monitoring IS running, herdr or not), and `hasExternal ==
    /// false` with the server off never reaches the rows branch to begin
    /// with (see `decide`).
    static func showsMonitoringDisabledBanner(isServerRunning: Bool, hasExternal: Bool) -> Bool {
        !isServerRunning && hasExternal
    }
}

// MARK: - Row Focus Target

/// Pure resolution of the surface a row's click should focus, extracted
/// from `AgentRowView.body` so it's directly testable without mounting
/// the view — mirrors `AgentSidebarGate` / `AgentRowDisplay`'s own
/// extraction shape. Not `@MainActor`: unlike `AgentRowDisplay` (which
/// calls into `AgentRegistry`, a `@MainActor` type), this touches only
/// plain `Sendable` values.
enum AgentRowFocusTarget {

    /// The surface to focus when a row is clicked, or `nil` when the row
    /// has no resolvable focus target at all — `AgentRowView` renders a
    /// `nil` result as a non-interactive row (no tap, no hover
    /// highlight) rather than posting `.calyxFocusSurface` for a surface
    /// nothing can resolve. Resolution order:
    ///   1. `focusSurfaceID`, when set, always wins — it is the explicit
    ///      "focus this Calyx surface instead" pointer `AgentEntry`
    ///      documents for an `.external` row whose own `surfaceID` isn't
    ///      a `SurfaceRegistry` id.
    ///   2. Otherwise, a `.hooks`/`.titleHeuristic` row's own `surfaceID`
    ///      IS a real `SurfaceRegistry` id (that's where those sources
    ///      get it from) and is always resolvable.
    ///   3. Otherwise -- an `.external` row with no `focusSurfaceID` (true
    ///     of every UNBRIDGED herdr row: `HerdrAgentMirror` only
    ///     resolves one for a pane the pane registry actually bridges --
    ///     see `HerdrAgentMirror.swift`'s header) -- there is nothing
    ///     valid to focus.
    static func resolve(source: AgentSource, surfaceID: UUID, focusSurfaceID: UUID?) -> UUID? {
        if let focusSurfaceID { return focusSurfaceID }
        return source == .external ? nil : surfaceID
    }
}

// MARK: - Agent Row View

private struct AgentRowView: View {
    let entry: AgentEntry
    /// The "current" instant used to render `lastEventAt`'s relative
    /// label, supplied by the enclosing `TimelineView` so it stays live
    /// without this row managing its own timer.
    let now: Date

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    private var dotColor: Color {
        switch entry.state {
        case .blocked: return .red
        case .working: return .yellow
        case .done:    return .blue
        case .idle:    return .green
        }
    }

    /// The row's primary label. Delegates to `AgentRowDisplay.primaryLabel`
    /// so the derivation exists in exactly one place, directly testable
    /// without mounting this view.
    private var displayName: String {
        AgentRowDisplay.primaryLabel(cwd: entry.cwd, kind: entry.kind)
    }

    /// The row's secondary label. Delegates to `AgentRowDisplay.subtitle`
    /// so the derivation exists in exactly one place, directly testable
    /// without mounting this view.
    private var subtitle: String {
        AgentRowDisplay.subtitle(kind: entry.kind, source: entry.source)
    }

    /// The surface this row's click should focus, per
    /// `AgentRowFocusTarget.resolve`'s doc comment -- `nil` for a row
    /// with no resolvable target (an unbridged herdr row).
    private var focusTarget: UUID? {
        AgentRowFocusTarget.resolve(source: entry.source, surfaceID: entry.surfaceID, focusSurfaceID: entry.focusSurfaceID)
    }

    var body: some View {
        // Presentation choice for a row with no resolvable focus
        // target (`focusTarget == nil`) -- rather than keeping the tap
        // gesture wired to `entry.surfaceID` (for an UNBRIDGED herdr
        // row, a synthetic id no `SurfaceRegistry` knows, so the click
        // would be a silent no-op), the row is rendered as plain,
        // non-interactive content: no `.onTapGesture` and no hover
        // highlight. This branch has no hover writer of its own --
        // `isHovering` is only ever flipped by the `.onAssumeInsideHover`
        // attached in the interactive branch below -- so the
        // `.onChange` below clears it back to `false` on the transition
        // into this branch, keeping the background fill in `rowContent`
        // from ever appearing here even for a row that WAS hovered right
        // up to the moment it lost its focus target (e.g. its bridging
        // Calyx pane closed while the pointer was still over the row).
        // This was chosen as the least surprising option over, say, a
        // visibly "disabled" treatment (dimmed/greyed row) -- the row
        // still needs to convey real, current agent state at a glance;
        // only the click AFFORDANCE (hover feedback inviting a tap) is
        // removed, matching how every other purely-informational element
        // in this sidebar (e.g. `hooksIssuesBanner`) already has no
        // hover/tap treatment at all.
        Group {
            if let focusTarget {
                rowContent
                    .onAssumeInsideHover($isHovering)
                    .onTapGesture {
                        NotificationCenter.default.post(
                            name: .calyxFocusSurface,
                            object: nil,
                            userInfo: ["surfaceID": focusTarget]
                        )
                    }
            } else {
                rowContent
            }
        }
        // `focusTarget` can flip non-nil -> nil at runtime (its bridging
        // Calyx pane closing prunes `focusSurfaceID`), which tears down
        // `.onAssumeInsideHover` above along with it -- AppKit sends no
        // `mouseExited` to a tracking view already removed from the
        // hierarchy, so nothing else would ever clear a hover left
        // `true` at that instant. Mirrors `CloseButtonHoverHighlight`'s
        // own `.onChange(of: isVisible)` guard for the identical
        // tracking-view-removal case.
        .onChange(of: focusTarget) { _, newValue in
            if newValue == nil { isHovering = false }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            // State dot
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            // Name + agent kind
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if entry.unreadCount > 0 {
                UnreadCountBadge(count: entry.unreadCount)
            }

            Text(Self.relativeDateFormatter.localizedString(for: entry.lastEventAt, relativeTo: now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(reduceTransparency ? 0.08 : 0.05))
            }
        }
        .opacity(controlActiveState == .key ? 1.0 : 0.5)
        .accessibilityIdentifier(AccessibilityID.Sidebar.agentRow(id: entry.id))
    }
}

// MARK: - Row Display

/// Pure label derivation extracted from `AgentRowView.displayName` so
/// it's directly testable without mounting the view.
@MainActor
enum AgentRowDisplay {

    /// The Agents sidebar row's primary label: the pane's working
    /// directory basename, or `AgentEntry.displayName(forKind:)` when
    /// no `cwd` has been reported yet. Reuses `AgentRegistry.basename`
    /// rather than re-deriving it, so the basename logic exists in
    /// exactly one place (same reasoning as `AgentRowView.displayName`
    /// itself already documented).
    static func primaryLabel(cwd: String?, kind: String) -> String {
        let basename = AgentRegistry.basename(cwd)
        return basename.isEmpty ? AgentEntry.displayName(forKind: kind) : basename
    }

    /// The Agents sidebar row's secondary label: `AgentEntry
    /// .displayName(forKind:)`, with a plain `" via herdr"` suffix for
    /// `.external` rows so a row sourced from herdr rather than Calyx's
    /// own hooks/title-heuristic pipeline is distinguishable at a
    /// glance ("Claude Code via herdr"). Kept in natural reading order
    /// (kind first): `AgentRowView` pairs this with
    /// `.truncationMode(.middle)` on the rendered `Text`, so
    /// `.lineLimit(1)` truncating in the narrow (~60pt) subtitle column
    /// elides the MIDDLE of the string ("Clau...herdr") rather than the
    /// tail, keeping the marker visible without reordering the text.
    /// Native (`.hooks`/`.titleHeuristic`) rows are unchanged.
    static func subtitle(kind: String, source: AgentSource) -> String {
        let kindLabel = AgentEntry.displayName(forKind: kind)
        guard source == .external else { return kindLabel }
        return "\(kindLabel) via herdr"
    }
}
