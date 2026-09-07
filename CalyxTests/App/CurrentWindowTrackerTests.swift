//
//  CurrentWindowTrackerTests.swift
//  CalyxTests
//
//  Covers resolution of "the window the user is working in", in three
//  tiers: the key `CalyxWindowController`, else the front-most window
//  that is visible and on the active Space, else the last one that was
//  key, else the first open window. `AppDelegate.currentWindowController`
//  exposes this app-wide, and every consumer that needs a "which window"
//  answer with no more specific signal (the app-wide floating approval
//  panel, a target-pane-less MCP tool call, a new-tab/attach flow with no
//  explicit source window) resolves through it instead.
//
//  Coverage:
//  - `CurrentWindowResolver.resolve(key:frontMostVisible:lastKey:
//    ordered:)`: a pure, identity (`===`)-based function -- `key` wins if
//    non-nil, else `frontMostVisible` if non-nil, else `lastKey` while it
//    is still a member of `ordered`, else the first element of `ordered`,
//    nil when `ordered` is empty and every tier above is nil.
//  - `CurrentWindowTracker.didBecomeKey(_:)`: returns true exactly when
//    the designated host actually CHANGES (first designation, or a
//    switch to a different controller), false on every repeat call
//    with the SAME controller already designated.
//  - `lastKeyWindowController` is declared `weak`: once every strong reference to
//    the controller it points at is released, the property itself
//    reads nil, and `CurrentWindowResolver.resolve` falls back to
//    `ordered.first` rather than crash or return a dangling reference.
//
//  Every `CalyxWindowController` fixture below is built via
//  `GroupControllerFixture.swift`'s shared `GroupFixture.make(tabCount:)`
//  (a throwaway `CalyxWindow` + `restoring: true`, no live ghostty
//  surface) and is NEVER ordered front -- this file only ever calls
//  `CurrentWindowTracker`/`CurrentWindowResolver` methods directly against
//  the controller reference itself, matching every other lightweight
//  controller-fixture test file's own safety discipline.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CurrentWindowTrackerTests: XCTestCase {

    // MARK: - CurrentWindowResolver (full three-tier rule)

    private final class DummyHost {}

    func test_resolveThreeTier_nilEverything_emptyOrdered_returnsNil() {
        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: nil, ordered: [DummyHost]())

        XCTAssertNil(result, "With no candidates at all, there is nothing to resolve to")
    }

    func test_resolveThreeTier_nilLastKey_fallsBackToFirstOfOrdered() {
        let a = DummyHost()
        let b = DummyHost()

        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: nil, ordered: [a, b])

        XCTAssertTrue(result === a, "With no key, no front-most-visible host, and no last-key host, the resolver must fall back to the FIRST ordered candidate")
    }

    func test_resolveThreeTier_lastKeyMemberOfOrdered_returnsLastKey() {
        let a = DummyHost()
        let b = DummyHost()

        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: b, ordered: [a, b])

        XCTAssertTrue(result === b, "A last-key host that is still present in ordered must win over ordered.first")
    }

    func test_resolveThreeTier_lastKeyNotMemberOfOrdered_fallsBackToFirst() {
        let a = DummyHost()
        let b = DummyHost()

        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: b, ordered: [a])

        XCTAssertTrue(result === a, "Once the last-key host is no longer a member of ordered, the resolver must fall back to ordered.first")
    }

    /// The resolver's own doc-contract is identity (`===`), never
    /// equatable/structural equality -- proven with two DISTINCT
    /// instances that would compare equal under a naive Equatable
    /// conformance but must never be treated as the same host here.
    /// `DummyHost` deliberately has no `Equatable` conformance at all,
    /// so this test only compiles if `resolve` never requires one.
    func test_resolveThreeTier_usesIdentityNotEquality() {
        let a = DummyHost()
        let bOriginal = DummyHost()
        let bReplacement = DummyHost()

        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: bOriginal, ordered: [a, bReplacement])

        XCTAssertTrue(result === a, "A distinct instance occupying the same 'logical' slot must not satisfy identity: with the exact lastKey instance absent from ordered, this must fall back to ordered.first")
    }

    func test_resolveThreeTier_keyBeatsFrontMostVisible() {
        let key = DummyHost()
        let frontMost = DummyHost()

        let result = CurrentWindowResolver.resolve(key: key, frontMostVisible: frontMost, lastKey: nil, ordered: [])

        XCTAssertTrue(result === key, "A real key host must win over every lower tier")
    }

    func test_resolveThreeTier_frontMostVisibleBeatsLastKey() {
        let frontMost = DummyHost()
        let lastKey = DummyHost()

        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: frontMost, lastKey: lastKey, ordered: [lastKey])

        XCTAssertTrue(result === frontMost, "With no real key host, the front-most visible-on-active-Space host must win over the last-key tier")
    }

    func test_resolveThreeTier_lastKeyBeatsFirstOfOrdered() {
        let first = DummyHost()
        let lastKey = DummyHost()

        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: lastKey, ordered: [first, lastKey])

        XCTAssertTrue(result === lastKey, "With no key and no front-most-visible host, the last-key host must win over ordered.first")
    }

    func test_resolveThreeTier_noCandidatesAtAll_fallsBackToFirstOfOrdered() {
        let first = DummyHost()

        let result = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: nil, ordered: [first])

        XCTAssertTrue(result === first, "With no key, no front-most-visible host, and no last-key host, the resolver must fall back to ordered.first")
    }

    // MARK: - CurrentWindowTracker fixtures

    private func makeController() -> CalyxWindowController {
        GroupFixture.make(tabCount: 1).controller
    }

    // MARK: - didBecomeKey

    func test_didBecomeKey_firstDesignation_returnsTrue() {
        let tracker = CurrentWindowTracker()
        let controller = makeController()

        let changed = tracker.didBecomeKey(controller)

        XCTAssertTrue(changed, "The very first designation is always a change, from no host to this controller")
        XCTAssertTrue(tracker.lastKeyWindowController === controller)
    }

    func test_didBecomeKey_repeatSameController_returnsFalse() {
        let tracker = CurrentWindowTracker()
        let controller = makeController()

        _ = tracker.didBecomeKey(controller)
        let changedAgain = tracker.didBecomeKey(controller)

        XCTAssertFalse(changedAgain, "Re-designating the SAME already-current host must report no change")
    }

    func test_didBecomeKey_switchToDifferentController_returnsTrue() {
        let tracker = CurrentWindowTracker()
        let first = makeController()
        let second = makeController()

        _ = tracker.didBecomeKey(first)
        let changed = tracker.didBecomeKey(second)

        XCTAssertTrue(changed, "Switching the designated host to a DIFFERENT controller is a change")
        XCTAssertTrue(tracker.lastKeyWindowController === second)
    }

    // MARK: - CurrentWindowTracker.lastKeyWindowController feeding CurrentWindowResolver

    func test_lastKeyWindowController_winsTierThree_whileStillInList() {
        let tracker = CurrentWindowTracker()
        let first = makeController()
        let second = makeController()
        _ = tracker.didBecomeKey(second)

        let resolved = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: tracker.lastKeyWindowController, ordered: [first, second])

        XCTAssertTrue(resolved === second, "tier 3 must return the last-key host while it's still a member of the given list")
    }

    func test_lastKeyWindowController_fallsBackToFirst_onceRemovedFromList() {
        let tracker = CurrentWindowTracker()
        let first = makeController()
        let second = makeController()
        _ = tracker.didBecomeKey(second)

        let resolved = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: tracker.lastKeyWindowController, ordered: [first])

        XCTAssertTrue(resolved === first, "Once the last-key host has been removed from the list, tier 3 must fall back to the list's first element")
    }

    func test_lastKeyWindowController_emptyList_returnsNil() {
        let tracker = CurrentWindowTracker()
        let controller = makeController()
        _ = tracker.didBecomeKey(controller)

        let resolved = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: tracker.lastKeyWindowController, ordered: [CalyxWindowController]())

        XCTAssertNil(resolved, "With zero open windows, there is no host at all -- a target-pane-less request must simply wait")
    }

    // MARK: - lastKeyWindowController is weak

    /// Designates a freshly-created controller as the host, WITHOUT
    /// keeping any strong reference to it beyond this function's own
    /// scope, then returns -- so by the time this function returns, the
    /// controller's only strong reference (this local variable) is
    /// gone. `withExtendedLifetime` is deliberately NOT used here: the
    /// whole point is to let ARC deallocate it.
    private func designateAndDropController(_ tracker: CurrentWindowTracker) {
        let controller = GroupFixture.make(tabCount: 1).controller
        _ = tracker.didBecomeKey(controller)
    }

    func test_lastKeyWindowController_isWeak_clearsOnceControllerDeallocates() {
        let tracker = CurrentWindowTracker()
        let survivor = makeController()

        // The dropped controller deallocates only once the autorelease
        // pool that `designateAndDropController(_:)` ran under actually
        // drains -- an implicit pool spanning this whole test method
        // (XCTest's own per-test pool) does not drain until AFTER this
        // test method returns, so asserting `lastKeyWindowController == nil` right
        // after the call, with no pool drain in between, observes a
        // still-live (not yet deallocated) controller. Draining an
        // explicit, narrower pool right here forces that deallocation
        // to happen before the assertion below runs.
        autoreleasepool {
            designateAndDropController(tracker)
        }

        XCTAssertNil(tracker.lastKeyWindowController, "lastKeyWindowController is weak: once every strong reference to the designated controller is released, this must read nil, never a dangling reference")

        let resolved = CurrentWindowResolver.resolve(key: nil, frontMostVisible: nil, lastKey: tracker.lastKeyWindowController, ordered: [survivor])
        XCTAssertTrue(resolved === survivor, "With the last-key host deallocated, tier 3 must fall back to the given list's first element")
    }
}
