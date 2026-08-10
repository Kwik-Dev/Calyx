// SessionBrowserModel.swift
// Calyx
//
// UI-independent logic layer behind the session browser window:
// fetches the daemon's full session ledger
// (`SessionDaemonClient.listAll()`), keeps only its Running sessions
// (an Exited entry has no affordances here -- nothing to attach to,
// nothing to reconnect -- and the daemon ledger's own GC handles its
// eventual removal, so the browser is a view of attachable/killable
// sessions, not the raw ledger), flags orphaned running sessions
// (a session with no live ghostty surface attached in this Calyx
// process — `SessionSurfaceMap` has no entry for it), and exposes
// attach/kill actions. Kept separate from
// `SessionBrowserWindowController` (AppKit/SwiftUI chrome) so it's
// directly unit-testable — no window, no real daemon process — the
// same way `SessionBrowserModelTests` exercises it.
//
import Foundation

struct SessionBrowserRow: Identifiable, Equatable, Sendable {
    var id: String { info.id }
    let info: SessionInfo
    /// `true` for a running session with no current `SessionSurfaceMap`
    /// entry -- i.e. the daemon still has its child process alive, but
    /// no ghostty surface in this Calyx process is attached to it
    /// (orphaned by a crash, a `kill -9`'d Calyx process, or a session
    /// started by a different Calyx launch). Every `SessionBrowserRow`
    /// wraps a running session (`SessionBrowserModel.refresh()` never
    /// produces a row for an exited one), so this is the only case
    /// `isOrphan` distinguishes.
    let isOrphan: Bool
    /// `true` when `SessionSurfaceMap` currently has a surface for
    /// this session in this Calyx process — i.e. it's already visibly
    /// attached somewhere, so "Attach" in the browser should reveal
    /// that pane rather than open a second attach connection.
    let isAttachedHere: Bool

    /// User-visible label for the `isOrphan` badge (`SessionBrowserRowView`).
    /// Kept separate from the SwiftUI view so this string is testable
    /// without a snapshot/view-inspection dependency. Internal name
    /// (`isOrphan`) is unchanged this cycle -- only the user-visible
    /// wording moves from "Orphaned" to "Detached".
    static let orphanBadgeLabel = "Detached"

    /// User-visible label for the row's Attach/Show button
    /// (`SessionBrowserRowView`, `Button("Attach") { model.attach(row) }`
    /// today -- a literal, unconditional string, same one-line pattern
    /// as the `isOrphan` badge before `orphanBadgeLabel` existed). An
    /// already-attached row's button currently still reads "Attach",
    /// which is meaningless -- attaching a session that's already
    /// visibly attached somewhere in this process makes no sense; the
    /// action it actually performs (via `SessionAttachRoutingPolicy`'s
    /// `.focusExistingSurface` routing) is revealing/focusing that pane,
    /// so the label must read a focus verb instead. Exactly "Show" (team
    /// decision, not an implementer choice) once `isAttachedHere`;
    /// unchanged "Attach" otherwise.
    var attachButtonLabel: String {
        isAttachedHere ? "Show" : "Attach"
    }
}

/// Wraps `HerdrSessionInfo` the same way `SessionBrowserRow` wraps
/// `SessionInfo`, so the herdr section has its own row type independent
/// of whatever UI-only state `SessionBrowserRow` carries for
/// calyx-session rows (`isOrphan`/`isAttachedHere` have no herdr
/// equivalent -- herdr identity never enters `SessionSurfaceMap` by
/// design).
struct HerdrSessionRow: Identifiable, Equatable, Sendable {
    var id: String { info.id }
    let info: HerdrSessionInfo
}

@MainActor
@Observable
final class SessionBrowserModel {

    private(set) var rows: [SessionBrowserRow] = []

    /// Populated by `refresh()` from the injected `herdrProvider`, gated
    /// on `herdrAvailability()` (binary resolution only -- see that
    /// property's own doc comment for why "is any session actually
    /// alive" is entirely `herdrProvider`'s own job, not this gate's).
    /// Reset to `[]` on every `refresh()` while herdr is unavailable, so
    /// a herdr that dies mid-session disappears from the browser on the
    /// next poll rather than leaving a frozen last-known list.
    private(set) var herdrRows: [HerdrSessionRow] = []

    private let daemonClient: SessionDaemonClientProtocol
    private let surfaceMap: SessionSurfaceMap
    private let hostCandidateProvider: SSHHostCandidateProvider
    /// Herdr session lister -- see `HerdrSessionProvider.swift`. Defaults
    /// to the production `HerdrCLISessionProvider` (bare discovery +
    /// liveness probe; CLI enrichment isn't wired in yet).
    private let herdrProvider: HerdrSessionProviderProtocol
    /// Reports whether the herdr integration should currently be
    /// treated as available: a CHEAP binary-resolution check only, no
    /// discovery, no socket probes. This must stay free of any per-tick
    /// cost heavier than reading a memoized resolver result, since
    /// `refresh()` calls it unconditionally on every poll. "Is any
    /// session actually alive" deliberately does NOT live here:
    /// `herdrProvider.listSessions()` already performs that discovery +
    /// liveness sweep and returns `[]` when nothing is alive, and
    /// `showHerdrSection` already hides the section from an empty
    /// `herdrRows` -- duplicating that check here would mean two
    /// discovery sweeps (and a second, redundant set of socket probes)
    /// per poll instead of one. A closure, mirroring
    /// `SSHHostCandidateProvider`'s own `loadConfig` closure-injection
    /// precedent, rather than a protocol, so this file never needs to
    /// depend on `HerdrBinaryResolver` directly -- a fake closure here
    /// lets tests fix the answer without touching real PATH state.
    /// `() async -> Bool`, not a plain `() -> Bool`: a memoized HIT is
    /// just a lock-guarded property read, but a MISS (herdr not
    /// installed) re-walks PATH via `FileManager.isExecutableFile` on
    /// every single call -- see `HerdrBinaryResolver`'s own doc comment
    /// for why a miss is deliberately never cached -- and
    /// `defaultHerdrAvailability()` below hops that walk onto
    /// `DispatchQueue.global()` so `refresh()`'s 1s poll never runs it on
    /// the caller's thread (this property is only ever called from
    /// `@MainActor` `refresh()`, so "the caller's thread" means the main
    /// thread).
    /// Defaults to `defaultHerdrAvailability()` (below); an undetected
    /// herdr still renders exactly like today, unchanged, since an
    /// unresolvable binary means `herdrProvider.listSessions()` is never
    /// even called (see `refresh()`'s own negative-invariant test).
    private let herdrAvailability: () async -> Bool

    /// Remote host candidates for the "New Remote Session…" picker,
    /// populated by `refreshRemoteHostCandidates()` from the injected
    /// `hostCandidateProvider`, in its own declaration order.
    private(set) var remoteHostCandidates: [String] = []

    /// Invoked by `attachToRemoteHost(_:)` with the `SessionSpawnContext`
    /// a chosen remote host must turn into -- structurally identical to
    /// what `CalyxWindowController.remoteSessionSpawnContext(forHost:)`
    /// produces for the same host, so both entry points feed the same
    /// downstream spawn contract. Actual surface/window creation is a
    /// `CalyxWindowController` concern, kept out of this pure logic
    /// layer -- mirrors `onAttachRequested`'s injectable-closure
    /// pattern.
    var onRemoteSessionRequested: ((SessionSpawnContext) -> Void)?

    /// R12-A item 3 (r12-fix-spec.md): guards against `refresh()`'s 1s
    /// poll timer stacking an unbounded number of concurrent
    /// `listAllBounded()` round-trips behind a slow/hung daemon. A
    /// second `refresh()` issued while one is still in flight is a
    /// no-op instead of starting its own overlapping daemon call; the
    /// poll naturally backs off to the bound's own cadence instead.
    private var isRefreshing = false

    /// Invoked by `attach(_:)` with the row to attach to. Actual
    /// surface/window creation is a `SessionBrowserWindowController` /
    /// `CalyxWindowController` concern, deliberately kept out of this
    /// pure logic layer — tests inject a closure and assert it was
    /// called with the right row instead of driving real AppKit.
    var onAttachRequested: ((SessionBrowserRow) -> Void)?

    /// Invoked by `attachHerdr(_:)` with the herdr row to attach to --
    /// mirrors `onAttachRequested`'s injectable-closure pattern exactly.
    var onHerdrAttachRequested: ((HerdrSessionRow) -> Void)?

    init(
        daemonClient: SessionDaemonClientProtocol = SessionDaemonClient.shared,
        surfaceMap: SessionSurfaceMap = .shared,
        hostCandidateProvider: SSHHostCandidateProvider = SSHHostCandidateProvider(),
        herdrProvider: HerdrSessionProviderProtocol = HerdrCLISessionProvider(),
        herdrAvailability: @escaping () async -> Bool = SessionBrowserModel.defaultHerdrAvailability()
    ) {
        self.daemonClient = daemonClient
        self.surfaceMap = surfaceMap
        self.hostCandidateProvider = hostCandidateProvider
        self.herdrProvider = herdrProvider
        self.herdrAvailability = herdrAvailability
    }

    /// Builds the production `herdrAvailability` default: binary
    /// resolution only, no discovery, no socket probes (see
    /// `herdrAvailability`'s own doc comment for why that's the whole
    /// rule now). `resolver` is constructed ONCE here -- this factory
    /// runs once per `SessionBrowserModel` instance, exactly like any
    /// other default-parameter expression (Swift evaluates a default
    /// argument fresh per call that omits it, not once globally) -- and
    /// captured by the returned closure, so every later call the closure
    /// receives (e.g. `SessionBrowserView`'s 1s poll, indirectly through
    /// `refresh()`) reuses the SAME `HerdrBinaryResolver` instance
    /// instead of reconstructing one per poll. That reuse is what makes
    /// `HerdrBinaryResolver`'s own per-instance memoization of
    /// `resolve()` (see that type's doc comment) actually pay off here:
    /// repeated polls against an absent/present binary cost one property
    /// read after the first call, not a fresh PATH walk every second.
    ///
    /// The returned closure hops `resolver.resolve()` itself onto
    /// `DispatchQueue.global()` via `withCheckedContinuation`, mirroring
    /// `SystemCommandRunner.locate(_:)`'s identical "run blocking work on
    /// a background queue, resume a non-throwing continuation" shape --
    /// so we do not park the calling thread inside a blocking
    /// `FileManager.isExecutableFile` PATH walk. `refresh()` calls this
    /// unconditionally on every 1s poll while the herdr binary is
    /// undetected (a permanent miss, per `HerdrBinaryResolver`'s own
    /// never-cache-a-miss contract), and `refresh()` runs on `@MainActor`,
    /// so without this hop that walk would run on the main thread once a
    /// second for every user without herdr installed. `resolver` is
    /// `Sendable` (its cache lives behind `OSAllocatedUnfairLock`, see
    /// that type's own doc comment), so capturing it directly in the
    /// `@Sendable` dispatch closure is sound.
    private static func defaultHerdrAvailability() -> () async -> Bool {
        let resolver = HerdrBinaryResolver()
        return {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async {
                    continuation.resume(returning: resolver.resolve() != nil)
                }
            }
        }
    }

    /// Refreshes `rows` from `daemonClient.listAll()`, for Running
    /// sessions only.
    ///
    /// The daemon ledger never removes `Exited` entries on its own (its
    /// retention GC runs on its own schedule); a `listAll()` result
    /// mixing Running and Exited sessions is the ledger's normal shape,
    /// not an edge case. An Exited session has zero affordances here --
    /// nothing to attach to, nothing to reconnect -- so keeping a row
    /// for one would accumulate as a permanent dead row in the browser
    /// (observed in production: 7 stale `Exited(137)` rows) rather than
    /// disappearing once the ledger eventually GCs it. Filtering here
    /// keeps the browser a view of sessions you can actually attach to
    /// or kill.
    ///
    /// R10-C item 2 (r10-fix-spec.md): routed through `listAllBounded()`
    /// rather than `listAll()` directly, since a hung daemon used to
    /// freeze the whole session browser forever. Shares the same 5s
    /// bound `AppDelegate`'s agent-resume path already applied to itself
    /// (see `SessionDaemonClientProtocol.listAllBounded()`'s own doc
    /// comment).
    ///
    /// R14-A sweep addendum item 1 (r14-fix-spec.md): guards on
    /// `Task.isCancelled` before assigning `rows`, mirroring
    /// `AppDelegate.listAllSessionsBounded`'s identical R12-A item 4
    /// guard. Without this, a closed-window poll cancellation (once
    /// R14-A propagates it into `listAllBounded()`'s own race) could
    /// still resolve early with a result that arrives after the
    /// caller gave up, wiping this SHARED model's rows with a stale
    /// value -- an empty flash on reopen.
    ///
    /// After the calyx-session block above, gates the herdr step on
    /// `herdrAvailability()` -- an unresolvable binary clears
    /// `herdrRows` to `[]` and returns WITHOUT ever calling
    /// `herdrProvider.listSessions()` (undetected herdr costs zero
    /// work, checked as a permanent structural invariant by
    /// `SessionBrowserModelHerdrTests`'s own negative test). That
    /// clearing assignment gets the identical `Task.isCancelled` guard
    /// as the `rows` and available-branch `herdrRows` assignments above
    /// it, for the same reason: a late-resolving cancellation must not
    /// let a stale result (here, the unconditional `[]`) overwrite a
    /// previously-populated `herdrRows`
    /// (`SessionBrowserModelHerdrTests`'s own cancellation-guard test).
    /// Clearing unconditionally (not just leaving stale rows alone) is
    /// what makes the herdr section actually disappear on the next poll
    /// after herdr dies, rather than showing a frozen last-known list.
    /// When available, routes through `boundedHerdrListSessions()`
    /// rather than a bare `await`, for the identical reason
    /// `listAllBounded()` exists above: a provider call (this stage's
    /// own bare discovery+probe is fast, but the protocol boundary is
    /// still an injection point a future CLI-enrichment implementation
    /// could make slow) must never freeze this shared poll loop.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let sessions = await daemonClient.listAllBounded()
        guard !Task.isCancelled else { return }
        rows = sessions.filter { $0.state == .running }.map { info in
            let isAttached = surfaceMap.surfaceID(for: info.id) != nil
            return SessionBrowserRow(
                info: info,
                isOrphan: !isAttached,
                isAttachedHere: isAttached
            )
        }

        guard await herdrAvailability() else {
            guard !Task.isCancelled else { return }
            herdrRows = []
            return
        }
        let herdrSessions = await boundedHerdrListSessions()
        guard !Task.isCancelled else { return }
        herdrRows = herdrSessions.map { HerdrSessionRow(info: $0) }
    }

    /// Races `herdrProvider.listSessions()` against the shared
    /// `daemonQueryBoundTimeoutSeconds` bound, degrading to `[]` on
    /// timeout, by reusing `SessionDaemonClientProtocol`'s own
    /// `bounded(operation:onTimeout:timeoutSeconds:)` through
    /// `daemonClient` -- the identical winner-cancels-loser race
    /// `listAllBounded()` uses (promoted from `private` to `internal` in
    /// `SessionDaemonClient.swift` so this file can call it directly
    /// instead of duplicating its own ~80-line bridge). Omitting
    /// `timeoutSeconds:` lets the default `daemonQueryBoundTimeoutSeconds`
    /// bind, so this shares the exact same constant (its `#if DEBUG`
    /// override seam included) as every other bounded daemon call,
    /// rather than inventing a second one.
    private func boundedHerdrListSessions() async -> [HerdrSessionInfo] {
        let herdrProvider = self.herdrProvider
        return await daemonClient.bounded(operation: { await herdrProvider.listSessions() }, onTimeout: { [] })
    }

    /// Requests attaching to `row`'s session.
    func attach(_ row: SessionBrowserRow) {
        onAttachRequested?(row)
    }

    /// Requests attaching to `row`'s herdr session. Mirrors `attach(_:)`
    /// exactly -- herdr identity flows through the same
    /// injected-closure seam, just its own closure/row type.
    func attachHerdr(_ row: HerdrSessionRow) {
        onHerdrAttachRequested?(row)
    }

    /// Kills `row`'s session via the daemon, then refreshes.
    func kill(_ row: SessionBrowserRow) async {
        await daemonClient.kill(id: row.info.id)
        await refresh()
    }

    /// Populates `remoteHostCandidates` from the injected
    /// `hostCandidateProvider`. Gated on
    /// `SessionSettings.persistentSessionsEnabled`: `SessionSpawnPlanner
    /// .plan(for:)` silently downgrades a host-carrying spawn to a local
    /// `.passthrough` while that flag is off, so offering a remote host to
    /// attach to here would be a silent lie about what "Attach" is about
    /// to do. Leaves `remoteHostCandidates` untouched (not cleared) while
    /// the flag is off -- `showRemoteHostsSection` is what actually hides
    /// the section, independent of whatever this array holds.
    func refreshRemoteHostCandidates() {
        guard SessionSettings.persistentSessionsEnabled else { return }
        remoteHostCandidates = hostCandidateProvider.hostCandidates()
    }

    /// Whether the Remote Hosts section should render at all. Reads
    /// `SessionSettings.persistentSessionsEnabled` live (not a cached
    /// snapshot), so flipping the setting off hides the section
    /// immediately, even if `remoteHostCandidates` still holds a stale
    /// non-empty list from an earlier refresh taken while the setting was
    /// on.
    var showRemoteHostsSection: Bool {
        SessionSettings.persistentSessionsEnabled && !remoteHostCandidates.isEmpty
    }

    /// Whether the herdr section should render at all. Mirrors
    /// `showRemoteHostsSection`'s shape: an empty/undetected herdr (no
    /// binary, no live socket, or a live-but-session-less herdr) must
    /// stay pixel-identical to today, so this is purely `herdrRows`'s
    /// own emptiness, not a separate "is herdr detected" flag.
    var showHerdrSection: Bool {
        !herdrRows.isEmpty
    }

    /// Requests spawning a new remote session against `host`.
    func attachToRemoteHost(_ host: String) {
        onRemoteSessionRequested?(SessionSpawnContext(host: host, origin: .tab))
    }

    /// Per-host install status for the Remote Hosts row's Install button
    /// (`installStatus(forHost:)`), mirroring `isRefreshing`'s existing
    /// in-flight-flag precedent but keyed per host, since different
    /// hosts' installs are independent of each other.
    enum RemoteInstallStatus: Equatable, Sendable {
        case idle
        case installing
        case succeeded
        /// The failing `CommandResult`'s stderr; `nil` when
        /// `installRemote(host:)` itself returned `nil`.
        case failed(String?)
    }

    private(set) var remoteInstallStatuses: [String: RemoteInstallStatus] = [:]

    /// A host with no install attempted yet reports `.idle`.
    func installStatus(forHost host: String) -> RemoteInstallStatus {
        remoteInstallStatuses[host] ?? .idle
    }

    /// Deploys the daemon to `host` via the injected `daemonClient`'s
    /// own `installRemote(host:)`, returning its result -- mirrors
    /// `kill(_:)`'s existing injectable-client pattern. Also drives
    /// `installStatus(forHost:)` around that same call: `.installing`
    /// while the daemon round-trip is in flight, then `.succeeded` or
    /// `.failed` once it resolves. Return value/signature unchanged --
    /// this only adds a status side effect.
    func installRemote(host: String) async -> CommandResult? {
        remoteInstallStatuses[host] = .installing
        let result = await daemonClient.installRemote(host: host)
        if let result, result.exitCode == 0 {
            remoteInstallStatuses[host] = .succeeded
        } else {
            remoteInstallStatuses[host] = .failed(result?.stderr)
        }
        return result
    }
}
