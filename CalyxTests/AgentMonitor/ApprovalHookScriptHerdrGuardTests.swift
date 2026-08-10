//
//  ApprovalHookScriptHerdrGuardTests.swift
//  CalyxTests
//
//  Coverage for the herdr-environment guard ApprovalHookScript.scriptBody
//  (calyx-approval-hook) carries -- the approval-hook counterpart of
//  AgentHookScriptHerdrGuardTests (calyx-agent-hook's identical guard).
//  Running a herdr server from inside a Calyx pane's shell means every
//  shell herdr itself spawns can inherit that pane's CALYX_SURFACE_ID;
//  without a guard, a PreToolUse hook running INSIDE a herdr pane would
//  POST to /approval-request under that stale, misattributed surface,
//  routing a real permission decision to the wrong pane's approval
//  inbox. The fix: calyx-approval-hook exits 0 WITHOUT posting whenever
//  ANY HERDR_*-prefixed environment variable NAME is present, mirroring
//  both the script's own existing CALYX_SURFACE_ID/CALYX_SESSION_ID
//  early-exit guard and calyx-agent-hook's identical HERDR_* guard.
//
//  The guard is implemented via awk's ENVIRON key iteration (matching
//  variable NAMES only -- never reading any ENVIRON value) rather than
//  `env | grep -q '^HERDR_'`. The multiline-value false-positive test
//  below pins exactly why that distinction matters: `env` prints raw
//  NAME=value records with no escaping, so an unrelated variable whose
//  VALUE happens to contain an embedded newline followed by text that
//  merely looks like a HERDR_-prefixed assignment renders, from grep's
//  line-oriented point of view, as if it were its own NAME=value line --
//  a false positive that silently drops a real permission request. awk's
//  ENVIRON array is built from the process's actual environ records, not
//  by re-splitting printed text on newlines, so an embedded newline
//  inside a value can never be misread as a variable-name boundary.
//
//  Why a fake `curl` on PATH instead of ApprovalHookPipelineIntegrationTests'
//  own real-CalyxMCPServer-plus-AgentRegistry pipeline style (mirrors
//  AgentHookScriptHerdrGuardTests' identical reasoning): every assertion
//  here is a NEGATIVE ("curl must never run"). curl runs in the script's
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
//  - CALYX_SURFACE_ID set + HERDR_PANE_ID set -> exit 0, curl NEVER
//    invoked
//  - CALYX_SURFACE_ID set + a DIFFERENT HERDR_*-prefixed variable
//    (HERDR_SESSION_ID) set -> exit 0, curl NEVER invoked (prefix-match
//    generality, not one hardcoded variable name)
//  - CALYX_SESSION_ID (not CALYX_SURFACE_ID) set + HERDR_PANE_ID set ->
//    exit 0, curl NEVER invoked (the guard must apply regardless of
//    which CALYX_* variable is what's actually set -- a real
//    persistent-session pane shape, see AgentHookScriptSessionIDPipelineTests)
//  - Prefix-match boundary (negative-invariant): HERDRX_FOO (not
//    HERDR_*-prefixed -- no underscore after HERDR) must NOT trip the
//    guard, curl IS still invoked
//  - Multiline-value false-positive immunity: an unrelated variable
//    whose VALUE contains an embedded newline followed by text shaped
//    like a HERDR_*-prefixed assignment must NOT trip the guard, curl
//    IS still invoked -- pins the awk-vs-`env | grep` distinction above
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

    func test_surfaceIDSet_differentHerdrPrefixedVariableSet_exitsZeroWithoutInvokingCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "HERDR_SESSION_ID": "abc123"]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 0,
                       "The guard must match ANY HERDR_*-prefixed variable, not one hardcoded name -- " +
                       "HERDR_SESSION_ID (not HERDR_PANE_ID) must suppress the POST too")
    }

    func test_sessionIDSetInsteadOfSurfaceID_herdrPaneIDSet_exitsZeroWithoutInvokingCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SESSION_ID": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "HERDR_PANE_ID": "w1:p1"]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 0,
                       "The HERDR_* guard must apply regardless of which CALYX_* variable is what's set -- " +
                       "CALYX_SESSION_ID alone, without CALYX_SURFACE_ID, is a real persistent-session " +
                       "pane shape (see AgentHookScriptSessionIDPipelineTests)")
    }

    // MARK: - Prefix-match boundary (negative-invariant)

    func test_surfaceIDSet_nonUnderscoreTerminatedHerdrPrefixVariable_stillInvokesCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "HERDRX_FOO": "1"]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "HERDRX_FOO is not HERDR_*-prefixed (no underscore after HERDR) and must NOT trip " +
                       "the guard -- pins a real prefix-match implementation (e.g. case \"HERDR_*\") " +
                       "against an over-broad implementation that merely greps for the substring HERDR " +
                       "anywhere in the environment")
    }

    // MARK: - Multiline-value false-positive immunity (awk ENVIRON key-matching, not env|grep)

    func test_surfaceIDSet_unrelatedVariableValueContainsNewlineFollowedByHerdrLookingLine_stillInvokesCurl() throws {
        let exitCode = try runHookScript(
            stdinJSON: sampleStdin,
            extraEnv: [
                "CALYX_SURFACE_ID": UUID().uuidString,
                "SOME_UNRELATED_VAR": "first-line\nHERDR_FAKE=1",
            ]
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(curlInvocationCount(), 1,
                       "A variable VALUE containing an embedded newline followed by text that merely " +
                       "looks like a HERDR_*-prefixed assignment must never trip the guard -- the guard " +
                       "matches environment variable NAMES only, never scans values, so this must still " +
                       "invoke curl. An `env | grep -q '^HERDR_'` implementation is fooled by this: " +
                       "`env`'s own NAME=value dump renders the embedded newline as if it were a new text " +
                       "line, so grep misreads the embedded fake assignment as a real variable name")
    }
}
