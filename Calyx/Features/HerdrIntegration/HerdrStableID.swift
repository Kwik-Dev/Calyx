// HerdrStableID.swift
// Calyx
//
// Deterministic UUID derivation from a herdr identity string, so a
// HerdrAgentMirror-produced Agents-sidebar row (AgentEntry.surfaceID)
// keeps the SAME identity across app restarts and reconnects. `UUID()`
// would mint a brand-new random identity every time the same herdr pane
// is (re)discovered, which would defeat SwiftUI's row identity/diffing
// and any future "remember this row" persistence -- this file exists
// specifically to rule that out.
//
// Algorithm (frozen -- see HerdrStableIDTests' own exact-vector test,
// pinned against a hand-derived `shasum -a 256` value, not just this
// file's own output, so a "looks-plausible-but-wrong" implementation --
// e.g. one built on `String.hashValue`, which is reseeded every process
// launch and therefore UNSTABLE across restarts, exactly the failure
// mode this file exists to rule out -- cannot slip through by
// accidentally satisfying only the RELATIONAL tests below):
//   1. Namespace: "calyx-herdr:<socketPath>:<paneID>" (colon-joined).
//   2. Hash the namespaced string's UTF-8 bytes with CryptoKit SHA-256
//      -- mirrors `ConfigFileUtils.lockFilePath(forResolvedPath:)`'s own
//      SHA-256-based stable-identity precedent.
//   3. Take the digest's first 16 bytes (32 hex characters) and format
//      them as a standard 8-4-4-4-12 UUID string.
// Deliberately NOT UUIDv5's own version/variant nibble-twiddling (RFC
// 4122's "set bits so this reads as a name-based UUID" convention) --
// this UUID is never interpreted as a "real" UUIDv5 by anything
// downstream (it is only ever compared for equality as
// `AgentEntry.surfaceID`/`.id`), and skipping it keeps the algorithm
// hand-verifiable end-to-end with a single `shasum -a 256` invocation
// (see HerdrStableIDTests for the exact derivation).
//
// `socketPath` is part of the namespace -- not just `paneID` alone --
// because herdr pane ids (`HerdrPaneID`, e.g. "w9:p1") are only unique
// WITHIN one herdr server/session; two independent herdr sessions (two
// different sockets) can legitimately reuse the same workspace/pane
// numbering, and without the socket path in the hash input their rows
// would collide onto the same `AgentEntry.id`.
//

import CryptoKit
import Foundation

enum HerdrStableID {
    /// Derives a stable, deterministic `UUID` identifying one herdr pane
    /// across app restarts and reconnects -- see this file's header for
    /// the frozen algorithm. Pure and side-effect-free: equal
    /// `(socketPath, paneID)` pairs always produce the equal `UUID`, in
    /// this process or any other.
    static func make(socketPath: String, paneID: String) -> UUID {
        let namespaced = "calyx-herdr:\(socketPath):\(paneID)"
        let digest = SHA256.hash(data: Data(namespaced.utf8))
        // `UUID(uuid:)` is a raw pass-through of its 16 bytes into the
        // standard 8-4-4-4-12 textual layout -- unlike UUIDv5, it never
        // rewrites any version/variant bits, exactly the "deliberately
        // NOT UUIDv5" property this file's header documents.
        let bytes = Array(digest.prefix(16))
        let raw: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: raw)
    }
}
