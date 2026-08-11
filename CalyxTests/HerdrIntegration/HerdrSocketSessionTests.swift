//
//  HerdrSocketSessionTests.swift
//  CalyxTests
//
//  Coverage for HerdrSocketSession: request/response id correlation,
//  the `ping` handshake, `session.snapshot` decoding, the
//  `events.subscribe` ack-then-events flow (including the EOF-vs-
//  failure stream-termination distinction), the once-per-connection
//  subscribe rule, and `abandon()`'s own non-ARC teardown contract. See
//  HerdrSocketSession.swift's own header for the full wire contract.
//
//  Every test below drives a real `InMemoryHerdrTransport` (never a
//  stub -- see HerdrTransport.swift's own header) through
//  `HerdrSocketSession`'s actual public API, so a test that reaches an
//  assertion at all is proof the type's real request/response and
//  event-stream plumbing works, not proof that some fake shortcut
//  happened to satisfy a weak check. Fixture response/event lines are
//  hand-built from the exact wire shapes measured against a real herdr
//  0.8.0 server, matching HerdrEvent.swift's own header.
//
//  Coverage:
//  - start() connects the transport with the given socket path
//  - ping() sends a "ping" request and parses version/protocol/
//    capabilities from the response
//  - snapshot() sends a "session.snapshot" request and decodes
//    `agents[]`
//  - id correlation: two concurrent requests (ping + snapshot), replied
//    to OUT OF ORDER, each resolve to their OWN matching result --
//    proves correlation is by id, not by send/receive order
//  - subscribe() sends "events.subscribe", awaits the ack, then
//    delivers pushed events (decoded via HerdrEvent) on the SAME
//    returned stream, which finishes NORMALLY (no throw) on a clean
//    transport EOF
//  - subscribe()'s returned stream finishes BY THROWING on a transport
//    failure -- distinct from the clean-EOF case above, the core
//    "EOF surfaced distinctly from a [transport] error" regression pin
//    at the session/stream layer
//  - a second subscribe() call on the same session throws
//    HerdrSocketSessionError.alreadySubscribed
//  - B4: ping()/snapshot()/subscribe() each throw
//    HerdrSocketSessionError.rpc(HerdrRPCError), carrying herdr's own
//    "code"/"message", when the server responds with herdr's error
//    shape ({"id":..,"error":{"code":..,"message":..}}) instead of a
//    "result" -- previously zero coverage of the .rpc branch existed at
//    all, since every fixture response line was result-shaped
//  - B3: ping()/subscribe() each throw the NORMALIZED
//    HerdrSocketSessionError (not a raw HerdrTransportError) when their
//    own `transport.send` races the receive loop observing a terminal
//    transport event and losing -- see
//    `InMemoryHerdrTransport.beforeSend`'s own doc comment for how the
//    race is made deterministic
//  - BLOCKER regression: `abandon()` resolves a pending request (e.g. a
//    `ping()` stuck forever awaiting a reply that will never come) the
//    same way an ordinary transport EOF would, AND lets a session that
//    was otherwise leaked by that stuck continuation actually be
//    released once its last external strong reference is dropped -- see
//    `HerdrSocketSession.abandon()`'s own doc comment and
//    `HerdrIntegrationCoordinatorTests`' own end-to-end coverage of the
//    same fix from the caller side (HANDSHAKE DEADLINE (A2)'s timeout
//    arm)
//  - R1 wire-shape pin: ping()'s and session.snapshot()'s request lines
//    are each a JSON object with EXACTLY the keys "id"/"method"/
//    "params" -- "params" PRESENT and a JSON OBJECT, never omitted and
//    never `null`. Decodes the ACTUAL line handed to the transport and
//    asserts its parsed JSON structure (never a string match --
//    JSONEncoder's key order is not stable). events.subscribe()'s own
//    request line (believed already correct) is pinned the same way,
//    plus its params.subscriptions array, so it stays correct. See
//    HerdrSocketSession.swift's own header for why herdr's real server
//    rejects a request with "params" omitted or `null`.
//  - R2 BLOCKER regression pin, the check that would have caught the
//    shipped bug regardless of which method regressed: every request
//    line a full handshake can produce (ping, events.subscribe,
//    session.snapshot) independently satisfies herdr's documented
//    minimum request envelope -- non-empty string "id", non-empty
//    string "method", "params" present and a JSON object. The shipped
//    bug was `HerdrNoParamsRequest` omitting "params" entirely for BOTH
//    ping and session.snapshot, discovered only by probing a real herdr
//    0.8.0 server directly -- the pre-existing test suite never pinned
//    the actual wire shape, only the request's "method".
//
//  None of the guard/XCTFail-and-return checks below use a force
//  unwrap (`!`) on anything derived from `HerdrSocketSession` /
//  `InMemoryHerdrTransport` output -- a missing/malformed message would
//  otherwise crash the whole test process instead of failing this one
//  test cleanly.
//

import XCTest
@testable import Calyx

final class HerdrSocketSessionTests: XCTestCase {

    // MARK: - start()

    func test_start_connectsTransport_withGivenSocketPath() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)

        try await session.start(socketPath: "/tmp/herdr-start-test/herdr.sock")

        let connected = await transport.lastConnectedSocketPath()
        XCTAssertEqual(connected, "/tmp/herdr-start-test/herdr.sock")
    }

    // MARK: - ping()

    func test_ping_sendsPingRequest_andParsesVersionProtocolCapabilitiesFromResponse() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-ping-test/herdr.sock")

        async let pingTask = session.ping()

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, requestMethod(inLine: line) == "ping", let id = requestID(inLine: line) else {
            XCTFail("expected ping() to send exactly one 'ping' request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(pingResponseLine(id: id))

        let result = try await pingTask
        XCTAssertEqual(result.version, "0.8.0")
        XCTAssertEqual(result.protocolVersion, 19)
        XCTAssertTrue(result.capabilities.liveHandoff)
        XCTAssertFalse(result.capabilities.detachedServerDaemon)
    }

    // MARK: - snapshot()

    func test_snapshot_sendsSessionSnapshotRequest_andDecodesAgentsList() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-snapshot-test/herdr.sock")

        async let snapshotTask = session.snapshot()

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, requestMethod(inLine: line) == "session.snapshot", let id = requestID(inLine: line) else {
            XCTFail("expected snapshot() to send exactly one 'session.snapshot' request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(snapshotResponseLine(id: id))

        let result = try await snapshotTask
        XCTAssertEqual(result.agents.count, 1)
        XCTAssertEqual(result.agents.first?.paneID, "w9:p1")
        XCTAssertEqual(result.agents.first?.agentStatus, .blocked)
        XCTAssertEqual(result.focusedWorkspaceID, "w9")
    }

    // MARK: - id correlation

    func test_idCorrelation_twoInterleavedRequests_eachResolveToItsOwnResponse_regardlessOfReplyOrder() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-correlate-test/herdr.sock")

        async let pingTask = session.ping()
        async let snapshotTask = session.snapshot()

        let sent = await awaitSentMessages(transport, atLeast: 2)
        guard sent.count == 2,
              let pingLine = sent.first(where: { requestMethod(inLine: $0) == "ping" }),
              let snapshotLine = sent.first(where: { requestMethod(inLine: $0) == "session.snapshot" }),
              let pingID = requestID(inLine: pingLine),
              let snapshotID = requestID(inLine: snapshotLine)
        else {
            XCTFail("expected exactly one 'ping' request and one 'session.snapshot' request, each with an id; got \(sent)")
            return
        }

        // Reply OUT OF ORDER: snapshot's response arrives before
        // ping's, proving correlation is by id, not send/receive order.
        await transport.simulateLine(snapshotResponseLine(id: snapshotID))
        await transport.simulateLine(pingResponseLine(id: pingID))

        let ping = try await pingTask
        XCTAssertEqual(ping.version, "0.8.0")
        XCTAssertEqual(ping.protocolVersion, 19)

        let snapshot = try await snapshotTask
        XCTAssertEqual(snapshot.agents.first?.paneID, "w9:p1")
    }

    // MARK: - subscribe(): ack then events on one stream, clean EOF termination

    func test_subscribe_sendsEventsSubscribeRequest_awaitsAck_thenDeliversPushedEventsOnReturnedStream_andFinishesCleanlyOnEOF() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-subscribe-test/herdr.sock")

        async let streamTask = session.subscribe([.typeOnly("pane.created")])

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, requestMethod(inLine: line) == "events.subscribe", let id = requestID(inLine: line) else {
            XCTFail("expected subscribe() to send exactly one 'events.subscribe' request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(subscribeAckLine(id: id))

        let stream = try await streamTask
        var iterator = stream.makeAsyncIterator()

        await transport.simulateLine(paneCreatedEventLine())

        let firstEvent = try await iterator.next()
        guard case .paneCreated(let pane) = firstEvent else {
            XCTFail("expected the first event on the stream to be .paneCreated, got \(String(describing: firstEvent))")
            return
        }
        XCTAssertEqual(pane.paneID, "w9:p1")

        await transport.simulateEOF()
        let afterEOF = try await iterator.next()
        XCTAssertNil(afterEOF, "the stream must finish (next() returns nil) after a clean transport EOF, without throwing")
    }

    // MARK: - subscribe(): failure termination, distinct from clean EOF

    func test_subscribe_streamFinishesByThrowing_onTransportFailure_distinctFromCleanEOF() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-subscribe-failure-test/herdr.sock")

        async let streamTask = session.subscribe([.typeOnly("pane.created")])

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, requestMethod(inLine: line) == "events.subscribe", let id = requestID(inLine: line) else {
            XCTFail("expected subscribe() to send exactly one 'events.subscribe' request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(subscribeAckLine(id: id))

        let stream = try await streamTask
        var iterator = stream.makeAsyncIterator()

        await transport.simulateFailure("server crashed")

        do {
            _ = try await iterator.next()
            XCTFail("expected the stream to throw after a transport failure, but it completed without error")
        } catch {
            // expected
        }
    }

    // MARK: - subscribe(): once per connection

    func test_subscribe_secondCallOnSameSession_throwsAlreadySubscribed() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-resubscribe-test/herdr.sock")

        async let firstStreamTask = session.subscribe([.typeOnly("pane.created")])

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, let id = requestID(inLine: line) else {
            XCTFail("expected the first subscribe() to send an 'events.subscribe' request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(subscribeAckLine(id: id))
        _ = try await firstStreamTask

        do {
            _ = try await session.subscribe([.typeOnly("pane.updated")])
            XCTFail("expected a second subscribe() call on the same session to throw")
        } catch let error as HerdrSocketSessionError {
            XCTAssertEqual(error, .alreadySubscribed)
        }
    }

    // MARK: - RPC error responses (B4): ping/snapshot/subscribe each surface herdr's error shape

    func test_ping_throwsRPCError_carryingHerdrsCodeAndMessage_whenServerRespondsWithErrorObject() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-ping-rpcerror-test/herdr.sock")

        async let pingTask = session.ping()

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, let id = requestID(inLine: line) else {
            XCTFail("expected ping() to send exactly one request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(errorResponseLine(id: id, code: "invalid_request", message: "ping is not available"))

        do {
            _ = try await pingTask
            XCTFail("expected ping() to throw when the server responds with an error object")
        } catch let error as HerdrSocketSessionError {
            XCTAssertEqual(error, .rpc(HerdrRPCError(code: "invalid_request", message: "ping is not available")))
        }
    }

    func test_snapshot_throwsRPCError_carryingHerdrsCodeAndMessage_whenServerRespondsWithErrorObject() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-snapshot-rpcerror-test/herdr.sock")

        async let snapshotTask = session.snapshot()

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, let id = requestID(inLine: line) else {
            XCTFail("expected snapshot() to send exactly one request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(errorResponseLine(id: id, code: "internal_error", message: "snapshot failed"))

        do {
            _ = try await snapshotTask
            XCTFail("expected snapshot() to throw when the server responds with an error object")
        } catch let error as HerdrSocketSessionError {
            XCTAssertEqual(error, .rpc(HerdrRPCError(code: "internal_error", message: "snapshot failed")))
        }
    }

    func test_subscribe_throwsRPCError_carryingHerdrsCodeAndMessage_whenAckIsAnErrorObject() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-subscribe-rpcerror-test/herdr.sock")

        async let streamTask = session.subscribe([.agentStatusChanged(paneID: "w9:p1")])

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, let id = requestID(inLine: line) else {
            XCTFail("expected subscribe() to send exactly one 'events.subscribe' request with an id; got \(sent)")
            return
        }
        await transport.simulateLine(errorResponseLine(id: id, code: "invalid_request", message: "pane_id is required"))

        do {
            _ = try await streamTask
            XCTFail("expected subscribe() to throw when its ack is an error object")
        } catch let error as HerdrSocketSessionError {
            XCTAssertEqual(error, .rpc(HerdrRPCError(code: "invalid_request", message: "pane_id is required")))
        }
    }

    // MARK: - send races session termination (B3): normalized error, not a raw HerdrTransportError

    func test_ping_throwsNormalizedSessionError_notRawTransportError_whenSendRacesSessionTermination() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-race-ping-test/herdr.sock")

        // Deterministically interleave: while `ping()`'s underlying
        // `sendNoParamsRequest` is suspended INSIDE `transport.send(...)`
        // (having already passed its own `terminationError == nil`
        // check, since that check runs strictly before `send` is ever
        // called), let the receive loop fully process a simulated
        // transport failure -- including `terminate()` setting
        // `terminationError` -- BEFORE `send` itself resolves (and
        // throws, because the transport is now closed). See
        // `InMemoryHerdrTransport.beforeSend`'s own doc comment.
        await transport.setBeforeSend {
            await transport.simulateFailure("boom")
            // A generous number of yields lets the already-scheduled
            // receive-loop resumption (which only needs a free turn on
            // the session actor -- free, since sendNoParamsRequest is
            // suspended here, not holding it) actually run `terminate()`
            // to completion before this hook returns and `send`
            // proceeds to its `isClosed` check.
            for _ in 0..<100 {
                await Task.yield()
            }
        }

        do {
            _ = try await session.ping()
            XCTFail("expected ping() to throw once its send races session termination")
        } catch let error as HerdrSocketSessionError {
            XCTAssertEqual(
                error, .transportFailure("boom"),
                "expected the NORMALIZED session error, not a raw HerdrTransportError, from a send that raced termination"
            )
        } catch {
            XCTFail("expected a HerdrSocketSessionError, got raw \(type(of: error)): \(error)")
        }

        await transport.setBeforeSend(nil) // breaks the transport -> closure -> transport retain cycle
    }

    func test_subscribe_throwsNormalizedSessionError_notRawTransportError_whenSendRacesSessionTermination() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-race-subscribe-test/herdr.sock")

        // See the identical construction (and its doc comment) in
        // `test_ping_throwsNormalizedSessionError_notRawTransportError_whenSendRacesSessionTermination`
        // above -- `subscribe(_:)`'s own `transport.send` catch block has
        // the same B3 fix and deserves the same race coverage.
        await transport.setBeforeSend {
            await transport.simulateFailure("boom")
            for _ in 0..<100 {
                await Task.yield()
            }
        }

        do {
            _ = try await session.subscribe([.typeOnly("pane.created")])
            XCTFail("expected subscribe() to throw once its send races session termination")
        } catch let error as HerdrSocketSessionError {
            XCTAssertEqual(
                error, .transportFailure("boom"),
                "expected the NORMALIZED session error, not a raw HerdrTransportError, from a send that raced termination"
            )
        } catch {
            XCTFail("expected a HerdrSocketSessionError, got raw \(type(of: error)): \(error)")
        }

        await transport.setBeforeSend(nil)
    }

    // MARK: - abandon() (BLOCKER regression: a stuck handshake must not leak the session)

    /// `abandon()`'s primary contract in isolation: a request that is
    /// STUCK forever (its reply is deliberately never simulated) must
    /// resolve, throwing, the moment `abandon()` runs -- the same
    /// `.transportEOF` an ordinary clean disconnect would produce (see
    /// `HerdrSocketSession.abandon()`'s own doc comment for why
    /// `transport.close()` is what makes that happen). Without this,
    /// `HerdrIntegrationCoordinator`'s HANDSHAKE DEADLINE (A2) timeout
    /// arm would have no way to unstick a `performHandshake` suspended
    /// inside this exact call.
    func test_abandon_resolvesAStuckPendingRequest_asTransportEOF() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-abandon-test/herdr.sock")

        async let pingTask = session.ping()
        _ = await awaitSentMessages(transport, atLeast: 1) // ping is in flight, never answered

        await session.abandon()

        do {
            _ = try await pingTask
            XCTFail("expected the stuck ping() to throw once the session is abandoned")
        } catch let error as HerdrSocketSessionError {
            XCTAssertEqual(
                error, .transportEOF,
                "abandon() must resolve a still-pending request the SAME way an ordinary transport EOF would"
            )
        } catch {
            XCTFail("expected a HerdrSocketSessionError, got raw \(type(of: error)): \(error)")
        }
    }

    /// BLOCKER regression, the actual leak this fix exists for: before
    /// `abandon()` existed, a session with a permanently-stuck pending
    /// request could never be released -- the `CheckedContinuation`
    /// inside `awaitEntry` does not resume itself on cancellation, so
    /// whatever `Task` closure was awaiting it (and everything that
    /// closure captured, including this session) stayed alive forever.
    /// Drives the whole stuck-then-abandoned sequence inside a nested
    /// function so that function's own strong reference to `session` is
    /// released the moment it returns, leaving `weakSession` as the only
    /// way to observe whether anything ELSE (the receive loop's own
    /// momentarily-strengthened `self`, or -- pre-fix -- the caller's
    /// stuck continuation) still retains it.
    func test_abandon_letsAStuckSessionActuallyBeReleased_noLeak() async throws {
        let transport = InMemoryHerdrTransport()
        weak var weakSession: HerdrSocketSession?

        func driveStuckHandshakeThenAbandon() async {
            let session = HerdrSocketSession(transport: transport)
            weakSession = session
            try? await session.start(socketPath: "/tmp/herdr-abandon-release-test/herdr.sock")

            async let pingTask = session.ping()
            _ = await awaitSentMessages(transport, atLeast: 1)

            await session.abandon()
            // Let the stuck ping() actually resolve (throwing -- already
            // pinned by the sibling test above, so discarded here)
            // before this function returns and drops its own reference.
            _ = try? await pingTask
        }

        await driveStuckHandshakeThenAbandon()

        await waitUntil { weakSession == nil }
        XCTAssertNil(
            weakSession,
            "BLOCKER: abandon() must let a stuck session actually be released once every external strong " +
            "reference to it is dropped, not leak it forever"
        )
    }

    // MARK: - Wire shape (R1): pins the FULL request envelope, not just "method"
    //
    // The bug these catch: `HerdrNoParamsRequest` (the type ping()/
    // snapshot() currently use) omits "params" entirely. Measured
    // directly against a real herdr 0.8.0 server: a request with
    // "params" omitted, or sent as `null`, is rejected with
    // {"error":{"code":"invalid_request",...}} AND the connection is
    // closed -- see HerdrSocketSession.swift's own header. Every test
    // below decodes the ACTUAL line handed to `transport.send`, never a
    // string match (JSONEncoder's key order is not stable).

    func test_ping_requestLine_hasExactlyIdMethodParams_withParamsAsAnObject() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-wireshape-ping-test/herdr.sock")

        async let pingTask = session.ping()

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, let object = jsonObject(inLine: line) else {
            XCTFail("expected ping() to send exactly one decodable JSON request; got \(sent)")
            return
        }

        XCTAssertEqual(
            Set(object.keys), ["id", "method", "params"],
            "expected ping()'s request line to contain EXACTLY id/method/params, got \(line)"
        )
        XCTAssertEqual(object["method"] as? String, "ping")
        assertSatisfiesMinimumRequestEnvelope(line)

        // Resolve the still-pending ping() so this test doesn't hang.
        guard let id = object["id"] as? String else {
            XCTFail("expected \"id\" to be a String, got \(line)")
            return
        }
        await transport.simulateLine(pingResponseLine(id: id))
        _ = try await pingTask
    }

    func test_snapshot_requestLine_hasExactlyIdMethodParams_withParamsAsAnObject() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-wireshape-snapshot-test/herdr.sock")

        async let snapshotTask = session.snapshot()

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, let object = jsonObject(inLine: line) else {
            XCTFail("expected snapshot() to send exactly one decodable JSON request; got \(sent)")
            return
        }

        XCTAssertEqual(
            Set(object.keys), ["id", "method", "params"],
            "expected snapshot()'s request line to contain EXACTLY id/method/params, got \(line)"
        )
        XCTAssertEqual(object["method"] as? String, "session.snapshot")
        assertSatisfiesMinimumRequestEnvelope(line)

        // Resolve the still-pending snapshot() so this test doesn't hang.
        guard let id = object["id"] as? String else {
            XCTFail("expected \"id\" to be a String, got \(line)")
            return
        }
        await transport.simulateLine(snapshotResponseLine(id: id))
        _ = try await snapshotTask
    }

    /// Believed already correct today -- pinned so it STAYS correct.
    func test_subscribe_requestLine_hasIdMethodAndParamsObjectContainingSubscriptionsArray() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-wireshape-subscribe-test/herdr.sock")

        async let streamTask = session.subscribe([.typeOnly("pane.created")])

        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard let line = sent.first, let object = jsonObject(inLine: line) else {
            XCTFail("expected subscribe() to send exactly one decodable JSON request; got \(sent)")
            return
        }

        XCTAssertEqual(object["method"] as? String, "events.subscribe")
        assertSatisfiesMinimumRequestEnvelope(line)

        guard let params = object["params"] as? [String: Any] else {
            XCTFail("expected \"params\" to be a JSON object, got \(line)")
            return
        }
        guard let subscriptions = params["subscriptions"] as? [Any] else {
            XCTFail("expected params.subscriptions to be a JSON array, got \(line)")
            return
        }
        XCTAssertEqual(subscriptions.count, 1, "expected exactly the one subscription passed to subscribe(_:), got \(line)")
        guard let firstSubscription = subscriptions.first as? [String: Any] else {
            XCTFail("expected params.subscriptions[0] to be a JSON object, got \(line)")
            return
        }
        XCTAssertEqual(firstSubscription["type"] as? String, "pane.created")

        // Resolve the still-pending subscribe() so this test doesn't hang.
        guard let id = object["id"] as? String else {
            XCTFail("expected \"id\" to be a String, got \(line)")
            return
        }
        await transport.simulateLine(subscribeAckLine(id: id))
        _ = try await streamTask
    }

    // MARK: - Regression (R2): every handshake request line, independently, against herdr's minimum envelope
    //
    // This is the check that would have caught the shipped bug
    // regardless of which method regressed: unlike the per-method tests
    // above (which also pin the exact key set / a specific "method"
    // value), this one is deliberately generic -- it says nothing about
    // WHICH method a request line belongs to, only that every line the
    // session hands to the transport during a full handshake carries a
    // non-empty "id", a non-empty "method", and a "params" that is
    // present and a JSON object.

    func test_everyHandshakeRequestLine_independently_satisfiesHerdrsMinimumEnvelope() async throws {
        let transport = InMemoryHerdrTransport()
        let session = HerdrSocketSession(transport: transport)
        try await session.start(socketPath: "/tmp/herdr-envelope-regression-test/herdr.sock")

        async let pingTask = session.ping()
        async let snapshotTask = session.snapshot()
        async let subscribeTask = session.subscribe([.typeOnly("pane.created")])

        let sent = await awaitSentMessages(transport, atLeast: 3)
        guard sent.count == 3,
              let pingLine = sent.first(where: { requestMethod(inLine: $0) == "ping" }),
              let snapshotLine = sent.first(where: { requestMethod(inLine: $0) == "session.snapshot" }),
              let subscribeLine = sent.first(where: { requestMethod(inLine: $0) == "events.subscribe" }),
              let pingID = requestID(inLine: pingLine),
              let snapshotID = requestID(inLine: snapshotLine),
              let subscribeID = requestID(inLine: subscribeLine)
        else {
            XCTFail("expected exactly one ping / session.snapshot / events.subscribe request, each with an id; got \(sent)")
            return
        }

        for line in [pingLine, snapshotLine, subscribeLine] {
            assertSatisfiesMinimumRequestEnvelope(line)
        }

        // Resolve every still-pending call so this test doesn't hang.
        await transport.simulateLine(pingResponseLine(id: pingID))
        await transport.simulateLine(snapshotResponseLine(id: snapshotID))
        await transport.simulateLine(subscribeAckLine(id: subscribeID))
        _ = try await pingTask
        _ = try await snapshotTask
        _ = try await subscribeTask
    }

    // MARK: - Fixture builders (exact shapes measured against real herdr 0.8.0)

    private func pingResponseLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"pong","version":"0.8.0","protocol":19,"capabilities":{"live_handoff":true,"detached_server_daemon":false}}}"#
    }

    private func snapshotResponseLine(id: String) -> String {
        #"""
        {"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"focused_workspace_id":"w9","focused_tab_id":"w9:t1","focused_pane_id":"w9:p1","workspaces":[],"tabs":[],"panes":[],"layouts":[],"agents":[{"terminal_id":"term_658b1a46d5aba9","agent":"claude","agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":false,"state_change_seq":5,"cwd":"/Users/eguchiyuuichi","foreground_cwd":"/Users/eguchiyuuichi","revision":0}]}}}
        """#
    }

    private func subscribeAckLine(id: String) -> String {
        #"{"id":"\#(id)","result":{"type":"subscription_started"}}"#
    }

    /// herdr's measured error response shape --
    /// {"id":"..","error":{"code":"..","message":".."}} (B4).
    private func errorResponseLine(id: String, code: String, message: String) -> String {
        #"{"id":"\#(id)","error":{"code":"\#(code)","message":"\#(message)"}}"#
    }

    private func paneCreatedEventLine() -> String {
        #"""
        {"data":{"pane":{"terminal_id":"term_658b1a46d5aba9","agent":"claude","agent_status":"blocked","workspace_id":"w9","tab_id":"w9:t1","pane_id":"w9:p1","focused":false,"state_change_seq":5,"cwd":"/Users/eguchiyuuichi","foreground_cwd":"/Users/eguchiyuuichi","revision":0},"type":"pane_created"},"event":"pane_created"}
        """#
    }

    // MARK: - Wire-line parsing helpers (parse back to JSON -- never string comparison, JSONEncoder key order isn't stable)

    private func jsonObject(inLine line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func requestID(inLine line: String) -> String? {
        jsonObject(inLine: line)?["id"] as? String
    }

    private func requestMethod(inLine line: String) -> String? {
        jsonObject(inLine: line)?["method"] as? String
    }

    // MARK: - Minimum request envelope assertion (R1/R2)

    /// Asserts that `line` decodes to a JSON object satisfying herdr's
    /// own documented MINIMUM request envelope, measured directly
    /// against a real herdr 0.8.0 server (see HerdrSocketSession.swift's
    /// own header): a non-empty string "id", a non-empty string
    /// "method", and a "params" value that is PRESENT and a JSON
    /// OBJECT -- never omitted entirely, never `null`. Both "params"
    /// omitted and "params": null make herdr respond with an
    /// "invalid_request" error AND close the connection.
    ///
    /// `object["params"]` is `nil` ONLY when the key is absent entirely
    /// -- `JSONSerialization` represents a JSON `null` as `NSNull`, a
    /// PRESENT dictionary value -- so the two guards below correctly
    /// distinguish "omitted" (first guard fails) from "null" (second
    /// guard's `is [String: Any]` check fails, since `NSNull` is not a
    /// dictionary) from a genuine object (both pass).
    ///
    /// Deliberately does NOT assert an exact key set or reject extra
    /// fields inside "params" -- this is a MINIMUM envelope check, used
    /// by the cross-cutting R2 regression test where the exact shape is
    /// intentionally out of scope; the per-method R1 tests above assert
    /// the exact key set themselves where the task calls for it.
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

    // MARK: - Bounded async polling (mirrors HerdrSessionDiscoveryTests' own waitUntil precedent)

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve -- a regression that leaves
    /// `condition()` permanently false (e.g. a message that is never
    /// actually sent, or a session that leaks instead of being released)
    /// exhausts this bound instead of hanging the test; the subsequent
    /// `guard ... else { XCTFail }` / `XCTAssert...` in each test above
    /// is what turns that into a clean, informative failure.
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
