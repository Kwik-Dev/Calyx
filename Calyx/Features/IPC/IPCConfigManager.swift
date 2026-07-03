// IPCConfigManager.swift
// Calyx
//
// Coordinates IPC config registration across Claude Code, Codex, OpenCode,
<<<<<<< New base: Add Crush IPC issue to handoff
// Hermes, and Grok, collecting results independently so one failure does not
// block the others.
||||||| Common ancestor
// and Hermes, collecting results independently so one failure does not block
// the others.
=======
// Hermes, pi, and Crush, collecting results independently so one failure
// does not block the others.
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M

import Foundation

// MARK: - ConfigStatus

enum ConfigStatus: Sendable {
    case success
    case skipped(reason: String)
    case failed(Error)
}

// MARK: - IPCConfigResult

struct IPCConfigResult: Sendable {
    let claudeCode: ConfigStatus
    let codex: ConfigStatus
    let openCode: ConfigStatus
    let hermes: ConfigStatus
<<<<<<< New base: Add Crush IPC issue to handoff
    let grok: ConfigStatus

    /// Every axis paired with the label the alert renders for it, in
    /// print order. `anySucceeded` and `issueMessages` both derive from
    /// this, and so does `IPCActivationPresenter`'s rendering of this
    /// result -- a newly supported agent CLI is added here once, not
    /// separately in each of those.
    var axes: [(name: String, status: ConfigStatus)] {
        [
            ("Claude Code config", claudeCode),
            ("Codex config", codex),
            ("OpenCode config", openCode),
            ("Hermes config", hermes),
            ("Grok config", grok),
        ]
    }
||||||| Common ancestor
=======
    let pi: ConfigStatus
    let crush: ConfigStatus
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M

    var anySucceeded: Bool {
<<<<<<< New base: Add Crush IPC issue to handoff
        for axis in axes {
            if case .success = axis.status { return true }
        }
||||||| Common ancestor
        if case .success = claudeCode { return true }
        if case .success = codex { return true }
        if case .success = openCode { return true }
        if case .success = hermes { return true }
=======
        if case .success = claudeCode { return true }
        if case .success = codex { return true }
        if case .success = openCode { return true }
        if case .success = hermes { return true }
        if case .success = pi { return true }
        if case .success = crush { return true }
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
        return false
    }

    /// One `"<name>: <localizedDescription>"` line per `.failed` axis.
    /// `[]` when no axis failed. Mirrors `AgentHooksResult.issueMessages`.
    var issueMessages: [String] {
        axes.compactMap { name, status in
            guard case .failed(let error) = status else { return nil }
            return "\(name): \(error.localizedDescription)"
        }
    }
}

// MARK: - IPCConfigManager

struct IPCConfigManager: Sendable {

    // MARK: - Public API

    /// Enables IPC MCP server config in Claude Code, Codex, OpenCode, Hermes, and Grok config files.
    /// Each tool is handled independently — one failing does not prevent the others.
    static func enableIPC(port: Int, token: String) -> IPCConfigResult {
        let claudeCode = enableClaudeCode(port: port, token: token)
        let codex = enableCodex(port: port, token: token)
        let openCode = enableOpenCode(port: port, token: token)
        let hermes = enableHermes(port: port, token: token)
<<<<<<< New base: Add Crush IPC issue to handoff
        let grok = enableGrok(port: port, token: token)
||||||| Common ancestor
=======
        let pi = enablePi()
        let crush = enableCrush(port: port, token: token)
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
        return IPCConfigResult(
            claudeCode: claudeCode,
            codex: codex,
            openCode: openCode,
<<<<<<< New base: Add Crush IPC issue to handoff
            hermes: hermes,
            grok: grok
||||||| Common ancestor
            hermes: hermes
=======
            hermes: hermes,
            pi: pi,
            crush: crush
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
        )
    }

    /// Disables IPC MCP server config in Claude Code, Codex, OpenCode, Hermes, and Grok config files.
    /// Does not check directory existence — the individual managers handle missing files as no-ops.
    static func disableIPC() -> IPCConfigResult {
        let claudeCode = disableClaudeCode()
        let codex = disableCodex()
        let openCode = disableOpenCode()
        let hermes = disableHermes()
<<<<<<< New base: Add Crush IPC issue to handoff
        let grok = disableGrok()
||||||| Common ancestor
=======
        let pi = disablePi()
        let crush = disableCrush()
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
        return IPCConfigResult(
            claudeCode: claudeCode,
            codex: codex,
            openCode: openCode,
<<<<<<< New base: Add Crush IPC issue to handoff
            hermes: hermes,
            grok: grok
||||||| Common ancestor
            hermes: hermes
=======
            hermes: hermes,
            pi: pi,
            crush: crush
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
        )
    }

    /// Returns whether IPC is currently enabled in each tool's config.
<<<<<<< New base: Add Crush IPC issue to handoff
    static func isIPCEnabled() -> (claudeCode: Bool, codex: Bool, openCode: Bool, hermes: Bool, grok: Bool) {
||||||| Common ancestor
    static func isIPCEnabled() -> (claudeCode: Bool, codex: Bool, openCode: Bool, hermes: Bool) {
=======
    static func isIPCEnabled() -> (claudeCode: Bool, codex: Bool, openCode: Bool, hermes: Bool, pi: Bool, crush: Bool) {
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
        (
            claudeCode: ClaudeConfigManager.isIPCEnabled(),
            codex: CodexConfigManager.isIPCEnabled(),
            openCode: OpenCodeConfigManager.isIPCEnabled(),
<<<<<<< New base: Add Crush IPC issue to handoff
            hermes: HermesConfigManager.isIPCEnabled(),
            grok: GrokConfigManager.isIPCEnabled()
||||||| Common ancestor
            hermes: HermesConfigManager.isIPCEnabled()
=======
            hermes: HermesConfigManager.isIPCEnabled(),
            pi: PiConfigManager.isIPCEnabled(),
            crush: CrushConfigManager.isIPCEnabled()
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
        )
    }

    // MARK: - Private: Claude Code

    private static func enableClaudeCode(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.claudeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try ClaudeConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableClaudeCode() -> ConfigStatus {
        do {
            try ClaudeConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Codex

    private static func enableCodex(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.codexConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try CodexConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableCodex() -> ConfigStatus {
        do {
            try CodexConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: OpenCode

    private static func enableOpenCode(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.openCodeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try OpenCodeConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableOpenCode() -> ConfigStatus {
        do {
            try OpenCodeConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Hermes

    private static func enableHermes(port: Int, token: String) -> ConfigStatus {
        let hermesDir = NSHomeDirectory() + "/.hermes/"
        guard ConfigFileUtils.directoryExists(at: hermesDir) else {
            return .skipped(reason: "not installed")
        }
        do {
            try HermesConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableHermes() -> ConfigStatus {
        do {
            try HermesConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }
<<<<<<< New base: Add Crush IPC issue to handoff

    // MARK: - Private: Grok

    private static func enableGrok(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.grokConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try GrokConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableGrok() -> ConfigStatus {
        do {
            try GrokConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }
||||||| Common ancestor
=======

    // MARK: - Private: pi

    private static func enablePi() -> ConfigStatus {
        let piDir = NSHomeDirectory() + "/.pi/agent/skills"
        guard directoryExists(at: piDir) else {
            return .skipped(reason: "not installed")
        }
        do {
            try PiConfigManager.enableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disablePi() -> ConfigStatus {
        do {
            try PiConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Crush

    private static func enableCrush(port: Int, token: String) -> ConfigStatus {
        // Detect Crush like other agents: by the presence of its config directory.
        // This avoids relying on PATH, which may not include Homebrew/bin when
        // Calyx is launched from the GUI.
        let crushDir = NSHomeDirectory() + "/.config/crush"
        guard directoryExists(at: crushDir) else {
            return .skipped(reason: "not installed")
        }
        do {
            try CrushConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableCrush() -> ConfigStatus {
        do {
            try CrushConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    /// Checks that a path exists and is a directory (not a file).
    private static func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
>>>>>>> Current commit: feat(ipc): add Crush & pi support and docs updatesIntroduce native Crush agent M
}
