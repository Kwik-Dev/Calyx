// GitRefFilterSettingsTests.swift
// CalyxTests
//
// Covers GitRefFilterSettings: the per-repository persisted ref-picker
// choice, same isolated-suite shape as SessionSettingsTests.

import Foundation
import XCTest
@testable import Calyx

final class GitRefFilterSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.GitRefFilterSettingsTests"

    override func setUp() {
        super.setUp()
        GitRefFilterSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        GitRefFilterSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_selection_defaultsToAutoWhenNothingSaved() {
        XCTAssertEqual(
            GitRefFilterSettings.selection(forRepo: "/repos/alpha"),
            .auto,
            "A repository with no saved selection must start on Auto"
        )
    }

    func test_setAll_persistsAcrossReads() {
        GitRefFilterSettings.set(.all, forRepo: "/repos/alpha")

        XCTAssertEqual(GitRefFilterSettings.selection(forRepo: "/repos/alpha"), .all)
    }

    func test_setRefs_persistsAcrossReads() {
        let selection = GitRefSelection.refs(["refs/heads/main", "refs/remotes/origin/main"])
        GitRefFilterSettings.set(selection, forRepo: "/repos/alpha")

        XCTAssertEqual(GitRefFilterSettings.selection(forRepo: "/repos/alpha"), selection)
    }

    func test_setAuto_removesTheStoredEntryEntirely() {
        GitRefFilterSettings.set(.all, forRepo: "/repos/alpha")
        GitRefFilterSettings.set(.all, forRepo: "/repos/beta")
        XCTAssertEqual(GitRefFilterSettings.selection(forRepo: "/repos/alpha"), .all)

        GitRefFilterSettings.set(.auto, forRepo: "/repos/alpha")

        XCTAssertEqual(
            GitRefFilterSettings.selection(forRepo: "/repos/alpha"), .auto,
            "Reading back after setting .auto must answer .auto"
        )

        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Isolated defaults suite must be reachable by name")
        }
        guard let data = defaults.data(forKey: "calyx.git.refSelections") else {
            return XCTFail(
                "beta's entry must still be persisted under this key -- the key vanishing " +
                "entirely, rather than just alpha's entry within it, is not what this test covers"
            )
        }
        guard let decoded = try? JSONDecoder().decode([String: GitRefSelection].self, from: data) else {
            return XCTFail("Persisted map must decode as [String: GitRefSelection]")
        }
        XCTAssertNil(
            decoded["/repos/alpha"],
            "Setting .auto must remove the repo's own entry from the persisted map, " +
            "not merely make reads answer .auto some other way"
        )
        XCTAssertEqual(
            decoded["/repos/beta"], .all,
            "Clearing alpha's entry must not disturb beta's, proving the decode above " +
            "actually inspected real data rather than failing silently"
        )
    }

    func test_multipleRepoIDs_areStoredIndependently() {
        GitRefFilterSettings.set(.all, forRepo: "/repos/alpha")
        GitRefFilterSettings.set(.refs(["refs/heads/main"]), forRepo: "/repos/beta")

        XCTAssertEqual(GitRefFilterSettings.selection(forRepo: "/repos/alpha"), .all)
        XCTAssertEqual(
            GitRefFilterSettings.selection(forRepo: "/repos/beta"),
            .refs(["refs/heads/main"])
        )
        XCTAssertEqual(GitRefFilterSettings.selection(forRepo: "/repos/gamma"), .auto)

        GitRefFilterSettings.set(.auto, forRepo: "/repos/alpha")

        XCTAssertEqual(GitRefFilterSettings.selection(forRepo: "/repos/alpha"), .auto)
        XCTAssertEqual(
            GitRefFilterSettings.selection(forRepo: "/repos/beta"),
            .refs(["refs/heads/main"]),
            "Clearing one repo's selection must not disturb another repo's"
        )
    }
}
