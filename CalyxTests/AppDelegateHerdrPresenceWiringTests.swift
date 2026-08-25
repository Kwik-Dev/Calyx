//
//  AppDelegateHerdrPresenceWiringTests.swift
//  CalyxTests
//
//  Covers AppDelegate as the HerdrSessionPresenceObserver that sits
//  between HerdrSessionPresence and HerdrIntegrationCoordinator.
//
//  Contract this file pins: herdr existing is a fact PRESENCE owns, so
//  a herdr installed (or put on PATH) after Calyx launched must still
//  get a HerdrTabCoordinator built for it -- the first live session
//  presence reports is when that is decided, not launch alone. Without
//  it, `setStructureEventObserver` stays nil for the whole process: the
//  mirror shows rows for that session while a pane.closed never closes
//  its bridge surface and no native herdr tab can be opened.
//
//  The herdr binary path is injected (`_herdrBinPathOverrideForTesting`)
//  rather than resolved from PATH: whether the machine running this
//  suite has herdr installed must not decide whether this test passes.
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateHerdrPresenceWiringTests: XCTestCase {

    private let socketPath = "/tmp/calyx-herdr-presence-wiring-test/herdr.sock"

    private var liveIdentity: HerdrSocketIdentity {
        HerdrSocketIdentity(socketPath: socketPath, deviceID: 16_777_232, inode: 404)
    }

    func test_presenceReportsALiveSession_whileHerdrTabCoordinatorIsStillNil_buildsItThen() async {
        let appDelegate = AppDelegate()
        appDelegate._herdrBinPathOverrideForTesting = "/opt/homebrew/bin/herdr"

        XCTAssertNil(
            appDelegate.herdrTabCoordinator,
            "Precondition: launch-time resolution never ran in this test host, so nothing is built yet"
        )

        appDelegate.herdrSessionPresenceDidChange(.appeared(liveIdentity))
        await waitUntil { appDelegate.herdrTabCoordinator != nil }

        XCTAssertNotNil(
            appDelegate.herdrTabCoordinator,
            "a herdr session presence reports live proves herdr exists -- a coordinator that is still nil must " +
            "be built then, or its structure-event observer stays nil for the rest of the process"
        )
    }

    /// A herdr resolved at launch is not rebuilt by a later transition:
    /// the coordinator holds per-workspace state (its own header), and
    /// replacing it would drop every tab already bridged through it.
    func test_presenceReportsALiveSession_whenACoordinatorAlreadyExists_keepsTheSameOne() async {
        let appDelegate = AppDelegate()
        appDelegate._herdrBinPathOverrideForTesting = "/opt/homebrew/bin/herdr"

        appDelegate.herdrSessionPresenceDidChange(.appeared(liveIdentity))
        await waitUntil { appDelegate.herdrTabCoordinator != nil }
        let first = appDelegate.herdrTabCoordinator

        appDelegate.herdrSessionPresenceDidChange(
            .replaced(
                previous: liveIdentity,
                current: HerdrSocketIdentity(socketPath: socketPath, deviceID: 16_777_232, inode: 505)
            )
        )
        for _ in 0..<500 { await Task.yield() }

        XCTAssertTrue(
            appDelegate.herdrTabCoordinator === first,
            "a later presence transition must not replace an existing coordinator: its per-workspace state, and " +
            "every tab bridged through it, belong to that instance"
        )
    }

    private func waitUntil(maxYields: Int = 5_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }
}
