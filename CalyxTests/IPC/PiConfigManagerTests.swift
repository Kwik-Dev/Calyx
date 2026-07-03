import XCTest
@testable import Calyx

/// Tests for `PiConfigManager`.
///
/// Coverage:
/// - `enableIPC` creates a skill directory with SKILL.md
/// - `disableIPC` removes the skill directory
/// - `isIPCEnabled` detection
/// - Security: symlink rejection
/// - Edge cases: missing pi skills dir (skipped), idempotent re-enable
final class PiConfigManagerTests: XCTestCase {

    private var skillsDir: String!

    private let beginDelimiter = "<!-- BEGIN CALYX IPC"
    private let endDelimiter = "<!-- END CALYX IPC -->"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        skillsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-skills-" + UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: skillsDir)
        super.tearDown()
    }

    private var skillDir: String { skillsDir + "/calyx-ipc" }
    private var skillFile: String { skillDir + "/SKILL.md" }

    // MARK: - enableIPC

    func test_enableIPC_createsSkillDirectoryAndFile() throws {
        // When
        try PiConfigManager.enableIPC(skillsDir: skillsDir)

        // Then
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDir), "skill directory should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile), "SKILL.md should exist")

        let content = try String(contentsOfFile: skillFile, encoding: .utf8)
        XCTAssertTrue(content.contains(beginDelimiter), "SKILL.md should contain BEGIN marker")
        XCTAssertTrue(content.contains(endDelimiter), "SKILL.md should contain END marker")
        XCTAssertTrue(content.contains("calyx ipc register-peer"), "SKILL.md should mention calyx ipc")
        XCTAssertTrue(content.contains("Install CLI to PATH"), "SKILL.md should reference CLI install")
    }

    func test_enableIPC_idempotent() throws {
        // When: enable twice
        try PiConfigManager.enableIPC(skillsDir: skillsDir)
        try PiConfigManager.enableIPC(skillsDir: skillsDir)

        // Then: still exactly one skill file
        let content = try String(contentsOfFile: skillFile, encoding: .utf8)
        let beginCount = content.components(separatedBy: beginDelimiter).count - 1
        let endCount = content.components(separatedBy: endDelimiter).count - 1
        XCTAssertEqual(beginCount, 1, "exactly one BEGIN marker")
        XCTAssertEqual(endCount, 1, "exactly one END marker")
    }

    func test_enableIPC_replacesStaleSkillDir() throws {
        // Given: an existing skill dir with old content
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: false)
        let oldContent = "\(beginDelimiter)\nOld stale body\n\(endDelimiter)\n"
        let oldData = oldContent.data(using: .utf8)!
        try oldData.write(to: URL(fileURLWithPath: skillFile))

        // When
        try PiConfigManager.enableIPC(skillsDir: skillsDir)

        // Then: content is fresh (not the old stale body)
        let content = try String(contentsOfFile: skillFile, encoding: .utf8)
        XCTAssertFalse(content.contains("Old stale body"), "stale body should be replaced")
        XCTAssertTrue(content.contains("calyx ipc"), "fresh body should be present")
    }

    // MARK: - disableIPC

    func test_disableIPC_removesSkillDirectory() throws {
        // Given
        try PiConfigManager.enableIPC(skillsDir: skillsDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillDir))

        // When
        try PiConfigManager.disableIPC(skillsDir: skillsDir)

        // Then
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillDir), "skill dir should be removed")
    }

    func test_disableIPC_noDir_noOp() throws {
        // Given: no skill dir
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillDir))

        // When/Then: no throw
        XCTAssertNoThrow(try PiConfigManager.disableIPC(skillsDir: skillsDir))
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueAfterEnable() throws {
        try PiConfigManager.enableIPC(skillsDir: skillsDir)
        XCTAssertTrue(PiConfigManager.isIPCEnabled(skillsDir: skillsDir))
    }

    func test_isIPCEnabled_falseBeforeEnable() {
        XCTAssertFalse(PiConfigManager.isIPCEnabled(skillsDir: skillsDir))
    }

    func test_isIPCEnabled_falseAfterDisable() throws {
        try PiConfigManager.enableIPC(skillsDir: skillsDir)
        try PiConfigManager.disableIPC(skillsDir: skillsDir)
        XCTAssertFalse(PiConfigManager.isIPCEnabled(skillsDir: skillsDir))
    }

    // MARK: - Security

    func test_enableIPC_symlinkSkillDirRejected() throws {
        // Given: skill dir path is a symlink to a real dir
        let realDir = skillsDir + "/real-skill"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: skillDir, withDestinationPath: realDir)

        // When/Then
        XCTAssertThrowsError(try PiConfigManager.enableIPC(skillsDir: skillsDir))
    }

    func test_enableIPC_symlinkSkillFileRejected() throws {
        // Given: SKILL.md is a symlink
        try FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: false)
        let realFile = skillsDir + "/real-skill.md"
        try "# test".write(toFile: realFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: skillFile, withDestinationPath: realFile)

        // When/Then
        XCTAssertThrowsError(try PiConfigManager.enableIPC(skillsDir: skillsDir))
    }
}