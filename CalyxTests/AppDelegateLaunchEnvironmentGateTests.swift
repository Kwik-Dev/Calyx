//
//  AppDelegateLaunchEnvironmentGateTests.swift
//  CalyxTests
//
//  The unit-test host isolation fix. ROOT CAUSE: the
//  CalyxTests scheme uses Calyx.app as its test HOST, and by the time any
//  test method runs, the host process has already completed a full,
//  ungated applicationDidFinishLaunching against the developer's real
//  environment (real ~/.calyx recovery counter increment, real
//  sessions.json overwritten on terminate, real persistent daemon
//  sessions spawned when persistentSessionsEnabled is true in real
//  UserDefaults). See LaunchEnvironmentPolicyTests's header for the full
//  root-cause narrative and the proposed isUnitTestHost() policy this
//  fix gates on.
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): driving
//  applicationDidFinishLaunching a SECOND time from within a test is not
//  useful here -- the bug is that the HOST's own, already-completed
//  launch ran unguarded, and that already happened before this test (or
//  any test) started executing. There is no seam that lets a test
//  observe "did applicationDidFinishLaunching's body run" by calling it
//  again. What IS observable post-hoc, in this same process, is a
//  residue of that one real launch: the unconditional "Add CLI to PATH"
//  block (AppDelegate.swift, applicationDidFinishLaunching, right after
//  applyGhosttyResourcesDirEnvironmentIfNeeded()) calls
//  `setenv("PATH", "\(binPath):\(currentPath)", 1)` with no existence
//  gate on binPath, so it runs on every single launch that reaches it,
//  unconditionally, with no dependence on bundle contents. With the
//  early-return gate in applicationDidFinishLaunching, this
//  process's own PATH must NEVER acquire that marker, because the host
//  never runs that launch body under a unit-test host in the first
//  place. Without the gate the assertion below would fail for real:
//  the host would already have run the launch before this test
//  executes, so the marker would be present in this process's PATH.
//  Gated behind LaunchEnvironmentPolicy.isUnitTestHost(), the host
//  never reaches the PATH setenv at all, and the assertion below holds.
//
//  Uses getenv(3) rather than ProcessInfo.processInfo.environment,
//  mirroring AppDelegateApplyGhosttyResourcesDirEnvironmentTests's own
//  currentValue() convention: setenv mutates the C process environment
//  directly, and only a live getenv read is guaranteed to reflect it.
//
//  Coverage:
//  - the CLI-bin PATH marker injected by applicationDidFinishLaunching's
//    unconditional setenv must be absent from this process's PATH once
//    unit-test hosts are gated out of the full launch
//

import XCTest
@testable import Calyx

final class AppDelegateLaunchEnvironmentGateTests: XCTestCase {

    private func currentPATH() -> String {
        getenv("PATH").map { String(cString: $0) } ?? ""
    }

    func test_unitTestHost_neverInjectsCLIBinIntoPATH() throws {
        let resourceURL = try XCTUnwrap(
            Bundle.main.resourceURL,
            "the test host's own app bundle must resolve a resource URL for this assertion to be meaningful"
        )
        let injectedBinPath = resourceURL.appendingPathComponent("bin").path

        XCTAssertFalse(
            currentPATH().contains(injectedBinPath),
            "applicationDidFinishLaunching's unconditional PATH setenv must never run for a unit-test host; " +
            "it injects \(injectedBinPath) into this process's PATH today because the host's launch is ungated"
        )
    }

    func test_terminalLaunchPATH_prefersBundledBinAndAugmentsWithLoginShellPATH() throws {
        let resourceURL = try XCTUnwrap(
            Bundle.main.resourceURL,
            "the test host's own app bundle must resolve a resource URL for this assertion to be meaningful"
        )
        let injectedBinPath = resourceURL.appendingPathComponent("bin").path

        XCTAssertEqual(
            AppDelegate.terminalLaunchPATH(),
            "\(injectedBinPath):\(SystemCommandRunner.augmentedPATH())",
            "terminalLaunchPATH must keep Calyx's bundled bin first and then append the same augmented PATH used by SystemCommandRunner so Finder/Dock launches still see Homebrew and fnm"
        )
    }
}
