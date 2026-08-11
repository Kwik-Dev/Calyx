// HerdrSocketSession.swift
// Calyx
//
// Actor over `HerdrTransport` implementing herdr's request/response +
// push-event wire protocol (measured against a real herdr 0.8.0
// server, protocol 19):
//
//   - Every request is one NDJSON line:
//     {"id":"...","method":"...","params":{...}} -- `params` is
//     REQUIRED and must be a JSON object on EVERY request, even for a
//     method that takes no arguments of its own (e.g. `ping`,
//     `session.snapshot`): measured directly against a real herdr
//     0.8.0 server, a request with `params` omitted entirely, or sent
//     as `null`, is rejected with {"error":{"code":"invalid_request",
//     "message":"..."}} AND the connection is closed. A method with
//     nothing of its own to send still encodes `params` as an empty
//     object (`{}`, via `HerdrEmptyParams` below) rather than omitting
//     the key.
//   - A response echoes the SAME "id": either {"id":..,"result":{...}}
//     or {"id":..,"error":{"code":"...","message":"..."}} -- note
//     `code` is a STRING here (see `HerdrRPCError`'s own doc comment),
//     and there is NO top-level "jsonrpc" field anywhere on this wire
//     -- this is NOT JSON-RPC 2.0. Do not reuse `JSONRPCRequest` /
//     `JSONRPCResponse` / `JSONRPCError` from
//     Calyx/Features/IPC/JSONRPC.swift here, and do not "fix"
//     `HerdrRPCError.code` to an Int to match `JSONRPCError` -- these
//     are two separate, non-interchangeable wire protocols that happen
//     to share this codebase's `AnyCodable` helper type, nothing more.
//   - `events.subscribe` may be sent AT MOST ONCE per connection: "a
//     connection accepts events.subscribe EXACTLY ONCE... a second
//     events.subscribe on a live subscribed connection causes the
//     server to close it." `subscribe(_:)` below enforces this itself
//     (throws `HerdrSocketSessionError.alreadySubscribed` rather than
//     ever putting a second attempt on the wire), and sets its
//     "already attempted" bookkeeping SYNCHRONOUSLY, before its first
//     `await`, closing the actor-reentrancy window a second,
//     concurrently-racing caller could otherwise slip through. The
//     flag is sticky even after a FAILED first attempt -- herdr's own
//     "exactly once" rule has no documented retry-after-failure
//     carve-out, and a failed attempt has very likely already gotten
//     this connection closed by the server anyway.
//   - On subscribe, herdr immediately replays every EXISTING pane as a
//     pane_created event on the SAME connection, before any newly
//     pushed events. The real implementation of `subscribe(_:)` must
//     create the returned event stream BEFORE awaiting the subscribe
//     ack, precisely so those replayed events are never dropped for
//     arriving before the stream existed.
//   - EOF vs failure: a single pending request (`ping`/`snapshot`/the
//     subscribe ack) has no more result coming either way once the
//     transport ends, so BOTH `.eof` and `.failure` must fail it (as
//     `.transportEOF` / `.transportFailure`, respectively) -- there is
//     no graceful way for a call awaiting exactly one result to do
//     anything else. The long-lived event stream `subscribe(_:)`
//     returns is different: `AsyncThrowingStream` already has an
//     idiomatic way to express "ended, and here is whether that is
//     exceptional" -- a clean transport EOF must finish the stream
//     NORMALLY (`for try await` simply ends, no throw), while a
//     transport failure must finish it BY THROWING. This is a
//     deliberate asymmetry between the two surfaces, not an
//     inconsistency -- see HerdrTransport.swift's own header for why
//     EOF and failure are distinct events in the first place.
//
// Implementation shape:
//   - A `pending: [String: PendingEntry]` id-correlation table mirrors
//     `LSPClient.PendingEntry`'s own early-result-slot pattern
//     (Calyx/Features/LSP/Client/LSPClient.swift): the pending slot is
//     registered BEFORE sending, not after, so a response the receive
//     loop processes between "send returns" and "the continuation is
//     attached" is stored as an early result instead of silently
//     dropped (which would hang the caller forever). Unlike
//     `LSPClient.PendingEntry`, this file's `PendingEntry` never
//     crosses actor isolation (no task group, no `@Sendable` closure
//     capture), so it does not need `@unchecked Sendable` -- every
//     touch happens directly inside this actor's own isolated methods.
//   - A receive loop (`start(socketPath:)` spawns it) consumes
//     `transport.incoming`, decoding each `.line` as either a response
//     (has "id") or a pushed event (decode via `HerdrEvent`), and
//     forwarding pushed events onto the active subscription's stream
//     continuation, if any. A line that is not valid JSON, or JSON this
//     file cannot make sense of (no "id" AND not a decodable
//     `HerdrEvent`), is silently dropped -- mirrors
//     `LSPClient.dispatch(body:)`'s own identical "can't usefully
//     respond because we don't know the id" precedent.
//   - On `.eof` / `.failure`, OR the receive loop ending for any other
//     reason (e.g. `transport.close()` being called directly, which
//     `HerdrTransport`'s own contract permits to finish `incoming`
//     WITHOUT yielding either terminal event first): fail every pending
//     request the matching way (`.transportEOF` / `.transportFailure`),
//     AND, if subscribed, finish the active event-stream continuation
//     the matching way (`.finish()` for EOF/unexplained-end,
//     `.finish(throwing:)` for failure). Idempotent -- the first
//     termination (by whichever path) wins.
//

import Foundation

// MARK: - HerdrSubscription

/// One entry of an `events.subscribe` request's `subscriptions` array.
enum HerdrSubscription: Sendable, Equatable {
    /// A bare {"type": "<name>"} subscription -- every type-only kind
    /// herdr documents: pane.created, pane.updated, pane.closed,
    /// pane.exited, pane.agent_detected, pane.focused, pane.moved,
    /// layout.updated, tab.*, workspace.*, worktree.*.
    case typeOnly(String)
    /// pane.agent_status_changed -- `paneID` is REQUIRED; there is NO
    /// global/type-only form of this subscription (subscribing without
    /// a pane_id is invalid_request and closes the connection).
    /// `agentStatus` is an optional server-side filter.
    case agentStatusChanged(paneID: String, agentStatus: HerdrAgentStatus? = nil)
    /// pane.scroll_changed -- `paneID` REQUIRED.
    case scrollChanged(paneID: String)
    /// pane.output_matched -- `paneID`, `source`, `match` all REQUIRED.
    case outputMatched(paneID: String, source: String, match: String)
}

extension HerdrSubscription: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
        case agentStatus = "agent_status"
        case source
        case match
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .typeOnly(let type):
            try container.encode(type, forKey: .type)
        case .agentStatusChanged(let paneID, let agentStatus):
            try container.encode("pane.agent_status_changed", forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encodeIfPresent(agentStatus, forKey: .agentStatus)
        case .scrollChanged(let paneID):
            try container.encode("pane.scroll_changed", forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case .outputMatched(let paneID, let source, let match):
            try container.encode("pane.output_matched", forKey: .type)
            try container.encode(paneID, forKey: .paneID)
            try container.encode(source, forKey: .source)
            try container.encode(match, forKey: .match)
        }
    }
}

// MARK: - Response payload types

/// `ping`'s result: {"type":"pong","version":"0.8.0","protocol":19,
/// "capabilities":{...}}. `type` itself ("pong") is not modeled --
/// `HerdrSocketSession.ping()` is the only caller, and it already knows
/// statically what it asked for. Plain compiler-synthesized
/// `Decodable`.
struct HerdrPingResult: Sendable, Equatable, Decodable {
    let version: String
    let protocolVersion: Int
    let capabilities: HerdrCapabilities

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case capabilities
    }
}

struct HerdrCapabilities: Sendable, Equatable, Decodable {
    let liveHandoff: Bool
    let detachedServerDaemon: Bool

    private enum CodingKeys: String, CodingKey {
        case liveHandoff = "live_handoff"
        case detachedServerDaemon = "detached_server_daemon"
    }
}

/// `session.snapshot`'s decoded `snapshot` object. `version`/
/// `protocolVersion` decode as `AnyCodable?` rather than a pinned
/// concrete type -- unlike `ping`'s own `version` (String) / `protocol`
/// (Int), NEITHER field's type was actually observed on this wire (the
/// measured facts this file is built from only name-check them as part
/// of `snapshot`'s shape); pinning a guessed type risks a hard decode
/// failure against a real server for a field none of this stage's
/// callers currently read. `workspaces`/`tabs`/`layouts` are similarly
/// `[AnyCodable]` -- present, but with an unmeasured element shape;
/// missing entirely is tolerated (defaults to `[]`). `panes`/`agents`
/// are the fields this stage actually consumes, so they stay REQUIRED,
/// strongly-typed arrays -- a `session.snapshot` response missing
/// either is a genuinely exceptional response worth surfacing as a
/// decode error rather than silently degrading to `[]`.
struct HerdrSessionSnapshot: Sendable, Equatable {
    let version: AnyCodable?
    let protocolVersion: AnyCodable?
    let focusedWorkspaceID: String?
    let focusedTabID: String?
    let focusedPaneID: String?
    let workspaces: [AnyCodable]
    let tabs: [AnyCodable]
    let panes: [HerdrPaneRecord]
    let layouts: [AnyCodable]
    let agents: [HerdrAgentRecord]
}

extension HerdrSessionSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces
        case tabs
        case panes
        case layouts
        case agents
    }

    /// `panes`/`agents` are required; `workspaces`/`tabs`/`layouts`
    /// default to `[]` when absent; `version`/`protocolVersion` are
    /// optional `AnyCodable`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(AnyCodable.self, forKey: .version)
        protocolVersion = try container.decodeIfPresent(AnyCodable.self, forKey: .protocolVersion)
        focusedWorkspaceID = try container.decodeIfPresent(String.self, forKey: .focusedWorkspaceID)
        focusedTabID = try container.decodeIfPresent(String.self, forKey: .focusedTabID)
        focusedPaneID = try container.decodeIfPresent(String.self, forKey: .focusedPaneID)
        workspaces = try container.decodeIfPresent([AnyCodable].self, forKey: .workspaces) ?? []
        tabs = try container.decodeIfPresent([AnyCodable].self, forKey: .tabs) ?? []
        layouts = try container.decodeIfPresent([AnyCodable].self, forKey: .layouts) ?? []
        panes = try container.decode([HerdrPaneRecord].self, forKey: .panes)
        agents = try container.decode([HerdrAgentRecord].self, forKey: .agents)
    }
}

/// `session.snapshot`'s full RPC result wrapper --
/// {"type":"session_snapshot","snapshot":{...}}. Private: only
/// `HerdrSocketSession.snapshot()` needs the outer "type" discriminator
/// stripped away; every other caller works with `HerdrSessionSnapshot`
/// directly.
private struct HerdrSnapshotRPCResult: Sendable, Decodable {
    let snapshot: HerdrSessionSnapshot
}

/// B5 fix: decodes just the top-level "result" key straight out of a
/// FULL, raw response line -- {"id":"..","result":{...T...}} -- as `T`.
/// `handleResponse` hands every successfully-resolved request the whole
/// raw line verbatim (see its own doc comment); this is what lets
/// `ping()` / `snapshot()` decode their own concrete result type
/// directly from it in ONE pass, without `HerdrSocketSession` itself
/// ever re-encoding `object["result"]` in isolation first.
private struct HerdrResponseEnvelope<T: Decodable>: Decodable {
    let result: T
}

// MARK: - HerdrRPCError

/// herdr's own error shape --
/// {"error":{"code":"invalid_request","message":"..."}}. `code` is a
/// STRING on this wire (e.g. "invalid_request"), unlike
/// `JSONRPCError.code` (an Int) used elsewhere in this codebase for
/// LSP/MCP -- these are deliberately two separate, non-interchangeable
/// types; do not conflate them or "fix" this one to match the other.
/// There is also no top-level "jsonrpc" field anywhere on this wire --
/// this is NOT JSON-RPC 2.0.
struct HerdrRPCError: Sendable, Equatable, Decodable, Error {
    let code: String
    let message: String
}

// MARK: - HerdrSocketSessionError

enum HerdrSocketSessionError: Error, Sendable, Equatable {
    /// `subscribe(_:)` called more than once on the same session -- see
    /// this file's header and `subscribe(_:)`'s own doc comment.
    case alreadySubscribed
    /// The server returned an "error" object for a request.
    case rpc(HerdrRPCError)
    /// The transport ended (EOF) while this request was still pending.
    case transportEOF
    /// The transport failed (not a clean EOF) while this request was
    /// still pending.
    case transportFailure(String)
    /// A response line had neither "result" nor "error" -- a genuine
    /// protocol violation, never observed against a real herdr server.
    /// (Before the B5 fix, this case was ALSO used when a successful
    /// "result" value failed to re-encode for the caller's own
    /// `Decodable` type; `handleResponse` no longer re-encodes anything
    /// -- see its own doc comment -- so that trigger no longer exists.)
    /// Mirrors `LSPClientError.malformedFraming`'s own precedent for
    /// "the wire said something this client cannot make
    /// sense of."
    case malformedResponse(String)
}

// MARK: - Outbound request envelopes

/// Empty JSON object payload for a request whose method takes no
/// arguments of its own (`ping`, `session.snapshot`) -- a
/// zero-stored-property struct's synthesized `Encodable` conformance
/// encodes as `{}`, which is what herdr requires there instead of
/// `params` being omitted or `null` -- see this file's header.
private struct HerdrEmptyParams: Encodable {}

/// `ping` / `session.snapshot` -- methods that take no arguments of
/// their own, but still carry `"params":{}` on the wire (via
/// `HerdrEmptyParams` above), the same as `HerdrSubscribeRequest`
/// below always carries its own non-empty `params` -- see this file's
/// header.
private struct HerdrEmptyParamsRequest: Encodable {
    let id: String
    let method: String
    let params = HerdrEmptyParams()
}

/// `events.subscribe`'s own params object.
private struct HerdrSubscribeParams: Encodable {
    let subscriptions: [HerdrSubscription]
}

private struct HerdrSubscribeRequest: Encodable {
    let id: String
    let method: String
    let params: HerdrSubscribeParams
}

// MARK: - HerdrSocketSession

/// Actor over `HerdrTransport` -- see this file's header for the full
/// wire contract.
actor HerdrSocketSession {

    /// Reference-typed dispatch slot held in `pending`, mirroring
    /// `LSPClient.PendingEntry`'s own early-result-slot pattern -- see
    /// this file's header for why this one does not need
    /// `@unchecked Sendable`. On a successful RPC response, `Data` is
    /// the WHOLE raw response line, verbatim (see `handleResponse`'s own
    /// doc comment) -- not a re-encoded "result" sub-value.
    private final class PendingEntry {
        var continuation: CheckedContinuation<Data, Error>?
        var earlyResult: Result<Data, Error>?
    }

    private let transport: any HerdrTransport

    /// B5 fix: shared `JSONDecoder`/`JSONEncoder` instances, reused
    /// across every request/response/event on this session, instead of
    /// allocating a fresh instance per call -- both types are stateless
    /// w.r.t. what they have previously encoded/decoded given the same
    /// input, and neither is configured with any per-call strategy here,
    /// so sharing changes nothing observable. Instance (not `static`)
    /// properties: a `static let` would need to be `Sendable`, and
    /// `JSONDecoder`/`JSONEncoder` are mutable reference types that do
    /// not conform.
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    /// `true` once the receive loop has observed a terminal transport
    /// event (`.eof`/`.failure`) or the incoming stream simply ended.
    /// Idempotency guard for `terminate(sessionError:finishStreamNormally:)`.
    private var isTerminated = false

    /// Set exactly once, by `terminate(sessionError:finishStreamNormally:)`.
    /// Consulted by `sendNoParamsRequest`/`subscribe` so a call made
    /// after the transport has already ended surfaces the SAME
    /// `HerdrSocketSessionError` case the original termination produced,
    /// instead of a raw `HerdrTransportError` from a doomed `send`.
    private var terminationError: HerdrSocketSessionError?

    private var nextRequestID = 1
    private var pending: [String: PendingEntry] = [:]

    /// See `subscribe(_:)`'s own doc comment for the "exactly once,
    /// sticky even after failure" contract this guards.
    private var hasAttemptedSubscribe = false

    /// Non-nil for the lifetime of one successful subscription -- the
    /// continuation of the `AsyncThrowingStream` returned by
    /// `subscribe(_:)`, fed by the receive loop and torn down by
    /// `terminate(sessionError:finishStreamNormally:)`.
    private var eventContinuation: AsyncThrowingStream<HerdrEvent, Error>.Continuation?

    init(transport: any HerdrTransport) {
        self.transport = transport
    }

    /// Connects `transport` to `socketPath` and starts the receive loop.
    /// Must be called exactly once before `ping` / `snapshot` /
    /// `subscribe`.
    func start(socketPath: String) async throws {
        try await transport.connect(socketPath: socketPath)

        // Unstructured and intentionally not retained: it needs no
        // external cancellation (ordinary teardown of this actor is
        // ARC-driven, not a routine `close()` call -- `abandon()` below
        // is a narrow, single-purpose exception, called only by
        // `HerdrIntegrationCoordinator`'s own HANDSHAKE DEADLINE (A2)
        // timeout arm; see that method's own doc comment) and keeps
        // running independently of this handle. Captures `self` weakly
        // so the receive loop can never keep this actor alive by itself
        // -- see `BSDHerdrTransport`'s own `deinit` doc comment for why
        // that matters for teardown-without-`close()`.
        let incoming = transport.incoming
        Task { [weak self] in
            for await event in incoming {
                guard let self else { return }
                await self.handle(event)
            }
            // The stream ended without a terminal `.eof`/`.failure`
            // element ever being observed above -- `HerdrTransport
            // .close()`'s own contract permits finishing `incoming`
            // this way (see this file's header). Treat it the same as
            // a clean EOF: a no-op if `.eof`/`.failure` already ran
            // `terminate(...)`, otherwise the only remaining chance to
            // resolve any still-pending requests / the event stream
            // instead of leaving them suspended forever. This is also
            // exactly the path `abandon()` below relies on.
            guard let self else { return }
            await self.terminate(sessionError: .transportEOF, finishStreamNormally: true)
        }
    }

    /// Emergency, non-ARC teardown for a session whose handshake is
    /// STUCK -- called ONLY by `HerdrIntegrationCoordinator`'s own
    /// HANDSHAKE DEADLINE (A2) timeout arm, when it wins the race
    /// against a `performHandshake` that is suspended inside some
    /// pending request's own `awaitEntry` continuation (e.g. `ping()`)
    /// with no result ever coming because herdr accepted the connection
    /// but never answers. Every OTHER caller in this codebase still
    /// relies on dropping its last strong reference to a
    /// `HerdrSocketSession` as that session's complete teardown (see
    /// this file's header) -- that only works because the reference is
    /// actually dropped; it does NOT work here, because a
    /// `CheckedContinuation` never resumes itself on cancellation, so a
    /// suspended `awaitEntry` call keeps whatever `Task` closure is
    /// awaiting it -- and everything that closure captured, including
    /// this session itself -- alive forever no matter how many times
    /// that `Task` is `cancel()`ed.
    ///
    /// `transport.close()` is what actually breaks that: it finishes
    /// `transport.incoming` (idempotently, per `HerdrTransport
    /// .close()`'s own contract) even though this session itself never
    /// called `close()` before. `start(socketPath:)`'s own receive loop
    /// above then observes `incoming` ending without ever having seen a
    /// terminal `.eof`/`.failure` element -- already one of its
    /// documented, handled cases -- and falls through to
    /// `terminate(sessionError: .transportEOF, finishStreamNormally:
    /// true)`, which fails every pending request (including the one
    /// STILL SUSPENDED inside `awaitEntry`) and finishes the event
    /// stream normally. That is what finally lets the stuck caller's
    /// `Task` closure unwind and release its own captures.
    func abandon() async {
        await transport.close()
    }

    /// `ping` handshake -- version + protocol + capabilities. `data` is
    /// the whole raw response line (B5 fix -- see `handleResponse`'s own
    /// doc comment); `HerdrResponseEnvelope` reads back out just its
    /// "result" key.
    func ping() async throws -> HerdrPingResult {
        let data = try await sendNoParamsRequest(method: "ping")
        return try jsonDecoder.decode(HerdrResponseEnvelope<HerdrPingResult>.self, from: data).result
    }

    /// `session.snapshot` -- the full session snapshot, including
    /// `agents[]` ("the authoritative source for rendering rows"). See
    /// `ping()`'s own comment on `data`/`HerdrResponseEnvelope`.
    func snapshot() async throws -> HerdrSessionSnapshot {
        let data = try await sendNoParamsRequest(method: "session.snapshot")
        return try jsonDecoder.decode(HerdrResponseEnvelope<HerdrSnapshotRPCResult>.self, from: data).result.snapshot
    }

    /// `events.subscribe` -- may be called AT MOST ONCE; see this
    /// file's header. On success, returns a stream of pushed events
    /// (the replayed pane_created burst included) that finishes
    /// NORMALLY on a clean transport EOF, or finishes BY THROWING on a
    /// transport failure -- see this file's header for why.
    func subscribe(_ subscriptions: [HerdrSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, Error> {
        if let terminationError {
            throw terminationError
        }
        guard !hasAttemptedSubscribe else {
            throw HerdrSocketSessionError.alreadySubscribed
        }
        // Set SYNCHRONOUSLY, before this method's first `await`, so a
        // second, concurrently-racing caller can never also observe
        // "not yet attempted" -- see this file's header.
        hasAttemptedSubscribe = true

        let id = makeRequestID()
        let requestData = try jsonEncoder.encode(
            HerdrSubscribeRequest(id: id, method: "events.subscribe", params: HerdrSubscribeParams(subscriptions: subscriptions))
        )
        let line = String(decoding: requestData, as: UTF8.self)

        // Create (and wire) the returned stream BEFORE the request is
        // even sent -- herdr can replay existing panes as pane_created
        // events as soon as it processes the subscribe, and they must
        // never be dropped for arriving before the stream existed.
        let (stream, continuation) = AsyncThrowingStream<HerdrEvent, Error>.makeStream()
        eventContinuation = continuation

        let entry = PendingEntry()
        pending[id] = entry

        do {
            try await transport.send(line)
        } catch {
            pending.removeValue(forKey: id)
            eventContinuation = nil
            // B3 fix: `transport.send` can race the receive loop
            // observing a terminal transport event WHILE this call was
            // suspended awaiting it (actor reentrancy) -- `terminationError`,
            // if now set, is the correctly-normalized
            // `HerdrSocketSessionError` that race produced; prefer it
            // over the raw, transport-level error `send` itself threw
            // (e.g. `HerdrTransportError.alreadyClosed`), so a caller
            // never sees an un-normalized error type from this actor --
            // see this file's header.
            let normalized = terminationError ?? error
            continuation.finish(throwing: normalized)
            throw normalized
        }

        do {
            _ = try await awaitEntry(id: id, entry: entry)
        } catch {
            eventContinuation = nil
            continuation.finish(throwing: error)
            throw error
        }

        return stream
    }

    // MARK: - Outbound requests

    private func makeRequestID() -> String {
        defer { nextRequestID += 1 }
        return String(nextRequestID)
    }

    private func sendNoParamsRequest(method: String) async throws -> Data {
        if let terminationError {
            throw terminationError
        }
        let id = makeRequestID()
        let requestData = try jsonEncoder.encode(HerdrEmptyParamsRequest(id: id, method: method))
        let line = String(decoding: requestData, as: UTF8.self)

        let entry = PendingEntry()
        pending[id] = entry

        do {
            try await transport.send(line)
        } catch {
            pending.removeValue(forKey: id)
            // B3 fix: see the identical race handling (and its doc
            // comment) in `subscribe(_:)`'s own `transport.send` catch
            // block above.
            throw terminationError ?? error
        }

        return try await awaitEntry(id: id, entry: entry)
    }

    /// Shared tail of every request: suspend on `entry`'s dispatch slot
    /// until the receive loop resolves it (or an early result already
    /// raced ahead of us). Runs in actor context, so the synchronous
    /// body of `withCheckedThrowingContinuation` can touch `pending` /
    /// `entry` directly -- mirrors `LSPClient.suspendOnEntry`.
    private func awaitEntry(id: String, entry: PendingEntry) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            if let early = entry.earlyResult {
                pending.removeValue(forKey: id)
                switch early {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
            } else {
                entry.continuation = continuation
            }
        }
    }

    // MARK: - Receive loop

    private func handle(_ event: HerdrTransportEvent) {
        switch event {
        case .line(let line):
            handleLine(line)
        case .eof:
            terminate(sessionError: .transportEOF, finishStreamNormally: true)
        case .failure(let failure):
            terminate(sessionError: .transportFailure(failure.message), finishStreamNormally: false)
        }
    }

    /// Parses one inbound NDJSON line and routes it to a pending
    /// request (has "id") or the active event-stream subscription
    /// (everything else, decoded via `HerdrEvent`). A line that is not
    /// valid JSON, not a JSON object, or -- lacking an "id" -- not a
    /// decodable `HerdrEvent`, is silently dropped: there is no id to
    /// correlate a response to, and no way to act on an event this file
    /// cannot make sense of. Mirrors `LSPClient.dispatch(body:)`'s own
    /// identical precedent.
    ///
    /// B5 fix: `data` (the line's raw UTF-8 bytes) is parsed via
    /// `JSONSerialization` exactly ONCE here -- the resulting
    /// `[String: Any]` is what BOTH the "id" check below AND
    /// `handleResponse`'s own lenient "error"/"result" field extraction
    /// work from -- and `data` itself is passed through to
    /// `handleResponse` as `rawLine`, so a successful "result" response
    /// can be resolved directly from it (see that method's own doc
    /// comment) without a second, redundant parse of the same bytes.
    private func handleLine(_ line: String) {
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = object["id"] as? String {
            handleResponse(id: id, object: object, rawLine: data)
            return
        }

        guard let event = try? jsonDecoder.decode(HerdrEvent.self, from: data) else {
            return
        }
        eventContinuation?.yield(event)
    }

    /// Resolves the pending request matching `id`, if any, using
    /// `object` (the SAME `[String: Any]` `handleLine` already parsed
    /// `rawLine` into) for the lenient "error"/"result" checks below.
    ///
    /// B5 fix: a successful "result" response resolves with `rawLine`
    /// -- the WHOLE raw response line, verbatim -- rather than
    /// re-encoding `object["result"]` in isolation via `AnyCodable` +
    /// `JSONEncoder`. `ping()` / `snapshot()` (the only two callers that
    /// need a concrete decoded type) read back out just the "result" key
    /// themselves, via `HerdrResponseEnvelope<T>` -- see its own doc
    /// comment. This removes a whole encode pass (`AnyCodable`'s own
    /// `Encodable` conformance plus `JSONEncoder`) that existed only to
    /// hand a caller data it could otherwise get directly from the bytes
    /// already sitting in `rawLine`.
    private func handleResponse(id: String, object: [String: Any], rawLine: Data) {
        guard let entry = pending.removeValue(forKey: id) else {
            // No matching pending request -- drop.
            return
        }

        let outcome: Result<Data, Error>
        if let errorObject = object["error"] as? [String: Any] {
            let code = (errorObject["code"] as? String) ?? ""
            let message = (errorObject["message"] as? String) ?? ""
            outcome = .failure(HerdrSocketSessionError.rpc(HerdrRPCError(code: code, message: message)))
        } else if object.keys.contains("result") {
            outcome = .success(rawLine)
        } else {
            outcome = .failure(HerdrSocketSessionError.malformedResponse("response missing both 'result' and 'error'"))
        }

        resolve(entry, with: outcome)
    }

    private func resolve(_ entry: PendingEntry, with outcome: Result<Data, Error>) {
        if let continuation = entry.continuation {
            entry.continuation = nil
            switch outcome {
            case .success(let data): continuation.resume(returning: data)
            case .failure(let error): continuation.resume(throwing: error)
            }
        } else {
            entry.earlyResult = outcome
        }
    }

    /// Terminal handling shared by `.eof`, `.failure`, and the receive
    /// loop simply ending -- see this file's header. Idempotent: only
    /// the FIRST call does anything.
    private func terminate(sessionError: HerdrSocketSessionError, finishStreamNormally: Bool) {
        guard !isTerminated else { return }
        isTerminated = true
        terminationError = sessionError

        let snapshot = pending
        pending.removeAll()
        for (_, entry) in snapshot {
            resolve(entry, with: .failure(sessionError))
        }

        if let continuation = eventContinuation {
            eventContinuation = nil
            if finishStreamNormally {
                continuation.finish()
            } else {
                continuation.finish(throwing: sessionError)
            }
        }
    }
}
