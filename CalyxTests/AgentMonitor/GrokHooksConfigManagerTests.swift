//
//  GrokHooksConfigManagerTests.swift
//  CalyxTests
//
//  Structural pins for `~/.grok/hooks/calyx.json`, the Calyx-owned hook
//  file GrokHooksConfigManager writes. Grok merges every `.json` under
//  `~/.grok/hooks/` and always trusts that directory, so the file is
//  Calyx's alone: install overwrites it wholesale and remove deletes it,
//  with no BEGIN/END markers to preserve foreign content the way
//  CodexHooksConfigManager must.
//
//  The two load-bearing pins are on PreToolUse. It carries both
//  handlers, because Grok has no PermissionRequest event and PreToolUse
//  is its only blocking one, and the approval handler states an explicit
//  timeout: Grok's hook default is 5 seconds (only Stop and SubagentStop
//  default to 600), so a gate left on the default would be killed and
//  fail open long before a human could answer the banner.
//
//  Every assertion parses the written JSON rather than matching
//  substrings, so key order (which JSONSerialization does not promise)
//  can never make a pin pass or fail by accident.
//

import XCTest
@testable import Calyx

final class GrokHooksConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var hooksPath: String!
    /// Paths with a space in them, matching the real install location
    /// (`~/Library/Application Support/Calyx/bin`) whose quoting the
    /// generated `command` strings depend on.
    private var scriptPath: String!
    private var approvalScriptPath: String!

    /// Every event key Calyx registers, spelled out here rather than
    /// read from the implementation so a dropped or renamed
    /// registration is a failure rather than a silently agreeing
    /// constant.
    private let expectedEventKeys: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Stop", "StopFailure", "StopCancelled", "SessionEnd", "Notification",
        "SubagentStart", "SubagentStop",
    ]

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        hooksPath = tempDir + "/hooks/calyx.json"
        let binDir = tempDir + "/Application Support/Calyx/bin"
        scriptPath = binDir + "/" + AgentHookScript.fileName
        approvalScriptPath = binDir + "/" + ApprovalHookScript.fileName
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        hooksPath = nil
        scriptPath = nil
        approvalScriptPath = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Installs, then returns the parsed top-level `hooks` object.
    private func installAndReadHooksObject(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        try GrokHooksConfigManager.installHooks(
            scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: hooksPath
        )
        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: hooksPath),
            "installHooks must create the hook file at configPath", file: file, line: line
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the hook file must be a JSON object", file: file, line: line
        )
        return try XCTUnwrap(
            root["hooks"] as? [String: Any],
            "Grok reads matcher groups from the top-level \"hooks\" object", file: file, line: line
        )
    }

    /// The matcher groups registered for `event`.
    private func groups(
        _ hooks: [String: Any], _ event: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [[String: Any]] {
        try XCTUnwrap(hooks[event] as? [[String: Any]],
                      "\(event) must be an array of matcher groups", file: file, line: line)
    }

    /// The handlers inside a matcher group.
    private func handlers(
        _ group: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) throws -> [[String: Any]] {
        try XCTUnwrap(group["hooks"] as? [[String: Any]],
                      "a matcher group must carry an inner \"hooks\" handler array", file: file, line: line)
    }

    /// Every handler registered for `event`, across all its groups.
    private func handlers(
        _ hooks: [String: Any], _ event: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [[String: Any]] {
        try groups(hooks, event, file: file, line: line).flatMap { try handlers($0, file: file, line: line) }
    }

    /// Every handler across every event, flattened.
    private func allHandlers(_ hooks: [String: Any]) throws -> [[String: Any]] {
        try hooks.keys.sorted().flatMap { try handlers(hooks, $0) }
    }

    private var expectedAgentCommand: String { "\"\(scriptPath!)\" grok" }
    private var expectedApprovalCommand: String { "\"\(approvalScriptPath!)\" grok" }

    /// Every event whose handlers are state pings only.
    private var stateOnlyEventKeys: Set<String> { expectedEventKeys.subtracting(["PreToolUse"]) }

    // MARK: - Event registration

    func test_installHooks_registersExactlyTheTwelveObservedEvents() throws {
        let hooks = try installAndReadHooksObject()

        XCTAssertEqual(Set(hooks.keys), expectedEventKeys,
                       "The registered set is exact in both directions: a missing event leaves the row " +
                       "stuck in a stale state, and an extra one costs a subprocess spawn per fire")
    }

    func test_installHooks_everyStatePingInvokesTheAgentHookWithAnExplicitGrokKind() throws {
        let hooks = try installAndReadHooksObject()

        for event in stateOnlyEventKeys.sorted() {
            for handler in try handlers(hooks, event) {
                XCTAssertEqual(handler["type"] as? String, "command",
                               "[\(event)] Calyx registers command handlers, never http ones")
                XCTAssertEqual(handler["command"] as? String, expectedAgentCommand,
                               "[\(event)] the script path must be double-quoted (the real install " +
                               "directory contains a space) and followed by an explicit kind " +
                               "argument, without which the script defaults to claude-code")
            }
        }
    }

    // MARK: - PreToolUse: state ping plus synchronous approval gate

    func test_installHooks_preToolUseCarriesTheStatePingThenTheApprovalGate() throws {
        let hooks = try installAndReadHooksObject()

        let preToolUseGroups = try groups(hooks, "PreToolUse")
        XCTAssertEqual(preToolUseGroups.count, 1,
                       "PreToolUse takes a single unfiltered matcher group holding both handlers")

        let preToolUseHandlers = try handlers(preToolUseGroups[0])
        XCTAssertEqual(preToolUseHandlers.count, 2,
                       "PreToolUse is Grok's only blocking event, so it carries both the state ping and " +
                       "the approval gate")
        XCTAssertEqual(preToolUseHandlers[0]["command"] as? String, expectedAgentCommand,
                       "The state ping runs first: Grok runs handlers in config order until one denies, " +
                       "so a ping placed behind the gate would be delayed for as long as a human takes " +
                       "to answer the banner")
        XCTAssertEqual(preToolUseHandlers[1]["command"] as? String, expectedApprovalCommand)
        for handler in preToolUseHandlers {
            XCTAssertEqual(handler["type"] as? String, "command")
        }
    }

    func test_installHooks_approvalGateStatesTheFullHookEntryTimeout() throws {
        let hooks = try installAndReadHooksObject()

        let approvalHandlers = try handlers(hooks, "PreToolUse")
            .filter { ($0["command"] as? String)?.contains(ApprovalHookScript.fileName) == true }
        XCTAssertEqual(approvalHandlers.count, 1, "Precondition: exactly one approval handler")

        XCTAssertEqual(approvalHandlers[0]["timeout"] as? Int, ApprovalHookTiming.hookEntryTimeoutSeconds,
                       "Grok kills a hook after 5 seconds unless it states its own timeout, and only " +
                       "Stop and SubagentStop default to 600. Without this value the gate is killed and " +
                       "fails open while the banner is still on screen. The value is the same constant " +
                       "the script's own curl deadline is derived from, so the two cannot drift apart")
        XCTAssertGreaterThan(ApprovalHookTiming.hookEntryTimeoutSeconds,
                             ApprovalHookTiming.curlTimeoutSeconds,
                             "The hook entry must outlive curl's own deadline, or the process is killed " +
                             "before the script can print the decision it already received")
    }

    func test_installHooks_approvalHookIsRegisteredOnlyForPreToolUse() throws {
        let hooks = try installAndReadHooksObject()

        for event in stateOnlyEventKeys.sorted() {
            for handler in try handlers(hooks, event) {
                let command = try XCTUnwrap(handler["command"] as? String)
                XCTAssertFalse(command.contains(ApprovalHookScript.fileName),
                               "[\(event)] is passive: Grok records its output but it changes no control " +
                               "flow, so a synchronous approval POST there would stall the session for a " +
                               "decision nothing would act on. Found: \(command)")
            }
        }
    }

    // MARK: - Notification matcher

    func test_installHooks_notificationIsFilteredToPermissionPrompt() throws {
        let hooks = try installAndReadHooksObject()

        let notificationGroups = try groups(hooks, "Notification")
        XCTAssertEqual(notificationGroups.count, 1)
        XCTAssertEqual(notificationGroups[0]["matcher"] as? String, "permission_prompt",
                       "Notification's matcher tests the notification type. permission_prompt is the " +
                       "only type that fires while a permission UI is actually waiting; an unfiltered " +
                       "Notification would fire on idle_prompt and task_complete too and paint the row " +
                       "blocked when nothing is waiting")
    }

    func test_installHooks_onlyNotificationCarriesAMatcher() throws {
        let hooks = try installAndReadHooksObject()

        for event in expectedEventKeys.subtracting(["Notification"]).sorted() {
            for group in try groups(hooks, event) {
                XCTAssertNil(group["matcher"],
                             "[\(event)] must match everything: a matcher on Stop or UserPromptSubmit is " +
                             "ignored with a warning, and on the tool events it would silently drop fires " +
                             "the row depends on")
            }
        }
    }

    // MARK: - Timeouts

    func test_installHooks_stopCarriesAnExplicitShortTimeout() throws {
        let hooks = try installAndReadHooksObject()

        let stopHandlers = try handlers(hooks, "Stop")
        XCTAssertEqual(stopHandlers.count, 1)
        XCTAssertEqual(stopHandlers[0]["timeout"] as? Int, 10,
                       "Grok defaults Stop to 600 seconds because stop gates commonly run builds. This " +
                       "handler is a fire-and-forget local POST sitting on the turn's critical path, so " +
                       "it states its own short deadline instead of inheriting that default")
    }

    // SubagentStop also defaults to 600 seconds in Grok, for the same
    // reason Stop does -- and a fire-and-forget POST reporting a child's
    // exit must not sit on that child's own exit path for up to 10
    // minutes. Same explicit-timeout treatment as Stop, same value.
    func test_installHooks_subagentStopCarriesAnExplicitTimeoutOfTen() throws {
        let hooks = try installAndReadHooksObject()

        let subagentStopHandlers = try handlers(hooks, "SubagentStop")
        XCTAssertEqual(subagentStopHandlers.count, 1)
        XCTAssertEqual(subagentStopHandlers[0]["timeout"] as? Int, 10,
                       "Grok defaults SubagentStop to 600 seconds like Stop; a fire-and-forget POST must " +
                       "not sit on the child's own exit path for up to 10 minutes")
    }

    func test_installHooks_subagentStartStatesNoExplicitTimeout() throws {
        let hooks = try installAndReadHooksObject()

        let subagentStartHandlers = try handlers(hooks, "SubagentStart")
        XCTAssertEqual(subagentStartHandlers.count, 1)
        XCTAssertNil(subagentStartHandlers[0]["timeout"],
                     "SubagentStart is not one of the two events Grok defaults to 600 seconds, so it " +
                     "keeps the ordinary 5-second observe default")
    }

    func test_installHooks_noStatePingOtherThanStopOrSubagentStopStatesATimeout() throws {
        let hooks = try installAndReadHooksObject()

        for event in stateOnlyEventKeys.subtracting(["Stop", "SubagentStop"]).sorted() {
            for handler in try handlers(hooks, event) {
                XCTAssertNil(handler["timeout"],
                             "[\(event)] inherits Grok's 5-second observe default, which is ample for a " +
                             "loopback POST; only the two handlers whose inherited default would be " +
                             "wrong state one")
            }
        }
    }

    func test_installHooks_preToolUseStatePingStatesNoTimeout() throws {
        let hooks = try installAndReadHooksObject()

        let statePingHandlers = try handlers(hooks, "PreToolUse")
            .filter { ($0["command"] as? String)?.contains(AgentHookScript.fileName) == true }
        XCTAssertEqual(statePingHandlers.count, 1, "Precondition: exactly one state ping on PreToolUse")

        XCTAssertNil(statePingHandlers[0]["timeout"],
                     "The state ping keeps the 5-second observe default even on PreToolUse: only the " +
                     "approval gate beside it needs a longer one")
    }

    // MARK: - Whole-file ownership

    func test_installHooks_overwritesPriorContentWholesale() throws {
        try FileManager.default.createDirectory(
            atPath: (hooksPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: hooksPath, contents: Data("""
        {"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"/tmp/stale-calyx-entry.sh"}]}]}}
        """.utf8))

        let hooks = try installAndReadHooksObject()

        XCTAssertEqual(Set(hooks.keys), expectedEventKeys,
                       "The file is Calyx's own, so a previous install's registrations are replaced, not " +
                       "merged: a stale event key left behind would keep firing forever")
        let commands = try allHandlers(hooks).compactMap { $0["command"] as? String }
        XCTAssertFalse(commands.contains { $0.contains("stale-calyx-entry") })
    }

    func test_installHooks_createsTheHooksDirectoryWhenAbsent() throws {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: (hooksPath as NSString).deletingLastPathComponent),
            "Precondition: the hooks directory must not exist yet"
        )

        _ = try installAndReadHooksObject()

        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksPath),
                      "A Grok install that has never used hooks has no ~/.grok/hooks directory yet")
    }

    // MARK: - removeHooks / areHooksInstalled

    func test_removeHooks_deletesTheFile() throws {
        _ = try installAndReadHooksObject()
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksPath), "Precondition: installed")

        try GrokHooksConfigManager.removeHooks(configPath: hooksPath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksPath),
                       "The file is entirely Calyx's, so removal deletes it rather than editing it")
    }

    func test_removeHooks_noFile_isNoOp() {
        XCTAssertNoThrow(try GrokHooksConfigManager.removeHooks(configPath: hooksPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksPath))
    }

    func test_areHooksInstalled_tracksInstallAndRemoval() throws {
        XCTAssertFalse(GrokHooksConfigManager.areHooksInstalled(configPath: hooksPath),
                       "No file means not installed")

        _ = try installAndReadHooksObject()
        XCTAssertTrue(GrokHooksConfigManager.areHooksInstalled(configPath: hooksPath))

        try GrokHooksConfigManager.removeHooks(configPath: hooksPath)
        XCTAssertFalse(GrokHooksConfigManager.areHooksInstalled(configPath: hooksPath))
    }

    func test_areHooksInstalled_fileWithoutCalyxCommands_returnsFalse() throws {
        try FileManager.default.createDirectory(
            atPath: (hooksPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: hooksPath, contents: Data("""
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/other/tool.sh"}]}]}}
        """.utf8))

        XCTAssertFalse(GrokHooksConfigManager.areHooksInstalled(configPath: hooksPath),
                       "A file at Calyx's path that names no Calyx script is not a Calyx install, so a " +
                       "launch-time resync must not treat it as one and silently overwrite it")
    }

    // MARK: - Default location

    func test_defaultConfigPath_isUnderTheGrokConfigRoot() {
        XCTAssertEqual(GrokHooksConfigManager.defaultConfigPath,
                       AgentToolPaths.grokConfigDirectory + "/hooks/calyx.json",
                       "Global hooks under ~/.grok/hooks are always trusted and need no folder-trust grant")
        XCTAssertTrue(AgentToolPaths.grokConfigDirectory.hasSuffix("/.grok"))
    }
}
