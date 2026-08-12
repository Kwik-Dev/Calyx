// HerdrPaneRef.swift
// Calyx
//
// Calyx-internal value type pairing which herdr socket a pane lives on
// with that pane's own wire id ({socketPath, paneID}) -- the same pair
// HerdrStableID.make(socketPath:paneID:) hashes together, since a herdr
// pane id ("w9:p1" shape) is only unique WITHIN one herdr server; two
// independent sockets can legitimately reuse the same workspace/pane
// numbering (see HerdrStableID.swift's own header).
//
// isValidPaneID(_:) is a SECURITY boundary, not a shape convenience:
// an earlier revision of HerdrAttachBridgeCommand interpolated a
// caller-supplied paneID directly into a shell command line via
// SessionCommandSynthesizer.shSafeToken, which would already escape a
// hostile paneID into an inert argument -- this validator was an
// independent, earlier gate, so an id shaped like an injection attempt
// never even reached command synthesis. HerdrAttachBridgeCommand.build
// now takes a herdr TERMINAL id instead (see that file's own header --
// `herdr agent attach <paneID>` only resolves a pane through herdr's
// AGENT registry and fails outright for a plain, agent-less shell pane;
// `herdr terminal attach <terminalID>` is the measured, working
// replacement), so paneID itself no longer reaches a shell command line
// at all -- this validator is RETAINED anyway, as a defense-in-depth
// identity check (HerdrRestoreCommandPolicy.decide and
// HerdrTabCoordinator.openWorkspace both still reject a malformed
// persisted/wire paneID outright, before ever consulting a
// session.snapshot's own terminal-id map for it), not because the
// shell-injection vector still exists through this specific field.
//
// SCHEMA: herdr's own machine-readable schema (`herdr api schema
// --json`, protocol 19, schema_version 1) marks every pane_id-shaped
// field as a bare string with no `pattern` constraining its shape, so
// there is no schema-level regex to derive this from. The accepted
// shape is instead pinned to measured live forms ("wB:p1", "wC:p1") and
// this codebase's own doc-comment examples ("w8:p1", "w9:p1"): "w" +
// one-or-more-alnum + ":" + "p" + one-or-more-alnum, full string match.
//
// Deliberately NOT HerdrPaneID(parsing:) (HerdrEvent.swift): that parser
// only requires non-empty text on both sides of the first colon, by
// design, so a malformed pane_id degrades a single record rather than
// failing a whole decode -- exactly wrong for a security boundary, which
// must reject "wB:p1; touch; #" outright.
//
// isValidTerminalID(_:) is HerdrAttachBridgeCommand's OWN security
// boundary now (see that file's own header): terminalID -- not paneID
// -- is what actually reaches `herdr terminal attach <terminalID>`'s
// shell command line, so it is this field, not paneID, that a hostile
// or corrupted value must never reach command synthesis through.
// MEASURED shape (live-server verification, herdr 0.8.0):
// "term_658cabe34ba1713" -- "term_" + one-or-more ASCII
// alnum/underscore, full string match. herdr's own schema (identical
// survey to isValidPaneID's own above) marks every terminal_id-shaped
// field as a bare string with no `pattern`, so -- as with paneID --
// there is no schema-level regex to derive this from either; the shape
// below is pinned to that one measured live value alone.

import Foundation

struct HerdrPaneRef: Codable, Equatable, Sendable {
    let socketPath: String
    let paneID: String
}

extension HerdrPaneRef {
    /// Full-string match against "w" + ASCII-alnum+ + ":" + "p" +
    /// ASCII-alnum+. Walks `s.utf8` byte-by-byte -- mirrors
    /// `SessionCommandSynthesizer.shSafeToken`'s own precedent -- rather
    /// than any `Character`/`String` substring API, so there is no
    /// grapheme-cluster or Unicode-normalization boundary for a hostile
    /// byte sequence to hide behind. ASCII-only (not
    /// `CharacterSet.alphanumerics`) so a Unicode confusable can never
    /// pass as a "letter" here.
    static func isValidPaneID(_ s: String) -> Bool {
        func isAlnum(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) // 0-9
                || (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x61 && byte <= 0x7A) // a-z
        }

        let bytes = Array(s.utf8)
        var index = 0

        guard index < bytes.count, bytes[index] == 0x77 else { return false } // "w"
        index += 1

        let workspaceStart = index
        while index < bytes.count, isAlnum(bytes[index]) { index += 1 }
        guard index > workspaceStart else { return false }

        guard index < bytes.count, bytes[index] == 0x3A else { return false } // ":"
        index += 1

        guard index < bytes.count, bytes[index] == 0x70 else { return false } // "p"
        index += 1

        let paneStart = index
        while index < bytes.count, isAlnum(bytes[index]) { index += 1 }
        guard index > paneStart else { return false }

        return index == bytes.count // full match -- no trailing garbage
    }

    /// Full-string match against "term_" + (ASCII-alnum-or-underscore)+.
    /// Byte-walks `s.utf8` -- see `isValidPaneID(_:)`'s own doc comment
    /// for why (identical reasoning: no grapheme-cluster/Unicode
    /// boundary, ASCII-only so a Unicode confusable can never pass).
    static func isValidTerminalID(_ s: String) -> Bool {
        func isAlnumOrUnderscore(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) // 0-9
                || (byte >= 0x41 && byte <= 0x5A) // A-Z
                || (byte >= 0x61 && byte <= 0x7A) // a-z
                || byte == 0x5F // "_"
        }

        let bytes = Array(s.utf8)
        let literalPrefix: [UInt8] = [0x74, 0x65, 0x72, 0x6D, 0x5F] // "term_"
        var index = 0
        for expected in literalPrefix {
            guard index < bytes.count, bytes[index] == expected else { return false }
            index += 1
        }

        let suffixStart = index
        while index < bytes.count, isAlnumOrUnderscore(bytes[index]) { index += 1 }
        guard index > suffixStart else { return false }

        return index == bytes.count // full match -- no trailing garbage
    }
}
