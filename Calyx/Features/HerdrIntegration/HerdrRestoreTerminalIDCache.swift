// HerdrRestoreTerminalIDCache.swift
// Calyx
//
// Per-restore-pass memoization of the terminal ids
// AppDelegate.createSurfaceWithPwd needs for a herdr-bridged leaf
// (HerdrRestoreCommandPolicy.decide's terminalID parameter).
// HerdrRestoreTerminalIDResolver.resolve performs real socket I/O, so
// resolving once per socket path is preferable to once per leaf.
//
// A reference type, not a process-lifetime singleton: one instance is
// constructed at the root of a single restore pass
// (AppDelegate.restoreSession / recoverPreservedSession) and shared by
// every window and tab that pass restores, then discarded. Terminal ids
// are not stable across a herdr server restart, so nothing may persist
// this cache beyond one pass: a later, independent pass always gets a
// fresh instance and resolves fresh ids.
//
// An empty resolve result is memoized too: a dead socket must cost
// exactly one resolve attempt per pass, not one per leaf on that socket.

import Foundation

@MainActor
final class HerdrRestoreTerminalIDCache {

    private let resolve: (String) -> [String: String]
    private var cache: [String: [String: String]] = [:]

    init(
        resolve: @escaping (String) -> [String: String] = {
            HerdrRestoreTerminalIDResolver.resolve(refs: [HerdrPaneRef(socketPath: $0, paneID: "")])
        }
    ) {
        self.resolve = resolve
    }

    /// Terminal ids for `socketPath`, keyed by
    /// `HerdrRestoreTerminalIDResolver.key(socketPath:paneID:)`. Resolved
    /// at most once per socket path for this instance's lifetime.
    func terminalIDs(forSocketPath socketPath: String) -> [String: String] {
        if let cached = cache[socketPath] { return cached }
        let resolved = resolve(socketPath)
        cache[socketPath] = resolved
        return resolved
    }
}
