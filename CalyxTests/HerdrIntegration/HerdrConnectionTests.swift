//
//  HerdrConnectionTests.swift
//  CalyxTests
//
//  Coverage for `HerdrOneShotRequest` and `HerdrEventStream` -- the two
//  single-use connection types replacing `HerdrSocketSession`'s own
//  request/response + push-event multiplexing. See
//  HerdrConnection.swift's own header for the full measured wire
//  contract these are built from.
//
//  Every test below drives a real `InMemoryHerdrTransport` (never a stub)
//  through the real public API, so a test that reaches an assertion at
//  all is proof the type's actual wire plumbing works. Fixture response/
//  event lines are hand-built from the exact wire shapes measured against
//  a real herdr 0.8.0 server, matching HerdrEvent.swift's/
//  HerdrConnection.swift's own headers.
//
//  TEST-MECHANICS NOTE: `InMemoryHerdrTransport.simulateLine(_:)` can be
//  called BEFORE `HerdrOneShotRequest.send`/`HerdrEventStream.subscribe`
//  even connects -- `AsyncStream`'s own default UNBOUNDED buffering means
//  a line yielded early just sits buffered until the consumer starts
//  reading, so most tests below "pre-buffer" their fixture response and
//  call `send`/`subscribe` as a single, non-concurrent `try await`
//  expression -- deliberately avoiding `async let`/`Task { req.send() }`
//  wrapping a `HerdrOneShotRequest`/`HerdrEventStream` VALUE itself
//  (noncopyable values cannot be captured by an escaping closure, so
//  wrapping the CONSUMING call itself in a child task is a compile
//  error; a plain top-level `try await` is not). This trick does NOT
//  work for `simulateEOF`/`simulateFailure`: both flip
//  `InMemoryHerdrTransport` to closed, and `send` (used internally by
//  both types to write the OUTBOUND request/subscribe line) throws
//  `.alreadyClosed` against an already-closed transport -- pre-buffering
//  either would make the OUTBOUND send itself fail, never reaching the
//  "awaiting a response, got EOF/failure" path the test exists to pin.
//  The EOF/failure-before-answering tests below instead wrap the call in
//  a plain `Task { ... }` that captures only the (Copyable, `Sendable`)
//  transport and constructs the noncopyable request/stream value ENTIRELY
//  inside its own closure body, then simulate EOF/failure only after
//  confirming the outbound line was actually sent.
//
//  Coverage:
//  - HerdrOneShotRequest.send: sends exactly one line with id/method/
//    params-as-an-object, returns the decoded result, and closes the
//    transport afterward (probed via a second send() throwing
//    .alreadyClosed -- InMemoryHerdrTransport exposes no other way to
//    observe closedness)
//  - HerdrOneShotRequest.send: the response's own "id" is NEVER
//    validated against what send() generated -- deliberate contract (see
//    HerdrConnection.swift's own header), not an oversight
//  - HerdrOneShotRequest.send: works for "session.snapshot" too (not
//    just "ping"), decoding a HerdrSessionSnapshot, proving genericity
//  - HerdrOneShotRequest.send: server responds with herdr's error shape
//    -> throws HerdrConnectionError.rpc, carrying herdr's own code/message
//  - HerdrOneShotRequest.send: transport EOFs / fails before answering ->
//    throws .transportEOF / .transportFailure, rather than hanging
//  - HerdrOneShotRequest.send: a response with neither "result" nor
//    "error" -> throws .malformedResponse
//  - HerdrEventStream.subscribe: sends exactly one events.subscribe line
//    carrying the FULL subscription list, and NEVER sends anything else
//    for the rest of its life -- sent-message count pinned at 1 across
//    many delivered events
//  - HerdrEventStream.subscribe: the ack's own "id" is never validated,
//    for the identical reason HerdrOneShotRequest.send's isn't
//  - HerdrEventStream.subscribe: yields decoded events in order
//  - HerdrEventStream.subscribe: the returned stream finishes NORMALLY on
//    a clean transport EOF, or BY THROWING on a transport failure
//  - HerdrEventStream.subscribe: an error-shaped ack, or the transport
//    EOFing/failing before any ack arrives, each throw -- before EVER
//    returning a stream, rather than hanging
//

import XCTest
@testable import Calyx

final class HerdrConnectionTests: XCTestCase {

    // MARK: - HerdrOneShotRequest: happy path, wire shape, transport closed afterward

    func test_send_sendsExactlyOneLine_withIdMethodParamsAsObject_returnsDecodedResult_closesTransportAfterward() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(pingResponseLine(id: "1"))

        let request = HerdrOneShotRequest(transport: transport)
        let result: HerdrPingResult = try await request.send(method: "ping", socketPath: "/tmp/herdr-oneshot-ping/herdr.sock")

        XCTAssertEqual(result.version, "0.8.0")
        XCTAssertEqual(result.protocolVersion, 19)
        XCTAssertEqual(result.capabilities?.liveHandoff, true)
        XCTAssertEqual(result.capabilities?.detachedServerDaemon, false)

        let connectedPath = await transport.lastConnectedSocketPath()
        XCTAssertEqual(connectedPath, "/tmp/herdr-oneshot-ping/herdr.sock")

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1, "expected send() to write exactly one request line")
        guard let object = jsonObject(inLine: sent[0]) else {
            XCTFail("expected a decodable JSON request line, got \(sent)")
            return
        }
        XCTAssertEqual(
            Set(object.keys), ["id", "method", "params"],
            "expected send()'s request line to contain EXACTLY id/method/params, got \(sent[0])"
        )
        XCTAssertEqual(object["method"] as? String, "ping")
        assertSatisfiesMinimumRequestEnvelope(sent[0])
        guard let params = object["params"] as? [String: Any] else {
            XCTFail("expected \"params\" to be a JSON object, got \(sent[0])")
            return
        }
        XCTAssertTrue(params.isEmpty, "expected an empty params object for a method with no arguments of its own")

        // Probe: InMemoryHerdrTransport exposes no direct `isClosed()`
        // accessor, so a second send() throwing .alreadyClosed is the
        // only observable proof that send() closed the transport
        // afterward.
        do {
            try await transport.send(#"{"id":"probe","method":"probe","params":{}}"#)
            XCTFail("expected the transport to already be closed after send() completed")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(error, .alreadyClosed, "send() must close the transport before returning")
        } catch {
            XCTFail("expected HerdrTransportError.alreadyClosed, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - HerdrOneShotRequest: response id is never validated (deliberate contract)

    func test_send_doesNotValidateResponseId_becauseOnlyOneResponseIsEverPossibleOnThisConnection() async throws {
        let transport = InMemoryHerdrTransport()
        // Deliberately a MISMATCHED id -- contract, not accident: a
        // one-shot connection carries at most one request and one
        // response (measured fact 2 -- see HerdrConnection.swift's own
        // header), so there is nothing else this line could be an answer
        // to, and send() must not reject it merely because its own
        // generated request id differs.
        await transport.simulateLine(pingResponseLine(id: "totally-different-id-999"))

        let request = HerdrOneShotRequest(transport: transport)
        let result: HerdrPingResult = try await request.send(method: "ping", socketPath: "/tmp/herdr-oneshot-idmismatch/herdr.sock")

        XCTAssertEqual(result.version, "0.8.0", "a mismatched response id must not prevent the result from decoding")
    }

    // MARK: - HerdrOneShotRequest: genericity -- works for session.snapshot too

    func test_send_withSessionSnapshotMethod_decodesSnapshotResult() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(snapshotResponseLine(id: "1"))

        let request = HerdrOneShotRequest(transport: transport)
        let result: HerdrSessionSnapshot = try await request.send(
            method: "session.snapshot", socketPath: "/tmp/herdr-oneshot-snapshot/herdr.sock"
        )

        XCTAssertEqual(result.agents.count, 1)
        XCTAssertEqual(result.agents.first?.paneID, "w9:p1")
        XCTAssertEqual(result.agents.first?.agentStatus, .blocked)
        XCTAssertEqual(result.focusedWorkspaceID, "w9")

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.compactMap { requestMethod(inLine: $0) }, ["session.snapshot"])
    }

    // MARK: - HerdrOneShotRequest: RPC error response

    func test_send_throwsRPCError_carryingHerdrsCodeAndMessage_whenServerRespondsWithErrorObject() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(errorResponseLine(id: "1", code: "invalid_request", message: "ping is not available"))

        let request = HerdrOneShotRequest(transport: transport)
        do {
            let _: HerdrPingResult = try await request.send(method: "ping", socketPath: "/tmp/herdr-oneshot-rpcerror/herdr.sock")
            XCTFail("expected send() to throw when the server responds with an error object")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .rpc(HerdrRPCError(code: "invalid_request", message: "ping is not available")))
        } catch {
            XCTFail("expected HerdrConnectionError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - HerdrOneShotRequest: EOF / failure before answering -- throws, never hangs

    func test_send_transportEOFsBeforeAnswering_throwsTransportEOF_ratherThanHanging() async throws {
        let transport = InMemoryHerdrTransport()

        // Captures only the Copyable/Sendable `transport` -- constructs
        // and consumes the noncopyable HerdrOneShotRequest ENTIRELY
        // inside this closure's own body. See this file's header
        // "TEST-MECHANICS NOTE".
        let task = Task { () throws -> HerdrPingResult in
            let request = HerdrOneShotRequest(transport: transport)
            return try await request.send(method: "ping", socketPath: "/tmp/herdr-oneshot-eof/herdr.sock")
        }

        _ = await awaitSentMessages(transport, atLeast: 1) // the request is confirmed in flight
        await transport.simulateEOF()

        do {
            _ = try await task.value
            XCTFail("expected send() to throw once the transport EOFs before answering, not hang")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .transportEOF)
        } catch {
            XCTFail("expected HerdrConnectionError, got \(type(of: error)): \(error)")
        }
    }

    func test_send_transportFailsBeforeAnswering_throwsTransportFailure() async throws {
        let transport = InMemoryHerdrTransport()

        let task = Task { () throws -> HerdrPingResult in
            let request = HerdrOneShotRequest(transport: transport)
            return try await request.send(method: "ping", socketPath: "/tmp/herdr-oneshot-failure/herdr.sock")
        }

        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateFailure("boom")

        do {
            _ = try await task.value
            XCTFail("expected send() to throw once the transport fails before answering, not hang")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .transportFailure("boom"))
        } catch {
            XCTFail("expected HerdrConnectionError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - HerdrOneShotRequest: malformed response (neither "result" nor "error")

    func test_send_responseWithNeitherResultNorError_throwsMalformedResponse() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(#"{"id":"1"}"#)

        let request = HerdrOneShotRequest(transport: transport)
        do {
            let _: HerdrPingResult = try await request.send(method: "ping", socketPath: "/tmp/herdr-oneshot-malformed/herdr.sock")
            XCTFail("expected send() to throw when the response has neither \"result\" nor \"error\"")
        } catch let error as HerdrConnectionError {
            guard case .malformedResponse = error else {
                XCTFail("expected .malformedResponse, got \(error)")
                return
            }
        } catch {
            XCTFail("expected HerdrConnectionError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - HerdrEventStream: sends exactly one line, the full subscription list

    func test_subscribe_sendsExactlyOneEventsSubscribeLine_withFullSubscriptionList() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(subscribeAckLine(id: "1"))

        let eventStream = HerdrEventStream(transport: transport)
        let subscriptions: [HerdrSubscription] = [
            .typeOnly("pane.created"), .typeOnly("pane.closed"), .agentStatusChanged(paneID: "w9:p1"),
        ]
        let stream = try await eventStream.subscribe(subscriptions, socketPath: "/tmp/herdr-eventstream-wireshape/herdr.sock")
        // Retained so ARC never tears down the connection mid-test; this
        // test's own point is the OUTBOUND line, not consumption.
        withExtendedLifetime(stream) {}

        let connectedPath = await transport.lastConnectedSocketPath()
        XCTAssertEqual(connectedPath, "/tmp/herdr-eventstream-wireshape/herdr.sock")

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1, "expected subscribe() to write exactly one request line")
        guard let object = jsonObject(inLine: sent[0]) else {
            XCTFail("expected a decodable JSON request line, got \(sent)")
            return
        }
        XCTAssertEqual(object["method"] as? String, "events.subscribe")
        assertSatisfiesMinimumRequestEnvelope(sent[0])

        guard let params = object["params"] as? [String: Any],
              let subs = params["subscriptions"] as? [[String: Any]] else {
            XCTFail("expected params.subscriptions to be a JSON array, got \(sent[0])")
            return
        }
        XCTAssertEqual(subs.count, 3, "expected every passed subscription to appear, in order")
        XCTAssertEqual(subs[0]["type"] as? String, "pane.created")
        XCTAssertEqual(subs[1]["type"] as? String, "pane.closed")
        XCTAssertEqual(subs[2]["type"] as? String, "pane.agent_status_changed")
        XCTAssertEqual(subs[2]["pane_id"] as? String, "w9:p1")
    }

    // MARK: - HerdrEventStream: never sends anything else, for its whole life

    func test_subscribe_neverSendsAnythingElse_sentMessageCountStaysAtOne_acrossManyDeliveredEvents() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(subscribeAckLine(id: "1"))

        let eventStream = HerdrEventStream(transport: transport)
        let stream = try await eventStream.subscribe([.typeOnly("pane.created")], socketPath: "/tmp/herdr-eventstream-onlysend/herdr.sock")
        var iterator = stream.makeAsyncIterator()

        for index in 0..<25 {
            await transport.simulateLine(paneCreatedEventLine(paneID: "w1:p\(index)"))
            _ = try await iterator.next()
            let sent = await transport.sentMessages()
            XCTAssertEqual(
                sent.count, 1,
                "an event stream must never send anything beyond its initial events.subscribe -- " +
                "still true after \(index + 1) delivered event(s)"
            )
        }
    }

    // MARK: - HerdrEventStream: ack id is never validated (deliberate contract, mirrors HerdrOneShotRequest)

    func test_subscribe_doesNotValidateAckId_becauseOnlyOneAckIsEverPossibleOnThisConnection() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(subscribeAckLine(id: "totally-different-id-999"))

        let eventStream = HerdrEventStream(transport: transport)
        let stream = try await eventStream.subscribe([.typeOnly("pane.created")], socketPath: "/tmp/herdr-eventstream-idmismatch/herdr.sock")
        var iterator = stream.makeAsyncIterator()

        await transport.simulateLine(paneCreatedEventLine())
        guard case .paneCreated(let pane) = try await iterator.next() else {
            XCTFail("expected the mismatched-id ack to still be accepted, and events to keep flowing")
            return
        }
        XCTAssertEqual(pane.paneID, "w9:p1")
    }

    // MARK: - HerdrEventStream: yields decoded events in order

    func test_subscribe_yieldsDecodedEventsInOrder() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(subscribeAckLine(id: "1"))

        let eventStream = HerdrEventStream(transport: transport)
        let stream = try await eventStream.subscribe([.typeOnly("pane.created")], socketPath: "/tmp/herdr-eventstream-order/herdr.sock")
        var iterator = stream.makeAsyncIterator()

        await transport.simulateLine(paneCreatedEventLine(paneID: "w1:p1"))
        await transport.simulateLine(paneClosedEventLine(paneID: "w1:p2"))
        await transport.simulateLine(paneExitedEventLine(paneID: "w1:p3"))

        guard case .paneCreated(let firstPane) = try await iterator.next() else {
            XCTFail("expected the first event to be .paneCreated")
            return
        }
        XCTAssertEqual(firstPane.paneID, "w1:p1")

        guard case .paneClosed(let secondPaneID) = try await iterator.next() else {
            XCTFail("expected the second event to be .paneClosed")
            return
        }
        XCTAssertEqual(secondPaneID, "w1:p2")

        guard case .paneExited(let thirdPaneID) = try await iterator.next() else {
            XCTFail("expected the third event to be .paneExited")
            return
        }
        XCTAssertEqual(thirdPaneID, "w1:p3")
    }

    // MARK: - HerdrEventStream: EOF/failure termination, once subscribed

    func test_subscribe_returnedStream_finishesNormally_onCleanEOF() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(subscribeAckLine(id: "1"))

        let eventStream = HerdrEventStream(transport: transport)
        let stream = try await eventStream.subscribe([.typeOnly("pane.created")], socketPath: "/tmp/herdr-eventstream-eof/herdr.sock")
        var iterator = stream.makeAsyncIterator()

        await transport.simulateEOF()

        let next = try await iterator.next()
        XCTAssertNil(next, "the stream must finish (next() returns nil) after a clean transport EOF, without throwing")
    }

    func test_subscribe_returnedStream_finishesByThrowing_onTransportFailure_distinctFromCleanEOF() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(subscribeAckLine(id: "1"))

        let eventStream = HerdrEventStream(transport: transport)
        let stream = try await eventStream.subscribe([.typeOnly("pane.created")], socketPath: "/tmp/herdr-eventstream-failure/herdr.sock")
        var iterator = stream.makeAsyncIterator()

        await transport.simulateFailure("server crashed")

        do {
            _ = try await iterator.next()
            XCTFail("expected the stream to throw after a transport failure, but it completed without error")
        } catch {
            // expected
        }
    }

    // MARK: - HerdrEventStream: ack failure -- throws before ever returning a stream

    func test_subscribe_ackIsErrorObject_throwsRPCError_beforeEverReturningAStream() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.simulateLine(errorResponseLine(id: "1", code: "invalid_request", message: "pane_id is required"))

        let eventStream = HerdrEventStream(transport: transport)
        do {
            _ = try await eventStream.subscribe([.agentStatusChanged(paneID: "w9:p1")], socketPath: "/tmp/herdr-eventstream-rpcerror/herdr.sock")
            XCTFail("expected subscribe() to throw when its ack is an error object")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .rpc(HerdrRPCError(code: "invalid_request", message: "pane_id is required")))
        } catch {
            XCTFail("expected HerdrConnectionError, got \(type(of: error)): \(error)")
        }
    }

    func test_subscribe_transportEOFsBeforeAckArrives_throwsTransportEOF_ratherThanHanging() async throws {
        let transport = InMemoryHerdrTransport()

        // See this file's header "TEST-MECHANICS NOTE" for why this must
        // be Task-wrapped (captures only the Sendable transport) rather
        // than pre-buffered.
        let task = Task { () throws -> AsyncThrowingStream<HerdrEvent, Error> in
            let eventStream = HerdrEventStream(transport: transport)
            return try await eventStream.subscribe([.typeOnly("pane.created")], socketPath: "/tmp/herdr-eventstream-ack-eof/herdr.sock")
        }

        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateEOF()

        do {
            _ = try await task.value
            XCTFail("expected subscribe() to throw once the transport EOFs before any ack arrives, not hang")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .transportEOF)
        } catch {
            XCTFail("expected HerdrConnectionError, got \(type(of: error)): \(error)")
        }
    }

    func test_subscribe_transportFailsBeforeAckArrives_throwsTransportFailure() async throws {
        let transport = InMemoryHerdrTransport()

        let task = Task { () throws -> AsyncThrowingStream<HerdrEvent, Error> in
            let eventStream = HerdrEventStream(transport: transport)
            return try await eventStream.subscribe([.typeOnly("pane.created")], socketPath: "/tmp/herdr-eventstream-ack-failure/herdr.sock")
        }

        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateFailure("boom")

        do {
            _ = try await task.value
            XCTFail("expected subscribe() to throw once the transport fails before any ack arrives, not hang")
        } catch let error as HerdrConnectionError {
            XCTAssertEqual(error, .transportFailure("boom"))
        } catch {
            XCTFail("expected HerdrConnectionError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Structural guards: HerdrPingResult / HerdrCapabilities (ResponseResult's "pong" branch)

    /// The "pong" branch of `ResponseResult` requires only `type`/
    /// `version`/`protocol` -- `capabilities` is optional AND nullable
    /// (`"anyOf":[ServerCapabilities,null]`, `"default":null`), so a
    /// payload carrying just the three required fields must decode
    /// successfully with `capabilities` nil, even though every real
    /// herdr 0.8.0 response observed so far has included it.
    func test_pingResult_decodesMinimalRequiredOnlyPayload_withCapabilitiesNil() throws {
        let json = Data(#"{"type":"pong","version":"0.8.0","protocol":19}"#.utf8)

        let result = try JSONDecoder().decode(HerdrPingResult.self, from: json)

        XCTAssertEqual(result.version, "0.8.0")
        XCTAssertEqual(result.protocolVersion, 19)
        XCTAssertNil(result.capabilities)
    }

    /// Required fields plus an explicit JSON `null` for `capabilities`
    /// (its NULLABLE optional) -- decodes identically to the minimal
    /// payload above.
    func test_pingResult_decodesRequiredPlusExplicitNullCapabilities_asNil() throws {
        let json = Data(#"{"type":"pong","version":"0.8.0","protocol":19,"capabilities":null}"#.utf8)

        let result = try JSONDecoder().decode(HerdrPingResult.self, from: json)

        XCTAssertNil(result.capabilities)
    }

    /// `ServerCapabilities`' own `required` list is `["live_handoff"]`
    /// only -- `detached_server_daemon` is a bare, never-null boolean
    /// with a schema `"default":false` this file deliberately does NOT
    /// apply (mirrors `HerdrAgentRecord.stateChangeSeq`'s own precedent
    /// in HerdrEvent.swift), so a payload carrying only `live_handoff`
    /// must decode with `detachedServerDaemon` nil, never a substituted
    /// `false`.
    func test_capabilities_decodesMinimalRequiredOnlyPayload_withDetachedServerDaemonNil() throws {
        let json = Data(#"{"live_handoff":true}"#.utf8)

        let capabilities = try JSONDecoder().decode(HerdrCapabilities.self, from: json)

        XCTAssertTrue(capabilities.liveHandoff)
        XCTAssertNil(
            capabilities.detachedServerDaemon,
            "absent detached_server_daemon must decode to nil, never the schema's own \"default\": false"
        )
    }

    // MARK: - Fixture builders (exact shapes measured against real herdr 0.8.0)

    private func pingResponseLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"pong","version":"0.8.0","protocol":19,"capabilities":{"live_handoff":true,"detached_server_daemon":false}}}"#
    }

    private func snapshotResponseLine(id: String) -> String {
        #"""
        {"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"focused_workspace_id":"w9","focused_tab_id":"w9:t1","focused_pane_id":"w9:p1","workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[{"terminal_id":"term_658b1a46d5aba9","agent":"claude","agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":false,"state_change_seq":5,"cwd":"/Users/eguchiyuuichi","foreground_cwd":"/Users/eguchiyuuichi","revision":0}]}}}
        """#
    }

    private func subscribeAckLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    /// herdr's measured error response shape --
    /// {"id":"..","error":{"code":"..","message":".."}}.
    private func errorResponseLine(id: String, code: String, message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private func paneCreatedEventLine(paneID: String = "w9:p1") -> String {
        #"""
        {"data":{"pane":{"terminal_id":"term_\#(paneID)","agent":"claude","agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1","pane_id":"\#(paneID)","focused":false,"cwd":"/Users/eguchiyuuichi","foreground_cwd":"/Users/eguchiyuuichi","revision":0},"type":"pane_created"},"event":"pane_created"}
        """#
    }

    /// Flat `data.pane_id` B1 shape -- see HerdrEvent.swift's own header.
    private func paneClosedEventLine(paneID: String) -> String {
        #"{"event":"pane_closed","data":{"pane_id":"\#(paneID)"}}"#
    }

    private func paneExitedEventLine(paneID: String) -> String {
        #"{"event":"pane_exited","data":{"pane_id":"\#(paneID)"}}"#
    }

    // MARK: - Wire-line parsing helpers (parse back to JSON -- never string comparison, JSONEncoder key order isn't stable)

    private func jsonObject(inLine line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func requestMethod(inLine line: String) -> String? {
        jsonObject(inLine: line)?["method"] as? String
    }

    /// Asserts that `line` decodes to a JSON object satisfying herdr's
    /// own documented MINIMUM request envelope, measured directly
    /// against a real herdr 0.8.0 server: a non-empty string "id", a
    /// non-empty string "method", and a "params" value that is PRESENT
    /// and a JSON OBJECT -- never omitted entirely, never `null`.
    private func assertSatisfiesMinimumRequestEnvelope(
        _ line: String,
        file: StaticString = #filePath,
        line callLine: UInt = #line
    ) {
        guard let object = jsonObject(inLine: line) else {
            XCTFail("expected a decodable JSON object, got raw line: \(line)", file: file, line: callLine)
            return
        }
        guard let id = object["id"] as? String, !id.isEmpty else {
            XCTFail("expected a non-empty string \"id\", got \(String(describing: object["id"])) in \(line)", file: file, line: callLine)
            return
        }
        guard let method = object["method"] as? String, !method.isEmpty else {
            XCTFail("expected a non-empty string \"method\", got \(String(describing: object["method"])) in \(line)", file: file, line: callLine)
            return
        }
        guard let paramsValue = object["params"] else {
            XCTFail(
                "expected a \"params\" key to be PRESENT (herdr rejects a request with \"params\" omitted entirely), got \(line)",
                file: file, line: callLine
            )
            return
        }
        XCTAssertTrue(
            paramsValue is [String: Any],
            "expected \"params\" to be a JSON OBJECT, not \(String(describing: paramsValue)) (herdr also rejects \"params\": null), in \(line)",
            file: file, line: callLine
        )
    }

    // MARK: - Bounded async polling

    private func waitUntil(maxYields: Int = 10_000, _ condition: () async -> Bool) async {
        var iterations = 0
        while await !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    private func awaitSentMessages(_ transport: InMemoryHerdrTransport, atLeast count: Int) async -> [String] {
        await waitUntil { await transport.sentMessages().count >= count }
        return await transport.sentMessages()
    }
}
