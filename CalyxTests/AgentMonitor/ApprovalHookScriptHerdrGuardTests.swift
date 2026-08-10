//
//  ApprovalHookScriptHerdrGuardTests.swift
//  CalyxTests
//
//  Coverage for the herdr-environment guard ApprovalHookScript.scriptBody
//  (calyx-approval-hook) carries -- the approval-hook counterpart of
//  AgentHookScriptHerdrGuardTests (calyx-agent-hook's identical guard).
//  Running a herdr server from inside a Calyx pane's shell means every
//  shell herdr itself spawns can inherit that pane's CALYX_SURFACE_ID;
//  without a guard, a PreToolUse hook running INSIDE a herdr-managed
//  pane would POST to /approval-request under that stale, misattributed
//  surface, routing a real permission decision to the wrong pane's
//  approval inbox. The fix: calyx-approval-hook exits 0 WITHOUT posting
//  whenever HERDR_PANE_ID is set and non-empty, mirroring both the
//  script's own existing CALYX_SURFACE_ID/CALYX_SESSION_ID early-exit
//  guard and calyx-agent-hook's identical HERDR_PANE_ID guard.
//
//  HERDR_PANE_ID specifically -- not any HERDR_*-prefixed variable name --
//  is the guard's condition: herdr sets several HERDR_*-prefixed
//  variables inside its panes (e.g. HERDR_SOCKET_PATH, HERDR_TAB_ID,
//  HERDR_WORKSPACE_ID, HERDR_ENV), but only HERDR_PANE_ID reliably means
//  "this shell is running inside a herdr-managed pane". The others,
//  HERDR_SOCKET_PATH in particular, are user-facing configuration a
//  person may export in their own shell profile (to select a session by
//  default) from inside an ORDINARY Calyx pane that herdr never touched
//  at all -- an implementation that suppresses on any HERDR_-prefixed
//  name would silently lose approval routing for that pane the moment
//  the user exports it, which is exactly the regression this file's
//  HERDR_SOCKET_PATH-alone and HERDR_ENV-alone tests below pin against.
//
//  Why a fake `curl` on PATH instead of ApprovalHookPipelineIntegrationTests'
//  own real-CalyxMCPServer-plus-AgentRegistry pipeline style (mirrors
//  AgentHookScriptHerdrGuardTests' identical reasoning): every negative
//  assertion here is about curl never running. curl runs in the script's
//  own foreground (captured via `response=$(curl ...)`, no trailing `&`),
//  so `process.waitUntilExit()` already guarantees the fake curl has
//  already run-or-not by the time this file reads its record file -- no
//  server lifecycle, no @MainActor, and no polling-with-timeout needed on
//  every green run forever the way waiting out a real network round trip
//  to prove ABSENCE would require.
//
//  Coverage:
//  - Baseline sanity: CALYX_SURFACE_ID set, no HERDR_* variable -> curl
//    IS invoked exactly once (proves the fake-curl harness itself
//    works, so the zero-invocation assertions below aren't vacuous)
//  - CALYX_SURFACE_ID set + HERDR_PANE_ID set to a non-empty value ->
//    exit 0, curl NEVER invoked
//  - CALYX_SESSION_ID (not CALYX_SURFACE_ID) set + HERDR_PANE_ID set ->
//    exit 0, curl NEVER invoked (the guard must apply regardless of
//    which CALYX_* variable is what's actually set -- a real
//    persistent-session pane shape, see AgentHookScriptSessionIDPipelineTests)
//  - HERDR_PANE_ID set but EMPTY -> curl IS still invoked (the
//    condition is "set AND non-empty", not merely "the name is present
//    in the environment")
//  - CALYX_SURFACE_ID set + HERDR_SOCKET_PATH set, HERDR_PANE_ID absent
//    -> curl IS still invoked (an ordinary Calyx pane whose user
//    exported HERDR_SOCKET_PATH in their shell profile must keep normal
//    approval routing)
//  - CALYX_SURFACE_ID set + HERDR_ENV set, HERDR_PANE_ID absent -> curl
//    IS still invoked (same principle, a second herdr-set variable that
//    is not the guard's own signal)
//  - Residual regression guards: HERDRX_FOO (a name that merely starts
//    with the letters HERDR) and an unrelated variable whose VALUE
//    contains an embedded newline followed by text shaped like a
//    HERDR_PANE_ID assignment must NEVER trip the guard either -- curl
//    IS still invoked in both cases
//

import XCTest
@testable import Calyx

final class ApprovalHookScriptHerdrGuardTests: XCTestCase {

    // MARK: - Properties

    private var rootDir: String!
    private var tempHome: String!
    private var appSupportDir: String!
    private var fakeBinDir: String!
    private var recordPath: String!
    private var scriptPath: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        tempHome = rootDir + "/home"
        appSupportDir = tempHome + "/Library/Application Support/Calyx"
        fakeBinDir = rootDir + "/fakebin"
        recordPath = rootDir + "/curl-invocations.log"
        try! FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)

        try! AgentEndpointFile.write(port: 41831, token: "approval-herdr-guard-test-token", directory: appSupportDir)
        scriptPath = try! ApprovalHookScript.install(toDirectory: appSupportDir + "/bin")
        try! makeFakeCurl(atDirectory: fakeBinDir, recordingTo: recordPath)
    }

    override func tearDown() {
        if let rootDir { try? FileManager.default.removeItem(atPath: rootDir) }
        rootDir = nil
        tempHome = nil
        appSupportDir = nil
        fakeBinDir = nil
        recordPath = nil
        scriptPath = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a fake `curl` executable at `<dir>/curl` that drains its
    /// own stdin (so the real script's `--data-binary @-` never leaves
    /// anything unread), appends one "invoked" line to `recordPath` --
    /// baked directly into this script's own body, not threaded through
    /// an env var the real calyx-approval-hook script never forwards to
    /// curl anyway -- and exits 0. The empty stdout this produces flows
    /// into the real script's `response=$(curl ...)` capture as an empty
    /// string, which is irrelevant here: every assertion below is about
    /// curl's INVOCATION count, never the printed response body.
    private func makeFakeCurl(atDirectory dir: String, recordingTo recordPath: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let curlPath = dir + "/curl"
        let body = """
        #!/bin/sh
        cat > /dev/null
        printf 'invoked\\n' >> "\(recordPath)"
        exit 0
        """
        try body.write(toFile: curlPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curlPath)
    }

    private func curlInvocationCount() -> Int {
        guard let text = try? String(contentsOfFile: recordPath, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    /// Runs the installed `calyx-approval-hook` script as a real child
    /// process (`/bin/sh <script>`), with `fakeBinDir` prepended to PATH
    /// (ahead of the real system PATH, so `curl` resolves to the fake
    /// one while `sed` etc. still resolve normally) and `extraEnv`
    /// merged on top of the base HOME/PATH environment.
    @discardableResult
    private func runHookScript(stdinJSON: String, extraEnv: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        var env = ["HOME": tempHome!, "PATH": "\(fakeBinDir!):\(inheritedPath)"]
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private let sampleStdin = """
    {"session_id":"herdr-guard-session","tool_name":"Bash","hook_event_name":"PreToolUse"}
    """

    // MARK: - Baseline sanity (harness proof, not the guard itself)

    func test_baseline_surfaceIDSetNoHerdrVar_curlIsInvokedExactlyOnce() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "Precondition for every test below: with no HERDR_* variable present, the script " +
                       "must still reach and invoke curl exactly once -- proves the fake-curl harness " +
                       "itself works, so the zero-invocation assertions elsewhere in this file aren't " +
                       "silently vacuous")
    }

    // MARK: - HERDR_* guard

    func test_surfaceIDSet_herdrPaneIDSet_exitsZeroWithoutInvokingCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "HERDR_PANE_ID": "w1:p1"]
        )

        XCTAssertEqual(exitCode, 0, "Even inside a herdr pane, the script must still exit 0")
        XCTAssertEqual(curlInvocationCount(), 0,
                       "HERDR_PANE_ID present must suppress the POST entirely -- a herdr-spawned shell " +
                       "can inherit a stale CALYX_SURFACE_ID from the pane herdr's own server was started " +
                       "in, and must never misattribute an /approval-request to it")
    }

    func test_sessionIDSetInsteadOfSurfaceID_herdrPaneIDSet_exitsZeroWithoutInvokingCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SESSION_ID": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "HERDR_PANE_ID": "w1:p1"]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 0,
                       "The HERDR_PANE_ID guard must apply regardless of which CALYX_* variable is what's " +
                       "set -- CALYX_SESSION_ID alone, without CALYX_SURFACE_ID, is a real " +
                       "persistent-session pane shape (see AgentHookScriptSessionIDPipelineTests)")
    }

    // MARK: - HERDR_PANE_ID must be set AND non-empty

    func test_surfaceIDSet_herdrPaneIDSetToEmptyString_stillInvokesCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "HERDR_PANE_ID": ""]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "HERDR_PANE_ID present in the environment but set to an empty value must NOT trip " +
                       "the guard -- the condition is \"set AND non-empty\", not merely \"the name exists\"")
    }

    // MARK: - Other HERDR_*-prefixed variables must NOT suppress on their own

    func test_surfaceIDSet_herdrSocketPathSetWithoutPaneID_stillInvokesCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "HERDR_SOCKET_PATH": "/Users/dev/.config/herdr/herdr.sock"]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "HERDR_SOCKET_PATH alone, without HERDR_PANE_ID, must NOT suppress the POST -- it " +
                       "is user-facing configuration a person may export in their own shell profile to " +
                       "select a herdr session by default, from inside an ORDINARY Calyx pane herdr never " +
                       "touched, and must never cost that pane its approval routing")
    }

    func test_surfaceIDSet_herdrEnvSetWithoutPaneID_stillInvokesCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "HERDR_ENV": "1"]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "HERDR_ENV alone, without HERDR_PANE_ID, must NOT suppress the POST either -- only " +
                       "HERDR_PANE_ID is a reliable \"this shell is herdr-managed\" signal, not any other " +
                       "HERDR_*-prefixed variable herdr happens to also set")
    }

    // MARK: - Residual regression guards

    func test_surfaceIDSet_nonUnderscoreTerminatedHerdrPrefixVariable_stillInvokesCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "HERDRX_FOO": "1"]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "HERDRX_FOO (a name that merely starts with the letters HERDR, not HERDR_PANE_ID " +
                       "itself) must NOT trip the guard -- curl must still be invoked")
    }

    func test_surfaceIDSet_unrelatedVariableValueContainsNewlineFollowedByHerdrLookingLine_stillInvokesCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: [
                "CALYX_SURFACE_ID": UUID().uuidString,
                "SOME_UNRELATED_VAR": "first-line\nHERDR_PANE_ID=w9:p9",
            ]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "An unrelated variable's VALUE containing an embedded newline followed by text " +
                       "shaped like a HERDR_PANE_ID assignment must never influence the guard -- the " +
                       "guard reads the shell's own $HERDR_PANE_ID parameter directly, which stays unset " +
                       "here regardless of what any other variable's value happens to contain, so curl " +
                       "must still be invoked")
    }
}
