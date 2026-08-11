// HerdrEvent.swift
// Calyx
//
// Decoding for herdr's wire shapes. The AUTHORITATIVE contract for every
// type in this file is herdr's own machine-readable schema (`herdr api
// schema --json`, protocol 19, schema_version 1) -- specifically
// `success_response.$defs.PaneInfo` / `.AgentInfo` / `.SessionSnapshot` /
// `.AgentSessionInfo` / `.PaneScrollInfo` (each identical to its
// same-named sibling under `event.$defs`) and
// `subscription_event.$defs.PaneAgentStatusChangedEvent` /
// `.AgentStatus`. Every `required`/optional split below is read off that
// schema, not guessed from a sample. Live wire samples (measured against
// a real herdr 0.8.0 server, protocol 19) appear only as corroboration/
// fixture material alongside the schema-derived facts -- they are NOT
// the source of truth, and must never be extrapolated beyond what they
// literally showed (this file was broken three times in a row by doing
// exactly that).
//
//   - AgentStatus: exactly five values -- "idle", "working", "blocked",
//     "done", "unknown". "unknown" is herdr's OWN status value (the
//     common default for a plain shell pane with no agent detected),
//     never to be confused with `HerdrAgentStatus.unrecognized`, this
//     file's own tolerant fallback for any wire string outside those
//     five.
//
//   - PaneInfo vs AgentInfo: two SEPARATE schema `$defs`, not one shape
//     reused twice -- an earlier version of this file wrongly asserted
//     panes carry "the same field set" as agents; the schema says
//     otherwise. Both share the identical 7 REQUIRED fields
//     (`terminal_id`, `agent_status`, `workspace_id`, `tab_id`,
//     `pane_id`, `focused`, `revision`) and 10 further OPTIONAL fields in
//     common (`agent`, `agent_session`, `cwd`, `display_agent`,
//     `foreground_cwd`, `state_labels`, `terminal_title`,
//     `terminal_title_stripped`, `title`, `tokens`), then DIVERGE:
//     `PaneInfo` alone additionally has optional `label`/`scroll`;
//     `AgentInfo` alone additionally has optional `interactive_ready`/
//     `launch_pending`/`name`/`screen_detection_skipped`/
//     `state_change_seq`. `HerdrPaneRecord`/`HerdrAgentRecord` stay two
//     independent flat structs (no shared base type) -- the schema itself
//     models them as two separate `$defs` that have already diverged;
//     collapsing that into one Swift type (or a shared common-fields
//     struct every call site would need to reach through) would couple
//     two contractually-independent shapes for no wire-level benefit, and
//     would force every existing `.paneID`/`.agentStatus`-style accessor
//     across the codebase through an extra `.common.` hop.
//
//     OPTIONAL vs NULLABLE are two different things on this wire, and
//     both types below decode every optional field with
//     `decodeIfPresent`, which handles BOTH uniformly: a
//     `["string","null"]`/`anyOf[..,null]`-typed field (e.g. `cwd`,
//     `agent_session`, `scroll`) may be absent OR explicitly JSON
//     `null`; a bare `"type":"object"`/`"boolean"`/`"integer"`-typed
//     optional field (e.g. `state_labels`, `tokens`,
//     `interactive_ready`, `state_change_seq`) may only be ABSENT --
//     the schema never allows an explicit `null` for those, so a test
//     fixture must not put one there (that would be an illegal payload,
//     not a valid "nullable" case). `state_change_seq` also carries a
//     schema-level `"default": 0`, which this file deliberately does
//     NOT apply -- only `required` fields become non-optional Swift
//     properties here, so an absent `state_change_seq` decodes to `nil`,
//     never a substituted `0`, keeping "the server didn't send this"
//     visibly distinct from "the server sent zero".
//
//   - `state_labels`/`tokens` (on `PaneInfo`/`AgentInfo`) decode as
//     `[String: String]?`, per the schema's own
//     `additionalProperties: {"type": "string"}` -- a plain string-to-
//     string map when present, never arbitrary JSON.
//
//   - `HerdrAgentSessionInfo` (`AgentSessionInfo` in the schema) and
//     `HerdrPaneScrollInfo` (`PaneScrollInfo`) are new types added by
//     this pass -- both have EVERY field required, so each has no
//     optional/nullable split to worry about. `HerdrAgentSessionInfo
//     .kind` (`AgentSessionRefKind`: "id"/"path" today) follows
//     `HerdrAgentStatus`'s own established tolerant-decode precedent --
//     an `.unrecognized(String)` fallback case rather than a strict
//     raw-value enum -- because `agent_session` is itself an OPTIONAL
//     field: a strict enum would let a future third `kind` value fail
//     the decode of the ENTIRE pane/agent record (and transitively the
//     whole snapshot) it lives inside, over one forward-compatible field
//     nobody asked this file to reject.
//
//   - `HerdrSessionSnapshot` (`SessionSnapshot` in the schema) lives in
//     THIS file (moved from HerdrConnection.swift, which keeps only the
//     RPC envelope types that unwrap it -- see that file's own
//     `HerdrSnapshotRPCResult`) because it is a wire SHAPE, exactly what
//     this file exists to model. All 7 of `version`, `protocol`,
//     `workspaces`, `tabs`, `panes`, `layouts`, `agents` are REQUIRED
//     (an earlier version of this file wrongly treated `version`/
//     `protocol` as optional `AnyCodable` and let `workspaces`/`tabs`/
//     `layouts` default to `[]` when absent -- the schema requires the
//     KEY on all seven, even though an empty array is a legal VALUE for
//     the array-typed ones); only `focused_workspace_id`/
//     `focused_tab_id`/`focused_pane_id` are optional, and nullable.
//     `version`/`protocolVersion` are now concretely `String`/`Int` (the
//     schema states `"type":"string"`/`"format":"uint32"` respectively)
//     -- the old AnyCodable typing existed only because neither field's
//     TYPE had been observed on the wire yet; the schema settles it.
//     `workspaces`/`tabs`/`layouts` stay `[AnyCodable]` -- their element
//     shapes (`WorkspaceInfo`/`TabInfo`/`PaneLayoutSnapshot`) are real
//     schema `$defs` but are NOT among the six shapes this pass commits
//     to modeling, so only THIS type's own required/optional shape (the
//     part this file's callers actually observe -- none of them read
//     `.workspaces`/`.tabs`/`.layouts` today, only `.panes`/`.agents`) is
//     fixed here; fully typing those three is future work, not silently
//     assumed.
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
//     whose payload this file deliberately reads in a shape-tolerant,
//     defensive way even though the schema now fully specifies it
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
//     carrying just the closed/exited pane's raw id `String`. The
//     schema (`event.$defs.EventData`'s "pane_closed"/"pane_exited"
//     variants, identical in `success_response.$defs.EventData`) now
//     settles the shape: it is ALWAYS FLAT --
//     {"type":"pane_closed","pane_id":"...","workspace_id":"..."},
//     `pane_id`/`workspace_id` both REQUIRED alongside `type` -- there is
//     no nested `pane` object variant anywhere, unlike "pane_created"
//     above. The id is nonetheless still read TOLERANTLY rather than
//     from that one schema-confirmed shape alone: `data.pane.pane_id`
//     (mirroring "pane_created"'s own nested `pane` object) is tried
//     FIRST -- a defensive, zero-cost fallback against a non-conforming
//     or future server, not a hedge against genuine shape uncertainty --
//     before the flat `data.pane_id` real traffic actually matches;
//     otherwise -- missing "data" entirely, "data"/"pane" present but
//     not an object, or "pane_id" missing/not a `String` in BOTH
//     locations, none of which a schema-conforming server can actually
//     produce -- this decodes to `.unknown(eventType:)` (the SAME
//     tolerant landing spot every other unmodeled-but-recognised event
//     type already uses) rather than throwing. This is a deliberate
//     departure from "pane_created"'s own strict-throwing precedent
//     (a "pane_created" whose nested `pane` object fails to decode DOES
//     throw): a `HerdrEvent` this file already recognises well enough
//     to name (unlike a totally foreign string) degrading to
//     `.unknown` on a payload-shape surprise, rather than losing the
//     whole line's decode entirely, was decided HERE to be the more
//     useful failure mode for these two event types -- now purely a
//     defensive posture, since the schema rules out a conforming server
//     ever actually triggering it.
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
// suppresses memberwise synthesis; extensions do not). This applies to
// `HerdrAgentRecord`, `HerdrPaneRecord`, `HerdrSessionSnapshot`, and
// `HerdrEvent` -- each mixes required and optional fields (or, for
// `HerdrEvent`, dispatches on a discriminator) explicitly enough to be
// worth spelling out by hand rather than leaning on synthesis.
// `HerdrPaneAgentStatusChangedEvent`, `HerdrAgentSessionInfo`, and
// `HerdrPaneScrollInfo` are left as plain compiler-synthesized
// `Decodable` (a private `CodingKeys` enum where a wire key needs
// renaming, nothing more) -- Swift's synthesis already calls
// `decodeIfPresent` for every `Optional`-typed stored property and
// `decode` for every non-optional one, which is exactly the required/
// optional behavior these three types need, and all three are either
// entirely required-fields-only (`AgentSessionInfo`, `PaneScrollInfo`)
// or only ever reached indirectly through `HerdrEvent.init(from:)`
// (`HerdrPaneAgentStatusChangedEvent`), so a hand-written `init(from:)`
// would only restate what synthesis already does correctly.
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

// MARK: - HerdrAgentSessionInfo

/// `AgentSessionInfo` in the schema -- how herdr itself refers to an
/// agent's own session (e.g. Claude Code's session id/transcript path).
/// EVERY field is required (`source`, `agent`, `kind`, `value`); see
/// this file's header for why `kind` gets `.unrecognized(String)`
/// tolerance rather than a strict raw-value enum.
enum HerdrAgentSessionRefKind: Sendable, Equatable, Hashable {
    case id
    case path
    case unrecognized(String)
}

extension HerdrAgentSessionRefKind: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "id": self = .id
        case "path": self = .path
        default: self = .unrecognized(raw)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .id: try container.encode("id")
        case .path: try container.encode("path")
        case .unrecognized(let raw): try container.encode(raw)
        }
    }
}

/// See `HerdrAgentSessionRefKind`'s own doc comment. Left as plain
/// compiler-synthesized `Decodable` -- see this file's header for why.
struct HerdrAgentSessionInfo: Sendable, Equatable, Decodable {
    let source: String
    let agent: String
    let kind: HerdrAgentSessionRefKind
    let value: String
}

// MARK: - HerdrAgentRecord

/// One row of `snapshot.agents[]` -- "the authoritative source for
/// rendering rows" per herdr's own wire contract. `AgentInfo` in the
/// schema (see this file's header) -- 7 required fields, then 15
/// optional ones, 9 of which are also nullable. Field GROUPING below
/// (required, then optional-and-nullable, then optional-but-never-null)
/// mirrors that split; property ORDER within each group otherwise
/// follows the schema's own `required` array / alphabetical property
/// listing.
struct HerdrAgentRecord: Sendable, Equatable {
    // Required.
    let terminalID: String
    let agentStatus: HerdrAgentStatus
    let workspaceID: String
    let tabID: String
    /// Raw wire value, e.g. "w9:p1" -- see this file's header for why
    /// this is NOT parsed into `HerdrPaneID` at decode time.
    let paneID: String
    let focused: Bool
    let revision: Int

    // Optional; may be absent OR explicit JSON `null`.
    /// `nil` for a pane with no agent CLI detected -- `agentStatus ==
    /// .unknown` is documented as the common default for a plain shell
    /// pane, implying such panes can appear here with no agent identity
    /// to report.
    let agent: String?
    let agentSession: HerdrAgentSessionInfo?
    let cwd: String?
    let displayAgent: String?
    let foregroundCwd: String?
    let name: String?
    let terminalTitle: String?
    let terminalTitleStripped: String?
    let title: String?

    // Optional; may ONLY be absent -- never explicit JSON `null` (see
    // this file's header).
    let interactiveReady: Bool?
    let launchPending: Bool?
    let screenDetectionSkipped: Bool?
    /// `nil` when absent -- NOT defaulted to `0`; see this file's
    /// header for why the schema's own `"default": 0` is deliberately
    /// not applied here.
    let stateChangeSeq: Int?
    let stateLabels: [String: String]?
    let tokens: [String: String]?
}

extension HerdrAgentRecord: Decodable {
    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agentStatus = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused
        case revision
        case agent
        case agentSession = "agent_session"
        case cwd
        case displayAgent = "display_agent"
        case foregroundCwd = "foreground_cwd"
        case name
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case title
        case interactiveReady = "interactive_ready"
        case launchPending = "launch_pending"
        case screenDetectionSkipped = "screen_detection_skipped"
        case stateChangeSeq = "state_change_seq"
        case stateLabels = "state_labels"
        case tokens
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.terminalID = try container.decode(String.self, forKey: .terminalID)
        self.agentStatus = try container.decode(HerdrAgentStatus.self, forKey: .agentStatus)
        self.workspaceID = try container.decode(String.self, forKey: .workspaceID)
        self.tabID = try container.decode(String.self, forKey: .tabID)
        self.paneID = try container.decode(String.self, forKey: .paneID)
        self.focused = try container.decode(Bool.self, forKey: .focused)
        self.revision = try container.decode(Int.self, forKey: .revision)
        self.agent = try container.decodeIfPresent(String.self, forKey: .agent)
        self.agentSession = try container.decodeIfPresent(HerdrAgentSessionInfo.self, forKey: .agentSession)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
        self.foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
        self.terminalTitleStripped = try container.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.interactiveReady = try container.decodeIfPresent(Bool.self, forKey: .interactiveReady)
        self.launchPending = try container.decodeIfPresent(Bool.self, forKey: .launchPending)
        self.screenDetectionSkipped = try container.decodeIfPresent(Bool.self, forKey: .screenDetectionSkipped)
        self.stateChangeSeq = try container.decodeIfPresent(Int.self, forKey: .stateChangeSeq)
        self.stateLabels = try container.decodeIfPresent([String: String].self, forKey: .stateLabels)
        self.tokens = try container.decodeIfPresent([String: String].self, forKey: .tokens)
    }
}

// MARK: - HerdrPaneScrollInfo

/// `PaneScrollInfo` in the schema -- EVERY field required. Left as
/// plain compiler-synthesized `Decodable` (a `CodingKeys` enum for the
/// snake_case renames, nothing more) -- see this file's header.
struct HerdrPaneScrollInfo: Sendable, Equatable, Decodable {
    let offsetFromBottom: Int
    let maxOffsetFromBottom: Int
    let viewportRows: Int

    private enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }
}

// MARK: - HerdrPaneRecord

/// One row of `snapshot.panes[]`. `PaneInfo` in the schema (see this
/// file's header) -- the SAME 7 required fields as `HerdrAgentRecord`,
/// plus 10 optional fields in common, but NOT the same field set as
/// `HerdrAgentRecord` overall: `label`/`scroll` exist only here;
/// `interactive_ready`/`launch_pending`/`name`/
/// `screen_detection_skipped`/`state_change_seq` exist only on
/// `HerdrAgentRecord`. See this file's header for the full comparison
/// and for why this stays a separate flat type rather than sharing a
/// base with `HerdrAgentRecord`.
struct HerdrPaneRecord: Sendable, Equatable {
    // Required.
    let terminalID: String
    let agentStatus: HerdrAgentStatus
    let workspaceID: String
    let tabID: String
    let paneID: String
    let focused: Bool
    let revision: Int

    // Optional; may be absent OR explicit JSON `null`.
    let agent: String?
    let agentSession: HerdrAgentSessionInfo?
    let cwd: String?
    let displayAgent: String?
    let foregroundCwd: String?
    let label: String?
    let scroll: HerdrPaneScrollInfo?
    let terminalTitle: String?
    let terminalTitleStripped: String?
    let title: String?

    // Optional; may ONLY be absent -- never explicit JSON `null` (see
    // this file's header).
    let stateLabels: [String: String]?
    let tokens: [String: String]?
}

extension HerdrPaneRecord: Decodable {
    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case agentStatus = "agent_status"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case paneID = "pane_id"
        case focused
        case revision
        case agent
        case agentSession = "agent_session"
        case cwd
        case displayAgent = "display_agent"
        case foregroundCwd = "foreground_cwd"
        case label
        case scroll
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case title
        case stateLabels = "state_labels"
        case tokens
    }

    init(from decoder: any Decoder) throws {
        // Same required/optional decode strategy as
        // `HerdrAgentRecord.init(from:)` above; see that type's own
        // comment -- this type's field SET differs (see this type's own
        // doc comment), but the decode STRATEGY per field does not.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.terminalID = try container.decode(String.self, forKey: .terminalID)
        self.agentStatus = try container.decode(HerdrAgentStatus.self, forKey: .agentStatus)
        self.workspaceID = try container.decode(String.self, forKey: .workspaceID)
        self.tabID = try container.decode(String.self, forKey: .tabID)
        self.paneID = try container.decode(String.self, forKey: .paneID)
        self.focused = try container.decode(Bool.self, forKey: .focused)
        self.revision = try container.decode(Int.self, forKey: .revision)
        self.agent = try container.decodeIfPresent(String.self, forKey: .agent)
        self.agentSession = try container.decodeIfPresent(HerdrAgentSessionInfo.self, forKey: .agentSession)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.displayAgent = try container.decodeIfPresent(String.self, forKey: .displayAgent)
        self.foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.scroll = try container.decodeIfPresent(HerdrPaneScrollInfo.self, forKey: .scroll)
        self.terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
        self.terminalTitleStripped = try container.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.stateLabels = try container.decodeIfPresent([String: String].self, forKey: .stateLabels)
        self.tokens = try container.decodeIfPresent([String: String].self, forKey: .tokens)
    }
}

// MARK: - HerdrPaneAgentStatusChangedEvent

/// Payload of the dot-notation `pane.agent_status_changed` event --
/// `subscription_event.$defs.PaneAgentStatusChangedEvent` in the schema
/// (see this file's header) --
/// {"event":"pane.agent_status_changed","data":{"pane_id":"w9:p1",
/// "workspace_id":"w9","agent_status":"working","agent":"claude",
/// "display_agent":null,"title":null,"state_labels":{...}}}.
/// `paneID`/`workspaceID`/`agentStatus` are REQUIRED. `agent`/
/// `displayAgent`/`title` are optional AND nullable (`["string","null"]`
/// on the wire). `stateLabels` is optional but NEVER null (a bare
/// `"type":"object"`, `additionalProperties: string`) -- hence
/// `[String: String]?`, not `AnyCodable?`: the schema now states this
/// shape outright, so there is no more "not part of what was measured"
/// uncertainty to hedge with a type-erased value.
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
    let stateLabels: [String: String]?

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

// MARK: - HerdrSessionSnapshot

/// `session.snapshot`'s decoded `snapshot` object -- `SessionSnapshot`
/// in the schema (see this file's header). Moved here from
/// HerdrConnection.swift, which keeps only the RPC envelope types that
/// unwrap this shape (`HerdrSnapshotRPCResult`) -- this type itself is a
/// wire SHAPE, not connection plumbing.
///
/// `version`, `protocolVersion` (wire key "protocol"), `workspaces`,
/// `tabs`, `panes`, `layouts`, `agents` are ALL required -- a
/// `session.snapshot` response missing any of them is a genuinely
/// exceptional response worth surfacing as a decode error, not silently
/// degrading (see this file's header for what the previous version of
/// this type got wrong here). `panes`/`agents` are strongly typed
/// (`HerdrPaneRecord`/`HerdrAgentRecord`); `workspaces`/`tabs`/`layouts`
/// stay `[AnyCodable]` -- see this file's header for why their element
/// shapes are out of scope for this pass. Only `focusedWorkspaceID`/
/// `focusedTabID`/`focusedPaneID` are optional, and nullable.
struct HerdrSessionSnapshot: Sendable, Equatable {
    // Required.
    let version: String
    let protocolVersion: Int
    let workspaces: [AnyCodable]
    let tabs: [AnyCodable]
    let panes: [HerdrPaneRecord]
    let layouts: [AnyCodable]
    let agents: [HerdrAgentRecord]

    // Optional; may be absent OR explicit JSON `null`.
    let focusedWorkspaceID: String?
    let focusedTabID: String?
    let focusedPaneID: String?
}

extension HerdrSessionSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case workspaces
        case tabs
        case panes
        case layouts
        case agents
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        self.workspaces = try container.decode([AnyCodable].self, forKey: .workspaces)
        self.tabs = try container.decode([AnyCodable].self, forKey: .tabs)
        self.panes = try container.decode([HerdrPaneRecord].self, forKey: .panes)
        self.layouts = try container.decode([AnyCodable].self, forKey: .layouts)
        self.agents = try container.decode([HerdrAgentRecord].self, forKey: .agents)
        self.focusedWorkspaceID = try container.decodeIfPresent(String.self, forKey: .focusedWorkspaceID)
        self.focusedTabID = try container.decodeIfPresent(String.self, forKey: .focusedTabID)
        self.focusedPaneID = try container.decodeIfPresent(String.self, forKey: .focusedPaneID)
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
