// HerdrEvent.swift
// Calyx
//
// Decoding for herdr's wire shapes, measured against a real herdr
// 0.8.0 server (protocol 19) over its Unix socket:
//
//   - AgentStatus: exactly five values, from herdr's own bundled
//     `herdr api schema --json` (subscription_event.$defs.AgentStatus)
//     -- "idle", "working", "blocked", "done", "unknown". "unknown" is
//     herdr's OWN status value (the common default for a plain shell
//     pane with no agent detected), never to be confused with
//     `HerdrAgentStatus.unrecognized`, this file's own tolerant
//     fallback for any wire string outside those five.
//
//   - Agent/pane records: `snapshot.agents[]` is "the authoritative
//     source for rendering rows" -- one measured example:
//     {"terminal_id":"term_658b1a46d5aba9","agent":"claude",
//      "agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1",
//      "pane_id":"w9:p1","focused":false,"state_change_seq":5,
//      "cwd":"/Users/eguchiyuuichi","foreground_cwd":"/Users/eguchiyuuichi",
//      "revision":0}
//     `snapshot.panes[]` records carry the SAME field set (yes,
//     including their own `pane_id` -- that is what was actually
//     observed, not simplified away here) plus additional "scroll
//     info" fields whose exact shape was not part of what was
//     measured; those extra fields decode away silently (Decodable
//     only reads keys it is told about), which doubles as this file's
//     own "unknown extra JSON fields tolerated" regression pin.
//
//   - The event envelope is inconsistent about naming and this file
//     must accept BOTH:
//       snake_case: {"data":{"pane":{...pane record...},"type":"pane_created"},
//                    "event":"pane_created"}
//       dot-notation: {"event":"pane.agent_status_changed",
//                      "data":{"pane_id":"w9:p1","workspace_id":"w9",
//                              "agent_status":"working","agent":"claude",
//                              "display_agent":null,"title":null,
//                              "state_labels":{...}}}
//     These two shapes, PLUS "pane_closed"/"pane_exited" (see the B1
//     rule below), are the only ones modeled as strongly-typed
//     `HerdrEvent` cases -- they are the only ones whose payload fields
//     were fully measured (pane_created/pane.agent_status_changed), or
//     whose payload this file deliberately reads in a
//     shape-tolerant way rather than requiring a fully-measured shape
//     (pane_closed/pane_exited, B1). Every OTHER named event type this
//     server can push (pane_updated, pane_focused, pane_moved,
//     pane_agent_detected, layout_updated, tab.*, workspace.*,
//     worktree.*, pane.scroll_changed, pane.output_matched) decodes to
//     `.unknown(eventType:)` for now -- deliberately DEFERRED, not
//     forgotten: extrapolating a REQUIRED payload shape from a
//     same-family sibling (e.g. assuming pane_updated carries a full
//     `pane` object just because pane_created does) would freeze an
//     unverified guess into this stage's contract.
//
//   - B1 rule: "pane_closed" and "pane_exited" both decode to
//     `.paneClosed(paneID:)` / `.paneExited(paneID:)` respectively,
//     carrying just the closed/exited pane's raw id `String`. Unlike
//     "pane_created" above, NEITHER event's payload shape was actually
//     measured against a real server -- only that a pane id must be in
//     there somewhere -- so the id is read TOLERANTLY rather than from
//     one fully-committed shape: `data.pane.pane_id` (mirroring
//     "pane_created"'s own nested `pane` object) is preferred WHEN it
//     yields a `String`; otherwise a flat `data.pane_id` is tried;
//     otherwise -- missing "data" entirely, "data"/"pane" present but
//     not an object, or "pane_id" missing/not a `String` in BOTH
//     locations -- this decodes to `.unknown(eventType:)` (the SAME
//     tolerant landing spot every other unmodeled-but-recognised event
//     type already uses) rather than throwing. This is a deliberate
//     departure from "pane_created"'s own strict-throwing precedent
//     (a "pane_created" whose nested `pane` object fails to decode DOES
//     throw): a `HerdrEvent` this file already recognises well enough
//     to name (unlike a totally foreign string) degrading to
//     `.unknown` on a payload-shape surprise, rather than losing the
//     whole line's decode entirely, was decided HERE to be the more
//     useful failure mode for two event types whose exact shape was
//     never confirmed in the first place.
//
//   - `HerdrPaneID` parses a pane id like "w9:p1" into its workspace
//     and local parts. Kept as a SEPARATE, independently-fallible
//     parser rather than something `HerdrAgentRecord`/`HerdrPaneRecord`
//     decode their own `pane_id` field into -- a malformed pane_id
//     must never fail decoding of the whole record/snapshot it lives
//     inside (mirrors this codebase's established "a degraded row
//     beats an error" precedent, e.g. `HerdrCLISessionProvider`'s own
//     doc comment in HerdrSessionProvider.swift). Callers needing the
//     parsed workspace/local parts call `HerdrPaneID(parsing:)` on the
//     raw `String` field themselves.
//
// Every `Decodable` type in this file tolerates unknown/extra JSON
// keys (a keyed decoding container only ever reads the keys it asks
// for) and throws only when a field it actually requires is missing or
// the wrong shape -- that throw IS this file's "decode error" contract,
// distinct from a transport-level `.eof` / `.failure`
// (`HerdrTransport.swift`) and distinct from an unrecognised-but-
// well-formed event TYPE, which decodes tolerantly to `.unknown`
// rather than throwing.
//
// Every hand-written `init(from:)` / `init(parsing:)` below lives in an
// `extension`, never the primary type declaration, so the
// compiler-synthesized memberwise initializer stays available
// (declaring a custom initializer in a type's PRIMARY declaration
// suppresses memberwise synthesis; extensions do not).
// `HerdrPaneAgentStatusChangedEvent` is the one exception -- it is only
// ever reached indirectly, through `HerdrEvent.init(from:)`, so it is
// left as plain compiler-synthesized `Decodable`.
//

import Foundation

// MARK: - HerdrAgentStatus

/// herdr's `AgentStatus` -- exactly five wire values (see this file's
/// header). `.unrecognized(String)` is this type's OWN tolerant
/// fallback for any string outside those five (a future sixth herdr
/// status, or a transient protocol skew) -- NOT one of herdr's own
/// values, so it must never be produced for any of the five known
/// strings, including "unknown" itself (`.unknown` is the correct
/// decode for that one).
enum HerdrAgentStatus: Sendable, Equatable, Hashable {
    case idle
    case working
    case blocked
    case done
    case unknown
    case unrecognized(String)
}

extension HerdrAgentStatus: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "idle": self = .idle
        case "working": self = .working
        case "blocked": self = .blocked
        case "done": self = .done
        case "unknown": self = .unknown
        default: self = .unrecognized(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .idle: try container.encode("idle")
        case .working: try container.encode("working")
        case .blocked: try container.encode("blocked")
        case .done: try container.encode("done")
        case .unknown: try container.encode("unknown")
        case .unrecognized(let raw): try container.encode(raw)
        }
    }
}

// MARK: - HerdrPaneID

/// Parsed form of a herdr pane id like "w9:p1" -- the part before the
/// FIRST ":" is the owning workspace id (matching that same pane's own
/// separate `workspace_id` field on the wire); the part after is the
/// pane's own local id. `nil` for anything that is not exactly
/// "<workspace>:<local>" with both parts non-empty: no colon at all, an
/// empty workspace part (a leading ":"), or an empty local part (a
/// trailing ":"). See this file's header for why this is a SEPARATE
/// parser rather than something `HerdrAgentRecord`/`HerdrPaneRecord`
/// decode their own `pane_id` field into directly.
struct HerdrPaneID: Sendable, Equatable, Hashable {
    let workspaceID: String
    let localID: String
}

extension HerdrPaneID {
    init?(parsing raw: String) {
        guard let colonIndex = raw.firstIndex(of: ":") else { return nil }
        let workspace = raw[raw.startIndex..<colonIndex]
        let local = raw[raw.index(after: colonIndex)...]
        guard !workspace.isEmpty, !local.isEmpty else { return nil }
        self.workspaceID = String(workspace)
        self.localID = String(local)
    }
}

// MARK: - HerdrAgentRecord

/// One row of `snapshot.agents[]` -- "the authoritative source for
/// rendering rows" per herdr's own wire contract. Field set and
/// ordering mirror the exact measured example in this file's header.
struct HerdrAgentRecord: Sendable, Equatable {
    let terminalID: String
    /// `nil` for a pane with no agent CLI detected -- `agentStatus ==
    /// .unknown` is documented as the common default for a plain shell
    /// pane, implying such panes can appear here with no agent identity
    /// to report.
    let agent: String?
    let agentStatus: HerdrAgentStatus
    let workspaceID: String
    let tabID: String
    /// Raw wire value, e.g. "w9:p1" -- see this file's header for why
    /// this is NOT parsed into `HerdrPaneID` at decode time.
    let paneID: String
    let focused: Bool
    let stateChangeSeq: Int
    let cwd: String?
    let foregroundCwd: String?
    let revision: Int
}

extension HerdrAgentRecord: Decodable {
    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agent
        case agentStatus = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused
        case stateChangeSeq = "state_change_seq"
        case cwd
        case foregroundCwd = "foreground_cwd"
        case revision
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.terminalID = try container.decode(String.self, forKey: .terminalID)
        self.agent = try container.decodeIfPresent(String.self, forKey: .agent)
        self.agentStatus = try container.decode(HerdrAgentStatus.self, forKey: .agentStatus)
        self.workspaceID = try container.decode(String.self, forKey: .workspaceID)
        self.tabID = try container.decode(String.self, forKey: .tabID)
        self.paneID = try container.decode(String.self, forKey: .paneID)
        self.focused = try container.decode(Bool.self, forKey: .focused)
        self.stateChangeSeq = try container.decode(Int.self, forKey: .stateChangeSeq)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        self.revision = try container.decode(Int.self, forKey: .revision)
    }
}

// MARK: - HerdrPaneRecord

/// One row of `snapshot.panes[]`. Carries the SAME field set as
/// `HerdrAgentRecord` (see this file's header for why, including the
/// admittedly-redundant-looking `pane_id`) plus additional "scroll
/// info" fields not modeled here -- see this file's header.
struct HerdrPaneRecord: Sendable, Equatable {
    let terminalID: String
    let agent: String?
    let agentStatus: HerdrAgentStatus
    let workspaceID: String
    let tabID: String
    let paneID: String
    let focused: Bool
    let stateChangeSeq: Int
    let cwd: String?
    let foregroundCwd: String?
    let revision: Int
}

extension HerdrPaneRecord: Decodable {
    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agent
        case agentStatus = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused
        case stateChangeSeq = "state_change_seq"
        case cwd
        case foregroundCwd = "foreground_cwd"
        case revision
    }

    init(from decoder: any Decoder) throws {
        // Identical field mapping to `HerdrAgentRecord.init(from:)`
        // above; see that type's own comment.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.terminalID = try container.decode(String.self, forKey: .terminalID)
        self.agent = try container.decodeIfPresent(String.self, forKey: .agent)
        self.agentStatus = try container.decode(HerdrAgentStatus.self, forKey: .agentStatus)
        self.workspaceID = try container.decode(String.self, forKey: .workspaceID)
        self.tabID = try container.decode(String.self, forKey: .tabID)
        self.paneID = try container.decode(String.self, forKey: .paneID)
        self.focused = try container.decode(Bool.self, forKey: .focused)
        self.stateChangeSeq = try container.decode(Int.self, forKey: .stateChangeSeq)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        self.revision = try container.decode(Int.self, forKey: .revision)
    }
}

// MARK: - HerdrPaneAgentStatusChangedEvent

/// Payload of the dot-notation `pane.agent_status_changed` event --
/// {"event":"pane.agent_status_changed","data":{"pane_id":"w9:p1",
/// "workspace_id":"w9","agent_status":"working","agent":"claude",
/// "display_agent":null,"title":null,"state_labels":{...}}}.
/// `paneID`/`workspaceID`/`agentStatus` are REQUIRED; `agent`/
/// `displayAgent`/`title`/`stateLabels` are optional. `stateLabels`'
/// own shape was not part of what was measured beyond being present as
/// an object, so it decodes as `AnyCodable?`
/// (Calyx/Features/IPC/JSONRPC.swift's existing type-erased JSON
/// value, reused rather than reimplemented).
///
/// Left as plain compiler-synthesized `Decodable` (no hand-written
/// `init(from:)`) -- see this file's header for why: it is only ever
/// reached indirectly, through `HerdrEvent.init(from:)`'s own
/// `.data` decode for the "pane.agent_status_changed" case.
struct HerdrPaneAgentStatusChangedEvent: Sendable, Equatable, Decodable {
    let paneID: String
    let workspaceID: String
    let agentStatus: HerdrAgentStatus
    let agent: String?
    let displayAgent: String?
    let title: String?
    let stateLabels: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agentStatus = "agent_status"
        case agent
        case displayAgent = "display_agent"
        case title
        case stateLabels = "state_labels"
    }
}

// MARK: - HerdrEvent

/// Decoded form of one pushed event line, accepting BOTH envelope
/// namings herdr uses on the wire -- see this file's header.
enum HerdrEvent: Sendable, Equatable {
    /// Snake_case envelope:
    /// {"data":{"pane":{...pane record...},"type":"pane_created"},"event":"pane_created"}
    case paneCreated(HerdrPaneRecord)
    /// Dot-notation:
    /// {"event":"pane.agent_status_changed","data":{...}}
    case paneAgentStatusChanged(HerdrPaneAgentStatusChangedEvent)
    /// "pane_closed" -- see this file's header "B1 rule" for exactly how
    /// `paneID` is read out of the envelope, and when this decodes to
    /// `.unknown(eventType: "pane_closed")` instead.
    case paneClosed(paneID: String)
    /// "pane_exited" -- see this file's header "B1 rule"; identical
    /// envelope handling to `.paneClosed` above, just the other event
    /// name.
    case paneExited(paneID: String)
    /// Every other named event type herdr can push -- see this file's
    /// header for the full list and why they are deliberately deferred
    /// rather than guessed at. Also the tolerant landing spot for any
    /// event type string not recognised at all (a future addition to
    /// herdr's own wire protocol), AND for a "pane_closed"/"pane_exited"
    /// envelope this file cannot find a pane id in -- see this file's
    /// header "B1 rule".
    case unknown(eventType: String)
}

extension HerdrEvent: Decodable {
    private enum EnvelopeCodingKeys: String, CodingKey {
        case event
        case data
    }

    private enum PaneDataCodingKeys: String, CodingKey {
        case pane
    }

    /// B1: the "data" object shape `paneID(fromDataOf:)` reads a
    /// "pane_closed"/"pane_exited" envelope's pane id out of -- carries
    /// BOTH keys `paneID(fromDataOf:)` may need (the nested "pane"
    /// object, and the flat "pane_id"), since which one is actually
    /// present is exactly what that function is tolerantly probing for.
    private enum PaneClosedOrExitedDataCodingKeys: String, CodingKey {
        case pane
        case paneID = "pane_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EnvelopeCodingKeys.self)
        // The top-level "event" key is present on BOTH envelope shapes
        // (unlike "data.type", which only the snake_case shape has) --
        // see this file's header -- so it is the one reliable
        // discriminator to key decoding off of. A line missing this key
        // entirely is not a recognised envelope at all, and this throws
        // for it -- that throw is this file's "malformed line" /
        // decode-error contract.
        let eventType = try container.decode(String.self, forKey: .event)

        switch eventType {
        case "pane_created":
            let dataContainer = try container.nestedContainer(keyedBy: PaneDataCodingKeys.self, forKey: .data)
            let pane = try dataContainer.decode(HerdrPaneRecord.self, forKey: .pane)
            self = .paneCreated(pane)
        case "pane.agent_status_changed":
            let changed = try container.decode(HerdrPaneAgentStatusChangedEvent.self, forKey: .data)
            self = .paneAgentStatusChanged(changed)
        case "pane_closed", "pane_exited":
            // B1 rule -- see this file's header. Tolerant: a pane id
            // that cannot be found falls back to `.unknown` below rather
            // than throwing.
            if let paneID = Self.paneID(fromDataOf: container) {
                self = eventType == "pane_closed" ? .paneClosed(paneID: paneID) : .paneExited(paneID: paneID)
            } else {
                self = .unknown(eventType: eventType)
            }
        default:
            // Every other named-but-unmeasured event type, plus any
            // string not recognised at all -- see this file's header.
            self = .unknown(eventType: eventType)
        }
    }

    /// B1: best-effort pane id extraction for "pane_closed"/
    /// "pane_exited" -- see this file's header "B1 rule" for the
    /// precedence this implements. NEVER throws: every fallible step is
    /// `try?`, deliberately -- per this stage's own instructions, a
    /// missing/malformed pane id here falls back to `.unknown(eventType:)`
    /// at the `init(from:)` call site above, rather than failing the
    /// whole line's decode the way "pane_created"'s own nested `pane`
    /// object does.
    private static func paneID(fromDataOf container: KeyedDecodingContainer<EnvelopeCodingKeys>) -> String? {
        guard let dataContainer = try? container.nestedContainer(keyedBy: PaneClosedOrExitedDataCodingKeys.self, forKey: .data) else {
            return nil
        }
        // Prefer `data.pane.pane_id` (mirrors "pane_created"'s own
        // nested `pane` object) -- but only when it actually yields a
        // `String`; any failure along the way (no "pane" key, "pane" not
        // an object, no "pane_id" inside it, or "pane_id" not a
        // `String`) falls through to the flat form below rather than
        // giving up immediately.
        if let paneContainer = try? dataContainer.nestedContainer(keyedBy: PaneClosedOrExitedDataCodingKeys.self, forKey: .pane),
           let nestedPaneID = try? paneContainer.decode(String.self, forKey: .paneID) {
            return nestedPaneID
        }
        // Flat `data.pane_id`. `try?` here also covers "pane_id" simply
        // being absent, or present but not a `String`.
        return try? dataContainer.decode(String.self, forKey: .paneID)
    }
}
