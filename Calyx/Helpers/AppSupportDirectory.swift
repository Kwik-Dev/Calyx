// AppSupportDirectory.swift
// Calyx
//
// Resolves Calyx's `~/Library/Application Support/Calyx` directory.

import Foundation

enum AppSupportDirectory {
    /// `~/Library/Application Support/Calyx`. Falls back to a manually
    /// constructed path in the (practically unreachable on macOS) case
    /// where `FileManager` can't resolve the search path domain.
    static var path: String {
        let fm = FileManager.default
        let appSupport = fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Calyx", isDirectory: true).path
    }

    /// `<path>/locks`: the directory holding the per-config-path lock
    /// files that `ConfigFileUtils.atomicWrite` deliberately never
    /// deletes (see its doc comment for why they must persist).
    ///
    /// Under the unit-test host this resolves beneath a temporary
    /// directory instead, so running the suite never adds to the user's
    /// real one. The redirect is keyed off the host rather than offered
    /// as a per-test override because a lock file is named after a hash
    /// of the config path it guards, and tests write to a path carrying
    /// a fresh UUID: one test that forgot to opt in would go on minting
    /// a new permanent file there on every write. Production resolves to
    /// the real directory unchanged, so two writers of one config path
    /// still contend on a single inode.
    static var locksPath: String {
        let root = LaunchEnvironmentPolicy.isUnitTestHost() ? unitTestHostRoot : path
        return (root as NSString).appendingPathComponent("locks")
    }

    /// Stand-in for `path` under the unit-test host, scoped to the
    /// process so concurrent hosts stay out of each other's way.
    /// Resolved once, because every `locksPath` call within a run has to
    /// name the same directory for a lock file to identify a lock.
    private static let unitTestHostRoot: String = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("Calyx-UnitTestHost-\(ProcessInfo.processInfo.processIdentifier)")
}
