//
//  HerdrPaneRefTests.swift
//  CalyxTests
//
//  Covers HerdrPaneRef -- a Calyx-internal value type pairing
//  which herdr socket a pane lives on with that pane's own wire id
//  ({socketPath, paneID}). This pairing is already treated as meaningful
//  elsewhere in this codebase: HerdrStableID.make(socketPath:paneID:)
//  hashes the SAME two values together, because HerdrStableID.swift's
//  own header explains herdr pane ids ("w9:p1" shape) are only unique
//  WITHIN one herdr server/session -- two independent herdr sockets can
//  legitimately reuse the same workspace/pane numbering.
//
//  isValidPaneID(_:) IS A SECURITY BOUNDARY, NOT A SHAPE CONVENIENCE:
//  HerdrAttachBridgeCommand (see HerdrAttachBridgeCommandTests
//  .swift) interpolates a caller-supplied paneID directly into a shell
//  command line via SessionCommandSynthesizer.shSafeToken. shSafeToken
//  itself is battle-tested against arbitrary bytes (see that type's own
//  doc comment), so a shell-metacharacter-laden paneID would still be
//  escaped into an inert single-quoted argv word rather than executed --
//  but this validator exists as an INDEPENDENT, earlier gate: an id
//  shaped like an injection attempt should never even reach command
//  synthesis, let alone `herdr agent attach` on the far end of that
//  command.
//
//  SCHEMA-DERIVED SHAPE (per this project's schema-first rule): herdr's
//  own machine-readable schema (`herdr api schema --json`, protocol 19,
//  schema_version 1, matching a live herdr 0.8.0 server) marks every
//  pane_id-shaped field (LayoutNode's "pane" branch, PaneTarget,
//  PaneNeighborParams, etc.) as a bare `"type":"string"` (or
//  `["string","null"]` where optional) with NO `pattern` and NO
//  `description` constraining its shape anywhere in the schema --
//  confirmed by enumerating every "description" key in the full schema
//  dump (ten hits total, none attached to any pane_id field, none
//  attached to any request/response `$defs` at all along the pane_id
//  path). There is therefore no schema-level regex to derive this
//  validator from. The accepted shape is instead PINNED to the
//  measured live forms: "wB:p1" and "wC:p1" (read via `workspace.list`
//  and `layout.export` against a real, running herdr 0.8.0 server's
//  ~/.config/herdr/herdr.sock), "w8:p1" (HerdrPaneRef.swift's own
//  doc-comment example), and "w9:p1" (HerdrEvent.swift's own measured
//  doc-comment example) -- all of shape "w" + one-or-more-alnum + ":" +
//  "p" + one-or-more-alnum.
//
//  Deliberately NOT reusing HerdrPaneID(parsing:) (HerdrEvent.swift) for
//  this job: that parser only requires "non-empty before AND after the
//  first colon" -- by design, per its own doc comment, because a
//  malformed pane_id there must degrade a single record rather than
//  fail a whole decode. That tolerance is exactly wrong for a SECURITY
//  boundary: HerdrPaneID(parsing:) would happily accept
//  "wB:p1; touch; #" (non-empty on both sides of the first colon), which
//  isValidPaneID(_:) below must reject outright.
//

import XCTest
@testable import Calyx

final class HerdrPaneRefTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_roundTrip_encodeThenDecode_producesEqualValue() throws {
        let original = HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HerdrPaneRef.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func test_roundTrip_valuesRequiringJSONEscaping_surviveIntact() throws {
        // socketPath/paneID are plain Calyx-internal Strings, not
        // schema-pinned wire fields (see this file's header) -- this
        // exercises the JSON string-escaping path itself (an embedded
        // quote, plus non-ASCII characters), rather than re-testing
        // JSONEncoder/JSONDecoder's own already battle-tested String
        // handling.
        let original = HerdrPaneRef(
            socketPath: "/tmp/herdr \"quoted\" ünïcode/herdr.sock",
            paneID: "wB:p1"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HerdrPaneRef.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - isValidPaneID -- acceptance/rejection table

    func test_isValidPaneID_acceptanceRejectionTable() {
        let cases: [(id: String, expected: Bool, reason: String)] = [
            // Accept: measured live forms and doc-comment example forms.
            ("wB:p1", true, "measured live form (workspace.list/layout.export against a real herdr 0.8.0 server)"),
            ("wC:p1", true, "measured live form"),
            ("w8:p1", true, "HerdrPaneRef.swift's own doc-comment example form"),
            ("w9:p1", true, "HerdrEvent.swift's own measured doc-comment example"),
            // Accept: multi-character alnum runs on both sides -- proves
            // the shape is "w" + alnum+ + ":" + "p" + alnum+, not
            // "w" + exactly-one-char + ":" + "p" + exactly-one-char (a
            // real herdr session will eventually have a double-digit
            // workspace or pane count).
            ("w10:p23", true, "multi-character workspace and pane numbers must not be rejected"),

            // Reject: structurally wrong shape.
            ("", false, "empty string"),
            ("wBp1", false, "missing colon"),
            ("B:p1", false, "missing the \"w\" workspace prefix"),
            ("wB:1", false, "missing the \"p\" pane prefix"),
            ("wB:", false, "empty local part after the colon"),
            (":p1", false, "empty workspace part before the colon"),
            ("wB:p1:p2", false, "trailing garbage after a well-formed id must be rejected -- full-string match, not a prefix match"),

            // Reject: shell metacharacters. This id is interpolated into
            // a shell command line by HerdrAttachBridgeCommand, so each
            // of these is a distinct injection vector this validator
            // must reject on its own, ahead of shSafeToken. Payloads are
            // harmless-if-ever-actually-executed, matching
            // HerdrAttachCommandSynthesizerTests' own established
            // precedent (a no-op "touch"/"true", never destructive, even
            // in the hypothetical case this validator were broken).
            ("wB:p1; touch; #", false, "semicolon command sequencing"),
            ("wB:p1`true`", false, "backtick command substitution"),
            ("wB:p1$(true)", false, "$() command substitution"),
            ("wB:p1 extra", false, "embedded space"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                HerdrPaneRef.isValidPaneID(testCase.id), testCase.expected,
                "isValidPaneID(\(testCase.id.debugDescription)) expected \(testCase.expected) -- \(testCase.reason)"
            )
        }
    }
}
