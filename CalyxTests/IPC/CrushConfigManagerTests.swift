import XCTest
@testable import Calyx

/// Tests for `CrushConfigManager`.
///
/// Coverage:
/// - `enableIPC` upserts a `calyx-ipc` MCP entry in `crush.json`
/// - `disableIPC` removes the entry, drops empty `mcp` key
/// - `isIPCEnabled` detection
/// - Security: symlink rejection
/// - Edge cases: missing files, invalid JSON, preserves other entries
final class CrushConfigManagerTests: XCTestCase {

    private var configDir: String!
    private var crushJsonPath: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crush-" + UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        crushJsonPath = configDir + "/crush.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: configDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeCrushJSON(_ content: String) {
        FileManager.default.createFile(atPath: crushJsonPath, contents: Data(content.utf8))
    }

    private func readCrushDict() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: crushJsonPath))
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    // MARK: - enableIPC

    func test_enableIPC_createsCrushJSONFromScratch() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: crushJsonPath))

        try CrushConfigManager.enableIPC(port: 41830, token: "abc123", configDir: configDir)

        let dict = try readCrushDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNotNil(mcp, "mcp key should exist")

        let calyxIPC = mcp?["calyx-ipc"] as? [String: Any]
        XCTAssertNotNil(calyxIPC)
        XCTAssertEqual(calyxIPC?["type"] as? String, "http")
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://localhost:41830/mcp")

        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer abc123")
    }

    func test_enableIPC_preservesOtherMCPServers() throws {
        let existing = """
        {
            "mcp": {
                "other-server": {
                    "type": "http",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeCrushJSON(existing)

        try CrushConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir)

        let dict = try readCrushDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNotNil(mcp?["other-server"], "other-server preserved")
        XCTAssertNotNil(mcp?["calyx-ipc"], "calyx-ipc added")
    }

    func test_enableIPC_preservesOtherTopLevelKeys() throws {
        let existing = """
        {
            "theme": "dark",
            "model": "claude-sonnet",
            "mcp": {}
        }
        """
        writeCrushJSON(existing)

        try CrushConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir)

        let dict = try readCrushDict()
        XCTAssertEqual(dict["theme"] as? String, "dark")
        XCTAssertEqual(dict["model"] as? String, "claude-sonnet")
    }

    func test_enableIPC_upsertsExistingCalyxEntry() throws {
        let existing = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:40000/mcp",
                    "headers": {
                        "Authorization": "Bearer old-token"
                    }
                }
            }
        }
        """
        writeCrushJSON(existing)

        try CrushConfigManager.enableIPC(port: 55555, token: "new-token", configDir: configDir)

        let dict = try readCrushDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertEqual(mcp?.count, 1, "no duplicates")

        let calyxIPC = mcp?["calyx-ipc"] as? [String: Any]
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://localhost:55555/mcp")
        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer new-token")
        XCTAssertEqual(headers?.count, 1)
    }

    // MARK: - disableIPC

    func test_disableIPC_removesCalyxEntry() throws {
        let existing = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:41830/mcp",
                    "headers": { "Authorization": "Bearer tok" }
                },
                "other-server": {
                    "type": "http",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeCrushJSON(existing)

        try CrushConfigManager.disableIPC(configDir: configDir)

        let dict = try readCrushDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNil(mcp?["calyx-ipc"], "calyx-ipc removed")
        XCTAssertNotNil(mcp?["other-server"], "other-server preserved")
    }

    func test_disableIPC_removesMcpKeyIfEmpty() throws {
        let existing = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:41830/mcp",
                    "headers": { "Authorization": "Bearer tok" }
                }
            },
            "theme": "dark"
        }
        """
        writeCrushJSON(existing)

        try CrushConfigManager.disableIPC(configDir: configDir)

        let dict = try readCrushDict()
        XCTAssertNil(dict["mcp"], "mcp key removed when empty")
        XCTAssertEqual(dict["theme"] as? String, "dark")
    }

    func test_disableIPC_noFile_noOp() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: crushJsonPath))
        XCTAssertNoThrow(try CrushConfigManager.disableIPC(configDir: configDir))
    }

    // MARK: - Security

    func test_enableIPC_symlinkRejected() throws {
        let realFile = configDir + "/real_crush.json"
        writeCrushJSON("{}")
        try FileManager.default.moveItem(atPath: crushJsonPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: crushJsonPath, withDestinationPath: realFile)

        XCTAssertThrowsError(try CrushConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir))
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueWhenPresent() {
        let existing = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:41830/mcp",
                    "headers": { "Authorization": "Bearer tok" }
                }
            }
        }
        """
        writeCrushJSON(existing)
        XCTAssertTrue(CrushConfigManager.isIPCEnabled(configDir: configDir))
    }

    func test_isIPCEnabled_falseWhenAbsent() {
        writeCrushJSON("{\"mcp\": {\"other\": {}}}")
        XCTAssertFalse(CrushConfigManager.isIPCEnabled(configDir: configDir))
    }

    func test_isIPCEnabled_falseWhenNoFile() {
        XCTAssertFalse(CrushConfigManager.isIPCEnabled(configDir: configDir))
    }
}