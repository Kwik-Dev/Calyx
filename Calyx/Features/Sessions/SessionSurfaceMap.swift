// SessionSurfaceMap.swift
// Calyx
//
// Bidirectional registry between a calyx-session ID (ULID string,
// stable across reconnect) and the ghostty surface UUID currently
// attached to it (unstable — a reconnect creates a fresh surface).
// `CalyxMCPServer` consults this to resolve `/agent-event` requests that
// carry a session ID (rather than a raw surface UUID) in
// `X-Calyx-Surface-ID`.

import Foundation

@MainActor
final class SessionSurfaceMap {

    static let shared = SessionSurfaceMap()

    private var surfaceBySessionID: [String: UUID] = [:]
    private var sessionIDBySurface: [UUID: String] = [:]

    init() {}

    /// Records both directions (sessionID -> surfaceID and surfaceID ->
    /// sessionID), replacing whichever registration currently holds
    /// either side of the new pair: registering a second surface under
    /// the same `sessionID` clears that prior surface's reverse entry,
    /// and registering a sessionID onto a surfaceID some other session
    /// currently occupies clears that other session's forward entry.
    /// Double registration replaces, it does not accumulate, in both
    /// directions, so a stale entry on either side can never outlive the
    /// registration that superseded it.
    func register(sessionID: String, surfaceID: UUID) {
        let priorSurfaceID = surfaceBySessionID[sessionID]
        let priorSessionID = sessionIDBySurface[surfaceID]

        if let priorSurfaceID, priorSurfaceID != surfaceID {
            sessionIDBySurface.removeValue(forKey: priorSurfaceID)
        }
        if let priorSessionID, priorSessionID != sessionID {
            surfaceBySessionID.removeValue(forKey: priorSessionID)
        }

        surfaceBySessionID[sessionID] = surfaceID
        sessionIDBySurface[surfaceID] = sessionID
    }

    func surfaceID(for sessionID: String) -> UUID? {
        surfaceBySessionID[sessionID]
    }

    func sessionID(for surfaceID: UUID) -> String? {
        sessionIDBySurface[surfaceID]
    }

    /// Removes both directions of the mapping for `sessionID`.
    func unregister(sessionID: String) {
        guard let surfaceID = surfaceBySessionID.removeValue(forKey: sessionID) else { return }
        sessionIDBySurface.removeValue(forKey: surfaceID)
    }

    /// Re-points `sessionID`'s registration from `old` to `new` in one
    /// step (the reconnect case: a fresh surface replaces the one whose
    /// child just exited). If `new` already belongs to a different
    /// session, that session's forward entry is cleared too, so it does
    /// not keep resolving to a surface that now belongs to `old`'s
    /// session (the same replaces-both-directions guarantee `register`
    /// makes).
    func replaceSurface(old: UUID, new: UUID) {
        guard let sessionID = sessionIDBySurface.removeValue(forKey: old) else { return }
        if let priorSessionID = sessionIDBySurface[new], priorSessionID != sessionID {
            surfaceBySessionID.removeValue(forKey: priorSessionID)
        }
        surfaceBySessionID[sessionID] = new
        sessionIDBySurface[new] = sessionID
    }
}
