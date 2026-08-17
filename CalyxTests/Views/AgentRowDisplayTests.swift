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
//  - cwdLabel: returns AgentRegistry.basename(cwd) unchanged for a
//    non-empty basename; falls back to "N/A" for a nil or empty cwd,
//    matching primaryLabel's own fallback
//  - cwdLabel(entryCwd:source:surfaceID:focusSurfaceID:paneCwd:): mirrors
//    primaryLabel(source:surfaceID:focusSurfaceID:paneTitle:)'s
//    composition exactly. A non-empty entryCwd wins outright and
//    paneCwd is never consulted; a nil or empty entryCwd falls back to
//    the basename of paneCwd(focusTarget). focusTarget comes from the
//    same AgentRowFocusTarget.resolve primaryLabel's composed overload
//    uses; an .external row reaches paneCwd only through
//    focusSurfaceID, never its own (herdr) surfaceID
//  - subtitle: kind label per agent kind, plus a " via herdr" suffix
//    for an .external source
//  - tooltip: title/cwdLabel/subtitle newline-joined in that order,
//    always three lines; every string is passed through verbatim,
//    including non-ASCII characters and the " via herdr" suffix
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

    func test_cwdLabel_nilCwd_returnsNA() {
        XCTAssertEqual(AgentRowDisplay.cwdLabel(cwd: nil), "N/A")
    }

    func test_cwdLabel_emptyCwd_returnsNA() {
        XCTAssertEqual(AgentRowDisplay.cwdLabel(cwd: ""), "N/A")
    }

    /// Pins that `cwdLabel` and `primaryLabel` share the exact same
    /// fallback string for their respective unresolvable inputs, so the
    /// two rules cannot silently diverge into two different "missing
    /// value" spellings.
    func test_cwdLabel_and_primaryLabel_shareTheSameFallbackString() {
        let cwdFallback = AgentRowDisplay.cwdLabel(cwd: nil)
        let titleFallback = AgentRowDisplay.primaryLabel(title: nil)

        XCTAssertEqual(cwdFallback, "N/A")
        XCTAssertEqual(titleFallback, "N/A")
        XCTAssertEqual(cwdFallback, titleFallback)
    }

    // MARK: - cwdLabel(entryCwd:source:surfaceID:focusSurfaceID:paneCwd:)

    /// entryCwd wins whenever non-empty: paneCwd must not be consulted
    /// at all, proven by recording every invocation rather than only
    /// asserting the returned string -- an implementation that calls
    /// paneCwd and discards its result would still pass a
    /// return-value-only assertion.
    func test_cwdLabel_composed_entryCwdNonEmpty_returnsBasenameWithoutConsultingPaneCwd() {
        var paneCwdInvocations: [UUID] = []
        let paneCwd: (UUID) -> String? = { id in
            paneCwdInvocations.append(id)
            return "/should/not/be/used"
        }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: "/Users/dev/repo-a",
            source: .hooks,
            surfaceID: UUID(),
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "repo-a")
        XCTAssertEqual(paneCwdInvocations, [],
                       "paneCwd must not be consulted at all when entryCwd is non-empty")
    }

    /// A nil entryCwd falls back to paneCwd(focusTarget) -- for a
    /// .hooks row with no focusSurfaceID, the focus target is the row's
    /// own surfaceID. paneCwd distinguishes surfaceID from an unrelated
    /// id so this fails if the implementation resolves the wrong target.
    func test_cwdLabel_composed_entryCwdNil_returnsBasenameOfPaneCwdAtFocusTarget() {
        let surfaceID = UUID()
        let unrelatedID = UUID()
        let paneCwd: (UUID) -> String? = { id in
            switch id {
            case surfaceID: return "/Users/dev/live-pane-cwd"
            case unrelatedID: return "/should/not/be/used/unrelated-cwd"
            default: return nil
            }
        }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: nil,
            source: .hooks,
            surfaceID: surfaceID,
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "live-pane-cwd",
                       "a .hooks row with no focusSurfaceID must resolve its cwd through its own surfaceID")
    }

    /// An empty entryCwd must be treated exactly like nil -- falling
    /// back to paneCwd -- not returned as an empty basename.
    func test_cwdLabel_composed_entryCwdEmpty_returnsBasenameOfPaneCwdAtFocusTarget() {
        let surfaceID = UUID()
        let paneCwd: (UUID) -> String? = { id in
            id == surfaceID ? "/Users/dev/live-pane-cwd" : nil
        }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: "",
            source: .hooks,
            surfaceID: surfaceID,
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "live-pane-cwd",
                       "an empty entryCwd must fall back to paneCwd exactly like a nil entryCwd")
    }

    /// entryCwd nil and paneCwd's resolved value also nil: both halves
    /// are unresolvable, so the fallback is "N/A".
    func test_cwdLabel_composed_entryCwdNilAndPaneCwdNil_returnsNA() {
        let paneCwd: (UUID) -> String? = { _ in nil }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: nil,
            source: .hooks,
            surfaceID: UUID(),
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "N/A")
    }

    /// Same as above for the empty-string spelling of "unresolvable" on
    /// both sides -- an empty paneCwd result must reach the same "N/A"
    /// fallback as a nil one, not an empty basename.
    func test_cwdLabel_composed_entryCwdEmptyAndPaneCwdEmpty_returnsNA() {
        let paneCwd: (UUID) -> String? = { _ in "" }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: "",
            source: .hooks,
            surfaceID: UUID(),
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "N/A")
    }

    /// Pins the same focus-target resolution primaryLabel's composed
    /// overload uses: an .external row's own surfaceID is a herdr pane
    /// id, never resolvable in paneCwd, so only focusSurfaceID can reach
    /// the bridging Calyx surface's recorded cwd. The two ids carry
    /// different cwd values so this fails if the implementation
    /// wrongly passes surfaceID instead of the resolved focus target.
    func test_cwdLabel_composed_externalRow_resolvesThroughFocusSurfaceIDNotOwnSurfaceID() {
        let herdrPaneID = UUID()
        let calyxSurfaceID = UUID()
        let paneCwd: (UUID) -> String? = { id in
            switch id {
            case herdrPaneID: return "/should/not/be/used/herdr-pane-cwd"
            case calyxSurfaceID: return "/Users/dev/bridged-surface-cwd"
            default: return nil
            }
        }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: nil,
            source: .external,
            surfaceID: herdrPaneID,
            focusSurfaceID: calyxSurfaceID,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "bridged-surface-cwd",
                       "an .external row must reach its cwd through focusSurfaceID -- reading the entry's own surfaceID instead would return \"herdr-pane-cwd\"")
    }

    /// An unbridged herdr row (.external source, no focusSurfaceID) has
    /// no resolvable focus target at all, so it falls back to "N/A"
    /// rather than resolving through its own (herdr) surfaceID.
    func test_cwdLabel_composed_externalRowNoFocusSurfaceID_returnsNA() {
        let herdrPaneID = UUID()
        let paneCwd: (UUID) -> String? = { id in
            id == herdrPaneID ? "/should/not/be/used/herdr-pane-cwd" : nil
        }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: nil,
            source: .external,
            surfaceID: herdrPaneID,
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "N/A",
                       "an unbridged .external row must fall back to N/A rather than resolving through its own herdr surfaceID")
    }

    /// A trailing slash on entryCwd must not survive into the basename
    /// -- basename derivation must stay AgentRegistry.basename, not a
    /// separately reimplemented split.
    func test_cwdLabel_composed_entryCwdTrailingSlash_returnsBasenameWithoutTrailingSlash() {
        let paneCwd: (UUID) -> String? = { _ in nil }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: "/Users/dev/repo-a/",
            source: .hooks,
            surfaceID: UUID(),
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "repo-a")
    }

    /// A single-segment (no path separator) paneCwd value passes
    /// through basename unchanged, matching AgentRegistry.basename's own
    /// single-segment behavior.
    func test_cwdLabel_composed_paneCwdSingleSegment_returnsBasenameUnchanged() {
        let surfaceID = UUID()
        let paneCwd: (UUID) -> String? = { id in
            id == surfaceID ? "repo-a" : nil
        }

        let result = AgentRowDisplay.cwdLabel(
            entryCwd: nil,
            source: .hooks,
            surfaceID: surfaceID,
            focusSurfaceID: nil,
            paneCwd: paneCwd
        )

        XCTAssertEqual(result, "repo-a")
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
    /// `tooltip` joins whatever `cwdLabel` string it's given
    /// unconditionally, with no emptiness special-casing of its own, so
    /// an empty `cwdLabel` still produces three newline-joined lines
    /// with a blank middle line, not two lines with the cwd line
    /// dropped.
    func test_tooltip_emptyCwdLabel_stillJoinsThreeLines() {
        let result = AgentRowDisplay.tooltip(title: "Refactor billing service", cwdLabel: "", subtitle: "Claude Code")

        XCTAssertEqual(result, "Refactor billing service\n\nClaude Code",
                       "an empty cwdLabel must still be joined as the middle line, not dropped -- tooltip performs no emptiness check of its own")
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
