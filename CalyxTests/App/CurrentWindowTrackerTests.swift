//
//  CurrentWindowTrackerTests.swift
//  CalyxTests
//
//  Covers resolution of "the window the user is working in": the key
//  `CalyxWindowController`, else the last one that was key, else the
//  first open window. `AppDelegate.currentWindowController` exposes
//  this app-wide, and every consumer that used to resolve its own
//  "key, else first" window (the app-wide floating approval panel, a
//  target-pane-less MCP tool call, a new-tab/attach flow with no
//  explicit source window) resolves through it instead.
//
//  Coverage:
//  - `CurrentWindowResolver.resolve(lastKey:ordered:)`: a pure, identity
//    (`===`)-based function -- lastKey wins while it is still a member
//    of `ordered`, else the first element of `ordered`, nil when
//    `ordered` is empty regardless of `lastKey`.
//  - `CurrentWindowTracker.didBecomeKey(_:)`: returns true exactly when
//    the designated host actually CHANGES (first designation, or a
//    switch to a different controller), false on every repeat call
//    with the SAME controller already designated.
//  - `CurrentWindowTracker.resolve(in:)`: delegates to the resolver
//    above using its own `lastKeyWindowController`, so it returns the last-key
//    controller while it is still present in the given list, and falls
//    back to the list's first element once that controller has been
//    removed.
//  - `lastKeyWindowController` is declared `weak`: once every strong reference to
//    the controller it points at is released, the property itself
//    reads nil, and `resolve(in:)` falls back to `ordered.first` rather
//    than crash or return a dangling reference.
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

    // MARK: - CurrentWindowResolver (pure function)

    private final class DummyHost {}

    func test_resolve_nilLastKey_emptyOrdered_returnsNil() {
        let result = CurrentWindowResolver.resolve(lastKey: nil, ordered: [DummyHost]())

        XCTAssertNil(result, "With no candidates at all, there is nothing to resolve to")
    }

    func test_resolve_nilLastKey_returnsFirstOfOrdered() {
        let a = DummyHost()
        let b = DummyHost()

        let result = CurrentWindowResolver.resolve(lastKey: nil, ordered: [a, b])

        XCTAssertTrue(result === a, "With no last-key host, the resolver must fall back to the FIRST ordered candidate")
    }

    func test_resolve_lastKeyMemberOfOrdered_returnsLastKey() {
        let a = DummyHost()
        let b = DummyHost()

        let result = CurrentWindowResolver.resolve(lastKey: b, ordered: [a, b])

        XCTAssertTrue(result === b, "A last-key host that is still present in ordered must win over ordered.first")
    }

    func test_resolve_lastKeyNotMemberOfOrdered_fallsBackToFirst() {
        let a = DummyHost()
        let b = DummyHost()

        let result = CurrentWindowResolver.resolve(lastKey: b, ordered: [a])

        XCTAssertTrue(result === a, "Once the last-key host is no longer a member of ordered, the resolver must fall back to ordered.first")
    }

    /// The resolver's own doc-contract is identity (`===`), never
    /// equatable/structural equality -- proven with two DISTINCT
    /// instances that would compare equal under a naive Equatable
    /// conformance but must never be treated as the same host here.
    /// `DummyHost` deliberately has no `Equatable` conformance at all,
    /// so this test only compiles if `resolve` never requires one.
    func test_resolve_usesIdentityNotEquality() {
        let a = DummyHost()
        let bOriginal = DummyHost()
        let bReplacement = DummyHost()

        let result = CurrentWindowResolver.resolve(lastKey: bOriginal, ordered: [a, bReplacement])

        XCTAssertTrue(result === a, "A distinct instance occupying the same 'logical' slot must not satisfy identity: with the exact lastKey instance absent from ordered, this must fall back to ordered.first")
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

    // MARK: - resolve(in:)

    func test_resolve_returnsLastKeyController_whileStillInList() {
        let tracker = CurrentWindowTracker()
        let first = makeController()
        let second = makeController()
        _ = tracker.didBecomeKey(second)

        let resolved = tracker.resolve(in: [first, second])

        XCTAssertTrue(resolved === second, "resolve(in:) must return the last-key host while it's still a member of the given list")
    }

    func test_resolve_fallsBackToFirst_onceLastKeyControllerRemoved() {
        let tracker = CurrentWindowTracker()
        let first = makeController()
        let second = makeController()
        _ = tracker.didBecomeKey(second)

        let resolved = tracker.resolve(in: [first])

        XCTAssertTrue(resolved === first, "Once the last-key host has been removed from the list, resolve(in:) must fall back to the list's first element")
    }

    func test_resolve_emptyList_returnsNil() {
        let tracker = CurrentWindowTracker()
        let controller = makeController()
        _ = tracker.didBecomeKey(controller)

        let resolved = tracker.resolve(in: [])

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

        let resolved = tracker.resolve(in: [survivor])
        XCTAssertTrue(resolved === survivor, "With the last-key host deallocated, resolve(in:) must fall back to the given list's first element")
    }
}
