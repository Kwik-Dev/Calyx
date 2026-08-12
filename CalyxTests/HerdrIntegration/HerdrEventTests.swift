//
//  HerdrEventTests.swift
//  CalyxTests
//
//  Tests for HerdrEvent.swift: HerdrAgentStatus, HerdrPaneID,
//  HerdrAgentRecord, and HerdrEvent's dual-envelope decoding. See that
//  file's own header for the exact measured wire shapes these tests
//  are derived from.
//
//  Coverage:
//  - HerdrAgentStatus: all five known wire values decode to their
//    matching case; an unrecognised string decodes to
//    .unrecognized(<original string>), never throwing
//  - HerdrPaneID: a valid "w9:p1" parses into workspace/local parts;
//    malformed input (empty string, no colon, empty workspace part,
//    empty local part) is rejected (nil)
//  - HerdrAgentRecord: every measured field decodes correctly from the
//    exact wire example in HerdrEvent.swift's header
//  - HerdrEvent decodes the snake_case envelope (pane_created) into
//    .paneCreated, carrying a correctly-decoded HerdrPaneRecord
//  - HerdrEvent decodes the dot-notation envelope
//    (pane.agent_status_changed) into .paneAgentStatusChanged, with
//    required fields (pane_id/workspace_id/agent_status) and optional
//    fields (agent/display_agent) both correct
//  - B1: HerdrEvent decodes "pane_closed"/"pane_exited" into
//    .paneClosed(paneID:)/.paneExited(paneID:), reading the pane id from
//    EITHER the nested `data.pane.pane_id` shape (covered via
//    "pane_closed") OR the flat `data.pane_id` shape (covered via
//    "pane_exited") -- see HerdrEvent.swift's own header "B1 rule" for
//    the exact precedence -- and falls back to .unknown(eventType:),
//    preserving the original type string, for a "data" object present
//    but with no pane id in either location, rather than throwing
//  - HerdrEvent decodes "workspace_closed" into
//    .workspaceClosed(workspaceID:) from a schema-minimal payload
//    (only "type"/"workspace_id" on "data"), from the full shape
//    measured live against a real herdr 0.8.0 server (a nested
//    "workspace" object present but ignored -- not modeled), and with
//    "workspace" as explicit JSON null; and THROWS (unlike B1's
//    tolerant fallback above) when the schema-required "workspace_id"
//    is missing
//  - HerdrEvent tolerates an unrecognised event TYPE string, decoding
//    to .unknown(eventType:) with the ORIGINAL string preserved,
//    rather than throwing
//  - HerdrEvent tolerates unknown/extra JSON fields anywhere in the
//    envelope (both top-level and inside the nested pane record)
//    without throwing, and without corrupting the fields it DOES know
//    about
//  - HerdrEvent throws a real DecodingError for a line that isn't even
//    a recognisable envelope (missing the required "event" key); see
//    this file's own comment on it below
//  - Structural guards (schema required/optional contract): for
//    HerdrPaneRecord, HerdrAgentRecord, HerdrSessionSnapshot,
//    HerdrAgentSessionInfo, HerdrPaneScrollInfo, and
//    HerdrPaneAgentStatusChangedEvent, a payload containing ONLY the
//    schema's required fields decodes successfully with every optional
//    property nil; and, where the type has nullable-typed optionals, the
//    same payload with those fields present as explicit JSON `null`
//    (never the optional-but-non-nullable ones -- see
//    HerdrEvent.swift's own header) also decodes successfully with the
//    same nil result. This is the regression pin for the exact defect
//    class that shipped three times: a Swift property that should have
//    been optional (per the schema's own `required` list) instead
//    required, so a legal minimal server payload failed to decode.
//

import XCTest
@testable import Calyx

final class HerdrEventTests: XCTestCase {

    // MARK: - HerdrAgentStatus

    func test_agentStatus_decodesAllFiveKnownWireValues() throws {
        let cases: [(wire: String, expected: HerdrAgentStatus)] = [
            ("idle", .idle),
            ("working", .working),
            ("blocked", .blocked),
            ("done", .done),
            ("unknown", .unknown),
        ]
        for testCase in cases {
            let json = Data(#""\#(testCase.wire)""#.utf8)
            let decoded = try JSONDecoder().decode(HerdrAgentStatus.self, from: json)
            XCTAssertEqual(decoded, testCase.expected, "expected \(testCase.wire.debugDescription) to decode to \(testCase.expected)")
        }
    }

    func test_agentStatus_unrecognisedString_decodesToUnrecognizedCase_preservingOriginalString_withoutThrowing() throws {
        let json = Data(#""future_status_v2""#.utf8)

        let decoded = try JSONDecoder().decode(HerdrAgentStatus.self, from: json)

        XCTAssertEqual(decoded, .unrecognized("future_status_v2"))
    }

    // MARK: - HerdrPaneID

    func test_paneID_parsesValidWorkspaceAndLocalParts() throws {
        let parsed = try XCTUnwrap(HerdrPaneID(parsing: "w9:p1"))

        XCTAssertEqual(parsed.workspaceID, "w9")
        XCTAssertEqual(parsed.localID, "p1")
    }

    func test_paneID_rejectsMalformedInput() {
        let malformedValues = ["", "w9p1", ":p1", "w9:"]
        for malformed in malformedValues {
            XCTAssertNil(HerdrPaneID(parsing: malformed), "expected nil for malformed pane id \(malformed.debugDescription)")
        }
    }

    // MARK: - HerdrAgentRecord

    func test_agentRecord_decodesEveryMeasuredField() throws {
        let json = Data(#"""
        {"terminal_id":"term_658b1a46d5aba9","agent":"claude","agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":false,"state_change_seq":5,"cwd":"/Users/eguchiyuuichi","foreground_cwd":"/Users/eguchiyuuichi","revision":0}
        """#.utf8)

        let record = try JSONDecoder().decode(HerdrAgentRecord.self, from: json)

        XCTAssertEqual(record.terminalID, "term_658b1a46d5aba9")
        XCTAssertEqual(record.agent, "claude")
        XCTAssertEqual(record.agentStatus, .blocked)
        XCTAssertEqual(record.workspaceID, "w9")
        XCTAssertEqual(record.tabID, "w9:t1")
        XCTAssertEqual(record.paneID, "w9:p1")
        XCTAssertFalse(record.focused)
        XCTAssertEqual(record.stateChangeSeq, 5)
        XCTAssertEqual(record.cwd, "/Users/eguchiyuuichi")
        XCTAssertEqual(record.foregroundCwd, "/Users/eguchiyuuichi")
        XCTAssertEqual(record.revision, 0)
    }

    // MARK: - HerdrEvent: snake_case envelope

    func test_decode_snakeCaseEnvelope_paneCreated_decodesNestedPaneRecord() throws {
        let json = Data(#"""
        {"data":{"pane":{"terminal_id":"term_1","agent":"claude","agent_status":"working","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":true,"cwd":"/Users/dev","foreground_cwd":"/Users/dev","revision":2},"type":"pane_created"},"event":"pane_created"}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        guard case .paneCreated(let pane) = event else {
            XCTFail("expected .paneCreated, got \(event)")
            return
        }
        XCTAssertEqual(pane.paneID, "w9:p1")
        XCTAssertEqual(pane.terminalID, "term_1")
        XCTAssertEqual(pane.agentStatus, .working)
        XCTAssertTrue(pane.focused)
        XCTAssertEqual(pane.revision, 2)
    }

    // MARK: - HerdrEvent: dot-notation envelope

    func test_decode_dotNotationEnvelope_paneAgentStatusChanged_decodesRequiredAndOptionalFields() throws {
        let json = Data(#"""
        {"event":"pane.agent_status_changed","data":{"pane_id":"w9:p1","workspace_id":"w9","agent_status":"working","agent":"claude","display_agent":null,"title":null,"state_labels":{"blocked":"Waiting"}}}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        guard case .paneAgentStatusChanged(let changed) = event else {
            XCTFail("expected .paneAgentStatusChanged, got \(event)")
            return
        }
        XCTAssertEqual(changed.paneID, "w9:p1")
        XCTAssertEqual(changed.workspaceID, "w9")
        XCTAssertEqual(changed.agentStatus, .working)
        XCTAssertEqual(changed.agent, "claude")
        XCTAssertNil(changed.displayAgent)
        XCTAssertNil(changed.title)
    }

    // MARK: - HerdrEvent: paneClosed / paneExited (B1)

    /// Nested shape: `data.pane.pane_id` -- mirrors "pane_created"'s own
    /// nested `pane` object. Also covers "pane_closed".
    func test_decode_paneClosed_nestedPaneIDShape_decodesPaneID() throws {
        let json = Data(#"""
        {"event":"pane_closed","data":{"pane":{"pane_id":"w9:p1"},"type":"pane_closed"}}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        XCTAssertEqual(event, .paneClosed(paneID: "w9:p1"))
    }

    /// Flat shape: `data.pane_id` directly, no nested `pane` object.
    /// Also covers "pane_exited".
    func test_decode_paneExited_flatPaneIDShape_decodesPaneID() throws {
        let json = Data(#"""
        {"event":"pane_exited","data":{"pane_id":"w9:p2"}}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        XCTAssertEqual(event, .paneExited(paneID: "w9:p2"))
    }

    /// Malformed: a "data" object present, but with no "pane_id" in
    /// either the nested `pane` location or flat -- per this stage's own
    /// instructions (and HerdrEvent.swift's header "B1 rule"), this
    /// falls back to `.unknown(eventType:)`, preserving the ORIGINAL
    /// event type string, rather than throwing.
    func test_decode_paneClosed_malformedEnvelopeLackingAnyPaneID_decodesToUnknown_preservingOriginalEventTypeString() throws {
        let json = Data(#"""
        {"event":"pane_closed","data":{"workspace_id":"w9"}}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        XCTAssertEqual(event, .unknown(eventType: "pane_closed"))
    }

    // MARK: - HerdrEvent: workspaceClosed

    /// Schema-minimal payload: only "type" and "workspace_id" on "data"
    /// (`event.$defs.EventData`'s "workspace_closed" variant's own
    /// `required` list, `herdr api schema --json`) -- the nested
    /// "workspace" object is optional and not modeled at all
    /// (HerdrEvent.swift's own header), so it is deliberately absent
    /// here.
    func test_decode_workspaceClosed_minimalRequiredFieldsOnlyPayload_decodesWorkspaceID() throws {
        let json = Data(#"""
        {"event":"workspace_closed","data":{"type":"workspace_closed","workspace_id":"w9"}}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        XCTAssertEqual(event, .workspaceClosed(workspaceID: "w9"))
    }

    /// The full shape measured live against a real herdr 0.8.0 server
    /// (`herdr workspace close <id>`, subscribed to "workspace.closed")
    /// -- corroborates the minimal-payload test above: the nested
    /// "workspace" object is present but still ignored.
    func test_decode_workspaceClosed_fullMeasuredShape_decodesWorkspaceID() throws {
        let json = Data(#"""
        {"data":{"type":"workspace_closed","workspace":{"active_tab_id":"w5:t1","agent_status":"unknown","focused":true,"label":"spike","number":1,"pane_count":1,"tab_count":1,"workspace_id":"w5"},"workspace_id":"w5"},"event":"workspace_closed"}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        XCTAssertEqual(event, .workspaceClosed(workspaceID: "w5"))
    }

    /// "workspace" as explicit JSON `null` (the schema's own
    /// "anyOf":[WorkspaceInfo,null]) must decode identically to it being
    /// absent entirely -- it is not modeled either way.
    func test_decode_workspaceClosed_explicitNullWorkspace_stillDecodesWorkspaceID() throws {
        let json = Data(#"""
        {"event":"workspace_closed","data":{"type":"workspace_closed","workspace":null,"workspace_id":"w9"}}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        XCTAssertEqual(event, .workspaceClosed(workspaceID: "w9"))
    }

    /// Unlike B1's tolerant "pane_closed"/"pane_exited" fallback above, a
    /// "workspace_closed" envelope missing the schema-REQUIRED
    /// "workspace_id" THROWS -- this file's own default decode-error
    /// contract (see this file's own header), deliberately not extended
    /// to this event the way B1 was.
    func test_decode_workspaceClosed_missingWorkspaceID_throwsDecodingError() {
        let json = Data(#"{"event":"workspace_closed","data":{"type":"workspace_closed"}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(HerdrEvent.self, from: json))
    }

    // MARK: - HerdrEvent: unknown event type tolerated

    func test_decode_unrecognisedEventType_decodesToUnknownCase_preservingOriginalTypeString() throws {
        let json = Data(#"""
        {"event":"totally_made_up_future_event","data":{"whatever":123}}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        XCTAssertEqual(event, .unknown(eventType: "totally_made_up_future_event"))
    }

    // MARK: - HerdrEvent: unknown extra fields tolerated

    func test_decode_unknownExtraFields_tolerated_atEnvelopeLevelAndInsideNestedPaneRecord() throws {
        let json = Data(#"""
        {"server_time":999,"data":{"pane":{"terminal_id":"term_1","agent":"claude","agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":false,"cwd":"/Users/dev","foreground_cwd":"/Users/dev","revision":0,"scroll_offset":42,"scroll_at_bottom":true},"type":"pane_created","extra_data_field":"ignored"},"event":"pane_created"}
        """#.utf8)

        let event = try JSONDecoder().decode(HerdrEvent.self, from: json)

        guard case .paneCreated(let pane) = event else {
            XCTFail("expected .paneCreated even with unknown extra fields present, got \(event)")
            return
        }
        XCTAssertEqual(pane.paneID, "w9:p1")
        XCTAssertEqual(pane.agentStatus, .blocked)
    }

    // MARK: - HerdrEvent: malformed envelope throws (decode error)

    /// A line missing the required "event" key entirely is not a
    /// recognisable envelope at all, and decoding it must throw rather
    /// than silently succeed: reading a required top-level key via
    /// `container.decode` (as opposed to `decodeIfPresent`) throws
    /// `DecodingError.keyNotFound` as an inherent property of
    /// `HerdrEvent.init(from:)`. It remains a real, valuable regression
    /// pin -- it would fail if a future change swapped that `decode`
    /// for a lenient `decodeIfPresent`.
    func test_decode_missingEventKey_throwsDecodingError() {
        let json = Data(#"{"data":{"foo":"bar"}}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(HerdrEvent.self, from: json))
    }

    // MARK: - Structural guards: HerdrPaneRecord (PaneInfo)

    /// The regression pin for this stage's whole reason to exist: a
    /// payload carrying ONLY `PaneInfo`'s 7 schema-required fields must
    /// decode successfully, with every one of the other 12 (optional)
    /// properties `nil`.
    func test_paneRecord_decodesMinimalRequiredOnlyPayload_withEveryOptionalNil() throws {
        let json = Data(#"""
        {"pane_id":"w9:p1","terminal_id":"term_1","workspace_id":"w9","tab_id":"w9:t1","focused":true,"agent_status":"working","revision":0}
        """#.utf8)

        let pane = try JSONDecoder().decode(HerdrPaneRecord.self, from: json)

        XCTAssertEqual(pane.paneID, "w9:p1")
        XCTAssertEqual(pane.terminalID, "term_1")
        XCTAssertEqual(pane.workspaceID, "w9")
        XCTAssertEqual(pane.tabID, "w9:t1")
        XCTAssertTrue(pane.focused)
        XCTAssertEqual(pane.agentStatus, .working)
        XCTAssertEqual(pane.revision, 0)
        XCTAssertNil(pane.agent)
        XCTAssertNil(pane.agentSession)
        XCTAssertNil(pane.cwd)
        XCTAssertNil(pane.displayAgent)
        XCTAssertNil(pane.foregroundCwd)
        XCTAssertNil(pane.label)
        XCTAssertNil(pane.scroll)
        XCTAssertNil(pane.terminalTitle)
        XCTAssertNil(pane.terminalTitleStripped)
        XCTAssertNil(pane.title)
        XCTAssertNil(pane.stateLabels)
        XCTAssertNil(pane.tokens)
    }

    /// Required fields plus an explicit JSON `null` for every one of
    /// `PaneInfo`'s NULLABLE optionals (`["string","null"]`/`anyOf`-
    /// with-null on the wire) -- `state_labels`/`tokens` are deliberately
    /// EXCLUDED here (bare `"type":"object"`, optional but never null;
    /// see HerdrEvent.swift's own header) -- decodes identically to the
    /// minimal payload above.
    func test_paneRecord_decodesRequiredPlusExplicitNullForNullableOptionals_asNil() throws {
        let json = Data(#"""
        {"pane_id":"w9:p1","terminal_id":"term_1","workspace_id":"w9","tab_id":"w9:t1","focused":true,"agent_status":"working","revision":0,"agent":null,"agent_session":null,"cwd":null,"display_agent":null,"foreground_cwd":null,"label":null,"scroll":null,"terminal_title":null,"terminal_title_stripped":null,"title":null}
        """#.utf8)

        let pane = try JSONDecoder().decode(HerdrPaneRecord.self, from: json)

        XCTAssertEqual(pane.paneID, "w9:p1")
        XCTAssertNil(pane.agent)
        XCTAssertNil(pane.agentSession)
        XCTAssertNil(pane.cwd)
        XCTAssertNil(pane.displayAgent)
        XCTAssertNil(pane.foregroundCwd)
        XCTAssertNil(pane.label)
        XCTAssertNil(pane.scroll)
        XCTAssertNil(pane.terminalTitle)
        XCTAssertNil(pane.terminalTitleStripped)
        XCTAssertNil(pane.title)
    }

    // MARK: - Structural guards: HerdrAgentRecord (AgentInfo)

    /// Same guard as `HerdrPaneRecord`'s above, for `AgentInfo`'s own 7
    /// required fields and 15 optional ones (`HerdrAgentRecord` has 8
    /// more optional properties than `HerdrPaneRecord`: `interactive_ready`/
    /// `launch_pending`/`name`/`screen_detection_skipped`/
    /// `state_change_seq` where `HerdrPaneRecord` has `label`/`scroll`
    /// instead -- see HerdrEvent.swift's own header).
    func test_agentRecord_decodesMinimalRequiredOnlyPayload_withEveryOptionalNil() throws {
        let json = Data(#"""
        {"terminal_id":"term_1","agent_status":"working","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":true,"revision":0}
        """#.utf8)

        let record = try JSONDecoder().decode(HerdrAgentRecord.self, from: json)

        XCTAssertEqual(record.terminalID, "term_1")
        XCTAssertEqual(record.agentStatus, .working)
        XCTAssertEqual(record.workspaceID, "w9")
        XCTAssertEqual(record.tabID, "w9:t1")
        XCTAssertEqual(record.paneID, "w9:p1")
        XCTAssertTrue(record.focused)
        XCTAssertEqual(record.revision, 0)
        XCTAssertNil(record.agent)
        XCTAssertNil(record.agentSession)
        XCTAssertNil(record.cwd)
        XCTAssertNil(record.displayAgent)
        XCTAssertNil(record.foregroundCwd)
        XCTAssertNil(record.name)
        XCTAssertNil(record.terminalTitle)
        XCTAssertNil(record.terminalTitleStripped)
        XCTAssertNil(record.title)
        XCTAssertNil(record.interactiveReady)
        XCTAssertNil(record.launchPending)
        XCTAssertNil(record.screenDetectionSkipped)
        XCTAssertNil(record.stateChangeSeq, "absent state_change_seq must decode to nil, never the schema's own \"default\": 0 -- see HerdrEvent.swift's header")
        XCTAssertNil(record.stateLabels)
        XCTAssertNil(record.tokens)
    }

    /// Required fields plus an explicit JSON `null` for every one of
    /// `AgentInfo`'s NULLABLE optionals -- `interactive_ready`/
    /// `launch_pending`/`screen_detection_skipped`/`state_change_seq`/
    /// `state_labels`/`tokens` are deliberately EXCLUDED (never null on
    /// this wire; see HerdrEvent.swift's own header).
    func test_agentRecord_decodesRequiredPlusExplicitNullForNullableOptionals_asNil() throws {
        let json = Data(#"""
        {"terminal_id":"term_1","agent_status":"working","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":true,"revision":0,"agent":null,"agent_session":null,"cwd":null,"display_agent":null,"foreground_cwd":null,"name":null,"terminal_title":null,"terminal_title_stripped":null,"title":null}
        """#.utf8)

        let record = try JSONDecoder().decode(HerdrAgentRecord.self, from: json)

        XCTAssertEqual(record.terminalID, "term_1")
        XCTAssertNil(record.agent)
        XCTAssertNil(record.agentSession)
        XCTAssertNil(record.cwd)
        XCTAssertNil(record.displayAgent)
        XCTAssertNil(record.foregroundCwd)
        XCTAssertNil(record.name)
        XCTAssertNil(record.terminalTitle)
        XCTAssertNil(record.terminalTitleStripped)
        XCTAssertNil(record.title)
    }

    // MARK: - Structural guards: HerdrSessionSnapshot (SessionSnapshot)

    /// All 7 of `SessionSnapshot`'s fields are required -- `version`/
    /// `protocol`/`workspaces`/`tabs`/`panes`/`layouts`/`agents` -- even
    /// though an empty array is a legal VALUE for the array-typed ones.
    /// Only `focused_workspace_id`/`focused_tab_id`/`focused_pane_id`
    /// are optional, and absent here.
    func test_sessionSnapshot_decodesMinimalRequiredOnlyPayload_withFocusedFieldsNil() throws {
        let json = Data(#"""
        {"version":"0.8.0","protocol":19,"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[]}
        """#.utf8)

        let snapshot = try JSONDecoder().decode(HerdrSessionSnapshot.self, from: json)

        XCTAssertEqual(snapshot.version, "0.8.0")
        XCTAssertEqual(snapshot.protocolVersion, 19)
        XCTAssertEqual(snapshot.workspaces.count, 0)
        XCTAssertEqual(snapshot.tabs.count, 0)
        XCTAssertEqual(snapshot.panes.count, 0)
        XCTAssertEqual(snapshot.layouts.count, 0)
        XCTAssertEqual(snapshot.agents.count, 0)
        XCTAssertNil(snapshot.focusedWorkspaceID)
        XCTAssertNil(snapshot.focusedTabID)
        XCTAssertNil(snapshot.focusedPaneID)
    }

    /// Required fields plus an explicit JSON `null` for all three
    /// `focused_*` fields (all nullable on the wire) -- decodes
    /// identically to the minimal payload above.
    func test_sessionSnapshot_decodesRequiredPlusExplicitNullForFocusedFields_asNil() throws {
        let json = Data(#"""
        {"version":"0.8.0","protocol":19,"workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[],"focused_workspace_id":null,"focused_tab_id":null,"focused_pane_id":null}
        """#.utf8)

        let snapshot = try JSONDecoder().decode(HerdrSessionSnapshot.self, from: json)

        XCTAssertNil(snapshot.focusedWorkspaceID)
        XCTAssertNil(snapshot.focusedTabID)
        XCTAssertNil(snapshot.focusedPaneID)
    }

    // MARK: - Structural guards: HerdrAgentSessionInfo (AgentSessionInfo)

    /// Every field of `AgentSessionInfo` is required -- there is no
    /// optional/nullable split to guard, so the "minimal" payload IS the
    /// full payload.
    func test_agentSessionInfo_decodesFullyRequiredPayload() throws {
        let json = Data(#"""
        {"source":"herdr:claude","agent":"claude","kind":"id","value":"session-value-1"}
        """#.utf8)

        let info = try JSONDecoder().decode(HerdrAgentSessionInfo.self, from: json)

        XCTAssertEqual(info.source, "herdr:claude")
        XCTAssertEqual(info.agent, "claude")
        XCTAssertEqual(info.kind, .id)
        XCTAssertEqual(info.value, "session-value-1")
    }

    /// `kind` tolerates a wire value outside the schema's current
    /// "id"/"path" enum -- see HerdrEvent.swift's own header for why
    /// `HerdrAgentSessionRefKind` mirrors `HerdrAgentStatus`'s own
    /// `.unrecognized(String)` precedent here.
    func test_agentSessionInfo_unrecognisedKind_decodesToUnrecognizedCase_withoutThrowing() throws {
        let json = Data(#"""
        {"source":"herdr:claude","agent":"claude","kind":"future_kind_v2","value":"session-value-1"}
        """#.utf8)

        let info = try JSONDecoder().decode(HerdrAgentSessionInfo.self, from: json)

        XCTAssertEqual(info.kind, .unrecognized("future_kind_v2"))
    }

    // MARK: - Structural guards: HerdrPaneScrollInfo (PaneScrollInfo)

    /// Every field of `PaneScrollInfo` is required -- there is no
    /// optional/nullable split to guard, so the "minimal" payload IS the
    /// full payload.
    func test_paneScrollInfo_decodesFullyRequiredPayload() throws {
        let json = Data(#"""
        {"offset_from_bottom":0,"max_offset_from_bottom":10,"viewport_rows":23}
        """#.utf8)

        let scroll = try JSONDecoder().decode(HerdrPaneScrollInfo.self, from: json)

        XCTAssertEqual(scroll.offsetFromBottom, 0)
        XCTAssertEqual(scroll.maxOffsetFromBottom, 10)
        XCTAssertEqual(scroll.viewportRows, 23)
    }

    // MARK: - Structural guards: HerdrPaneAgentStatusChangedEvent (subscription_event.PaneAgentStatusChangedEvent)

    /// A payload carrying ONLY `pane_id`/`workspace_id`/`agent_status`
    /// (the 3 schema-required fields) decodes successfully, with
    /// `agent`/`displayAgent`/`title`/`stateLabels` all `nil`.
    func test_paneAgentStatusChangedEvent_decodesMinimalRequiredOnlyPayload_withEveryOptionalNil() throws {
        let json = Data(#"""
        {"pane_id":"w9:p1","workspace_id":"w9","agent_status":"working"}
        """#.utf8)

        let changed = try JSONDecoder().decode(HerdrPaneAgentStatusChangedEvent.self, from: json)

        XCTAssertEqual(changed.paneID, "w9:p1")
        XCTAssertEqual(changed.workspaceID, "w9")
        XCTAssertEqual(changed.agentStatus, .working)
        XCTAssertNil(changed.agent)
        XCTAssertNil(changed.displayAgent)
        XCTAssertNil(changed.title)
        XCTAssertNil(changed.stateLabels)
    }

    /// Required fields plus an explicit JSON `null` for `agent`/
    /// `display_agent`/`title` (this event's only NULLABLE optionals --
    /// `state_labels` is deliberately EXCLUDED, a bare `"type":"object"`
    /// that is optional but never null on this wire).
    func test_paneAgentStatusChangedEvent_decodesRequiredPlusExplicitNullForNullableOptionals_asNil() throws {
        let json = Data(#"""
        {"pane_id":"w9:p1","workspace_id":"w9","agent_status":"working","agent":null,"display_agent":null,"title":null}
        """#.utf8)

        let changed = try JSONDecoder().decode(HerdrPaneAgentStatusChangedEvent.self, from: json)

        XCTAssertNil(changed.agent)
        XCTAssertNil(changed.displayAgent)
        XCTAssertNil(changed.title)
    }
}
