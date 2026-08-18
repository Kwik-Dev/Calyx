//
//  IPCCommandPaletteTests.swift
//  CalyxTests
//
//  Pins the three-way IPC command-palette split: `ipc.enable` (offered
//  while the server is not running), `ipc.reconfigure` (offered while it
//  is running, re-running the same idempotent `enableIPC()` handler so an
//  agent CLI installed after the first enable gets its config written
//  without a destructive disable/enable round trip), and `ipc.disable`
//  (offered while it is running). Queries
//  `controller.commandRegistry.allCommands` directly, the same style as
//  `SessionCommandPaletteTests`, rather than driving the real palette UI.
//
//  Availability comes from the live `CalyxMCPServer.shared` singleton's
//  `isRunning`, which none of these tests may flip: nothing in `CalyxTests`
//  ever starts `.shared`. Every existing IPC test that calls `start()`/
//  `stop()` (`CalyxMCPServerTests`, `CalyxMCPServerWiringBugSpecTests`,
//  `CalyxMCPServerLoopbackBugSpecTests`) does so on its own fresh
//  `CalyxMCPServer()` instance bound to a real loopback port, never on
//  `.shared`. `IPCActivationCoordinatorTests` injects a fake
//  `IPCServerControl` into `IPCActivationCoordinator`, but the palette
//  closures under test here read `CalyxMCPServer.shared.isRunning`
//  directly and never go through that seam. `isRunning`'s setter is
//  `private`, which `@testable import` does not lift across files, and
//  `CalyxMCPServer` exposes no test-only setter for it (contrast
//  `_testSetToken`, `_testInjectLSPBridge`). The tests below therefore
//  only observe the not-running branch of each gate. Observing the
//  running branch would need either a real `start()` call, which binds a
//  real port and does not belong in a unit test, or a seam this file does
//  not add.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class IPCCommandPaletteTests: XCTestCase {

    /// Minimal controller for direct registry inspection, mirroring
    /// `SessionCommandPaletteTests.makeController()`. `restoring: true`
    /// skips `setupTerminalSurface()`, which needs a live Ghostty app
    /// instance; `setupCommandRegistry()` runs regardless of `restoring`,
    /// so every palette command, IPC included, is registered.
    private func makeController() -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    private func command(_ id: String, in controller: CalyxWindowController) throws -> PaletteCommand {
        try XCTUnwrap(
            controller.commandRegistry.allCommands.first(where: { $0.id == id }),
            "setupCommandRegistry must register a '\(id)' command"
        )
    }

    // MARK: - Registration and titles

    func test_ipcEnableCommand_isRegistered() throws {
        let controller = makeController()
        _ = try command("ipc.enable", in: controller)
    }

    func test_ipcEnableCommand_titleIsEnableAIAgentIPC() throws {
        let controller = makeController()
        let enableCommand = try command("ipc.enable", in: controller)

        XCTAssertEqual(enableCommand.title, "Enable AI Agent IPC",
                       "ipc.enable's title must read exactly \"Enable AI Agent IPC\", the title the " +
                       "not-running row of the palette must show")
    }

    func test_ipcReconfigureCommand_isRegistered() throws {
        let controller = makeController()
        _ = try command("ipc.reconfigure", in: controller)
    }

    func test_ipcReconfigureCommand_titleIsReconfigureAIAgentIPC() throws {
        let controller = makeController()
        let reconfigureCommand = try command("ipc.reconfigure", in: controller)

        XCTAssertEqual(reconfigureCommand.title, "Reconfigure AI Agent IPC",
                       "ipc.reconfigure's title must read exactly \"Reconfigure AI Agent IPC\", distinct " +
                       "from ipc.enable's title so the running-state row never reads as a second Enable")
    }

    func test_ipcDisableCommand_isRegistered() throws {
        let controller = makeController()
        _ = try command("ipc.disable", in: controller)
    }

    func test_ipcDisableCommand_titleIsDisableAIAgentIPC() throws {
        let controller = makeController()
        let disableCommand = try command("ipc.disable", in: controller)

        XCTAssertEqual(disableCommand.title, "Disable AI Agent IPC",
                       "ipc.disable's title must read exactly \"Disable AI Agent IPC\"")
    }

    // MARK: - Availability at the live (not-running) singleton state

    /// Not running is the one state from which the server can be
    /// started, so `ipc.enable` must stay offered in it.
    func test_ipcEnableCommand_isAvailable_whenServerNotRunning() throws {
        XCTAssertFalse(CalyxMCPServer.shared.isRunning,
                       "Precondition: no test starts the shared server, so these gates are read in the not-running state")
        let controller = makeController()
        let enableCommand = try command("ipc.enable", in: controller)

        XCTAssertTrue(enableCommand.isAvailable(),
                      "ipc.enable must be offered while the server is not running, since that is the " +
                      "only state from which it can be started")
    }

    func test_ipcReconfigureCommand_isUnavailable_whenServerNotRunning() throws {
        XCTAssertFalse(CalyxMCPServer.shared.isRunning,
                       "Precondition: no test starts the shared server, so these gates are read in the not-running state")
        let controller = makeController()
        let reconfigureCommand = try command("ipc.reconfigure", in: controller)

        XCTAssertFalse(reconfigureCommand.isAvailable(),
                       "ipc.reconfigure must be hidden while the server is not running, since there is " +
                       "no running configuration to reconfigure")
    }

    /// `ipc.disable`'s gate reads `CalyxMCPServer.shared.isRunning`
    /// directly. This pins the not-running half of "`ipc.disable` and
    /// `ipc.reconfigure` agree"; the running half cannot be pinned here,
    /// per this file's header comment.
    func test_ipcDisableCommand_isUnavailable_whenServerNotRunning() throws {
        XCTAssertFalse(CalyxMCPServer.shared.isRunning,
                       "Precondition: no test starts the shared server, so these gates are read in the not-running state")
        let controller = makeController()
        let disableCommand = try command("ipc.disable", in: controller)

        XCTAssertFalse(disableCommand.isAvailable(),
                       "ipc.disable must be hidden while the server is not running, since there is " +
                       "nothing running to disable")
    }

    // MARK: - Enable/reconfigure mutual exclusivity

    /// A plain `XCTAssertNotEqual` on the two `Bool`s is exactly an XOR:
    /// with only two possible values, "not equal" and "exactly one true"
    /// coincide. Written this way (rather than two separate `isAvailable`
    /// assertions) so the test cannot pass with both true or both false;
    /// either of those is the shape of the regression it pins.
    func test_ipcEnableAndReconfigureAvailability_areMutuallyExclusive() throws {
        let controller = makeController()
        let enableCommand = try command("ipc.enable", in: controller)
        let reconfigureCommand = try command("ipc.reconfigure", in: controller)

        XCTAssertNotEqual(enableCommand.isAvailable(), reconfigureCommand.isAvailable(),
                          "exactly one of ipc.enable/ipc.reconfigure must be available at a time. Both " +
                          "available at once is the regression this pins: \"Enable AI Agent IPC\" showing " +
                          "in the palette alongside \"Disable AI Agent IPC\" while the server is already " +
                          "running")
    }
}
