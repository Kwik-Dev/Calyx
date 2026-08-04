// BellFeatures.swift
// Calyx
//
// Typed bit-flag mirror of ghostty's `bell-features` config option, and
// the injectable side-effect seam for AppDelegate.processRingBell.

import Foundation

// MARK: - BellFeatures

/// Mirrors ghostty's `bell-features` config option
/// (`ghostty/src/config/Config.zig`,
/// `pub const BellFeatures = packed struct { system: bool = false; audio:
/// bool = false; attention: bool = true; title: bool = true; border: bool
/// = false }` — field declaration order is bit order, LSB first;
/// confirmed by reading the `ghostty` submodule pinned at
/// 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28, the exact commit
/// `GhosttyKit.xcframework`'s headers were built from). Calyx's FFI
/// layer (`GhosttyConfigManager`) has no typed accessor for a
/// packed-bool-struct config value, so this reconstructs ghostty's own
/// bit layout by hand as a Swift `OptionSet`, for the app to decode
/// `bell-features`'s raw integer config value against.
///
/// Each feature's effect (from `Config.zig`'s own doc comment on
/// `bell-features`):
///   - `system`: macOS plays the system alert sound.
///   - `audio`: play a custom sound file (`bell-audio-path`).
///   - `attention` (enabled by default): bounce the dock icon once while
///     unfocused.
///   - `title` (enabled by default): prepend a bell emoji to the alerted
///     surface's title until refocused/interacted with.
///   - `border`: display a border around the alerted surface until
///     refocused/interacted with.
struct BellFeatures: OptionSet, Sendable {
    let rawValue: UInt32

    static let system = BellFeatures(rawValue: 1 << 0)
    static let audio = BellFeatures(rawValue: 1 << 1)
    static let attention = BellFeatures(rawValue: 1 << 2)
    static let title = BellFeatures(rawValue: 1 << 3)
    static let border = BellFeatures(rawValue: 1 << 4)

    /// Mirrors `Config.zig`'s `BellFeatures{}` struct-literal default
    /// (`attention`/`title` both `true`, everything else `false`) — i.e.
    /// `[.attention, .title]`, raw value `0b0000_1100` (12).
    /// `BellFeaturesTests` pins this exact value so a future `ghostty`
    /// submodule bump that changes the upstream default fails loudly
    /// here instead of silently drifting Calyx's own assumption out of
    /// sync.
    static let ghosttyDefault: BellFeatures = [.attention, .title]
}

// MARK: - BellEffectHandlers

/// Injectable seam for `AppDelegate.processRingBell`'s per-feature side
/// effects, following this codebase's closure-based DI convention (see
/// `CalyxWindowController.recoveryBarModel`/`approvalBannerModel`'s own
/// closure-injected callbacks) rather than a protocol: each `BellFeatures`
/// bit maps to exactly one independent, parameterless action, so a
/// struct-of-closures needs no additional abstraction. Tests substitute
/// their own recording closures so `processRingBell`'s dispatch is
/// assertable without actually playing a sound (`NSSound.beep()` is
/// unmockable and audibly disruptive under a test run) or bouncing the
/// real dock icon.
///
/// Every closure defaults to a no-op, but `AppDelegate.processRingBell`
/// already dispatches to all five unconditionally, whenever the
/// matching `BellFeatures` bit is set (see that method's own doc
/// comment) — this is not a RED-phase stub. `handleRingBellNotification`
/// (`AppDelegate.swift`), the real production call site, wires
/// `performSystemBell`/`performAudioBell`/`requestAttention` to real
/// system effects; `flashTitle`/`flashBorder` are the two left as
/// no-ops there (bell-emoji-in-title and border-flash presentation are
/// out of scope for this pass — see that call site's own doc comment).
struct BellEffectHandlers {
    var performSystemBell: () -> Void = {}
    var performAudioBell: () -> Void = {}
    var requestAttention: () -> Void = {}
    var flashTitle: () -> Void = {}
    var flashBorder: () -> Void = {}
}
