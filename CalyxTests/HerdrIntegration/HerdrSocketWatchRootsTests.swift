//
//  HerdrSocketWatchRootsTests.swift
//  CalyxTests
//
//  Covers HerdrSocketWatchRoots.directories: which directories a
//  herdr-socket watcher must observe, decided purely -- every
//  filesystem question is answered by a closure this file supplies, so
//  no fixture ever touches disk here.
//
//  Contract this file pins:
//  - An EXISTING config root contributes both itself and its
//    "sessions" subdirectory (a socket can appear directly in either).
//  - Each immediate subdirectory of "sessions" is contributed, ONE
//    level only -- a directory nested deeper than
//    <configRoot>/sessions/<name> is never watched, because herdr never
//    places a socket there.
//  - A config root that does NOT exist contributes its NEAREST EXISTING
//    ancestor instead: watching a nonexistent directory is impossible,
//    and the ancestor is what reveals the config root itself being
//    created later.
//  - HERDR_SOCKET_PATH, when present and non-empty, contributes the
//    PARENT directory of the socket it names (a watcher observes
//    directories, never files). Absent or empty contributes nothing.
//  - The result is deduplicated: HERDR_SOCKET_PATH legitimately
//    collides with a directory the config-root scan already found, and
//    a directory watched twice would deliver every event twice.
//

import XCTest
@testable import Calyx

final class HerdrSocketWatchRootsTests: XCTestCase {

    // MARK: - Pure filesystem stand-in

    /// Answers `directoryExists`/`subdirectories` from an explicit set
    /// of absolute directory paths -- a directory's immediate
    /// subdirectories are exactly the members of the set whose parent
    /// path is that directory.
    private struct FakeDirectoryTree {
        let directories: Set<String>

        func exists(_ path: String) -> Bool { directories.contains(path) }

        func immediateSubdirectories(of path: String) -> [String] {
            directories.filter { candidate in
                candidate.hasPrefix(path + "/")
                    && !candidate.dropFirst(path.count + 1).contains("/")
            }.sorted()
        }
    }

    private func directories(
        configRoot: String, environment: [String: String] = [:], tree: FakeDirectoryTree
    ) -> [String] {
        HerdrSocketWatchRoots.directories(
            configRootDirectory: configRoot,
            environment: environment,
            directoryExists: { tree.exists($0) },
            subdirectories: { tree.immediateSubdirectories(of: $0) }
        )
    }

    // MARK: - Existing config root

    func test_directories_existingConfigRoot_includesRootAndSessionsDirectory() {
        let tree = FakeDirectoryTree(directories: ["/cfg", "/cfg/sessions"])

        let result = directories(configRoot: "/cfg", tree: tree)

        XCTAssertEqual(
            Set(result), Set(["/cfg", "/cfg/sessions"]),
            "an existing config root must be watched together with its sessions/ directory -- the default " +
            "session's socket lives directly in the root, a named session's under sessions/"
        )
    }

    func test_directories_sessionsSubdirectories_areIncludedOneLevelOnly() {
        let tree = FakeDirectoryTree(directories: [
            "/cfg", "/cfg/sessions", "/cfg/sessions/work", "/cfg/sessions/work/deeper",
        ])

        let result = directories(configRoot: "/cfg", tree: tree)

        XCTAssertTrue(
            result.contains("/cfg/sessions/work"),
            "a named session's own directory holds that session's socket and must be watched"
        )
        XCTAssertFalse(
            result.contains("/cfg/sessions/work/deeper"),
            "herdr never places a socket deeper than sessions/<name>/ -- a second level must never be watched"
        )
        XCTAssertEqual(
            Set(result), Set(["/cfg", "/cfg/sessions", "/cfg/sessions/work"]),
            "the watched set is exactly the config root, sessions/, and sessions/'s immediate subdirectories"
        )
    }

    // MARK: - Missing config root

    func test_directories_missingConfigRoot_watchesNearestExistingAncestorInstead() {
        // Only "/a" exists: neither "/a/b" nor the config root
        // "/a/b/c" has been created yet.
        let tree = FakeDirectoryTree(directories: ["/a"])

        let result = directories(configRoot: "/a/b/c", tree: tree)

        XCTAssertEqual(
            result, ["/a"],
            "a config root that does not exist yet cannot be watched -- its nearest EXISTING ancestor must " +
            "stand in, so the config root being created later is itself observed"
        )
    }

    // MARK: - HERDR_SOCKET_PATH

    func test_directories_herdrSocketPathOverride_addsItsParentDirectory() {
        let tree = FakeDirectoryTree(directories: ["/cfg", "/cfg/sessions", "/elsewhere"])

        let result = directories(
            configRoot: "/cfg", environment: ["HERDR_SOCKET_PATH": "/elsewhere/herdr.sock"], tree: tree
        )

        XCTAssertEqual(
            Set(result), Set(["/cfg", "/cfg/sessions", "/elsewhere"]),
            "HERDR_SOCKET_PATH names a FILE; the watcher observes directories, so its parent directory must " +
            "be added alongside the config-root scan's own directories"
        )
    }

    func test_directories_herdrSocketPathAbsentOrEmpty_addsNothing() {
        let tree = FakeDirectoryTree(directories: ["/cfg", "/cfg/sessions"])

        let withoutVariable = directories(configRoot: "/cfg", tree: tree)
        let withEmptyVariable = directories(
            configRoot: "/cfg", environment: ["HERDR_SOCKET_PATH": ""], tree: tree
        )

        XCTAssertEqual(
            Set(withoutVariable), Set(["/cfg", "/cfg/sessions"]),
            "an unset HERDR_SOCKET_PATH must contribute no directory"
        )
        XCTAssertEqual(
            Set(withEmptyVariable), Set(["/cfg", "/cfg/sessions"]),
            "an empty HERDR_SOCKET_PATH is not a socket path -- it must contribute no directory, and in " +
            "particular never \"/\" (the parent of an empty path)"
        )
    }

    // MARK: - Dedup

    func test_directories_overrideCollidingWithConfigRoot_isNotWatchedTwice() {
        let tree = FakeDirectoryTree(directories: ["/cfg", "/cfg/sessions", "/cfg/sessions/work"])

        let result = directories(
            configRoot: "/cfg",
            environment: ["HERDR_SOCKET_PATH": "/cfg/sessions/work/herdr.sock"],
            tree: tree
        )

        XCTAssertEqual(
            result.filter { $0 == "/cfg/sessions/work" }.count, 1,
            "HERDR_SOCKET_PATH pointing inside a directory the config-root scan already found must not make " +
            "that directory appear twice -- a doubly-watched directory delivers every event twice"
        )
        XCTAssertEqual(
            result.count, Set(result).count,
            "no directory may appear more than once in the watched set"
        )
    }
}
