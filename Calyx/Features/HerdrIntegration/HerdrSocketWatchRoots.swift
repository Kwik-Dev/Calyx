// HerdrSocketWatchRoots.swift
// Calyx
//
// The set of directories a herdr-socket watcher must observe, extracted
// as a pure decision in the same shape as
// `HerdrHeuristicIngestionPolicy`: every filesystem question this needs
// answered (does a directory exist, what are its subdirectories) is
// supplied by the caller as a closure, so the decision itself never
// touches disk and is testable without any fixture.
//
// A herdr socket can appear at `<configRoot>/herdr.sock`, at
// `<configRoot>/sessions/<name>/herdr.sock`, or at whatever
// `HERDR_SOCKET_PATH` names -- see `HerdrSessionDiscovery.discover()`
// for the candidate set these roots must be able to reveal.

import Foundation

enum HerdrSocketWatchRoots {

    /// Directories to watch, deduplicated, preserving first-seen order.
    ///
    /// - `configRootDirectory` itself when it exists; when it does not,
    ///   its nearest EXISTING ancestor stands in, so the watcher still
    ///   sees the config root itself being created later.
    /// - `<configRootDirectory>/sessions`, and each of its immediate
    ///   subdirectories (one level only).
    /// - The parent directory of `environment["HERDR_SOCKET_PATH"]`,
    ///   when that variable is present and non-empty.
    ///
    /// `subdirectories` answers with the ABSOLUTE PATHS of the immediate
    /// subdirectories of the directory it is given, never bare names, so
    /// nothing here has to re-join paths it did not build itself.
    static func directories(
        configRootDirectory: String,
        environment: [String: String],
        directoryExists: (String) -> Bool,
        subdirectories: (String) -> [String]
    ) -> [String] {
        let sessionsDirectory = configRootDirectory + "/sessions"
        var candidates: [String] = [configRootDirectory, sessionsDirectory]
        candidates.append(contentsOf: subdirectories(sessionsDirectory))

        if let override = environment["HERDR_SOCKET_PATH"], !override.isEmpty {
            candidates.append((override as NSString).deletingLastPathComponent)
        }

        var seen = Set<String>()
        var watched: [String] = []
        watched.reserveCapacity(candidates.count)
        for candidate in candidates {
            let existing = nearestExistingAncestor(of: candidate, directoryExists: directoryExists)
            if seen.insert(existing).inserted {
                watched.append(existing)
            }
        }
        return watched
    }

    /// `path` itself when it exists, otherwise the closest ancestor that
    /// does -- a directory that is not there cannot be opened for
    /// watching, and its ancestor is what reveals it being created.
    /// `"/"` terminates the walk.
    private static func nearestExistingAncestor(
        of path: String,
        directoryExists: (String) -> Bool
    ) -> String {
        var current = path
        while current != "/" && !directoryExists(current) {
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return current
    }
}
