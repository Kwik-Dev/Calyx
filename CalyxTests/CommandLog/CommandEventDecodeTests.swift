//
//  CommandEventDecodeTests.swift
//  CalyxTests
//
//  TDD Red Phase for CommandEvent.decode(from:): the shell integration's
//  command-lifecycle JSON payload (snake_case, base64-encoded free-text
//  fields) decoding, mirroring AgentEventTests' coverage shape for
//  AgentEvent.decode(from:).
//
//  Coverage:
//  - start / end payloads populate the expected fields
//  - phase and cmd_id are mandatory; an unrecognized phase is rejected
//  - a start event without command_b64 is rejected
//  - invalid base64 in command_b64 / cwd_b64 rejects the whole event
//  - malformed / non-JSON input is rejected
//  - unknown/extra fields are tolerated
//  - base64 round-trip preserves multiline text, quotes, backslashes,
//    emoji, and Japanese text exactly
//

import XCTest
@testable import Calyx

final class CommandEventDecodeTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func b64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    // MARK: - Happy path

    func test_decode_start_populatesCommandCwdAndTimestamp() throws {
        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls -la"))",
            "cwd_b64": "\(b64("/Users/dev/repo"))",
            "ts": 1700000000000
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.phase, .start)
        XCTAssertEqual(event.cmdID, "abc-123")
        XCTAssertEqual(event.command, "ls -la")
        XCTAssertEqual(event.cwd, "/Users/dev/repo")
        XCTAssertEqual(event.ts, Date(timeIntervalSince1970: 1_700_000_000),
                       "ts must decode as epoch milliseconds, not epoch seconds")
    }

    func test_decode_end_requiresOnlyCmdIDPlusOptionalExitCode() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.phase, .end)
        XCTAssertEqual(event.cmdID, "abc-123")
        XCTAssertNil(event.command, "An end event carries no command_b64")
        XCTAssertNil(event.cwd, "An end event carries no cwd_b64")
        XCTAssertNil(event.exitCode, "exit_code is optional on an end event")
    }

    func test_decode_end_withExitCode_populatesExitCode() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 127 }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.exitCode, 127)
    }

    func test_decode_extraFields_areTolerated() throws {
        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls"))",
            "an_unknown_future_field": {"nested": [1, 2, 3]},
            "another_unknown_field": true
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.cmdID, "abc-123")
    }

    // MARK: - Rejection

    func test_decode_missingPhase_returnsNil() {
        // Sanity: a well-formed payload for the same fields must decode,
        // proving the rejection below is caused by the missing key and
        // not some other defect.
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "phase is mandatory")
    }

    func test_decode_unknownPhase_returnsNil() {
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "phase": "middle", "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "An unrecognized phase value must be rejected")
    }

    func test_decode_missingCmdID_returnsNil() {
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "phase": "end" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "cmd_id is mandatory")
    }

    func test_decode_startWithoutCommandB64_returnsNil() {
        let validData = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64("ls"))" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed start payload must decode")

        let data = json("""
        { "phase": "start", "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "A start event without command_b64 must be rejected")
    }

    func test_decode_invalidBase64InCommandB64_returnsNil() {
        let validData = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64("ls"))" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed start payload must decode")

        let data = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "not-valid-base64!!!" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "Invalid base64 in command_b64 must reject the whole event")
    }

    func test_decode_invalidBase64InCwdB64_returnsNil() {
        let validData = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls"))",
            "cwd_b64": "\(b64("/tmp"))"
        }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed start payload with cwd_b64 must decode")

        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls"))",
            "cwd_b64": "not-valid-base64!!!"
        }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "Invalid base64 in cwd_b64 must reject the whole event")
    }

    func test_decode_malformedJSON_returnsNil() {
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("this is not { json")
        XCTAssertNil(CommandEvent.decode(from: data), "Malformed / non-JSON input must be rejected")
    }

    // MARK: - Base64 round-trip

    func test_decode_base64RoundTrip_multilineCommandPreserved() throws {
        let command = "echo hello\ndone\nexit 0"
        let data = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64(command))" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.command, command, "A multiline command must round-trip through base64 exactly")
    }

    func test_decode_base64RoundTrip_quotesAndBackslashesPreserved() throws {
        let command = #"echo "hello" 'world' C:\Users\dev\repo \\ done"#
        let data = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64(command))" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.command, command,
                       "Single/double quotes and backslashes must round-trip through base64 exactly")
    }

    func test_decode_base64RoundTrip_emojiAndJapaneseTextPreserved() throws {
        let command = "echo 日本語テスト 🎉🚀 完了"
        let cwd = "/Users/開発者/プロジェクト"
        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64(command))",
            "cwd_b64": "\(b64(cwd))"
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.command, command, "Emoji and Japanese text in command_b64 must round-trip exactly")
        XCTAssertEqual(event.cwd, cwd, "Japanese text in cwd_b64 must round-trip exactly")
    }

    // MARK: - ts plausibility

    func test_decode_tsBelowPlausibleMillisThreshold_treatedAsAbsent() throws {
        // 1700000000 looks like an epoch-SECONDS value (a plausible
        // off-by-1000 shell-integration bug), not milliseconds -- far
        // below the plausible-epoch-milliseconds threshold, and would
        // otherwise decode into a bogus early-1970s Date.
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "ts": 1700000000 }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertNil(event.ts, "A ts value implausibly small to be epoch milliseconds must decode as absent")
    }

    func test_decode_tsAboveMaximumPlausibleMillisThreshold_treatedAsAbsent() throws {
        // A wildly-implausible far-future ts -- e.g. corrupted input --
        // must not decode into a bogus Date millennia from now, which
        // would otherwise let a multi-billion-year elapsed gap reach
        // CommandLogStore.finalize's duration derivation.
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "ts": 99999999999999999 }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertNil(event.ts, "A ts value implausibly large to be a real epoch-millisecond timestamp must decode as absent")
    }

    // MARK: - Type confusion

    func test_decode_phaseAsNumber_returnsNil() {
        let data = json("""
        { "phase": 133, "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "A non-string phase must be rejected, not crash")
    }

    func test_decode_cmdIDAsObject_returnsNil() {
        let data = json("""
        { "phase": "end", "cmd_id": {"a": 1} }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "A non-string cmd_id must be rejected, not crash")
    }

    func test_decode_exitCodeAsString_decodesWithExitCodeAbsent() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": "0" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data),
                                  "exit_code is optional -- a wrong-typed value must not fail the whole decode")

        XCTAssertNil(event.exitCode, "A string exit_code must not be coerced -- it decodes as absent")
    }

    func test_decode_tsAsString_decodesWithTsAbsent() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "ts": "1700000000000" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data),
                                  "ts is optional -- a wrong-typed value must not fail the whole decode")

        XCTAssertNil(event.ts, "A string ts must not be coerced -- it decodes as absent")
    }

    // MARK: - suspended flag (pane-exit suspend signal)
    //
    // fish's own $status inside fish_postexec cannot distinguish a
    // Ctrl-Z suspend from the previous command's real exit code, so the
    // shell integration reports a suspend through this separate boolean
    // instead of overloading exit_code. The tests below pin the decoded
    // value of `suspended` itself, in addition to confirming its
    // presence never disturbs an unrelated field's own decode. The
    // flag's behavioral effect -- how AgentRegistry's settle decision
    // treats it -- is pinned separately in CalyxMCPServerCommandEventTests.
    //
    // Plain JSON booleans are already pinned by
    // test_decode_end_suspendedTrue_doesNotDisturbExistingFields (true)
    // and test_decode_end_suspendedFalseAndSuspendedOmitted_bothDecodeFalse
    // (false); the tests below cover the remaining wrong-type and
    // edge-value shapes those two don't.

    func test_decode_end_suspendedTrue_doesNotDisturbExistingFields() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 0, "suspended": true }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.phase, .end)
        XCTAssertEqual(event.cmdID, "abc-123")
        XCTAssertEqual(event.exitCode, 0, "suspended's presence must not alter an unrelated field's own decode")
        XCTAssertEqual(event.suspended, true, "An explicit suspended:true must decode to true")
    }

    func test_decode_end_suspendedFalseAndSuspendedOmitted_bothDecodeFalse() throws {
        // The production fish integration should OMIT this key entirely
        // when nothing is stopped, appending it only inside the branch
        // that already detects a stopped job -- mirroring cwd_b64's and
        // ts's own optional-field shape in this same decoder, and
        // simpler for the shell script to construct than an
        // unconditional field carrying a default value. Decode must
        // tolerate an explicit "suspended": false regardless: a lenient
        // decoder must not depend on which of the two shapes the sender
        // chose.
        let omittedData = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 0 }
        """)
        let falseData = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 0, "suspended": false }
        """)

        let omittedEvent = try XCTUnwrap(CommandEvent.decode(from: omittedData))
        let falseEvent = try XCTUnwrap(CommandEvent.decode(from: falseData))

        XCTAssertEqual(omittedEvent.suspended, false, "An absent suspended key must decode to false")
        XCTAssertEqual(falseEvent.suspended, false, "An explicit suspended:false must decode to false")
        XCTAssertEqual(omittedEvent.exitCode, 0)
        XCTAssertEqual(falseEvent.exitCode, 0)
    }

    func test_decode_suspendedNumeric_zeroAndOneBridgeToBool_otherNumbersDecodeFalse() throws {
        // JSONSerialization represents a JSON number as NSNumber, and
        // Foundation's `NSNumber as? Bool` cast succeeds only when the
        // number's value is exactly 0 or 1, bridging to false and true
        // respectively; any other number fails that cast and falls
        // through to the decoder's own `?? false` fallback -- the same
        // fallback a wrong-typed string exercises (see
        // test_decode_suspendedString_decodesFalseRatherThanFailing
        // below). This {0, 1} window is Foundation's own NSNumber
        // bridging behavior, not something CommandEvent.decode itself
        // implements: decode makes no distinction between 1 and 2 of
        // its own; only the cast's own success or failure does.
        let oneData = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 0, "suspended": 1 }
        """)
        let zeroData = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 0, "suspended": 0 }
        """)
        let twoData = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 0, "suspended": 2 }
        """)

        let oneEvent = try XCTUnwrap(CommandEvent.decode(from: oneData),
                                     "suspended is optional -- a numeric value must not fail the whole decode")
        let zeroEvent = try XCTUnwrap(CommandEvent.decode(from: zeroData),
                                      "suspended is optional -- a numeric value must not fail the whole decode")
        let twoEvent = try XCTUnwrap(CommandEvent.decode(from: twoData),
                                     "suspended is optional -- a numeric value must not fail the whole decode")

        XCTAssertEqual(oneEvent.suspended, true, "A numeric 1 bridges to Bool true via NSNumber")
        XCTAssertEqual(zeroEvent.suspended, false, "A numeric 0 bridges to Bool false via NSNumber")
        XCTAssertEqual(twoEvent.suspended, false, "A number outside the {0, 1} bridging window decodes as false")

        XCTAssertEqual(oneEvent.exitCode, 0, "suspended's presence must not alter an unrelated field's own decode")
        XCTAssertEqual(zeroEvent.exitCode, 0, "suspended's presence must not alter an unrelated field's own decode")
        XCTAssertEqual(twoEvent.exitCode, 0, "suspended's presence must not alter an unrelated field's own decode")
    }

    func test_decode_suspendedString_decodesFalseRatherThanFailing() throws {
        // A JSON string has no NSNumber-to-Bool bridge to fall into
        // (contrast the numeric cases in
        // test_decode_suspendedNumeric_zeroAndOneBridgeToBool_otherNumbersDecodeFalse
        // above), so it exercises the decoder's own wrong-type
        // fallback directly -- the same `?? false` fallback exit_code
        // uses for its own wrong-typed value (see
        // test_decode_exitCodeAsString_decodesWithExitCodeAbsent
        // above).
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 0, "suspended": "true" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data),
                                  "suspended is optional -- a wrong-typed value must not fail the whole decode")

        XCTAssertEqual(event.suspended, false, "A string suspended must not be coerced -- it decodes as false")
        XCTAssertEqual(event.exitCode, 0, "suspended's presence must not alter an unrelated field's own decode")
    }

    func test_decode_suspendedTrue_alongsideUnrelatedUnknownField_stillTolerated() throws {
        let data = json("""
        {
            "phase": "end",
            "cmd_id": "abc-123",
            "exit_code": 0,
            "suspended": true,
            "an_unknown_future_field": {"nested": [1, 2, 3]}
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.cmdID, "abc-123")
        XCTAssertEqual(event.exitCode, 0)
        XCTAssertEqual(event.suspended, true)
    }

    func test_decode_startPhase_suspendedKeyStillDecodesRegardlessOfPhase() throws {
        // decode computes `suspended` unconditionally -- it applies no
        // phase check of its own -- so a start payload carrying the key
        // decodes it exactly as an end payload would. Pinned as
        // observed, not as a phase restriction the code does not
        // implement.
        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls"))",
            "suspended": true
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.phase, .start)
        XCTAssertEqual(event.suspended, true)
    }
}
