// HerdrNativeTabAttacherLive.swift
// Calyx
//
// Production HerdrNativeTabAttacher conformer: the type
// HerdrTabCoordinator actually drives outside tests.
// Every side-effectful dependency (tabsProvider, attachHook, focusHook,
// ratioMutationHook, closeLeafHook, sessionKillHook) is an injected
// closure, mirroring AppDelegateOpenHerdrAttachTabTests' established
// hook-seam pattern -- this type itself never touches a real window, a
// real ghostty surface, or windowControllers; AppDelegate's own closures
// (constructed alongside this type) do that work.
//
// attachTab builds the "shell" Tab from `plan` alone -- sessionRefs
// always stays empty (Tab.init's own default) and SessionSurfaceMap is
// never touched: herdr session identity must never enter either, the
// same permanent invariant openHerdrAttachTab pins (see
// HerdrHostedSurfaces.swift's header). herdrPaneRefs is set to EXACTLY
// plan.paneRefs. attachHook receives this Tab and is free to replace it
// with a corrected one before actually presenting it (AppDelegate's own
// attachHook does exactly that, to give the presented Tab the same
// SurfaceRegistry its leaves were actually created in -- see
// AppDelegate.swift's own herdr wiring comments); this type has no
// opinion on that, it only forwards attachHook's own return value
// verbatim.
//
// closeLeaf calls ONLY closeLeafHook. sessionKillHook is intentionally
// NEVER called from this type: a herdr pane carries no calyx-session
// identity (attachTab's Tab.sessionRefs always stays empty, see above),
// so there is never a session to kill. sessionKillHook exists purely so
// that never-kill invariant is provable from the outside (mirrors
// architecture.md's own "SessionCloseKillPolicy must never see herdr
// identity" invariant) -- AppDelegate still wires it to a real
// implementation, for honesty, even though this type never invokes it.

import Foundation

@MainActor
final class HerdrNativeTabAttacherLive: HerdrNativeTabAttacher {

    private let tabsProvider: () -> [Tab]
    private let attachHook: (Tab) -> Bool
    private let focusHook: (UUID) -> Void
    private let ratioMutationHook: (UUID, UUID, SplitDirection, Double) -> Void
    private let closeLeafHook: (UUID) -> Void
    /// Never invoked by this type -- see this file's header. Stored so
    /// AppDelegate can wire a real implementation, keeping the
    /// never-kill invariant honest rather than papering over it with a
    /// no-op closure.
    private let sessionKillHook: (UUID) -> Void

    init(
        tabsProvider: @escaping () -> [Tab],
        attachHook: @escaping (Tab) -> Bool,
        focusHook: @escaping (UUID) -> Void,
        ratioMutationHook: @escaping (UUID, UUID, SplitDirection, Double) -> Void,
        closeLeafHook: @escaping (UUID) -> Void,
        sessionKillHook: @escaping (UUID) -> Void
    ) {
        self.tabsProvider = tabsProvider
        self.attachHook = attachHook
        self.focusHook = focusHook
        self.ratioMutationHook = ratioMutationHook
        self.closeLeafHook = closeLeafHook
        self.sessionKillHook = sessionKillHook
    }

    /// Builds the "shell" Tab described in this file's header and
    /// invokes attachHook with it, returning attachHook's own result
    /// verbatim.
    func attachTab(plan: HerdrNativeTabPlan) -> Bool {
        let tab = Tab(
            title: plan.title,
            splitTree: SplitTree(root: plan.root, focusedLeafID: plan.focusedLeafID)
        )
        tab.herdrPaneRefs = plan.paneRefs
        return attachHook(tab)
    }

    /// Scans tabsProvider() for a tab whose herdrPaneRefs contain a ref
    /// matching BOTH socketPath AND a paneID prefixed "<workspaceID>:" --
    /// the colon is part of the prefix so "w1" never matches "w11:p1"
    /// (only "w1:p1" does).
    func focusExistingTab(withWorkspaceID workspaceID: String, socketPath: String) -> Bool {
        let paneIDPrefix = workspaceID + ":"
        for tab in tabsProvider() {
            let isMatch = tab.herdrPaneRefs.values.contains { ref in
                ref.socketPath == socketPath && ref.paneID.hasPrefix(paneIDPrefix)
            }
            guard isMatch else { continue }
            focusHook(tab.id)
            return true
        }
        return false
    }

    /// Forwards verbatim to ratioMutationHook -- no clamping here;
    /// SplitTree.setRatio's own SplitData.clampRatio is the injected
    /// hook's business, not this method's (see HerdrNativeTabAttacherLiveTests).
    func updateRatio(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double) {
        ratioMutationHook(leafA, leafB, direction, ratio)
    }

    /// Calls ONLY closeLeafHook -- see this file's header for why
    /// sessionKillHook is never called here.
    func closeLeaf(_ id: UUID) {
        closeLeafHook(id)
    }
}
