//
//  AgentRowDisplayTests.swift
//  CalyxTests
//
//  Tests for AgentRowDisplay: the pure label derivation behind the
//  Agents sidebar row, extracted from AgentRowView so it's directly
//  testable without mounting the view. The row renders three lines:
//  the pane's own recorded title (primaryLabel), the pane's cwd
//  basename (cwdLabel), and the agent kind label (subtitle).
//
//  Coverage:
//  - primaryLabel: returns a non-empty title unchanged, including its
//    exact leading/trailing padding, with no stripping, truncation, or
//    trimming of decoration glyphs or bracketed prefixes an agent CLI
//    writes into a pane title; falls back to "N/A" for a nil, empty, or
//    whitespace-only title
//  - cwdLabel: returns AgentRegistry.basename(cwd) unchanged, including
//    its empty-string result for a nil or empty cwd
//  - subtitle: kind label per agent kind, plus a " via herdr" suffix
//    for an .external source
//  - tooltip: title/cwdLabel/subtitle newline-joined in that order when
//    all three are present; an empty cwdLabel is omitted entirely (no
//    blank line), not left as a blank line; every string is passed
//    through verbatim, including non-ASCII characters and the " via
//    herdr" suffix
//  - unreadAccessibilityValue: empty string for a non-positive count,
//    mirroring the `entry.unreadCount > 0` guard the row wraps
//    UnreadCountBadge in; "N unread" for 1...99; capped at "99+ unread"
//    above 99, mirroring UnreadCountBadge's own "99+" digit cap
//

import XCTest
@testable import Calyx

@MainActor
final class AgentRowDisplayTests: XCTestCase {

    // MARK: - primaryLabel: non-empty title

    func test_primaryLabel_nonEmptyTitle_returnsTitleVerbatim() {
        XCTAssertEqual(
            AgentRowDisplay.primaryLabel(title: "My Session Title"),
            "My Session Title"
        )
    }

    // MARK: - primaryLabel: nil/empty/whitespace-only title falls back to "N/A"

    func test_primaryLabel_nilTitle_returnsNA() {
        XCTAssertEqual(AgentRowDisplay.primaryLabel(title: nil), "N/A")
    }

    func test_primaryLabel_emptyTitle_returnsNA() {
        XCTAssertEqual(AgentRowDisplay.primaryLabel(title: ""), "N/A")
    }

    /// A title with no non-whitespace content at all renders as a blank
    /// semibold line if let through unguarded -- this pins the fallback
    /// to "N/A" instead.
    func test_primaryLabel_whitespaceOnlyTitle_returnsNA() {
        XCTAssertEqual(AgentRowDisplay.primaryLabel(title: "   "), "N/A")
    }

    // MARK: - primaryLabel: title is never processed

    /// A non-empty title must come back exactly as given: no stripping a
    /// leading spinner/decoration glyph (the kind ClaudeTitleHeuristic
    /// classifies pane titles by -- a separate concern from this label).
    func test_primaryLabel_doesNotStripDecoratedTitle() {
        let title = "◐ Calyxの並行編集制御と承認UIの改善検討"
        XCTAssertEqual(AgentRowDisplay.primaryLabel(title: title), title)
    }

    /// A title with real (non-whitespace) content plus surrounding
    /// padding must come back byte-for-byte, padding included: the
    /// whitespace-only emptiness check above must trim only a COPY it
    /// uses to decide, never the string it returns.
    func test_primaryLabel_paddedTitle_isNotTrimmed() {
        let title = "  padded with whitespace  "
        XCTAssertEqual(AgentRowDisplay.primaryLabel(title: title), title)
    }

    // MARK: - cwdLabel

    func test_cwdLabel_nonEmptyCwd_returnsBasename() {
        XCTAssertEqual(AgentRowDisplay.cwdLabel(cwd: "/Users/dev/repo-a"), "repo-a")
    }

    func test_cwdLabel_nilCwd_returnsEmptyString() {
        XCTAssertEqual(AgentRowDisplay.cwdLabel(cwd: nil), "")
    }

    func test_cwdLabel_emptyCwd_returnsEmptyString() {
        XCTAssertEqual(AgentRowDisplay.cwdLabel(cwd: ""), "")
    }

    // MARK: - subtitle

    /// Covers all six `AgentEntry` kind constants, not just
    /// `claudeCodeKind`: a future edit that hardcodes one kind's label
    /// (e.g. always returning "Claude Code" regardless of `kind`) must
    /// fail here instead of passing on single-kind coverage alone.
    func test_subtitle_nativeSource_returnsKindLabelWithoutSuffix() {
        let cases: [(kind: String, expected: String)] = [
            (AgentEntry.claudeCodeKind, "Claude Code"),
            (AgentEntry.codexKind, "Codex"),
            (AgentEntry.openCodeKind, "OpenCode"),
            (AgentEntry.hermesKind, "Hermes Agent"),
            (AgentEntry.grokKind, "Grok"),
            (AgentEntry.piKind, "pi"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                AgentRowDisplay.subtitle(kind: testCase.kind, source: .hooks),
                testCase.expected,
                "kind: \(testCase.kind)"
            )
        }
    }

    /// Same per-kind coverage as above, for the `.external` (herdr)
    /// source's " via herdr" suffix.
    func test_subtitle_externalSource_appendsViaHerdrSuffix() {
        let cases: [(kind: String, expected: String)] = [
            (AgentEntry.claudeCodeKind, "Claude Code via herdr"),
            (AgentEntry.codexKind, "Codex via herdr"),
            (AgentEntry.openCodeKind, "OpenCode via herdr"),
            (AgentEntry.hermesKind, "Hermes Agent via herdr"),
            (AgentEntry.grokKind, "Grok via herdr"),
            (AgentEntry.piKind, "pi via herdr"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                AgentRowDisplay.subtitle(kind: testCase.kind, source: .external),
                testCase.expected,
                "kind: \(testCase.kind)"
            )
        }
    }

    // MARK: - tooltip

    func test_tooltip_allThreeLinesPresent_joinsInTitleCwdSubtitleOrder() {
        let result = AgentRowDisplay.tooltip(title: "Refactor billing service", cwdLabel: "repo-a", subtitle: "Claude Code")

        XCTAssertEqual(result, "Refactor billing service\nrepo-a\nClaude Code",
                       "title, cwdLabel, and subtitle must be newline-joined in that exact order when all three are present")
    }

    /// Asserts on the exact composed string, not just the line count --
    /// a stray blank line between title and subtitle (e.g. an
    /// unconditional cwd line joined as an empty string) would still
    /// produce two visible lines of TEXT but a third, blank line in the
    /// string, which a line-count-only assertion would miss.
    func test_tooltip_emptyCwdLabel_omitsCwdLineWithNoBlankLine() {
        let result = AgentRowDisplay.tooltip(title: "Refactor billing service", cwdLabel: "", subtitle: "Claude Code")

        XCTAssertEqual(result, "Refactor billing service\nClaude Code",
                       "an empty cwdLabel must be omitted entirely, not joined in as a blank line between title and subtitle")
    }

    /// Reuses the same non-ASCII title as
    /// `test_primaryLabel_doesNotStripDecoratedTitle` above, and a
    /// subtitle carrying the " via herdr" suffix `AgentRowDisplay
    /// .subtitle` appends for an `.external` source, to pin that
    /// `tooltip` passes both through unmodified.
    func test_tooltip_nonASCIITitleAndHerdrSuffixSubtitle_passedThroughVerbatim() {
        let title = "◐ Calyxの並行編集制御と承認UIの改善検討"
        let subtitle = "Claude Code via herdr"

        let result = AgentRowDisplay.tooltip(title: title, cwdLabel: "repo-a", subtitle: subtitle)

        XCTAssertEqual(result, "\(title)\nrepo-a\n\(subtitle)",
                       "title and subtitle must be passed through tooltip verbatim, including non-ASCII characters and the \" via herdr\" suffix")
    }

    // MARK: - unreadAccessibilityValue

    func test_unreadAccessibilityValue_zero_returnsEmptyString() {
        XCTAssertEqual(AgentRowDisplay.unreadAccessibilityValue(count: 0), "")
    }

    /// `entry.unreadCount` should never go negative in practice, but
    /// `rowContent`'s own guard (`if entry.unreadCount > 0`) treats
    /// anything not strictly positive as "nothing to show" -- this pins
    /// the same rule here rather than reading out a negative count.
    func test_unreadAccessibilityValue_negative_returnsEmptyString() {
        XCTAssertEqual(AgentRowDisplay.unreadAccessibilityValue(count: -1), "")
    }

    func test_unreadAccessibilityValue_one_returnsExactCount() {
        XCTAssertEqual(AgentRowDisplay.unreadAccessibilityValue(count: 1), "1 unread")
    }

    func test_unreadAccessibilityValue_many_returnsExactCount() {
        XCTAssertEqual(AgentRowDisplay.unreadAccessibilityValue(count: 42), "42 unread")
    }

    /// Pins the boundary just below `UnreadCountBadge`'s own "99+" cap:
    /// the drawn badge still shows the exact digits at 99, so the spoken
    /// value must too.
    func test_unreadAccessibilityValue_atCapBoundary_returnsExactCount() {
        XCTAssertEqual(AgentRowDisplay.unreadAccessibilityValue(count: 99), "99 unread")
    }

    /// Mirrors `UnreadCountBadge`'s own `count > 99 ? "99+" : "\(count)"`
    /// cap: past 99, the spoken value must match the drawn "99+" rather
    /// than diverging by reading out the exact, uncapped count.
    func test_unreadAccessibilityValue_overCap_returnsCappedValue() {
        XCTAssertEqual(AgentRowDisplay.unreadAccessibilityValue(count: 100), "99+ unread")
        XCTAssertEqual(AgentRowDisplay.unreadAccessibilityValue(count: 150), "99+ unread")
    }
}
