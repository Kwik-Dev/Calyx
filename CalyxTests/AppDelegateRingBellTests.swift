//
//  AppDelegateRingBellTests.swift
//  CalyxTests
//
//  Missing observer: `GhosttyActionRouter
//  .handleRingBell` (GhosttyAction.swift) posts `.ghosttyRingBell` for a
//  surface-targeted `GHOSTTY_ACTION_RING_BELL`, but no observer has ever
//  been registered for it — none of the user's configured `bell-features`
//  (system/audio/attention/title/border) ever fire for a normal terminal
//  bell. `AppDelegate.processRingBell(features:effects:)` is the intended
//  receiver once that observer exists; today it is an intentional no-op
//  stub, called directly here (this file only tests the feature-to-effect
//  dispatch contract, not notification routing).
//
//  `effects: BellEffectHandlers` (Calyx/GhosttyBridge/BellFeatures.swift)
//  is the injectable seam: tests substitute recording closures instead of
//  the production defaults, so a run never actually plays
//  `NSSound.beep()` or bounces the real dock icon.
//
//  Each test below picks a `BellFeatures` combination with AT LEAST one
//  bit set, so it carries both a "must have fired" assertion (which
//  currently fails, since the stub never calls any closure) and "must
//  NOT have fired" assertions for the complementary bits — every test in
//  this file pins the fix as a whole, even though individual
//  assertions within it may pass or fail independently.
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateRingBellTests: XCTestCase {

    /// Builds a `BellEffectHandlers` whose five closures each insert a
    /// distinct tag into `calledEffects` when invoked, and a closure to
    /// read the accumulated set back out.
    private func makeRecordingEffects() -> (effects: BellEffectHandlers, calledEffects: () -> Set<String>) {
        var calledEffects: Set<String> = []
        let effects = BellEffectHandlers(
            performSystemBell: { calledEffects.insert("system") },
            performAudioBell: { calledEffects.insert("audio") },
            requestAttention: { calledEffects.insert("attention") },
            flashTitle: { calledEffects.insert("title") },
            flashBorder: { calledEffects.insert("border") }
        )
        return (effects, { calledEffects })
    }

    /// ghostty's own default `bell-features` (`attention | title`) must
    /// dispatch to `requestAttention` and `flashTitle` ONLY. By hand:
    /// features = [.attention, .title], so `system`/`audio`/`border`
    /// must NOT fire.
    func test_processRingBell_ghosttyDefaultFeatures_triggersAttentionAndTitleOnly() {
        let appDelegate = AppDelegate()
        let (effects, calledEffects) = makeRecordingEffects()

        appDelegate.processRingBell(features: [.attention, .title], effects: effects)

        XCTAssertTrue(calledEffects().contains("attention"), "features containing .attention must trigger requestAttention")
        XCTAssertTrue(calledEffects().contains("title"), "features containing .title must trigger flashTitle")
        XCTAssertFalse(calledEffects().contains("system"), "features WITHOUT .system must not trigger performSystemBell")
        XCTAssertFalse(calledEffects().contains("audio"), "features WITHOUT .audio must not trigger performAudioBell")
        XCTAssertFalse(calledEffects().contains("border"), "features WITHOUT .border must not trigger flashBorder")
    }

    /// The complementary combination (`system | audio | border`) must
    /// dispatch to exactly those three, proving the mapping is not
    /// hard-coded to just the ghostty default. By hand: features =
    /// [.system, .audio, .border], so `attention`/`title` must NOT fire.
    func test_processRingBell_systemAudioBorderFeatures_triggersThoseThreeOnly() {
        let appDelegate = AppDelegate()
        let (effects, calledEffects) = makeRecordingEffects()

        appDelegate.processRingBell(features: [.system, .audio, .border], effects: effects)

        XCTAssertTrue(calledEffects().contains("system"), "features containing .system must trigger performSystemBell")
        XCTAssertTrue(calledEffects().contains("audio"), "features containing .audio must trigger performAudioBell")
        XCTAssertTrue(calledEffects().contains("border"), "features containing .border must trigger flashBorder")
        XCTAssertFalse(calledEffects().contains("attention"), "features WITHOUT .attention must not trigger requestAttention")
        XCTAssertFalse(calledEffects().contains("title"), "features WITHOUT .title must not trigger flashTitle")
    }
}
