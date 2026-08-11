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
        {"data":{"pane":{"terminal_id":"term_1","agent":"claude","agent_status":"working","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":true,"state_change_seq":7,"cwd":"/Users/dev","foreground_cwd":"/Users/dev","revision":2},"type":"pane_created"},"event":"pane_created"}
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
        {"server_time":999,"data":{"pane":{"terminal_id":"term_1","agent":"claude","agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":false,"state_change_seq":5,"cwd":"/Users/dev","foreground_cwd":"/Users/dev","revision":0,"scroll_offset":42,"scroll_at_bottom":true},"type":"pane_created","extra_data_field":"ignored"},"event":"pane_created"}
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
}
