//
//  HerdrTabTitlePolicyTests.swift
//  CalyxTests
//
//  Coverage for HerdrTabTitlePolicy.title: the pure decision behind
//  HerdrNativeTabPlan.title for a herdr-opened workspace tab. A present,
//  non-blank label wins, returned unmodified (never trimmed); a nil
//  label -- covering both an absent JSON key and an explicit JSON null,
//  which decode to the same Swift nil -- or a whitespace-only label
//  falls back to the workspace id.
//
//  Mirrors HerdrChildExitedPolicyTests' shape: a plain (non-@MainActor)
//  XCTestCase directly calling a pure, already-computed-argument static
//  function -- no actor isolation, no fixtures, no daemon/FFI involved.
//

import XCTest
@testable import Calyx

final class HerdrTabTitlePolicyTests: XCTestCase {

    // MARK: - Label present -> label wins

    func test_title_labelPresent_returnsLabelUnmodified() {
        XCTAssertEqual(HerdrTabTitlePolicy.title(label: "Calyx", workspaceID: "wJ"), "Calyx")
    }

    /// A workspace created in the home directory carries label "~" --
    /// this project's own measured shape for that case.
    func test_title_labelTilde_homeDirectoryWorkspace_returnsTilde() {
        XCTAssertEqual(HerdrTabTitlePolicy.title(label: "~", workspaceID: "wB"), "~")
    }

    func test_title_labelHasSurroundingWhitespace_returnsLabelUnmodified_neverTrimmed() {
        XCTAssertEqual(HerdrTabTitlePolicy.title(label: "  Calyx  ", workspaceID: "wJ"), "  Calyx  ")
    }

    // MARK: - Label absent, null, or blank -> workspace id wins

    func test_title_labelNil_absentKeyOrExplicitNull_returnsWorkspaceID() {
        XCTAssertEqual(HerdrTabTitlePolicy.title(label: nil, workspaceID: "wJ"), "wJ")
    }

    func test_title_labelEmptyString_returnsWorkspaceID() {
        XCTAssertEqual(HerdrTabTitlePolicy.title(label: "", workspaceID: "wJ"), "wJ")
    }

    func test_title_labelWhitespaceOnly_returnsWorkspaceID() {
        XCTAssertEqual(HerdrTabTitlePolicy.title(label: "   \n\t", workspaceID: "wJ"), "wJ")
    }
}
