// HerdrBinaryResolver.swift
// Calyx
//
// Resolves the (optional, user-installed) `herdr` binary's absolute
// path. herdr integration is entirely detection-based: unlike
// calyx-session (a bundled app resource resolved by
// SessionBinaryResolver), herdr is a third-party CLI the user installs
// themselves (Homebrew, Cargo, ...), so resolution here needs an
// in-process PATH scan and a list of well-known install locations
// rather than a Bundle lookup.
//
// Resolution order: `CALYX_HERDR_BIN` env override (non-empty) ->
// in-process PATH scan (FileManager.isExecutableFile, NEVER a
// subprocess -- a GUI app's launchd PATH frequently lacks
// Homebrew/Cargo) -> known absolute candidate paths, in order -> nil.
// Every tier is checked in this fixed priority order regardless of
// what earlier tiers contain; a `nil` result means herdr's UI must stay
// entirely absent -- Calyx behaves identically to today when herdr
// isn't installed.

import Foundation
import os

protocol HerdrBinaryResolverProtocol: Sendable {
    /// The user-installed `herdr` binary's absolute path, or `nil` when
    /// herdr isn't installed / discoverable.
    func resolve() -> String?
}

/// Production resolver. Both `environment` and `knownCandidates` are
/// injectable so tests never depend on this machine's actual PATH or
/// on real system install locations (`/opt/homebrew/...` etc. may or
/// may not exist on the machine running the test suite -- especially
/// once a manual smoke test `brew install`s herdr onto
/// this same development machine).
///
/// A FOUND path is memoized for the rest of this *instance's* lifetime
/// -- resolution walks PATH plus several known directories doing real
/// filesystem stats, and callers such as availability polling may
/// invoke `resolve()` repeatedly, so a resolver that already knows
/// herdr's path shouldn't re-scan on every call. A MISS, in contrast,
/// is never cached: herdr may be installed (`brew install herdr` or
/// similar) after Calyx has already probed and found nothing, and the
/// scan itself is cheap (a handful of `isExecutableFile` checks), so
/// caching a miss would permanently hide a herdr installed after
/// launch until the next app restart. The cache lives behind
/// `OSAllocatedUnfairLock` (mirrors `FSEventsEventSource`'s own
/// lock-protected-state idiom in `FileSyncManager.swift`) so a `let`
/// stored property can still be mutated from this non-`mutating`
/// method without a data race, and so this type keeps its synthesized
/// `Sendable` conformance -- no `@unchecked Sendable` needed anywhere.
/// The cache is a per-instance field (not `static`/type-global), so
/// distinct `HerdrBinaryResolver` instances constructed with distinct
/// `environment` values (as every test in this suite does) always
/// resolve independently.
struct HerdrBinaryResolver: HerdrBinaryResolverProtocol {

    private let environment: [String: String]
    private let knownCandidates: [String]
    private let cache = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// `/opt/homebrew/bin/herdr`, `/usr/local/bin/herdr`,
    /// `/opt/homebrew/opt/herdr/bin/herdr`, `~/.cargo/bin/herdr` --
    /// already tilde-expanded via `NSHomeDirectory()`, never a raw `~`
    /// prefix, since these are consumed directly by
    /// `FileManager.isExecutableFile(atPath:)`, which does not expand
    /// `~` itself.
    static var defaultKnownCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "/opt/homebrew/opt/herdr/bin/herdr",
            "\(home)/.cargo/bin/herdr",
        ]
    }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        knownCandidates: [String] = HerdrBinaryResolver.defaultKnownCandidates
    ) {
        self.environment = environment
        self.knownCandidates = knownCandidates
    }

    func resolve() -> String? {
        cache.withLock { cachedPath in
            if let cachedPath {
                return cachedPath
            }
            let resolved = resolveUncached()
            // Only a FOUND path is memoized -- a miss (nil) leaves the
            // cache untouched so the next call re-scans instead of
            // permanently hiding a herdr installed after this miss.
            if let resolved {
                cachedPath = resolved
            }
            return resolved
        }
    }

    /// The actual four-tier resolution walk, run at most once per
    /// instance -- see `resolve()` and this type's own doc comment for
    /// the memoization wrapping it.
    private func resolveUncached() -> String? {
        if let override = environment["CALYX_HERDR_BIN"], !override.isEmpty {
            return override
        }

        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":").map(String.init) {
                let candidate = directory + "/herdr"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        for candidate in knownCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return nil
    }
}
