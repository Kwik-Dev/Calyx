import XCTest
@testable import Calyx

final class IPCConfigManagerTests: XCTestCase {

    // MARK: - Shared helpers

    private static var skipped: ConfigStatus { .skipped(reason: "not installed") }

    // MARK: - IPCConfigResult.anySucceeded

    func test_anySucceeded_bothSuccess() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: .success,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_oneSuccess() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_otherSuccess() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: .success,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_noneSuccess() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertFalse(result.anySucceeded)
    }

    func test_anySucceeded_failedAndSkipped() {
        let error = NSError(domain: "test", code: 1)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertFalse(result.anySucceeded)
    }

    // MARK: - all seven axes

    func test_anySucceeded_onlyOpenCode() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: .success,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_onlyHermes() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: .success,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_openCodeFailedOthersSkipped() {
        // Given: openCode failed, others skipped
        let error = NSError(domain: "test", code: 2)
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: .failed(error),
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        // Then
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when openCode failed and others skipped")
    }

    func test_anySucceeded_openCodeSuccessOthersFailed() {
        // Given: openCode success, others failed
        let error = NSError(domain: "test", code: 3)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .success,
            hermes: .failed(error),
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        // Then
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when openCode succeeded despite other failures")
    }

    func test_anySucceeded_onlyPi() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: .success,
            crush: Self.skipped
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_onlyCrush() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: .success
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_allSevenFail() {
        let error = NSError(domain: "test", code: 1)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .failed(error),
            hermes: .failed(error),
            grok: Self.skipped,
            pi: .failed(error),
            crush: .failed(error)
        )
        XCTAssertFalse(result.anySucceeded)
    }

    // MARK: - IPCConfigResult.anySucceeded (grok axis)

    func test_anySucceeded_onlyGrok() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: .success,
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertTrue(result.anySucceeded,
                      "A machine with Grok as its only agent CLI must still count as configured: " +
                      "anySucceeded gates whether the agent hooks get installed at all, so leaving grok " +
                      "out of it silently strands that machine with an MCP entry and no hooks")
    }

    func test_anySucceeded_grokFailedOthersSkipped() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: .failed(NSError(domain: "test", code: 6)),
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertFalse(result.anySucceeded, "A failure is not a success on the grok axis either")
    }

    func test_anySucceeded_grokSuccessOthersFailed() {
        let error = NSError(domain: "test", code: 7)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .failed(error),
            hermes: .failed(error),
            grok: .success,
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertTrue(result.anySucceeded)
    }

    // MARK: - IPCConfigResult.issueMessages

    func test_configIssueMessages_claudeCodeFailure_isReportedWithItsAxisName() {
        let result = IPCConfigResult(
            claudeCode: .failed(NSError(domain: "test", code: 20, userInfo: [NSLocalizedDescriptionKey: "boom"])),
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, ["Claude Code config: boom"],
                       "A failed Claude Code config write must reach the sidebar banner labeled by its own axis " +
                       "name, and the skipped axes around it must contribute no extra lines")
    }

    func test_configIssueMessages_codexFailure_isReportedWithItsAxisName() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: .failed(NSError(domain: "test", code: 21, userInfo: [NSLocalizedDescriptionKey: "boom"])),
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, ["Codex config: boom"],
                       "A failed Codex config write must reach the sidebar banner labeled by its own axis name")
    }

    func test_configIssueMessages_openCodeFailure_isReportedWithItsAxisName() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: .failed(NSError(domain: "test", code: 22, userInfo: [NSLocalizedDescriptionKey: "boom"])),
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, ["OpenCode config: boom"],
                       "A failed OpenCode config write must reach the sidebar banner labeled by its own axis name")
    }

    func test_configIssueMessages_hermesFailure_isReportedWithItsAxisName() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: .failed(NSError(domain: "test", code: 23, userInfo: [NSLocalizedDescriptionKey: "boom"])),
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, ["Hermes config: boom"],
                       "A failed Hermes config write must reach the sidebar banner labeled by its own axis name")
    }

    func test_configIssueMessages_grokFailure_isReportedWithItsAxisName() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: .failed(NSError(domain: "test", code: 24, userInfo: [NSLocalizedDescriptionKey: "boom"])),
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, ["Grok config: boom"],
                       "A failed Grok config write must reach the sidebar banner labeled by its own axis name")
    }

    func test_configIssueMessages_piFailure_isReportedWithItsAxisName() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: .failed(NSError(domain: "test", code: 30, userInfo: [NSLocalizedDescriptionKey: "boom"])),
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, ["pi config: boom"],
                       "A failed pi config write must reach the sidebar banner labeled by its own axis name")
    }

    func test_configIssueMessages_crushFailure_isReportedWithItsAxisName() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: .failed(NSError(domain: "test", code: 31, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        )

        XCTAssertEqual(result.issueMessages, ["Crush config: boom"],
                       "A failed Crush config write must reach the sidebar banner labeled by its own axis name")
    }

    func test_configIssueMessages_nothingFailed_isEmpty() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, [], "A mix of success and skipped axes with no failures must raise no banner at all")
    }

    func test_configIssueMessages_multipleFailures_includesALineForEachFailedAxis() {
        let claudeError = NSError(domain: "test", code: 25, userInfo: [NSLocalizedDescriptionKey: "claude boom"])
        let grokError = NSError(domain: "test", code: 26, userInfo: [NSLocalizedDescriptionKey: "grok boom"])
        let result = IPCConfigResult(
            claudeCode: .failed(claudeError),
            codex: Self.skipped,
            openCode: .success,
            hermes: Self.skipped,
            grok: .failed(grokError),
            pi: Self.skipped,
            crush: Self.skipped
        )

        XCTAssertEqual(result.issueMessages.count, 2,
                       "Two failed axes must produce exactly two lines, one per axis, not a single merged line")
        XCTAssertTrue(result.issueMessages.contains("Claude Code config: claude boom"),
                      "Every failed axis must contribute its own line even when other axes also failed")
        XCTAssertTrue(result.issueMessages.contains("Grok config: grok boom"),
                      "Every failed axis must contribute its own line even when other axes also failed")
    }

    // MARK: - IPCConfigResult.axes

    func test_configResultAxes_coversEveryStoredProperty() {
        let result = configResult()

        XCTAssertEqual(result.axes.count, Mirror(reflecting: result).children.count,
                       "Every stored axis must appear in `axes`: anySucceeded, issueMessages and every alert line " +
                       "derive from it, so a stored property missing from `axes` silently stops counting toward " +
                       "whether the machine is wired and stops its own failures from ever reaching the sidebar banner")
    }

    // MARK: - AgentHooksResult.issueMessages (grok axis)

    func test_issueMessages_grokFailure_isReported() {
        let result = AgentHooksResult(
            claudeCode: .success,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: .failed(NSError(domain: "test", code: 8, userInfo: [NSLocalizedDescriptionKey: "boom"])),
            pi: Self.skipped
        )

        XCTAssertEqual(result.issueMessages, ["Grok hooks: boom"],
                       "A failed Grok hook install must reach the sidebar banner. Silence there is the " +
                       "worst outcome: the user sees a Grok pane with no row and no reason why")
    }

    func test_issueMessages_grokSuccess_addsNothing() {
        let result = AgentHooksResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: .success,
            pi: .success
        )

        XCTAssertEqual(result.issueMessages, [], "A clean install raises no banner")
    }

    // MARK: - AgentHooksResult.issueMessages (pi axis)

    /// pi reaches Calyx through exactly one axis: the extension file.
    /// There is no MCP client config to fall back on, so a failed
    /// extension install means a pi pane is invisible to Calyx entirely,
    /// with nothing else on screen to reveal it. The label follows the
    /// same "<tool> <artifact>" scheme as "OpenCode plugin" and
    /// "Grok hooks", and matches the status line the IPC alert shows.
    func test_issueMessages_piFailure_isReported_andACleanPiInstallAddsNothing() {
        let failed = AgentHooksResult(
            claudeCode: .success,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: Self.skipped,
            pi: .failed(NSError(domain: "test", code: 9, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        )

        XCTAssertEqual(failed.issueMessages, ["pi extension: boom"],
                       "A failed pi extension install must reach the sidebar banner")

        let clean = AgentHooksResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: Self.skipped,
            pi: .success
        )

        XCTAssertEqual(clean.issueMessages, [],
                       "A successful pi install must not raise a banner of its own")
    }

    // MARK: - AgentHooksResult.anySucceeded

    func test_hooksAnySucceeded_onlyPiSuccess_isTrue() {
        // Given: pi is the only axis without an IPCConfigResult counterpart;
        // this is the exact case that makes a pi-only machine count as wired.
        let result = AgentHooksResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: Self.skipped,
            pi: .success
        )

        XCTAssertTrue(result.anySucceeded,
                      "A pi-only machine has no IPCConfigResult axis at all, so AgentHooksResult.anySucceeded is the " +
                      "only signal deciding whether it counts as wired. Missing pi here strands every pi-only machine")
    }

    func test_hooksAnySucceeded_onlyClaudeCodeSuccess_isTrue() {
        let result = AgentHooksResult(
            claudeCode: .success,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped
        )

        XCTAssertTrue(result.anySucceeded, "anySucceeded must return true when only Claude Code hooks succeeded")
    }

    func test_hooksAnySucceeded_onlyCodexSuccess_isTrue() {
        let result = AgentHooksResult(
            claudeCode: Self.skipped,
            codex: .success,
            openCode: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped
        )

        XCTAssertTrue(result.anySucceeded, "anySucceeded must return true when only Codex hooks succeeded")
    }

    func test_hooksAnySucceeded_onlyOpenCodeSuccess_isTrue() {
        let result = AgentHooksResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: .success,
            grok: Self.skipped,
            pi: Self.skipped
        )

        XCTAssertTrue(result.anySucceeded, "anySucceeded must return true when only the OpenCode plugin succeeded")
    }

    func test_hooksAnySucceeded_onlyGrokSuccess_isTrue() {
        let result = AgentHooksResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: .success,
            pi: Self.skipped
        )

        XCTAssertTrue(result.anySucceeded, "anySucceeded must return true when only Grok hooks succeeded")
    }

    func test_hooksAnySucceeded_allSkipped_isFalse() {
        let result = AgentHooksResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped
        )

        XCTAssertFalse(result.anySucceeded, "anySucceeded must return false when every axis, pi included, is skipped")
    }

    func test_hooksAnySucceeded_mixOfSkippedAndFailed_isFalse() {
        let result = AgentHooksResult(
            claudeCode: .failed(NSError(domain: "test", code: 27)),
            codex: Self.skipped,
            openCode: .failed(NSError(domain: "test", code: 28)),
            grok: Self.skipped,
            pi: .failed(NSError(domain: "test", code: 29))
        )

        XCTAssertFalse(result.anySucceeded,
                       "A failure is not a success on any axis: a mix of skipped and failed must never read as wired")
    }

    // MARK: - AgentHooksResult.axes

    func test_hooksResultAxes_coversEveryStoredProperty() {
        let result = hooksResult()

        XCTAssertEqual(result.axes.count, Mirror(reflecting: result).children.count,
                       "Every stored axis, pi included, must appear in `axes`: anySucceeded, issueMessages and " +
                       "every alert line derive from it, so a stored property missing from `axes` silently stops " +
                       "counting toward whether the machine is wired and stops its own failures from ever reaching " +
                       "the sidebar banner")
    }

    // MARK: - ConfigStatus pattern matching

    func test_configStatus_success() {
        let status: ConfigStatus = .success
        if case .success = status {
            // pass
        } else {
            XCTFail("Expected .success")
        }
    }

    func test_configStatus_skipped() {
        let status: ConfigStatus = .skipped(reason: "not installed")
        if case .skipped(let reason) = status {
            XCTAssertEqual(reason, "not installed")
        } else {
            XCTFail("Expected .skipped")
        }
    }

    func test_configStatus_failed() {
        let error = NSError(domain: "test", code: 42)
        let status: ConfigStatus = .failed(error)
        if case .failed(let err) = status {
            XCTAssertEqual((err as NSError).code, 42)
        } else {
            XCTFail("Expected .failed")
        }
    }

    // MARK: - allSevenSkipped

    func test_allSevenSkipped_isFalse() {
        let result = IPCConfigResult(
            claudeCode: Self.skipped,
            codex: Self.skipped,
            openCode: Self.skipped,
            hermes: Self.skipped,
            grok: Self.skipped,
            pi: Self.skipped,
            crush: Self.skipped
        )
        XCTAssertFalse(result.anySucceeded)
    }
}
