// BellFeaturesTests.swift
// CalyxTests
//
// `BellFeatures` (Calyx/GhosttyBridge/BellFeatures.swift) is a freshly
// authored, spec-derived OptionSet, not a stub with intentionally wrong
// behavior — there is no "implementation to fix later" beyond the raw
// bit values themselves, which are computed BY HAND from ghostty's own
// `Config.zig` (`pub const BellFeatures = packed struct { system: bool =
// false; audio: bool = false; attention: bool = true; title: bool = true;
// border: bool = false }`, field order = bit order, LSB first; read from
// the `ghostty` submodule pinned at
// 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28). These tests therefore PASS
// today by design (pinning/drift-detection tests, not fix-pinning ones):
// they exist so a typo here, or a future ghostty submodule bump that
// changes the upstream `bell-features` default, fails loudly instead of
// silently drifting out of sync with the real bit layout. The
// behavioral coverage for the bell-ringing feature itself lives in
// AppDelegateRingBellTests (processRingBell's still-stubbed dispatch).

import Testing
@testable import Calyx

@Suite("BellFeatures Tests")
struct BellFeaturesTests {

    // MARK: - Bit Interpretation

    @Test("rawValue 0b1100 decodes to attention + title only")
    func decodesAttentionAndTitleBits() {
        let features = BellFeatures(rawValue: 0b0000_1100)

        #expect(features.contains(.attention))
        #expect(features.contains(.title))
        #expect(!features.contains(.system))
        #expect(!features.contains(.audio))
        #expect(!features.contains(.border))
    }

    @Test("rawValue 0b10011 decodes to system + audio + border only")
    func decodesSystemAudioBorderBits() {
        // By hand: system(1) + audio(2) + border(16) = 19 = 0b1_0011.
        let features = BellFeatures(rawValue: 0b0001_0011)

        #expect(features.contains(.system))
        #expect(features.contains(.audio))
        #expect(features.contains(.border))
        #expect(!features.contains(.attention))
        #expect(!features.contains(.title))
    }

    @Test("individual flag raw values match Config.zig's packed-struct field order")
    func individualFlagRawValues() {
        #expect(BellFeatures.system.rawValue == 1)
        #expect(BellFeatures.audio.rawValue == 2)
        #expect(BellFeatures.attention.rawValue == 4)
        #expect(BellFeatures.title.rawValue == 8)
        #expect(BellFeatures.border.rawValue == 16)
    }

    // MARK: - Drift Detection

    @Test("ghosttyDefault matches Config.zig's BellFeatures{} struct-literal default (attention + title)")
    func ghosttyDefaultMatchesConfigZigDefault() {
        #expect(BellFeatures.ghosttyDefault == [.attention, .title])
        #expect(BellFeatures.ghosttyDefault.rawValue == 12)
    }
}
